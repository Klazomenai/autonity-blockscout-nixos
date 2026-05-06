# Behavioural full-stack VM sync test. Boots all six service modules in
# a single `pkgs.testers.nixosTest` VM with Autonity in `--dev` mode
# (single-validator Tendermint chain at chain ID 65111111, 1-second
# block period), then waits for chain progression to >= `blocksRequired`
# blocks AND the Blockscout indexer to catch up to the same threshold.
#
# Complementary to `checks.<system>.integration`:
#   - `integration` runs Autonity in `--dev` semantics' opposite —
#     `network = "mainnet"` with `--nodiscover --maxpeers=0` — so the
#     chain stays at genesis and behavioural connectivity is exercised
#     without paying the cost of waiting for blocks. Fast (~22 min cold).
#   - `integration-sync` (this) drives the same six services through
#     real chain progression + indexer ingestion. Catches the whole
#     class of regressions that only surface when blocks actually move
#     (indexer connectivity, JSON-RPC probe shape, single-source-of-
#     truth chain ID across backend/frontend/RPC). Adds ~70-180s wall-
#     clock on top of the integration baseline; total ~24-25 min cold.
#
# Probe vocabulary (locked during M2.5 design — full rationale in
# the M2.5 epic body at #38 and the per-probe issue at #34):
#
#   Geth-inherited (chain liveness):
#     1. `eth_blockNumber >= blocksRequired`
#     2. `eth_chainId == chainIdHex`
#
#   Autonity-native (consensus liveness — richer signal):
#     3. `tendermint_getCommittee` — assert committee size is exactly
#        1 (single-validator dev chain).
#     4. `tendermint_getCoreState` — assert `height` advances across
#        two consecutive samples; proves the Tendermint engine itself
#        is active, not just that an RPC handler responds.
#
#   The two consensus-liveness probes use the `tendermint_*` JSON-RPC
#   namespace (registered at `internal/web3ext/web3ext.go` in the
#   autonity fork as `tendermint_getCommittee` /
#   `tendermint_getCoreState`); the default HTTP API set per
#   `node/defaults.go` is `["net", "web3", "aut", "tendermint"]`, so
#   the namespace is exposed without any `--http.api` override.
#
#   Blockscout (indexer ingestion):
#     5. `psql -c "SELECT count(*) FROM blocks" >= blocksRequired`
#        — belt-and-braces; catches API/DB drift.
#     6. `GET /api/v2/main-page/indexing-status` returning
#        `finished_indexing_blocks: true` OR
#        `indexed_blocks_ratio >= 1.0`.
#     7. `GET /api/health` returning 200 once chain progresses.
#        (Note: NOT `/api/v2/health` — that path lands on the V2
#        FallbackController and returns 400 for unknown action.)
#
# Explicitly NOT in the local probe vocabulary: `eth_syncing`. Under
# `--dev` the node IS the chain source — it returns `false`
# tautologically. That probe is reserved for the M3 OVH post-deploy
# flow tracked in #36.
#
# `blocksRequired` defaults to 70: epoch period in dev mode is 60
# blocks (`core/genesis.go` `EpochPeriod: 60`), so 70 blocks crosses
# one full epoch transition with a 10-block safety buffer for TCG-
# emulated VM contention. Strict minimum would be 61 (one block past
# the epoch boundary); the buffer is cheap insurance.
#
# Out-of-scope per the locked design:
#   - No account-level state assertions: `--dev.etherbase` rotates per
#     launch and is not pinned (`flags.go:1599-1606`); probes reference
#     block-count, chainId, indexer state, and committee composition
#     only — no specific EOA addresses, balances, or signers.
#   - Tendermint timeouts not configurable
#     (`consensus/tendermint/core/timeout.go:14-21`). Block cadence may
#     degrade from 1s to 1.5–2s under TCG contention; the block-count
#     exit survives this, no wall-clock heuristic is used anywhere.
#   - In-memory chain DB. `--dev` forces `cfg.DataDir = ""` per the
#     `services.autonity.network = "dev"` mkOption documentation. This
#     test does NOT restart Autonity mid-run — the chain DB would rewind
#     to genesis and confuse the indexer.
{
  pkgs,
  flake,
  system,
}:

