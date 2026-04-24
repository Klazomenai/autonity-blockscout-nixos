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
    concatMapStrings
    attrNames
    optional
    ;
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

    http = {
      port = mkOption {
        type = types.port;
        default = 4000;
        description = ''
          TCP port the backend's Phoenix endpoint binds. The nginx
          reverse proxy (`blockscout-nginx` module, later PR) is
          expected to terminate TLS and forward to this port.
        '';
      };
      bindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Listen address for the backend Phoenix endpoint. Defaults
          to loopback — nginx reverse-proxies from the same host.
          Overriding to a non-loopback value triggers a warning.
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
        # credential + config options. EnvironmentFile below reads
        # that composed file, so the secret never appears in the
        # unit file or anywhere in the Nix store.
        ExecStartPre = [
          (pkgs.writeShellScript "blockscout-compose-env" ''
            set -eu
            umask 077

            secret_key_base=$(cat "$CREDENTIALS_DIRECTORY/secret_key_base")

            {
              echo "DATABASE_URL=postgres://${cfg.databaseUser}@/${cfg.databaseName}?host=${cfg.databaseHost}"
              echo "ACCOUNT_DATABASE_URL=postgres://${cfg.databaseUser}@/${cfg.databaseName}?host=${cfg.databaseHost}"
              echo "SECRET_KEY_BASE=$secret_key_base"

              echo "ACCOUNT_REDIS_URL=unix:///run/redis-${cfg.redisServerName}/redis.sock"

              echo "ETHEREUM_JSONRPC_VARIANT=geth"
              echo "ETHEREUM_JSONRPC_HTTP_URL=${cfg.ethereumRpc.httpUrl}"
              echo "ETHEREUM_JSONRPC_WS_URL=${cfg.ethereumRpc.wsUrl}"
              echo "ETHEREUM_JSONRPC_TRACE_URL=${cfg.ethereumRpc.traceUrl}"

              echo "CHAIN_ID=${toString cfg.chain.id}"
              echo "COIN=${cfg.chain.coin}"
              echo "COIN_NAME=${cfg.chain.coinName}"
              echo "NETWORK=${cfg.chain.network}"
              echo "SUBNETWORK=${cfg.chain.subnetwork}"

              echo "PORT=${toString cfg.http.port}"
              echo "BLOCKSCOUT_HOST=${cfg.http.host}"
              echo "BLOCKSCOUT_PROTOCOL=${cfg.http.protocol}"

              ${concatMapStrings (name: ''
                echo "${name}=${cfg.extraEnv.${name}}"
              '') (attrNames cfg.extraEnv)}
            } > "$RUNTIME_DIRECTORY/env"
          '')
        ]
        ++ optional cfg.autoMigrate (
          "!"
          + toString (
            pkgs.writeShellScript "blockscout-migrate" ''
              set -eu
              # Source the env file composed above so the migration
              # script sees DATABASE_URL, SECRET_KEY_BASE, etc.
              set -a
              . "$RUNTIME_DIRECTORY/env"
              set +a
              exec ${cfg.package}/bin/blockscout eval 'Explorer.Release.migrate()'
            ''
          )
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

    # Loud warning on non-loopback bindAddress. Same pattern as the
    # autonity module: exposure should be a conscious choice.
    warnings =
      let
        loopbackSafe = [
          "127.0.0.1"
          "::1"
          "localhost"
        ];
      in
      optional (!builtins.elem cfg.http.bindAddress loopbackSafe)
        "services.blockscout-backend.http.bindAddress is `${cfg.http.bindAddress}` — the backend API will be reachable beyond loopback. Ensure nginx TLS termination and an auth gate are in front of it (the blockscout-nginx module handles this by default).";
  };
}
