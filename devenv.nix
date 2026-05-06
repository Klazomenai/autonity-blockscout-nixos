{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Default chain ID + block-count threshold for the e2e harness.
  # Mirrors `tests/integration-sync.nix`'s `chainId` (Autonity dev
  # mode pre-bonded chain) and `blocksRequired` (one full epoch +
  # 10-block buffer).
  chainId = 65111111;
  blocksRequired = 70;

  # State directory rooted under devenv's per-shell state dir.
  # process-compose runs each `processes.*` entry in this directory
  # by default; we anchor service-specific subdirectories under it
  # so `devenv up` is repeatable (devenv-generated state survives
  # across `devenv up` invocations until the user explicitly
  # `devenv processes destroy`s them).
  stateDir = config.devenv.state;

  # Backend test secrets. Mirrors the values used by the systemd
  # ExecStart wrapper at `modules/blockscout-backend.nix` and the
  # test fixture in `tests/integration-sync.nix`'s
  # `system.activationScripts.test-secrets` (deterministic; not for
  # production use). devenv processes don't run under systemd or
  # inside a tmpfs-backed credentials dir, so we inject these
  # directly via process-compose env-var directives (`backendEnv`
  # below is rendered into `envExports` and `export`ed at the top of
  # the backend process's shell). No on-disk credentials file is
  # written — the values land in the BEAM's environment via the
  # process supervisor's standard env mechanism.
  testSecretKeyBase = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  testDbPassword = "test-password-not-for-production";

  # Backend env-var contract — same shape as the
  # `services.blockscout-backend.environment = { ... }` block at
  # `modules/blockscout-backend.nix:1000-1027`. Composed once here
  # and shared between the backend process and any operator-side
  # scripts/curls that need to talk to the same database.
  backendEnv = {
    HOME = "${stateDir}/backend-home";
    SECRET_KEY_BASE = testSecretKeyBase;
    DATABASE_URL = "postgres://blockscout:${testDbPassword}@127.0.0.1:5432/blockscout";
    ACCOUNT_DATABASE_URL = "postgres://blockscout:${testDbPassword}@127.0.0.1:5432/blockscout";
    ACCOUNT_REDIS_URL = "redis://127.0.0.1:6379";
    ECTO_USE_SSL = "false";
    ETHEREUM_JSONRPC_VARIANT = "geth";
    ETHEREUM_JSONRPC_HTTP_URL = "http://127.0.0.1:8545";
    ETHEREUM_JSONRPC_WS_URL = "ws://127.0.0.1:8546";
    ETHEREUM_JSONRPC_TRACE_URL = "http://127.0.0.1:8545";
    CHAIN_ID = toString chainId;
    COIN = "ATN";
    COIN_NAME = "Auton";
    NETWORK = "Autonity";
    SUBNETWORK = "MainNet";
    PORT = "4000";
    BLOCKSCOUT_HOST = "localhost";
    BLOCKSCOUT_PROTOCOL = "http";
  };

  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") backendEnv
  );