let
  hostName = "explorer.test";

  # Dev chain. Source-of-truth Nix integer; downstream consumers
  # (backend `chain.id`, frontend `publicEnv.NEXT_PUBLIC_NETWORK_ID`,
  # test assertion) all read from this binding. Hex form is computed
  # at eval time via `lib.toHexString` and lowercased to match the
  # geth-family JSON-RPC convention.
  chainId = 65111111;
  chainIdHex = "0x" + pkgs.lib.toLower (pkgs.lib.toHexString chainId);

  # Number of blocks the chain must advance to before the test exits
  # successfully. Default 70 = one full epoch crossed (EpochPeriod=60)
  # plus 10-block safety buffer for TCG-emulated VM contention. See
  # the file header for the full rationale.
  blocksRequired = 70;

  # Self-signed cert for nginx vhost — same pattern as the
  # `integration` check. Real ACME requires a public DNS name; the
  # self-signed cert is sufficient to exercise `forceSSL = true` and
  # the loopback reverse-proxy path.
  selfSignedCerts =
    pkgs.runCommand "self-signed-${hostName}"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
          -keyout $out/key.pem \
          -out $out/cert.pem \
          -subj "/CN=${hostName}" \
          -addext "subjectAltName=DNS:${hostName}"
      '';

  testSecretKeyBase = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
