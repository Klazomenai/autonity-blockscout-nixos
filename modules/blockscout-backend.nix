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
#   - Secrets: Phoenix `secret_key_base` ingested via systemd
#     `LoadCredential=` so the service never reads the source file
#     directly; composed into $RUNTIME_DIRECTORY/env by ExecStartPre
#     and read back via EnvironmentFile.
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
    concatStringsSep
    mapAttrsToList
    optional
    ;

  # Static env values — Nix-interpolated at module-eval time, written
  # verbatim into a Nix-store file by `pkgs.writeText`. Because Nix
  # produces the file content directly (not via `echo` inside a shell
  # script), values like `db$USER` or `db"quoted"` are stored as
  # literal characters — no bash expansion, no quote-closure risk.
  # The file is world-readable in the Nix store; this is fine because
  # it contains ZERO secrets — only configuration derived from module
  # options that are already visible in the flake source.
  staticEnvFile = pkgs.writeText "blockscout-backend.env" (
    concatStringsSep "\n" (
      [
        "DATABASE_URL=postgres://${cfg.databaseUser}@/${cfg.databaseName}?host=${cfg.databaseHost}"
        "ACCOUNT_DATABASE_URL=postgres://${cfg.databaseUser}@/${cfg.databaseName}?host=${cfg.databaseHost}"
        "ACCOUNT_REDIS_URL=unix:///run/redis-${cfg.redisServerName}/redis.sock"
        "ETHEREUM_JSONRPC_VARIANT=geth"
        "ETHEREUM_JSONRPC_HTTP_URL=${cfg.ethereumRpc.httpUrl}"
        "ETHEREUM_JSONRPC_WS_URL=${cfg.ethereumRpc.wsUrl}"
        "ETHEREUM_JSONRPC_TRACE_URL=${cfg.ethereumRpc.traceUrl}"
        "CHAIN_ID=${toString cfg.chain.id}"
        "COIN=${cfg.chain.coin}"
        "COIN_NAME=${cfg.chain.coinName}"
        "NETWORK=${cfg.chain.network}"
        "SUBNETWORK=${cfg.chain.subnetwork}"
        "PORT=${toString cfg.http.port}"
        "BLOCKSCOUT_HOST=${cfg.http.host}"
        "BLOCKSCOUT_PROTOCOL=${cfg.http.protocol}"
      ]
      ++ mapAttrsToList (k: v: "${k}=${v}") cfg.extraEnv
    )
    + "\n"
  );
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
        tokens. Ingested via systemd `LoadCredential=`; the service
        reads from `$CREDENTIALS_DIRECTORY/secret_key_base`, never
        from this source path. The file only needs to be readable by
        systemd (root at unit-start time), not by the `DynamicUser`-
        allocated UID.
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
      type = types.str;
      default = "blockscout";
    };

    databaseUser = mkOption {
      type = types.str;
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
        Run `Explorer.Release.migrate()` as an `ExecStartPre` before
        each service start. Idempotent — running against an already-
        migrated database is a no-op. Disable only if migrations are
        orchestrated externally (e.g. a separate admin tool).
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
        Additional environment variables passed to the backend.
        Escape hatch for the 50+ Blockscout env vars this module does
        not expose as first-class options. Values must be strings —
        Blockscout's runtime-config layer treats all env vars as
        strings.

        **Values MUST NOT contain newlines** — systemd's
        `EnvironmentFile` parser treats each newline as an entry
        boundary, so a multi-line value breaks the file. The `#`
        character and whitespace are fine; quotes and shell
        metacharacters are preserved literally (values are written
        via `pkgs.writeText` at Nix-eval time, never via a shell
        `echo` that could expand them).
      '';
    };
  };

  config = mkIf cfg.enable {
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

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/blockscout start";
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

        # Secret ingestion. systemd reads the source file as root at
        # unit-start time and exposes the contents via
        # $CREDENTIALS_DIRECTORY/secret_key_base — the DynamicUser
        # UID never needs read access to the source path.
        LoadCredential = [
          "secret_key_base:${cfg.secretKeyBaseFile}"
        ];

        # ExecStartPre: compose $RUNTIME_DIRECTORY/env from the
        # Nix-generated static env file + the secret read from
        # $CREDENTIALS_DIRECTORY. EnvironmentFile= below reads the
        # composed file.
        #
        # Static values (DATABASE_URL, CHAIN_ID, extraEnv entries,
        # etc.) are interpolated at Nix-eval time into
        # `${staticEnvFile}` — no bash `echo` touches them, so no
        # shell expansion / quote-closure risk. The one secret
        # (SECRET_KEY_BASE) is appended at runtime from the
        # credential tmpfs via `printf` + `cat`, which doesn't
        # interpolate the value.
        ExecStartPre = [
          (pkgs.writeShellScript "blockscout-compose-env" ''
            set -eu
            umask 077

            # Install the Nix-generated static env file into the
            # runtime dir at 0600.
            install -m 0600 ${staticEnvFile} "$RUNTIME_DIRECTORY/env"

            # Append the secret. `printf` + `cat` avoids shell
            # expansion of the secret's contents; the credential
            # file is expected to be a single line (operator
            # responsibility — newlines break EnvironmentFile).
            {
              printf 'SECRET_KEY_BASE='
              cat "$CREDENTIALS_DIRECTORY/secret_key_base"
              printf '\n'
            } >> "$RUNTIME_DIRECTORY/env"
          '')
        ]
        ++ optional cfg.autoMigrate (
          # No `!` prefix — the migrate step MUST run under the same
          # DynamicUser + SupplementaryGroups context as the main
          # unit so `psql` via /run/postgresql/.s.PGSQL.5432 uses the
          # `blockscout` role's trust auth. Running as root (the `!`
          # prefix) would bypass the blockscout role entirely.
          pkgs.writeShellScript "blockscout-migrate" ''
            set -eu
            # Source the env file composed above so the migration
            # script sees DATABASE_URL, SECRET_KEY_BASE, etc.
            set -a
            . "$RUNTIME_DIRECTORY/env"
            set +a
            exec ${cfg.package}/bin/blockscout eval 'Explorer.Release.migrate()'
          ''
        );

        # Use the systemd %t runtime-dir expansion so the path is
        # correct regardless of whether the service runs with or
        # without DynamicUser.
        EnvironmentFile = [ "-%t/blockscout-backend/env" ];

        # BEAM JIT needs writable + executable memory pages — opt out
        # of MemoryDenyWriteExecute. Per the nix-modules-hardening
        # skill's JIT exception list. Go, Rust, and non-JIT runtimes
        # keep the default `true`.
        MemoryDenyWriteExecute = false;

        # Defense-in-depth hardening per the nix-modules-hardening
        # skill matrix.
        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        PrivateUsers = true;
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
