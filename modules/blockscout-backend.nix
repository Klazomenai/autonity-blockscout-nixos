# NixOS service module for the Blockscout backend (Elixir/Phoenix API
# + indexer). This is the cross-service module where the plumbing
# established by autonity.nix, blockscout-postgresql.nix, and
# blockscout-redis.nix finally comes together.
#
# Cross-service contract:
#   - PostgreSQL: connects via UNIX socket /run/postgresql/.s.PGSQL.5432
#     (joining the `postgres` group via SupplementaryGroups for socket
#     filesystem access). Authentication: local `trust` auth scoped to
#     the specific role+database via services.postgresql.authentication
#     (mkBefore) — socket access is the auth boundary on a single-
#     machine deployment; see the `databaseAuthRationale` comment below.
#   - Redis: connects via UNIX socket /run/redis-<name>/redis.sock
#     (joining the `redis-<name>` group via SupplementaryGroups). Redis
#     has no authentication configured; socket access is the auth
#     boundary.
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
    optionalString
    literalExpression
    ;

  # Env-var-name regex — used to assert that every `secretEnvFiles`
  # key is a valid POSIX env var name. Enforced at `config.assertions`
  # time rather than via the submodule's `name` because submodule
  # naming happens at a later pass in the module system; an assertion
  # gives a clearer error message pointing at the exact offending key.
  envVarNameRegex = "^[A-Z_][A-Z0-9_]*$";

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

    # $(cat …) captures the credential file's bytes verbatim. Bash
    # variable assignment does not re-expand `$` / backticks in the
    # value, so secrets containing shell metacharacters are preserved
    # literally. Each credential file is expected to contain a single
    # value with no trailing content beyond an optional final newline
    # (bash command substitution strips trailing newlines).
    export SECRET_KEY_BASE="$(cat "$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE")"
    ${concatMapStringsSep "\n    " (name: ''
      export ${name}="$(cat "$CREDENTIALS_DIRECTORY/${name}")"
    '') (lib.attrNames cfg.secretEnvFiles)}
    ${optionalString cfg.autoMigrate ''
      ${cfg.package}/bin/blockscout eval 'Explorer.Release.migrate()'
    ''}
    exec ${cfg.package}/bin/blockscout start
  '';