in
pkgs.testers.nixosTest {
  name = "autonity-blockscout-integration-sync";

  nodes.machine =
    {
      config,
      lib,
      options,
      ...
    }:
    {
      imports = [ flake.nixosModules.default ];

      # Sync-stage VM is more memory-hungry AND CPU-hungry than the
      # static fixture: the indexer runs a real catchup pass +
      # realtime fetcher AND the Tendermint engine produces blocks at
      # 1/sec. 4 GiB is the observed floor for memory; bumped to
      # 5 GiB for the additional indexer working set.
      #
      # 4 cores instead of 2: under TCG (software-emulated x86, no
      # nested KVM on GitHub-Actions runners) Autonity's continuous
      # block production saturates one core, and a single remaining
      # core was not enough to bring up Blockscout's BEAM + Ecto
      # migrations + Phoenix endpoint within the default 900 s
      # `wait_for_open_port` timeout. Verified empirically against a
      # local TCG run: with 2 cores the backend never bound port
      # 4000 in 15 minutes (chain reached block 897 in that time);
      # with 4 cores the backend warms up in line with the static
      # `integration` test's experience.
      virtualisation.memorySize = 5120;
      virtualisation.cores = 4;
      virtualisation.diskSize = 4096;

      networking.extraHosts = ''
        127.0.0.1 ${hostName}
      '';

      system.stateVersion = "24.05";

      # Test secrets materialised on a /run tmpfs — same pattern as the
      # `integration` check.
      system.activationScripts.test-secrets = ''
        ${pkgs.coreutils}/bin/install -d -m 0755 /run/test-secrets
        ${pkgs.coreutils}/bin/install -m 0400 -o root -g root /dev/null /run/test-secrets/skb
        printf '%s' ${lib.escapeShellArg testSecretKeyBase} > /run/test-secrets/skb
        ${pkgs.coreutils}/bin/install -m 0440 -o postgres -g postgres /dev/null /run/test-secrets/db_password
        printf '%s' 'test-password-not-for-production' > /run/test-secrets/db_password
      '';

      services.autonity = {
        enable = true;
        # Single-validator Tendermint chain at chain ID 65111111. The
        # `network = "dev"` enum value (shipped via #32) emits `--dev`,
        # forces `--maxpeers 0` and `--nodiscover` automatically (the
        # binary internally disables peer discovery under `--dev`; this
        # module overrides argv to match for self-consistency), and
        # forces an in-memory chain database.
        network = "dev";
      };

      services.blockscout-postgresql = {
        enable = true;
        passwordFile = "/run/test-secrets/db_password";
      };
      systemd.services.postgresql.serviceConfig.TimeoutSec = lib.mkForce 600;
      services.blockscout-redis.enable = true;

      services.blockscout-backend = {
        enable = true;
        secretKeyBaseFile = "/run/test-secrets/skb";
        databasePasswordFile = "/run/test-secrets/db_password";
        # Single-source-of-truth threading: backend's `CHAIN_ID` env
        # var reads from the let-bound `chainId` (65111111). Module
        # default is 65000000 (MainNet), so this override is genuinely
        # active — unlike the static `integration` test where the
        # binding happens to match the default.
        chain.id = chainId;
      };

      services.blockscout-frontend = {
        enable = true;
        # Single-source-of-truth threading: frontend's
        # `NEXT_PUBLIC_NETWORK_ID` reads from the same `chainId`. The
        # `//`-against-`options.<…>.default` pattern preserves all 13
        # other publicEnv defaults while overriding only the chain ID.
        # See `tests/integration.nix` for the full rationale —
        # `types.attrsOf` with a non-empty default is shadowed by any
        # user-provided definition rather than per-key merged, so the
        # explicit `default //` form is required.
        publicEnv = options.services.blockscout-frontend.publicEnv.default // {
          NEXT_PUBLIC_NETWORK_ID = toString chainId;
        };
      };

      services.blockscout-nginx = {
        enable = true;
        serverName = hostName;
        acme.enable = false;
      };

      services.nginx.virtualHosts.${hostName} = {
        sslCertificate = "${selfSignedCerts}/cert.pem";
        sslCertificateKey = "${selfSignedCerts}/key.pem";
      };

      # Probe script + minimal Python interpreter for the in-VM
      # invocation. The probe LOGIC lives in `tests/probes.py` (single
      # source of truth shared with the host-native `nix run .#e2e`
      # runner per #35); the testScript below just sequences VM-only
      # liveness gates and then invokes that script with the
      # appropriate env-var contract.
      environment.etc."probes.py".source = ./probes.py;
      environment.systemPackages = [ pkgs.python3 ];
    };

  testScript = ''
    machine.start()

    # ---------------------------------------------------------------
    # 1. Boot completion + per-unit readiness.
    # ---------------------------------------------------------------
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("autonity.service")
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("redis-blockscout.service")
    machine.wait_for_unit("blockscout-backend.service")
    machine.wait_for_unit("blockscout-frontend.service")
    machine.wait_for_unit("nginx.service")

    machine.wait_for_open_port(8545)   # Autonity HTTP RPC
    # Backend + frontend take longer to bind their ports under the
    # sync test than under `integration` because Autonity's continuous
    # block production competes for scheduler time. Raised the
    # timeout from the default 900 s (15 min) to 1800 s (30 min) for
    # both, matching the empirical worst case observed under TCG.
    # The 4-core VM helps but doesn't eliminate the contention.
    machine.wait_for_open_port(4000, timeout=1800)  # Blockscout backend
    machine.wait_for_open_port(3000, timeout=1800)  # Blockscout frontend
    machine.wait_for_open_port(443)    # nginx HTTPS

    # ---------------------------------------------------------------
    # 2. Run the shared probe sequence inside the VM.
    #
    # `tests/probes.py` is the single source of truth for probe
    # LOGIC across both contexts (this VM + the host-native runner
    # behind `nix run .#e2e`). It reads connection details and
    # thresholds from environment variables. Here we set those env
    # vars to point at loopback (the VM's perspective) and to the
    # let-bound chainId / blocksRequired; in the host-native runner
    # the same script gets the same env-var shape pointed at host
    # processes instead.
    #
    # `PROBE_BACKEND_UNIT=blockscout-backend.service` enables the
    # systemctl-show CHAIN_ID cross-check (probe 9), which is VM-
    # specific (host-native mode runs the backend as a plain
    # process and skips that probe with a log line).
    #
    # `runuser -u postgres --` is used in the psql command because
    # nixosTest VMs don't ship a generated /etc/sudoers, so
    # `sudo -u postgres` would fail even when Postgres is healthy.
    # ---------------------------------------------------------------
    machine.succeed(
        "PROBE_RPC_URL=http://127.0.0.1:8545 "
        "PROBE_BACKEND_URL=http://127.0.0.1:4000 "
        "PROBE_FRONTEND_URL=http://127.0.0.1:3000 "
        "PROBE_CHAIN_ID=${toString chainId} "
        "PROBE_BLOCKS_REQUIRED=${toString blocksRequired} "
        "PROBE_PSQL_CMD='${pkgs.util-linux}/bin/runuser -u postgres -- "
        "${pkgs.postgresql}/bin/psql -At -d blockscout' "
        "PROBE_BACKEND_UNIT=blockscout-backend.service "
        "${pkgs.python3}/bin/python3 /etc/probes.py",
        timeout=1800,
    )

  '';
}
