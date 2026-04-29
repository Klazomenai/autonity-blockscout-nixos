# NixOS service module for the Blockscout backend (Elixir/Phoenix API
# + indexer). This is the cross-service module where the plumbing
# established by autonity.nix, blockscout-postgresql.nix, and
# blockscout-redis.nix finally comes together.
#
# Cross-service contract:
#   - PostgreSQL: TCP-localhost connection on `databaseHost:databasePort`
#     (default `localhost:5432`, matching the `blockscout-postgresql`
#     wrapper's `listen_addresses = "localhost"` default). Auth is
#     password-based via the standard nixpkgs pg_hba.conf
#     `host all all 127.0.0.1/32 scram-sha-256` rule; the role's
#     password is set by `blockscout-postgresql` during the
#     `postgresql-setup.service` one-shot unit (it appends `ALTER
#     ROLE … WITH PASSWORD …` to
#     `systemd.services.postgresql-setup.script`, NOT to
#     `postgresql.service.postStart` — nixpkgs creates the role
#     inside the setup unit, so that's where the password change has
#     to land), and the matching `databasePasswordFile` here drives
#     `LoadCredential=` ingestion + percent-encoded URL composition in
#     the ExecStart wrapper.
#     UNIX-socket connections were attempted in earlier drafts but
#     are NOT supported: Blockscout's
#     `Explorer.Repo.ConfigHelper.extract_parameters/1` requires a
#     `user:pass@host:port/db` URL form and Postgrex parses URL
#     host/port for the actual TCP connect, ignoring libpq's
#     `?host=` query parameter for socket overrides.
#   - Redis: TCP-localhost connection on `redisHost:redisPort`
#     (default `127.0.0.1:6379`, matching the `blockscout-redis`
#     wrapper's `bind = "127.0.0.1"` default byte-for-byte). The
#     IPv4 literal is preferred over the `localhost` name because
#     the wrapper binds IPv4 loopback only, and dual-stack glibc /
#     nss-resolve setups can return `::1` first for `localhost`.
#     Blockscout's Redix
#     client uses `Redix.URI.to_start_options/1` which only accepts
#     `redis://`, `valkey://`, and `rediss://` URL schemes — UNIX
#     sockets via `unix:///path` URIs are rejected at startup with
#     `ArgumentError`, the same shape as the Postgrex limitation
#     above (and an earlier draft of this module attempted UNIX
#     sockets here too before that fact surfaced). No authentication
#     is configured on the loopback Redis instance; loopback binding
#     is the auth boundary.
#   - Autonity: connects via loopback TCP to 127.0.0.1:8545 (http),
#     8546 (ws); the Autonity module binds loopback-only on those
#     ports by default.
#   - Secrets: every secret-holding env var (SECRET_KEY_BASE plus each
#     `secretEnvFiles` entry) is ingested via systemd `LoadCredential=`
#     — the service reads each value from `$CREDENTIALS_DIRECTORY/<NAME>`
#     at ExecStart time and `export`s it into the process environment
#     via the `blockscout-start` shell wrapper. Secret values never
#     touch the Nix store, EnvironmentFile, or the unit file.
#   - Static env: passed via `systemd.services.*.environment` (direct
#     systemd `Environment=` entries), not via an EnvironmentFile. This
#     side-steps the EnvironmentFile mechanism's unit-start-time load
#     ordering (EnvironmentFile is read BEFORE ExecStartPre, so a
#     dynamically-composed env file wouldn't be seen) and its format /
#     shell-parsing ambiguity.
#
# The `klazomenai/blockscout` flake is wired into pkgs via a
# nixpkgs.overlays entry on the glue-repo's nixosModules.default (see
# ../flake.nix), so `pkgs.blockscout` resolves to the mixRelease.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.blockscout-backend;
  inherit (lib)
    mkEnableOption
    mkOption
    mkPackageOption
    mkIf
    mkBefore
    types
    concatMapStringsSep
    mapAttrsToList
    optional
    optionalString
    literalExpression
    ;

  # Env-var-name regex — used to assert that every `secretEnvFiles`
  # key is a valid POSIX env var name. Enforced at `config.assertions`
  # time rather than via the submodule's `name` because submodule
  # naming happens at a later pass in the module system; an assertion
  # gives a clearer error message pointing at the exact offending key.
  envVarNameRegex = "^[A-Z_][A-Z0-9_]*$";

  # Loopback-host predicates. When `databaseHost` / `redisHost` point
  # at a loopback name, the corresponding upstream data-plane unit
  # lives on this same host and the backend SHOULD `Requires=`/
  # `After=` it. When they point at a remote hostname there is no
  # local unit for systemd to order against, and an unconditional
  # ordering would fail unit start the moment the operator disables
  # the local wrapper. So we gate the unit ordering on these
  # predicates rather than hard-coding it.
  #
  # `localhost` covers IPv4 and IPv6 loopback via /etc/hosts;
  # `127.0.0.1` is the IPv4 literal. The host regex on
  # `databaseHost` / `redisHost` is `^[a-zA-Z0-9.-]+$` — it forbids
  # the `:` character so IPv6 literals such as `::1` cannot be
  # configured against this option type, and including them in this
  # set would be unreachable defensive code. Widening the regex to
  # accept `[`/`]`-bracketed IPv6 literals would also require
  # changing the DATABASE_URL composition path; leave that for a
  # later IPv6-support pass if a real deployment needs it.
  loopbackHosts = [
    "localhost"
    "127.0.0.1"
  ];
  postgresLocal = lib.elem cfg.databaseHost loopbackHosts;
  redisLocal = lib.elem cfg.redisHost loopbackHosts;

  # Bash wrapper that exports each LoadCredential-sourced secret into
  # the process environment, optionally runs the migration, then execs
  # the main server. Static env vars are provided by systemd's
  # `Environment=` mechanism (see `systemd.services.*.environment`
  # below); only secrets flow through this wrapper.
  #
  # Why a wrapper rather than an EnvironmentFile? EnvironmentFile is
  # loaded by systemd at unit activation, BEFORE any ExecStartPre runs
  # — so an env file composed during ExecStartPre would never be seen
  # by ExecStart. The wrapper reads credentials at the moment
  # ExecStart fires, which is the only reliable point by which
  # LoadCredential has populated $CREDENTIALS_DIRECTORY.
  startScript = pkgs.writeShellScript "blockscout-start" ''
    set -eu

    # Defence-in-depth: anchor CWD at the release root before any
    # work. systemd's `WorkingDirectory=` directive on the unit is
    # the canonical mechanism (and is set in serviceConfig below),
    # but adding the cd here too guards against any intermediate
    # process layer that might silently override CWD. Required
    # because `config/runtime.exs` line 1732 uses CWD-relative
    # `Code.require_file` to load `config/runtime/<env>.exs` —
    # crashes the release at Config.Reader stage if CWD isn't the
    # release root.
    cd "${cfg.package}"

    # HOME points at the StateDirectory. BEAM's `Mix.start/2` calls
    # `Mix.Local.append_archives/0` → `Mix.path_for(:archives)` →
    # `Path.expand("~/.mix/...")` → `System.user_home!/0`. With
    # `DynamicUser=true` + `ProtectHome=true`, the dynamic user has
    # no /home/<user> entry and System.user_home!/0 raises
    # `RuntimeError: could not find the user home`. The
    # StateDirectory ($STATE_DIRECTORY = /var/lib/private/<name>
    # under DynamicUser) is writable by the unit's user and
    # persisted across restarts, so it's the right HOME for
    # Mix.Local's archive directory.
    export HOME="$STATE_DIRECTORY"

    # $(cat …) captures the credential file's bytes verbatim. Bash
    # variable assignment does not re-expand `$` / backticks in the
    # value, so secrets containing shell metacharacters are preserved
    # literally. Each credential file is expected to contain a single
    # value with no trailing content beyond an optional final newline
    # (bash command substitution strips trailing newlines).
    export SECRET_KEY_BASE="$(cat "$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE")"

    # DATABASE_URL composition with URL-encoded password. The
    # password is read from $CREDENTIALS_DIRECTORY (populated by
    # LoadCredential=DATABASE_PASSWORD via cfg.databasePasswordFile),
    # then percent-encoded byte-by-byte so that any of `: @ / ? # %`
    # in the password value doesn't break the URL parser. Composed
    # at exec time (not via systemd's Environment= directives) so the
    # password value never lands in the unit file or Nix store —
    # same secret-handling contract as SECRET_KEY_BASE above.
    #
    # Blockscout's Ecto layer (`Explorer.Repo.ConfigHelper.
    # extract_parameters/1`) requires URL form
    # `user:pass@host:port/db` and parses `host:port` for the actual
    # TCP connect — libpq's `?host=` query parameter for UNIX-socket
    # overrides is NOT honoured. So `databaseHost` is always treated
    # as a TCP host (loopback or remote), never as a socket path.
    db_password_raw=$(cat "$CREDENTIALS_DIRECTORY/DATABASE_PASSWORD")
    db_password_enc=$(
      LC_ALL=C
      out=""
      i=0
      len=''${#db_password_raw}
      while [ $i -lt $len ]; do
        c=''${db_password_raw:$i:1}
        case "$c" in
          [a-zA-Z0-9._~-]) out="$out$c" ;;
          *) out="$out$(printf '%%%02X' "'$c")" ;;
        esac
        i=$((i + 1))
      done
      printf '%s' "$out"
    )
    export DATABASE_URL="postgres://${cfg.databaseUser}:''${db_password_enc}@${cfg.databaseHost}:${toString cfg.databasePort}/${cfg.databaseName}"
    export ACCOUNT_DATABASE_URL="$DATABASE_URL"
    unset db_password_raw db_password_enc

    # RELEASE_COOKIE precedence (highest → lowest):
    #   1. `cookieFile` (operator-supplied, non-null) — systemd
    #      ingested it into $CREDENTIALS_DIRECTORY/RELEASE_COOKIE via
    #      LoadCredential=. Always wins, even if `extraEnv` also sets
    #      RELEASE_COOKIE; the file is the more deliberate of the two
    #      paths and `cookieFile` is documented as authoritative.
    #   2. Operator-supplied via `extraEnv.RELEASE_COOKIE` (or any
    #      other path that reaches systemd `Environment=`). Honoured
    #      via the `[ -z "''${RELEASE_COOKIE:-}" ]` check below — we
    #      only generate a value when nothing is in the env yet. This
    #      preserves the module-wide rule that `extraEnv` is the
    #      operator's escape hatch.
    #   3. Random per-restart fallback via `openssl rand -hex 24`.
    #      Fine for single-node deployments where no external Erlang
    #      node ever connects — for clustering the operator MUST
    #      supply `cookieFile` (or set `extraEnv.RELEASE_COOKIE`) so
    #      all nodes agree.
    #
    # `-hex 24` (48 hex chars) chosen over `-base64 24` because the
    # base64 alphabet includes `+`, `/`, and `=` which can interact
    # poorly with the elixir release wrapper's argument-quoting
    # under specific systemd-environment conditions: an earlier
    # base64 cookie would reach `beam.smp` with the leading `-` of
    # `-setcookie` somehow dropped, leaving the cookie value as a
    # positional flag (`unknown flag -<base64-value>` panic). Hex
    # encoding sidesteps that entirely — `[0-9a-f]` survives any
    # shell / wrapper arg-parsing path.
    ${
      if cfg.cookieFile != null then
        ''export RELEASE_COOKIE="$(cat "$CREDENTIALS_DIRECTORY/RELEASE_COOKIE")"''
      else
        ''
          if [ -z "''${RELEASE_COOKIE:-}" ]; then
            export RELEASE_COOKIE="$(${pkgs.openssl}/bin/openssl rand -hex 24)"
          fi
        ''
    }

    ${concatMapStringsSep "\n    " (name: ''
      export ${name}="$(cat "$CREDENTIALS_DIRECTORY/${name}")"
    '') (lib.attrNames cfg.secretEnvFiles)}
    ${optionalString cfg.autoMigrate ''
      # Module name is `Explorer.ReleaseTasks`, NOT `Explorer.Release`
      # — the fork ships the standard upstream-Blockscout
      # release-tasks helper at apps/explorer/lib/release_tasks.ex,
      # which `defmodule`s as `Explorer.ReleaseTasks`. The function is
      # `migrate/1` taking an unused `_argv` argument; `[]` is the
      # canonical "no argv" placeholder. Older Blockscout docs/issues
      # sometimes reference `Explorer.Release` (no -Tasks suffix);
      # that's a different module name from a different era and is
      # not what this fork ships.
      ${cfg.package}/bin/blockscout eval 'Explorer.ReleaseTasks.migrate([])'
    ''}
    ${optionalString (cfg.extraPostMigrate != "") ''
      # Operator-supplied post-migration SQL. Runs after
      # `Explorer.ReleaseTasks.migrate([])` (so any tables / columns
      # the SQL touches must already exist by then), and BEFORE
      # `${cfg.package}/bin/blockscout start` (so the BEAM supervisor
      # tree sees the resulting state when it boots).
      #
      # Logged at unit start so operators can see in journalctl that
      # a workaround / fixture was applied — bypassing migrations is
      # too easy to silently sneak past a maintenance review
      # otherwise.
      #
      # PGPASSWORD is exported via env (not argv — matches the
      # wrapper's secret-handling contract). Re-read from
      # $CREDENTIALS_DIRECTORY because $db_password_raw was unset
      # above to limit the in-memory exposure window.
      echo "blockscout-backend: applying services.blockscout-backend.extraPostMigrate SQL" >&2
      PGPASSWORD="$(cat "$CREDENTIALS_DIRECTORY/DATABASE_PASSWORD")" \
        ${pkgs.postgresql}/bin/psql \
        --host="${cfg.databaseHost}" \
        --port="${toString cfg.databasePort}" \
        --username="${cfg.databaseUser}" \
        --dbname="${cfg.databaseName}" \
        --no-psqlrc \
        -v ON_ERROR_STOP=1 \
        -f ${pkgs.writeText "blockscout-extra-post-migrate.sql" cfg.extraPostMigrate}
    ''}
    exec ${cfg.package}/bin/blockscout start
  '';