in
{
  options.services.blockscout-backend = {
    enable = mkEnableOption "the Blockscout Elixir/Phoenix backend (API + indexer)";

    package = mkPackageOption pkgs "blockscout" { };

    secretKeyBaseFile = mkOption {
      type = types.path;
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
      '';
    };

    databaseHost = mkOption {
      type = types.str;
      default = "/run/postgresql";
      description = ''
        PostgreSQL socket directory — the value passed as `host=` in
        the libpq connection string. Defaults to the standard nixpkgs
        location used by the `blockscout-postgresql` wrapper. Not a
        hostname: an absolute path to the directory containing
        `.s.PGSQL.<port>`.
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
    };

    databaseUser = mkOption {
      type = types.strMatching "^[a-zA-Z_][a-zA-Z0-9_]*$";
      default = "blockscout";
    };

    redisServerName = mkOption {
      type = types.strMatching "^[a-z0-9][a-z0-9_-]*$";
      default = "blockscout";
      description = ''
        Name of the `services.blockscout-redis.serverName` this
        backend talks to. Drives both the group the backend joins via
        `SupplementaryGroups = [ "redis-<name>" ]` and the socket
        path it connects to (`/run/redis-<name>/redis.sock`). Must
        match `services.blockscout-redis.serverName` (enforced on
        both sides via the same `types.strMatching` regex).
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
        Run `Explorer.Release.migrate()` in the ExecStart wrapper
        before starting the server. Idempotent — running against an
        already-migrated database is a no-op. Disable only if
        migrations are orchestrated externally (e.g. a separate admin
        tool) or if the migration step needs different error
        handling than "fail the whole unit on migration error".
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
              type = types.path;
              description = "Absolute path to a file containing the value for env var `${name}`.";
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
    # Validate secretEnvFiles keys at option-set time. The key is used
    # verbatim as both the LoadCredential= name and the
    # $CREDENTIALS_DIRECTORY/<NAME> filename, so unsafe characters
    # would leak into those paths. Checking via assertions rather than
    # at the submodule level so the error message can name the exact
    # offending key.
    assertions = mapAttrsToList (name: _: {
      assertion = builtins.match envVarNameRegex name != null;
      message = "services.blockscout-backend.secretEnvFiles key `${name}` is not a valid POSIX env var name (must match `${envVarNameRegex}`).";
    }) cfg.secretEnvFiles;

    # Local-socket `trust` authentication scoped to the specific role+
    # database. Rationale (databaseAuthRationale):
    #   - Socket filesystem access is already gated by the `postgres`
    #     group. Only services joining that group via
    #     SupplementaryGroups can reach /run/postgresql/.s.PGSQL.5432
    #     at all — in this stack, that's blockscout-backend and
    #     nothing else.
    #   - Once the socket is reached, the role scope limits access to
    #     the blockscout database + role.
    #   - Password-based auth would add a layer, but the password
    #     would have to be readable to the same process that already
    #     has socket access — same blast radius.
    #   - mkBefore puts this entry ahead of nixpkgs' default
    #     `local all all peer`, so the scoped `trust` rule matches
    #     first and the broader `peer` rule is never reached for this
    #     role+database combination.
    # Operators needing stronger auth can override
    # services.postgresql.authentication themselves and add a
    # password-sync mechanism; see the `username` description on
    # services.blockscout-postgresql for the two realistic paths.
    services.postgresql.authentication = mkBefore ''
      local ${cfg.databaseName} ${cfg.databaseUser} trust
    '';

    systemd.services.blockscout-backend = {
      description = "Blockscout Elixir/Phoenix backend (API + indexer)";
      after = [
        "network-online.target"
        "postgresql.service"
        "redis-${cfg.redisServerName}.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "postgresql.service"
        "redis-${cfg.redisServerName}.service"
      ];
      wantedBy = [ "multi-user.target" ];

      # Static (non-secret) env — systemd emits these as `Environment=`
      # directives in the unit file. No EnvironmentFile, no compose
      # step, no shell parsing of values: systemd passes them directly
      # to the process's env. Operator-supplied `extraEnv` is merged on
      # top; a collision on a key Nix defined here is resolved by the
      # usual attrset `//` semantics (operator wins).
      environment = {
        DATABASE_URL = "postgres://${cfg.databaseUser}@/${cfg.databaseName}?host=${cfg.databaseHost}";
        ACCOUNT_DATABASE_URL = "postgres://${cfg.databaseUser}@/${cfg.databaseName}?host=${cfg.databaseHost}";
        ACCOUNT_REDIS_URL = "unix:///run/redis-${cfg.redisServerName}/redis.sock";
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

        DynamicUser = true;
        StateDirectory = "blockscout-backend";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "blockscout-backend";
        RuntimeDirectoryMode = "0700";

        # Cross-service UNIX socket access. `postgres` and
        # `redis-<name>` groups are auto-created by the respective
        # upstream modules; joining them here grants filesystem
        # access to /run/postgresql/.s.PGSQL.5432 and
        # /run/redis-<name>/redis.sock respectively.
        SupplementaryGroups = [
          "postgres"
          "redis-${cfg.redisServerName}"
        ];

        # Secret ingestion. systemd reads each source file as root at
        # unit-start time and exposes the contents via
        # $CREDENTIALS_DIRECTORY/<NAME> — the DynamicUser UID never
        # needs read access to the source paths. Credential name
        # equals env var name (uppercase), so `startScript` can
        # `cat "$CREDENTIALS_DIRECTORY/$NAME"` and `export $NAME=…`
        # without any name translation.
        LoadCredential = [
          "SECRET_KEY_BASE:${cfg.secretKeyBaseFile}"
        ]
        ++ mapAttrsToList (name: entry: "${name}:${entry.path}") cfg.secretEnvFiles;

        # BEAM JIT needs writable + executable memory pages — opt out
        # of MemoryDenyWriteExecute. Per the nix-modules-hardening
        # skill's JIT exception list. Go, Rust, and non-JIT runtimes
        # keep the default `true`.
        MemoryDenyWriteExecute = false;

        # `PrivateUsers = false` is load-bearing, not a missing
        # hardening option. The service relies on `SupplementaryGroups`
        # to reach the PostgreSQL and Redis UNIX sockets; those
        # sockets are group-owned by `postgres` and `redis-<name>`
        # respectively at the HOST UID/GID level. `PrivateUsers = true`
        # would put the service in a user namespace where host GIDs
        # are remapped (typically to `nobody`), making the kernel's
        # permission check on the sockets fail with EACCES. Leave
        # explicitly false with this comment so future hardening
        # sweeps do not mistakenly re-enable it.
        PrivateUsers = false;

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