in
{
  packages = with pkgs; [
    nixfmt-rfc-style
    statix
    deadnix
    git
    git-lfs
    # Tools the operator may want when poking the running stack.
    curl
    jq
    python3
    postgresql # For client-side `psql` against the running stack.
  ];

  git-hooks.hooks = {
    nixfmt-rfc-style.enable = true;
    statix.enable = true;
    deadnix.enable = true;
  };

  # devenv processes — `devenv up` brings them all up under
  # process-compose. Same 5 services as `tests/integration-sync.nix`:
  # autonity (--dev), postgres, redis, blockscout backend, blockscout
  # frontend. Cross-service dependencies declared via `depends_on` so
  # process-compose orders startup correctly (postgres before backend,
  # autonity before backend, etc.).
  #
  # NOT a replacement for the VM check — these are plain processes
  # without systemd hardening, namespace isolation, or LoadCredential.
  # The killer feature is fast iteration: `devenv up`, hack on a
  # service, `Ctrl-C` to stop.
  processes = {
    postgres = {
      exec = ''
        set -eu
        PGDATA="${stateDir}/pg"
        if [ ! -f "$PGDATA/PG_VERSION" ]; then
          # --auth-host=scram-sha-256 + password_encryption =
          # scram-sha-256 below for parity with the
          # blockscout-postgresql NixOS module's auth posture.
          ${pkgs.postgresql}/bin/initdb -D "$PGDATA" \
            --auth-local=trust --auth-host=scram-sha-256 --no-locale --encoding=UTF8 \
            --username=postgres
          mkdir -p "${stateDir}/pg-sock"
          cat >> "$PGDATA/postgresql.conf" <<EOF
        listen_addresses = '127.0.0.1'
        port = 5432
        unix_socket_directories = '${stateDir}/pg-sock'
        # Match the blockscout-postgresql module's encryption choice;
        # pairs with --auth-host=scram-sha-256 above.
        password_encryption = scram-sha-256
        # Match the blockscout-postgresql NixOS module + tests/run-e2e.sh:
        # the postgres default of 100 exhausts under Blockscout's Ecto
        # connection pool during indexer catchup, tripping
        # "FATAL: sorry, too many clients already".
        max_connections = 250
        fsync = off
        synchronous_commit = off
        full_page_writes = off
        EOF
        fi
        # Start postgres in the foreground (process-compose-managed).
        exec ${pkgs.postgresql}/bin/postgres -D "$PGDATA"
      '';
      process-compose = {
        readiness_probe = {
          exec.command = "${pkgs.postgresql}/bin/pg_isready -h ${stateDir}/pg-sock -p 5432";
          period_seconds = 2;
          timeout_seconds = 30;
        };
      };
    };

    postgres-init = {
      exec = ''
        set -eu
        # Idempotent: skip if blockscout DB exists.
        if ${pkgs.postgresql}/bin/psql -h ${stateDir}/pg-sock -p 5432 -U postgres \
             -tAc "SELECT 1 FROM pg_database WHERE datname='blockscout'" \
             | ${pkgs.gnugrep}/bin/grep -q 1; then
          echo "postgres-init: blockscout DB already present"
          exit 0
        fi
        ${pkgs.postgresql}/bin/psql -h ${stateDir}/pg-sock -p 5432 -U postgres -d postgres <<SQL
        CREATE USER blockscout WITH SUPERUSER PASSWORD '${testDbPassword}';
        CREATE DATABASE blockscout OWNER blockscout;
        SQL
      '';
      process-compose = {
        depends_on.postgres.condition = "process_healthy";
      };
    };

    redis = {
      exec = ''
        exec ${pkgs.redis}/bin/redis-server \
          --port 6379 --bind 127.0.0.1 --dir ${stateDir} \
          --logfile /dev/stdout --daemonize no
      '';
      process-compose = {
        readiness_probe = {
          exec.command = "${pkgs.redis}/bin/redis-cli -p 6379 ping";
          period_seconds = 2;
          timeout_seconds = 10;
        };
      };
    };

    autonity-dev = {
      exec = ''
        set -eu
        mkdir -p ${stateDir}/autonity
        exec ${pkgs.autonity}/bin/autonity \
          --dev \
          --datadir ${stateDir}/autonity \
          --maxpeers 0 \
          --nodiscover \
          --port 30303 \
          --http \
          --http.addr 127.0.0.1 \
          --http.port 8545 \
          --http.api net,web3,eth,aut,tendermint \
          --ws \
          --ws.addr 127.0.0.1 \
          --ws.port 8546 \
          --ipcdisable
      '';
      process-compose = {
        readiness_probe = {
          exec.command = ''
            ${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8545 \
              -H 'Content-Type: application/json' \
              -d '{"jsonrpc":"2.0","method":"eth_chainId","id":1}'
          '';
          period_seconds = 2;
          timeout_seconds = 60;
        };
      };
    };

    blockscout-backend = {
      exec = ''
        set -eu
        mkdir -p ${stateDir}/backend-home
        ${envExports}
        cd ${pkgs.blockscout}
        # RELEASE_COOKIE must be exported BEFORE the migration eval,
        # not just before `start`. The blockscout release wrapper
        # requires a cookie for any invocation (eval, start, rpc,
        # etc.); the migrations call `bin/blockscout eval ...` which
        # would otherwise fall back to the in-store `releases/COOKIE`
        # placeholder file and fail. Same cookie reused for both eval
        # and start so the BEAM nodes agree.
        export RELEASE_COOKIE=$(${pkgs.openssl}/bin/openssl rand -hex 24)
        # Run migrations before start; idempotent. Same call as the
        # systemd wrapper at `modules/blockscout-backend.nix:324`.
        ${pkgs.blockscout}/bin/blockscout eval 'Explorer.ReleaseTasks.migrate([])'
        exec ${pkgs.blockscout}/bin/blockscout start
      '';
      process-compose = {
        depends_on = {
          postgres.condition = "process_healthy";
          postgres-init.condition = "process_completed_successfully";
          redis.condition = "process_healthy";
          autonity-dev.condition = "process_healthy";
        };
        readiness_probe = {
          exec.command = "${pkgs.curl}/bin/curl -fsS http://127.0.0.1:4000/api/health/liveness";
          period_seconds = 5;
          timeout_seconds = 600;
          initial_delay_seconds = 30;
        };
      };
    };

    blockscout-frontend = {
      exec = ''
        set -eu
        export HOSTNAME=127.0.0.1
        export PORT=3000
        export NEXT_PUBLIC_NETWORK_ID=${toString chainId}
        export NEXT_PUBLIC_API_HOST=localhost
        export NEXT_PUBLIC_API_PROTOCOL=http
        export NEXT_PUBLIC_API_PORT=4000
        export NEXT_PUBLIC_APP_HOST=localhost
        export NEXT_PUBLIC_APP_PROTOCOL=http
        export NEXT_PUBLIC_APP_PORT=3000
        # Locate server.js in the frontend package. The Blockscout
        # fork flattens the Next.js standalone tree to the package
        # root (server.js lives at `${pkgs.blockscout-frontend}/server.js`),
        # NOT under the upstream `*/standalone/*` convention.
        if [ ! -f "${pkgs.blockscout-frontend}/server.js" ]; then
          echo "could not find server.js at ${pkgs.blockscout-frontend}/server.js" >&2
          exit 1
        fi
        # Build a writable mirror of the frontend package in
        # ${stateDir}/frontend. The package is read-only (under
        # /nix/store), so we can't directly overwrite envs.js — but
        # Next.js's standalone server reads `public/` relative to its
        # CWD, so we can stand up a writable shadow tree where
        # everything except `public/assets/envs.js` is symlinked back
        # to the package, then write a fresh envs.js with the correct
        # chain ID. Mirrors the systemd module's BindReadOnlyPaths
        # overlay at the userspace level — same end behaviour: SSR
        # `process.env.NEXT_PUBLIC_*` and browser `window.__envs`
        # agree on the chain ID instead of disagreeing (which would
        # cause React hydration mismatches under any actual UI use).
        WRITABLE="${stateDir}/frontend"
        rm -rf "$WRITABLE"
        mkdir -p "$WRITABLE/public/assets"
        # `dotglob` so the `.next/` production-build directory at the
        # package root is mirrored — default shell glob skips
        # dotfiles.
        shopt -s dotglob
        for entry in "${pkgs.blockscout-frontend}"/*; do
          name=$(basename "$entry")
          case "$name" in
            public|server.js) continue ;;
            *) ln -s "$entry" "$WRITABLE/$name" ;;
          esac
        done
        # Copy server.js (not symlink) so Node's __dirname resolves
        # to $WRITABLE; the script does `process.chdir(__dirname)`
        # to find public/, which would otherwise CD back into the
        # read-only package dir and serve the original envs.js. The
        # alternative `--preserve-symlinks` flag breaks pnpm's
        # symlink-based node_modules layout, so copying just this
        # one small file is the targeted fix.
        cp "${pkgs.blockscout-frontend}/server.js" "$WRITABLE/server.js"
        for entry in "${pkgs.blockscout-frontend}/public"/*; do
          name=$(basename "$entry")
          [ "$name" = "assets" ] && continue
          ln -s "$entry" "$WRITABLE/public/$name"
        done
        for entry in "${pkgs.blockscout-frontend}/public/assets"/*; do
          name=$(basename "$entry")
          [ "$name" = "envs.js" ] && continue
          ln -s "$entry" "$WRITABLE/public/assets/$name"
        done
        # Single-line JSON envs.js with NETWORK_ID overridden to the
        # let-bound chainId. Other publicEnv defaults match
        # `modules/blockscout-frontend.nix:106-120` (mirrored verbatim).
        cat > "$WRITABLE/public/assets/envs.js" <<EOF
        window.__envs = {"NEXT_PUBLIC_API_HOST":"localhost","NEXT_PUBLIC_API_PROTOCOL":"http","NEXT_PUBLIC_API_PORT":"4000","NEXT_PUBLIC_NETWORK_NAME":"Autonity","NEXT_PUBLIC_NETWORK_SHORT_NAME":"ATN","NEXT_PUBLIC_NETWORK_ID":"${toString chainId}","NEXT_PUBLIC_NETWORK_RPC_URL":"http://localhost:8545","NEXT_PUBLIC_NETWORK_CURRENCY_NAME":"Auton","NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL":"ATN","NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS":"18","NEXT_PUBLIC_APP_HOST":"localhost","NEXT_PUBLIC_APP_PROTOCOL":"http","NEXT_PUBLIC_APP_PORT":"3000"};
        EOF
        cd "$WRITABLE"
        exec ${pkgs.nodejs_20}/bin/node "$WRITABLE/server.js"
      '';
      process-compose = {
        depends_on.blockscout-backend.condition = "process_healthy";
        readiness_probe = {
          exec.command = "${pkgs.curl}/bin/curl -fsS http://127.0.0.1:3000/";
          period_seconds = 2;
          timeout_seconds = 120;
        };
      };
    };
  };

  # Probe runner against the running `devenv up` stack. Same script
  # the VM check + `nix run .#e2e` invoke; here it's exposed as a
  # devenv script for manual operator invocation.
  scripts.e2e-probes.exec = ''
    PROBE_RPC_URL=http://127.0.0.1:8545 \
    PROBE_BACKEND_URL=http://127.0.0.1:4000 \
    PROBE_FRONTEND_URL=http://127.0.0.1:3000 \
    PROBE_CHAIN_ID=${toString chainId} \
    PROBE_BLOCKS_REQUIRED=${toString blocksRequired} \
    PROBE_PSQL_CMD="${pkgs.postgresql}/bin/psql -h ${stateDir}/pg-sock -p 5432 -U blockscout -At -d blockscout" \
    PGPASSWORD=${testDbPassword} \
    ${pkgs.python3}/bin/python3 ${./tests/probes.py}
  '';

  enterShell = ''
    echo "autonity-blockscout-nixos development environment"
    echo ""
    echo "Scope: x86_64-linux only."
    echo ""
    echo "Nix:"
    echo "  nix flake check        Run flake checks (fmt + hardening on PR; VM checks on main)"
    echo "  nix fmt                Format Nix files in-place"
    echo "  nix run .#e2e          Host-native end-to-end smoke (~3.5-5 min)"
    echo ""
    echo "devenv:"
    echo "  devenv up              Start full stack (autonity, postgres, redis, backend, frontend)"
    echo "  e2e-probes             Run the probe sequence against a running devenv-up stack"
    echo ""
  '';
}
