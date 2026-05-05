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
#     7. `GET /api/v2/health` returning 200 once chain progresses.
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

      # Sync-stage VM is more memory-hungry than the static fixture:
      # the indexer runs a real catchup pass + realtime fetcher AND
      # the Tendermint engine produces blocks at 1/sec. 4 GiB is the
      # observed floor; bumping to 5 GiB for the additional indexer
      # working set under sustained block production.
      virtualisation.memorySize = 5120;
      virtualisation.cores = 2;
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
    };

  testScript = ''
    import json
    import time

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
    machine.wait_for_open_port(4000)   # Blockscout backend
    machine.wait_for_open_port(3000)   # Blockscout frontend
    machine.wait_for_open_port(443)    # nginx HTTPS

    # ---------------------------------------------------------------
    # 2. Probe 2 (eth_chainId) — exact-equality against the let-bound
    # `chainIdHex`. Confirms Autonity is running the dev chain we
    # expect, AND that the threading from `chainId` (Nix int) to
    # `chainIdHex` (Nix-derived hex) is correct end-to-end.
    # ---------------------------------------------------------------
    def rpc_call(method, params=None):
        body = json.dumps({
            "jsonrpc": "2.0",
            "method": method,
            "params": params or [],
            "id": 1,
        })
        out = machine.succeed(
            "curl -fsS http://127.0.0.1:8545 "
            "-H 'Content-Type: application/json' "
            f"-d {repr(body)}"
        )
        return json.loads(out)

    def rpc_result(method, params=None):
        resp = rpc_call(method, params)
        if "result" not in resp:
            raise AssertionError(
                f"{method} returned no result field: {resp!r}"
            )
        return resp["result"]

    # Wait until JSON-RPC handler is answering coherently before
    # probing for content — `wait_for_open_port` only proves the
    # listener is bound, not that handlers are warm.
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:8545 "
        "-H 'Content-Type: application/json' "
        '-d \'{"jsonrpc":"2.0","method":"eth_chainId","id":1}\' ',
        timeout=120,
    )

    chain_id_hex = rpc_result("eth_chainId")
    assert chain_id_hex == "${chainIdHex}", (
        f"eth_chainId mismatch: expected ${chainIdHex}, got {chain_id_hex!r}"
    )

    # ---------------------------------------------------------------
    # 3. Probe 1 (eth_blockNumber >= blocksRequired) — wait for the
    # chain to actually produce blocks. Block period in dev is 1s
    # nominal; under TCG contention may degrade to 1.5-2s. Block-count
    # exit is robust to that drift; no wall-clock heuristic.
    #
    # This wait gates everything below it: probes 4 and 5 (consensus-
    # state probes) target the live Tendermint engine and need the
    # chain to be in a settled epoch state; probe 6 (psql block count)
    # needs the indexer to have caught up. Querying any of those
    # before the chain has progressed past startup transients trips
    # `tendermint_getCommittee` with "the inserting height is out of
    # epoch range" (committee cache not yet populated for the resolved
    # block height when only blocks 0-1 exist).
    # ---------------------------------------------------------------
    def block_number():
        return int(rpc_result("eth_blockNumber"), 16)

    # Poll in Python rather than via `wait_until_succeeds` + a shell
    # one-liner: keeps the hex→int conversion in Python (no in-VM jq
    # / printf hex-decoding gymnastics that would race pipe stdin) and
    # gives us a clear error message on timeout. Same effective
    # contract as `wait_until_succeeds`: poll every 2 s, fail after
    # the timeout window.
    deadline = time.monotonic() + 300
    while True:
        height = block_number()
        if height >= ${toString blocksRequired}:
            break
        if time.monotonic() > deadline:
            raise AssertionError(
                f"chain did not reach blocksRequired "
                f"(${toString blocksRequired}) in 300 s: got {height}"
            )
        time.sleep(2)

    # ---------------------------------------------------------------
    # 4. Probe 3 (tendermint_getCommittee at "0x0") — assert committee
    # size is exactly 1, matching the dev chain's `MaxCommitteeSize=1`.
    # Validates the Autonity-native consensus RPC namespace is
    # functional, not just the geth-inherited eth_*.
    #
    # We query at genesis ("0x0"), not "latest". `BlockChain
    # .EpochByHeight` (`core/blockchain_reader.go:43`) has a fast-path
    # for `height == 0` returning the genesis epoch directly. For any
    # other height it delegates to `HeaderChain.EpochByHeight`
    # (`core/headerchain.go:558`), which trips `ErrOutOfEpochRange`
    # ("the inserting height is out of epoch range") whenever the
    # queried height exceeds the latest registered epoch header's
    # `NextEpochBlock`. At block ~72 in dev mode the only registered
    # epoch header is still genesis (NextEpochBlock=60), so 72 > 60
    # trips the gate — passing "latest" or any non-zero height fails
    # until enough epoch transitions have been committed for the
    # cache to span the current head. Genesis committee on dev is the
    # pre-bonded dev validator (`core/genesis.go DeveloperGenesis
    # Block`), size 1 — semantically the same assertion target as
    # querying at "latest" would have been if the API permitted it.
    # ---------------------------------------------------------------
    committee = rpc_result("tendermint_getCommittee", ["0x0"])
    assert isinstance(committee, list), (
        f"tendermint_getCommittee did not return a list: {committee!r}"
    )
    assert len(committee) == 1, (
        f"tendermint_getCommittee returned {len(committee)} members, "
        f"expected 1 (single-validator dev chain): {committee!r}"
    )

    # ---------------------------------------------------------------
    # 5. Probe 4 (tendermint_getCoreState height advancing) — sample
    # twice with a sleep between, assert the Tendermint engine is
    # still producing. Defends against the failure mode where the
    # chain passed the threshold but then stalled (e.g. a consensus
    # livelock or scheduler starvation under TCG).
    # ---------------------------------------------------------------
    state_before = rpc_result("tendermint_getCoreState")
    height_before = int(state_before.get("height", 0))
    machine.succeed("sleep 5")
    state_after = rpc_result("tendermint_getCoreState")
    height_after_state = int(state_after.get("height", 0))
    assert height_after_state > height_before, (
        "tendermint_getCoreState height did not advance over 5s: "
        f"before={height_before} after={height_after_state}"
    )

    # ---------------------------------------------------------------
    # 6. Probe 5 (psql count(*) FROM blocks >= blocksRequired) — the
    # belt-and-braces direct-DB probe. Catches API/DB drift: e.g. a
    # cached `indexing-status` response while the underlying table is
    # empty, or vice versa.
    # ---------------------------------------------------------------
    # Same Python-loop pattern as the eth_blockNumber wait above:
    # query psql via machine.execute, parse the result in Python,
    # poll until the indexer has caught up to blocksRequired.
    #
    # `machine.execute` (not `succeed`) so we can tolerate the
    # startup window where Blockscout's Ecto migrations
    # (`Explorer.ReleaseTasks.migrate([])` inside the backend's
    # ExecStart wrapper) haven't yet created the `blocks` table.
    # Until then psql returns a non-zero status with "relation
    # \"blocks\" does not exist"; we treat that as count = 0 and
    # let the wait loop keep polling instead of hard-failing.
    # `wait_for_unit("blockscout-backend.service")` only proves the
    # unit is active, not that migrations have completed.
    def block_count_in_db():
        rc, out = machine.execute(
            "${pkgs.sudo}/bin/sudo -u postgres "
            "${pkgs.postgresql}/bin/psql -At -d blockscout "
            "-c 'SELECT count(*) FROM blocks'"
        )
        if rc != 0:
            return 0
        return int(out.strip())

    deadline = time.monotonic() + 600
    while True:
        count = block_count_in_db()
        if count >= ${toString blocksRequired}:
            break
        if time.monotonic() > deadline:
            raise AssertionError(
                f"indexer did not reach blocksRequired "
                f"(${toString blocksRequired}) in 600 s: got {count}"
            )
        time.sleep(5)

    # ---------------------------------------------------------------
    # 7. Probe 6 (/api/v2/main-page/indexing-status) — the
    # Blockscout-side view. With dev's 1s block production the indexer
    # may briefly oscillate between "finished_indexing_blocks: true"
    # and "false" as new blocks land. We accept either
    # `finished_indexing_blocks: true` or `indexed_blocks_ratio >=
    # 1.0` to ride that ratio flap.
    # ---------------------------------------------------------------
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/v2/main-page/indexing-status "
        "| ${pkgs.jq}/bin/jq -e "
        "'.finished_indexing_blocks == true or .indexed_blocks_ratio >= 1.0'",
        timeout=300,
    )

    # ---------------------------------------------------------------
    # 8. Probe 7 (/api/v2/health) — full chain-aware health check.
    # Returns 200 once the indexer has at least one block recorded
    # within `HEALTH_MONITOR_BLOCKS_PERIOD` (default 5 min, comfortably
    # passes at 1 block/sec). The static `integration` test asserts
    # this returns 400 (chain stuck at genesis); under sync the
    # contract flips.
    # ---------------------------------------------------------------
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/v2/health",
        timeout=300,
    )

    # ---------------------------------------------------------------
    # 9. Frontend cross-check — envs.js carries the dev chain ID, not
    # the module-default MainNet ID. Validates the publicEnv override
    # threading.
    # ---------------------------------------------------------------
    envsjs = machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:3000/assets/envs.js",
        timeout=120,
    )
    assert '"${toString chainId}"' in envsjs, (
        f"envs.js missing dev chain ID '${toString chainId}': {envsjs!r}"
    )

    # ---------------------------------------------------------------
    # 10. Backend CHAIN_ID env cross-check — same pattern as the
    # static `integration` test. The threading proved correct via the
    # eth_chainId / envs.js / count-of-blocks probes; this assertion
    # additionally verifies the backend module's `cfg.chain.id ->
    # CHAIN_ID` env-var rendering, closing the regression mode where
    # a future refactor of the backend's env wiring could leave this
    # test green.
    # ---------------------------------------------------------------
    backend_env = machine.succeed(
        "systemctl show -p Environment --value blockscout-backend.service"
    ).strip()
    assert "CHAIN_ID=${toString chainId}" in backend_env, (
        f"backend CHAIN_ID env missing or mismatched: {backend_env!r}"
    )
  '';
}