in
{
  options.services.blockscout-backend = {
    enable = mkEnableOption "the Blockscout Elixir/Phoenix backend (API + indexer)";

    package = mkPackageOption pkgs "blockscout" { };

    secretKeyBaseFile = mkOption {
      # types.str (not types.path) by design — Nix-path literals
      # (`./secret`) auto-copy into the world-readable /nix/store,
      # defeating the module's secrets contract. `types.str` accepts
      # path strings as-is; `config.assertions` below additionally
      # enforces that the value is absolute and not under /nix/store/.
      type = types.str;
      example = "/run/secrets/blockscout/secret_key_base";
      description = ''
        Absolute path to a file containing Phoenix `secret_key_base` —
        64+ bytes of random used to sign user sessions and verify CSRF
        tokens. Ingested via systemd `LoadCredential=SECRET_KEY_BASE=<path>`;
        the ExecStart wrapper reads from
        `$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE`, never from this
        source path. The file only needs to be readable by systemd
        (root at unit-start time), not by the `DynamicUser`-allocated
        UID.

        MUST be an absolute path NOT under `/nix/store/` — the
        module's secrets contract is that values never appear in the
        world-readable Nix store, so accidentally pointing this at a
        store path is a configuration error. Enforced via
        `config.assertions` at option-set time.
      '';
    };

    cookieFile = mkOption {
      # Same `types.str` rationale as `secretKeyBaseFile`.
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/blockscout/release_cookie";
      description = ''
        Absolute path to a file containing the BEAM release cookie —
        used as a shared-secret token authenticating distributed
        Erlang nodes to each other. Ingested via systemd
        `LoadCredential=RELEASE_COOKIE=<path>`; the ExecStart wrapper
        reads from `$CREDENTIALS_DIRECTORY/RELEASE_COOKIE`, never
        from this source path.

        nixpkgs' `mixRelease` deliberately deletes `releases/COOKIE`
        from the build output by default (`removeCookie = true`),
        treating cookies as secret. The release startup wrapper
        (`bin/.blockscout-wrapped`) falls back to
        `cat releases/COOKIE` when `RELEASE_COOKIE` env is unset —
        which produces a `cat: …/releases/COOKIE: No such file or
        directory` error and a permanent restart loop. So the
        operator (or this module) MUST provide `RELEASE_COOKIE`
        somehow.

        When this option is `null` (default), the module generates a
        random per-restart cookie inline in the ExecStart wrapper via
        `openssl rand -hex 24` (48 hex characters). The cookie lives
        only in the running BEAM process's environment — it is NOT
        persisted anywhere on disk. A new value is rolled on every
        restart of `blockscout-backend.service`; this is fine for
        single-node deployments where no external Erlang node ever
        connects to the BEAM distribution port.

        Hex (not base64) is deliberate: an earlier draft used
        `openssl rand -base64 24`, which produces values containing
        `+` / `/` / `=`. Under specific systemd-environment / release-
        wrapper argument-quoting paths, a leading `-` byte in the
        cookie or the `=` padding byte caused `beam.smp` to mis-parse
        `-setcookie <value>` and panic with `unknown flag …`. Hex
        digits round-trip cleanly through every shell / wrapper layer.

        For multi-node BEAM clustering, set `cookieFile` to a path
        sourced from sops-nix / agenix, with the same value across
        every node in the cluster.

        MUST be an absolute path NOT under `/nix/store/` (when
        non-null). Enforced via `config.assertions` at option-set
        time, same as `secretKeyBaseFile`.
      '';
    };

    databaseHost = mkOption {
      # Hostname-or-IPv4 shape — Blockscout's Ecto layer requires a
      # TCP-style URL `user:pass@host:port/db`, so this MUST resolve
      # to a TCP target; UNIX-socket paths are not supported. Local
      # postgres (the default `blockscout-postgresql` wrapper) listens
      # on `localhost`. Remote postgres uses the operator's hostname
      # or IP.
      type = types.strMatching "^[a-zA-Z0-9.-]+$";
      default = "localhost";
      description = ''
        TCP host for the PostgreSQL connection. The default
        `"localhost"` matches what the `blockscout-postgresql`
        wrapper listens on (`listen_addresses = "localhost"`).
        Override when pointing at a remote database host.

        UNIX-socket paths (e.g. `/run/postgresql`) are NOT supported.
        Blockscout's `Explorer.Repo.ConfigHelper.extract_parameters/1`
        parses the URL via a strict `user:pass@host:port/db` regex
        and Postgrex resolves `host:port` for the actual TCP
        connection without honouring libpq's `?host=` query parameter
        for UNIX-socket overrides. The strMatching regex enforces
        TCP-shape values at option-set time.
      '';
    };

    databasePort = mkOption {
      type = types.port;
      default = 5432;
      description = ''
        TCP port for the PostgreSQL connection. Default matches
        `services.blockscout-postgresql.port`'s default. Override
        both sides if the wrapper's port is changed.
      '';
    };

    databasePasswordFile = mkOption {
      # types.str (not types.path) — same Nix-store-leak rationale as
      # `secretKeyBaseFile`. Absolute-not-under-/nix/store/ enforced
      # via `config.assertions`.
      type = types.str;
      example = "/run/secrets/blockscout/db_password";
      description = ''
        Absolute path to a file containing the password for the
        `databaseUser` PostgreSQL role. Ingested via
        `LoadCredential=DATABASE_PASSWORD:<path>`; the ExecStart
        wrapper reads the value, percent-encodes it for safe URL
        embedding, and assembles `DATABASE_URL` at exec time. The
        password value never appears in the systemd unit file or the
        Nix store.

        The matching `services.blockscout-postgresql.passwordFile`
        should point at the SAME file so the role's password (set
        by the postgres wrapper's append to
        `systemd.services.postgresql-setup.script`) and the backend's
        connection password agree.

        MUST be an absolute path NOT under `/nix/store/` — the
        module's secrets contract is that values never appear in the
        world-readable Nix store. Enforced via `config.assertions`.
      '';
    };

    databaseName = mkOption {
      # SQL identifier regex — letters, digits, underscores, starting
      # with a letter or underscore. Enforced at option-set time so
      # the value can be safely interpolated into pg_hba.conf via
      # services.postgresql.authentication below (rejects whitespace,
      # newlines, quotes, and any other char that could inject an
      # extra pg_hba rule).
      type = types.strMatching "^[a-zA-Z_][a-zA-Z0-9_]*$";
      default = "blockscout";
      description = ''
        PostgreSQL database the Blockscout backend reads and writes.
        Must match the `databaseName` configured on the
        `blockscout-postgresql` wrapper (both default to
        `"blockscout"` — override either side and you must align the
        other manually).
      '';
    };

    databaseUser = mkOption {
      type = types.strMatching "^[a-zA-Z_][a-zA-Z0-9_]*$";
      default = "blockscout";
      description = ''
        PostgreSQL role the Blockscout backend connects as. Must
        match the `username` configured on the `blockscout-postgresql`
        wrapper (both default to `"blockscout"`). Used verbatim in
        the generated `services.postgresql.authentication` stanza,
        so the `types.strMatching` regex forbids any character that
        could inject an extra pg_hba rule.
      '';
    };

    redisServerName = mkOption {
      type = types.strMatching "^[a-z0-9][a-z0-9_-]*$";
      default = "blockscout";
      description = ''
        Name of the `services.blockscout-redis.serverName` this
        backend talks to. Drives the systemd unit name
        (`redis-<name>.service`) that the backend orders against.
        Must match `services.blockscout-redis.serverName` (enforced
        on both sides via the same `types.strMatching` regex).
      '';
    };

    redisHost = mkOption {
      # Same hostname-or-IPv4 regex shape as `databaseHost`. Both
      # backends ultimately compose URLs (`redis://host:port`,
      # `postgres://user:pass@host:port/db`) where `:` is a parser-
      # significant separator, so accepting `:` in the host segment
      # would conflict with bare-host URL parsing. IPv6-literal
      # support is a future widening that would change both the
      # regex AND the URL composition path on each side.
      type = types.strMatching "^[a-zA-Z0-9.-]+$";
      default = "127.0.0.1";
      description = ''
        Hostname (or IP) the backend connects to for Redis. Defaults
        to the IPv4 literal `127.0.0.1` to match exactly what
        `services.blockscout-redis.bind` resolves to (the wrapper
        binds IPv4 loopback only). Using the literal address rather
        than the `localhost` name avoids a class of failures where
        glibc / nss-resolve returns the IPv6 `::1` address first on
        dual-stack systems — Redis isn't listening there, so the
        connect would fail until glibc retried the IPv4 fallback
        (and on systems that don't retry, it would never succeed).

        Blockscout's Redix client rejects `unix://` URIs (only
        accepts `redis://`, `valkey://`, `rediss://`), so TCP is the
        only supported transport. Override to a remote hostname only
        if pointing at an external Redis.
      '';
    };

    redisPort = mkOption {
      type = types.port;
      default = 6379;
      description = ''
        TCP port the backend uses to reach Redis. Defaults to 6379;
        override here AND on `services.blockscout-redis.port` if
        moved.
      '';
    };

    ethereumRpc = {
      httpUrl = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8545";
        description = ''
          URL the backend indexer + API use for JSON-RPC calls.
          Defaults to loopback Autonity.
        '';
      };
      wsUrl = mkOption {
        type = types.str;
        default = "ws://127.0.0.1:8546";
      };
      traceUrl = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8545";
        description = ''
          URL for `debug_traceTransaction` calls. Blockscout requires
          the target Ethereum node to run in archive mode — the
          autonity module ships with `gcMode = "archive"` by default.
        '';
      };
    };

    chain = {
      id = mkOption {
        type = types.ints.positive;
        default = 65000000;
        description = "Chain ID. Default is Autonity MainNet.";
      };
      coin = mkOption {
        type = types.str;
        default = "ATN";
      };
      coinName = mkOption {
        type = types.str;
        default = "Auton";
      };
      network = mkOption {
        type = types.str;
        default = "Autonity";
      };
      subnetwork = mkOption {
        type = types.str;
        default = "MainNet";
      };
    };

    # Note on the absence of a `bindAddress` option here:
    # Blockscout binds its Phoenix endpoint on all interfaces
    # (`{0, 0, 0, 0}`) and does not read an env var for the listen
    # address in standard `config/runtime.exs`. Exposure is controlled
    # by two layers outside this module:
    #   1. NixOS `networking.firewall` is on by default with `http.port`
    #      absent from `allowedTCPPorts`, so external TCP reach to :4000
    #      is dropped.
    #   2. The `blockscout-nginx` module (upcoming PR) reverse-proxies
    #      from 127.0.0.1 to this port over loopback, which remains
    #      reachable regardless of which interface Blockscout binds.
    # Adding a `bindAddress` option without an upstream Blockscout
    # patch would be cosmetic — it couldn't actually constrain the
    # listen behaviour.
    http = {
      port = mkOption {
        type = types.port;
        default = 4000;
        description = ''
          TCP port the backend's Phoenix endpoint binds. The nginx
          reverse proxy (`blockscout-nginx` module, later PR) is
          expected to terminate TLS and forward to this port. The
          backend listens on all interfaces (Blockscout upstream
          does not read a listen-IP env var); the NixOS firewall
          drops external reach to this port by default.
        '';
      };
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = ''
          `BLOCKSCOUT_HOST` — the hostname the backend advertises to
          the frontend and emits in generated URLs. Defaults to
          `localhost` for smoke testing; in production this should
          be the public domain served through nginx.
        '';
      };
      protocol = mkOption {
        type = types.enum [
          "http"
          "https"
        ];
        default = "http";
        description = ''
          `BLOCKSCOUT_PROTOCOL`. Stays `http` at the backend layer
          because TLS terminates at the nginx reverse proxy; only
          set to `https` when the backend is reached directly over
          TLS.
        '';
      };
    };

    autoMigrate = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run `Explorer.ReleaseTasks.migrate([])` in the ExecStart
        wrapper before starting the server. Idempotent — running
        against an already-migrated database is a no-op. Disable only
        if migrations are orchestrated externally (e.g. a separate
        admin tool) or if the migration step needs different error
        handling than "fail the whole unit on migration error".

        Note: older Blockscout docs / issues sometimes refer to
        `Explorer.Release.migrate()` (no `-Tasks` suffix). That's a
        different module from a different era; this fork's release
        helper is `Explorer.ReleaseTasks.migrate/1` at
        `apps/explorer/lib/release_tasks.ex`.
      '';
    };

    extraPostMigrate = mkOption {
      type = types.lines;
      default = "";
      example = lib.literalExpression ''
        '''
          INSERT INTO migrations_status
            (migration_name, status, inserted_at, updated_at)
          VALUES ('some_migration_name', 'completed', now(), now())
          ON CONFLICT (migration_name)
            DO UPDATE SET status = 'completed', updated_at = now();
        '''
      '';
      description = ''
        SQL block run by `psql` against the configured database
        AFTER `Explorer.ReleaseTasks.migrate([])` (so any tables /
        columns the SQL touches must exist by then) and BEFORE the
        BEAM supervisor tree starts. Empty by default — operators
        opt in explicitly.

        Use cases include (but are not limited to):
        - Pre-seeding rows into `migrations_status` to skip a known-
          broken upstream Blockscout filling-migration that would
          otherwise crash-loop in the supervisor tree.
        - Test-only fixtures (the integration check uses this option
          to short-circuit one such broken migrator without altering
          production-deployment defaults).

        WARNING: SQL run here can silently bypass data-fix
        migrations. The wrapper's ExecStart logs a stderr line
        (`blockscout-backend: applying
        services.blockscout-backend.extraPostMigrate SQL`) every
        time the block fires so the bypass is visible in journalctl.
        Restrict to known-and-named migrations, document each
        statement's reason in the value, and revisit on every
        Blockscout version bump — once the upstream bug is fixed,
        leaving the row pinned at "completed" forever permanently
        skips the real migration once Blockscout adds a working one.

        Connection uses `databaseHost`, `databasePort`,
        `databaseUser`, `databaseName`, and the value at
        `databasePasswordFile` (read via the same `LoadCredential=
        DATABASE_PASSWORD` ingestion the runtime URL uses).
      '';
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        ACCOUNT_ENABLED = "false";
        DISABLE_INDEXER = "false";
        API_V2_ENABLED = "true";
      };
      description = ''
        Non-secret environment variables passed to the backend via
        systemd's unit-level `environment =` attrset — i.e. as
        `Environment=KEY=VALUE` entries in the generated unit file.
        Escape hatch for the 50+ Blockscout env vars this module does
        not expose as first-class options.

        **Values MUST NOT be secrets.** `extraEnv` entries land in
        the unit file under `/etc/systemd/system/` (and its Nix-store
        backing path), which is world-readable. For secret-holding
        env vars (API keys, OAuth client secrets, SMTP credentials,
        Sentry DSNs, etc.), use `secretEnvFiles` below — those are
        ingested via systemd `LoadCredential=` at ExecStart time and
        never appear in the unit file or the Nix store.
      '';
    };

    secretEnvFiles = mkOption {
      # Keys constrained to the env-var-name shape — letters, digits,
      # underscores, starting with a letter or underscore, uppercase
      # by convention (POSIX env vars). The key is used verbatim as
      # both the `LoadCredential=` name and the filename under
      # $CREDENTIALS_DIRECTORY, so unsafe characters would leak into
      # those paths.
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options.path = mkOption {
              # types.str (not types.path) — same rationale as
              # `secretKeyBaseFile`: Nix-path literals would auto-copy
              # into the world-readable /nix/store and defeat the
              # secrets contract. Absolute-not-in-store is enforced
              # via `config.assertions` at the module level so the
              # error message names the offending key.
              type = types.str;
              description = ''
                Absolute path (NOT under `/nix/store/`) to a file
                containing the value for env var `${name}`. Enforced
                via `config.assertions` at option-set time.
              '';
            };
          }
        )
      );
      default = { };
      example = literalExpression ''
        {
          ACCOUNT_AUTH0_CLIENT_SECRET.path = "/run/secrets/blockscout/auth0_client_secret";
          ETHERSCAN_API_KEY.path          = "/run/secrets/blockscout/etherscan_key";
        }
      '';
      description = ''
        Secret-holding environment variables whose values come from
        files. Each entry's attribute name is the env var name (must
        match `^[A-Z_][A-Z0-9_]*$`); `.path` is an absolute path to
        the file containing its value.

        Each file is ingested via systemd `LoadCredential=<NAME>=<path>`
        at unit start. The ExecStart shell wrapper reads the value
        from `$CREDENTIALS_DIRECTORY/<NAME>` and `export`s it into
        the process environment before `exec`ing the Blockscout
        release. Values never appear in the Nix store, the unit file,
        or any `EnvironmentFile`.

        Each file's contents must be a single value. Trailing
        newlines are fine (bash's `$(cat …)` strips them); embedded
        newlines end up in the env var verbatim, which may or may
        not be valid depending on how Blockscout parses the specific
        variable.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Validate:
    #   1. secretEnvFiles keys are valid POSIX env var names. The key
    #      is used verbatim as both the LoadCredential= name and the
    #      $CREDENTIALS_DIRECTORY/<NAME> filename, so unsafe chars
    #      would leak into those paths.
    #   2. Every secret path option (secretKeyBaseFile and each
    #      secretEnvFiles.<name>.path) is absolute and NOT under
    #      /nix/store/. The store is world-readable; letting a secret
    #      path resolve there (e.g. via a Nix-path literal like
    #      `./secret`) would silently defeat this module's secrets
    #      contract. Assertions give a clearer error than a type check
    #      because the message can name the exact offending option.
    assertions =
      (mapAttrsToList (name: _: {
        assertion = builtins.match envVarNameRegex name != null;
        message = "services.blockscout-backend.secretEnvFiles key `${name}` is not a valid POSIX env var name (must match `${envVarNameRegex}`).";
      }) cfg.secretEnvFiles)
      ++ [
        {
          assertion =
            lib.hasPrefix "/" cfg.secretKeyBaseFile && !lib.hasPrefix "/nix/store/" cfg.secretKeyBaseFile;
          message = "services.blockscout-backend.secretKeyBaseFile (`${cfg.secretKeyBaseFile}`) must be an absolute path NOT under /nix/store/. Storing secrets in the world-readable Nix store defeats the module's secrets contract.";
        }
        {
          assertion =
            lib.hasPrefix "/" cfg.databasePasswordFile && !lib.hasPrefix "/nix/store/" cfg.databasePasswordFile;
          message = "services.blockscout-backend.databasePasswordFile (`${cfg.databasePasswordFile}`) must be an absolute path NOT under /nix/store/. Same Nix-store-leak rationale as secretKeyBaseFile.";
        }
        {
          assertion =
            cfg.cookieFile == null
            || (lib.hasPrefix "/" cfg.cookieFile && !lib.hasPrefix "/nix/store/" cfg.cookieFile);
          message = "services.blockscout-backend.cookieFile (`${toString cfg.cookieFile}`) must be either null or an absolute path NOT under /nix/store/. Same Nix-store-leak rationale as secretKeyBaseFile.";
        }
      ]
      ++ mapAttrsToList (name: entry: {
        assertion = lib.hasPrefix "/" entry.path && !lib.hasPrefix "/nix/store/" entry.path;
        message = "services.blockscout-backend.secretEnvFiles.${name}.path (`${entry.path}`) must be an absolute path NOT under /nix/store/. Storing secrets in the world-readable Nix store defeats the module's secrets contract.";
      }) cfg.secretEnvFiles;

    # No `services.postgresql.authentication` injection: connection
    # is TCP-localhost (or remote TCP), authenticated by password
    # against nixpkgs' default pg_hba.conf `host all all 127.0.0.1/32
    # scram-sha-256` rule. The matching role password is set by
    # `blockscout-postgresql` via an appended step in
    # `systemd.services.postgresql-setup.script` from the same
    # `passwordFile`, and read on this side via LoadCredential into
    # the ExecStart wrapper which percent-encodes it for safe
    # embedding into the DATABASE_URL.

    systemd.services.blockscout-backend = {
      description = "Blockscout Elixir/Phoenix backend (API + indexer)";
      # Local data-plane unit ordering is conditional on
      # `databaseHost` / `redisHost` actually being loopback. With
      # remote-host configs the corresponding `postgresql.service` /
      # `redis-<name>.service` may not even exist on this host, so an
      # unconditional ordering would fail unit start with a
      # "missing required unit" error.
      after = [
        "network-online.target"
      ]
      ++ optional postgresLocal "postgresql.service"
      ++ optional redisLocal "redis-${cfg.redisServerName}.service";
      wants = [ "network-online.target" ];
      requires =
        optional postgresLocal "postgresql.service"
        ++ optional redisLocal "redis-${cfg.redisServerName}.service";
      wantedBy = [ "multi-user.target" ];

      # Static (non-secret) env — systemd emits these as `Environment=`
      # directives in the unit file. No EnvironmentFile, no compose
      # step, no shell parsing of values: systemd passes them directly
      # to the process's env. Operator-supplied `extraEnv` is merged on
      # top; a collision on a key Nix defined here is resolved by the
      # usual attrset `//` semantics (operator wins).
      #
      # DATABASE_URL deliberately NOT in this static-env block —
      # the password value would otherwise land in the unit file,
      # which is world-readable in the Nix store. Composed instead
      # at exec time in `startScript` (top `let`) using the
      # LoadCredential-sourced password percent-encoded for safe URL
      # embedding. ACCOUNT_DATABASE_URL likewise.
      environment = {
        ACCOUNT_REDIS_URL = "redis://${cfg.redisHost}:${toString cfg.redisPort}";
        # ECTO_USE_SSL is checked by Blockscout's runtime.exs /
        # config_helper and defaults to "true". Our local postgres
        # (`blockscout-postgresql` wrapper) doesn't ship SSL certs and
        # listens plaintext on loopback only, so SSL must be off for
        # local-loopback configs to avoid `Postgrex.Error: ssl not
        # available` at startup. Remote Postgres deployments very
        # commonly DO require SSL (cloud-managed RDS / Cloud SQL /
        # Aurora all reject plaintext by default), so for non-loopback
        # `databaseHost` we leave SSL on by default — gating on the
        # same `postgresLocal` predicate that drives unit ordering.
        # Either side of the predicate is overridable via `extraEnv`.
        ECTO_USE_SSL = if postgresLocal then "false" else "true";
        ETHEREUM_JSONRPC_VARIANT = "geth";
        ETHEREUM_JSONRPC_HTTP_URL = cfg.ethereumRpc.httpUrl;
        ETHEREUM_JSONRPC_WS_URL = cfg.ethereumRpc.wsUrl;
        ETHEREUM_JSONRPC_TRACE_URL = cfg.ethereumRpc.traceUrl;
        CHAIN_ID = toString cfg.chain.id;
        COIN = cfg.chain.coin;
        COIN_NAME = cfg.chain.coinName;
        NETWORK = cfg.chain.network;
        SUBNETWORK = cfg.chain.subnetwork;
        PORT = toString cfg.http.port;
        BLOCKSCOUT_HOST = cfg.http.host;
        BLOCKSCOUT_PROTOCOL = cfg.http.protocol;
      }
      // cfg.extraEnv;

      serviceConfig = {
        # ExecStart is a small shell wrapper that reads credentials
        # from $CREDENTIALS_DIRECTORY (populated by LoadCredential=
        # below), optionally runs the migration, and execs the
        # Blockscout release. See `startScript` in the top `let` for
        # the implementation and rationale (EnvironmentFile load
        # ordering makes it unsuitable for runtime-loaded secrets).
        ExecStart = startScript;
        Restart = "on-failure";
        RestartSec = "5s";

        # Working directory MUST be the release root. Blockscout's
        # `config/runtime.exs` calls
        #   Code.require_file("#{config_env()}.exs", "config/runtime")
        # which resolves the directory argument relative to the current
        # working directory, NOT relative to the release root or
        # `__DIR__`. Without this setting, systemd defaults the unit's
        # CWD to `/` (under DynamicUser + ProtectSystem=strict), the
        # `Code.require_file` call resolves to `/config/runtime/prod.exs`,
        # the file doesn't exist on the host filesystem, and the
        # release crashes at boot with:
        #   ERROR! Config provider Config.Reader failed with:
        #     ** (Code.LoadError) could not load /config/runtime/prod.exs.
        # The standard `bin/blockscout` script generated by `mix
        # release` does `cd "$RELEASE_ROOT"` before exec'ing the BEAM
        # — but our hardened ExecStart wrapper exec's the release
        # binary directly, bypassing that cd. Setting WorkingDirectory
        # here is the canonical fix; the `cd` at the top of
        # `startScript` (in the top `let`) is defence-in-depth in
        # case any intermediate process layer ever overrides CWD.
        WorkingDirectory = "${cfg.package}";

        DynamicUser = true;
        StateDirectory = "blockscout-backend";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "blockscout-backend";
        RuntimeDirectoryMode = "0700";

        # No SupplementaryGroups — both PostgreSQL and Redis are
        # reached over TCP-localhost rather than UNIX sockets, so the
        # backend has no need to join host system groups for socket
        # filesystem access. PostgreSQL pivoted because the Ecto/
        # Postgrex layer doesn't honour libpq's `?host=` for sockets;
        # Redis pivoted because Redix's URI parser rejects the
        # `unix://` scheme outright.

        # Secret ingestion. systemd reads each source file as root at
        # unit-start time and exposes the contents via
        # $CREDENTIALS_DIRECTORY/<NAME> — the DynamicUser UID never
        # needs read access to the source paths. Credential name
        # equals env var name (uppercase), so `startScript` can
        # `cat "$CREDENTIALS_DIRECTORY/$NAME"` and `export $NAME=…`
        # without any name translation.
        LoadCredential = [
          "SECRET_KEY_BASE:${cfg.secretKeyBaseFile}"
          "DATABASE_PASSWORD:${cfg.databasePasswordFile}"
        ]
        ++ optional (cfg.cookieFile != null) "RELEASE_COOKIE:${cfg.cookieFile}"
        ++ mapAttrsToList (name: entry: "${name}:${entry.path}") cfg.secretEnvFiles;

        # BEAM JIT needs writable + executable memory pages — opt out
        # of MemoryDenyWriteExecute. Per the nix-modules-hardening
        # skill's JIT exception list. Go, Rust, and non-JIT runtimes
        # keep the default `true`.
        MemoryDenyWriteExecute = false;

        # PrivateUsers left at its systemd default (false): both
        # PostgreSQL and Redis are now reached over TCP-localhost,
        # not UNIX sockets, so a user-namespace GID remap would no
        # longer break socket access. Setting `PrivateUsers = true`
        # explicitly is *probably* safe today but unverified against
        # the BEAM scheduler / Mix release loader; leave at the
        # systemd default until a separate hardening pass evaluates
        # it on a real workload.

        # Rest of the defense-in-depth baseline per the
        # nix-modules-hardening skill matrix.
        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        # No AF_NETLINK — the backend does not enumerate interfaces
        # or read routing information.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "~@cpu-emulation @debug @keyring @memlock @mount @obsolete @privileged @resources @setuid"
        ];
        UMask = "0077";
      };
    };
  };
}
