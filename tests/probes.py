"""End-to-end probe sequence for the Autonity + Blockscout sync test.

This script is the single source of truth for probe LOGIC across both
test-running contexts:

  - VM (`tests/integration-sync.nix`'s nixosTest testScript invokes it
    via `machine.succeed("python3 /etc/probes.py", environment={...})`
    after the VM's units are up).
  - Host-native (`tests/run-e2e.sh` invokes it after spinning up the
    5-service stack as background processes).

The two contexts differ only in HOW they reach localhost:port (nixosTest
SSH-into-the-VM-and-curl vs plain curl from the host process). The
probes themselves use plain `subprocess` + `urllib` and read connection
details from environment variables, so the same Python file runs
unmodified in either context.

Env-var contract:

  PROBE_RPC_URL              Default http://127.0.0.1:8545
                             Autonity HTTP JSON-RPC endpoint.
  PROBE_BACKEND_URL          Default http://127.0.0.1:4000
                             Blockscout backend Phoenix endpoint.
  PROBE_FRONTEND_URL         Default http://127.0.0.1:3000
                             Blockscout frontend Next.js endpoint.
  PROBE_CHAIN_ID             REQUIRED, decimal integer.
                             The dev chain ID (65111111 for the
                             current `services.autonity.network = "dev"`
                             fixture). Drives both the eth_chainId
                             exact-equality assertion AND the envs.js +
                             backend Environment cross-checks.
  PROBE_BLOCKS_REQUIRED      Default 70.
                             Block-count exit threshold for both the
                             chain-progression poll and the indexer-
                             ingestion poll. 70 = one full epoch
                             crossed (EpochPeriod=60 in dev) plus a
                             10-block buffer for TCG VM contention.
  PROBE_PSQL_CMD             REQUIRED, full psql command line.
                             Examples:
                               VM:    "runuser -u postgres -- psql -At -d blockscout"
                               host:  "psql -At -d blockscout -h /tmp/run-e2e-xxx/pg"
                             The script appends `-c '<query>'` to it.
  PROBE_BACKEND_UNIT         Optional. If set, the systemctl-show
                             cross-check runs to assert
                             CHAIN_ID=<chain_id> is in the unit's
                             Environment= directive. Skipped (with a
                             log line) when the backend isn't a
                             systemd unit (host-native mode).
  PROBE_VERIFY_ENVS_CHAIN_ID Optional. If set to "1", asserts that
                             the rendered envs.js contains the
                             expected chain ID substring. Set in the
                             VM context where the frontend module
                             bind-mounts a fresh envs.js generated
                             from the test's chainId. Unset (default)
                             in host-native mode where the frontend
                             serves the package's baked-in envs.js
                             with the upstream MainNet placeholder
                             chain ID — the host-native runner
                             doesn't replicate the BindReadOnlyPaths
                             overlay (out of scope for #35; would
                             require copying the standalone tree to a
                             writable tmpdir + overwriting envs.js).
                             The envs.js file is still verified to be
                             SERVED in host-native mode; only the
                             chain-ID value assertion is skipped.

Exit code 0 on all probes passing; non-zero with a clear stderr
message on first failure.
"""

import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request


# --------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------

RPC_URL = os.environ.get("PROBE_RPC_URL", "http://127.0.0.1:8545")
BACKEND_URL = os.environ.get("PROBE_BACKEND_URL", "http://127.0.0.1:4000")
FRONTEND_URL = os.environ.get("PROBE_FRONTEND_URL", "http://127.0.0.1:3000")
BACKEND_UNIT = os.environ.get("PROBE_BACKEND_UNIT")  # may be None

try:
    CHAIN_ID = int(os.environ["PROBE_CHAIN_ID"])
except KeyError:
    sys.exit("PROBE_CHAIN_ID env var is required (decimal integer)")
except ValueError:
    sys.exit(f"PROBE_CHAIN_ID must be a decimal integer, got: {os.environ['PROBE_CHAIN_ID']!r}")

CHAIN_ID_HEX = f"0x{CHAIN_ID:x}"  # lowercase hex per geth-family convention

BLOCKS_REQUIRED = int(os.environ.get("PROBE_BLOCKS_REQUIRED", "70"))

PSQL_CMD = os.environ.get("PROBE_PSQL_CMD")
if PSQL_CMD is None:
    sys.exit("PROBE_PSQL_CMD env var is required (e.g. 'psql -At -d blockscout')")
PSQL_ARGV = shlex.split(PSQL_CMD)


# --------------------------------------------------------------------
# JSON-RPC helpers
# --------------------------------------------------------------------


def rpc_call(method, params=None):
    """POST a single JSON-RPC request to RPC_URL, return parsed response."""
    body = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}
    ).encode("utf-8")
    req = urllib.request.Request(
        RPC_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def rpc_result(method, params=None):
    """rpc_call but return .result; raise if the response carries an error."""
    resp = rpc_call(method, params)
    if "result" not in resp:
        raise AssertionError(f"{method} returned no result field: {resp!r}")
    return resp["result"]


def block_number():
    return int(rpc_result("eth_blockNumber"), 16)


def core_height(state):
    """Tolerate `Height` (Go default JSON casing) or `height` (if upstream
    later adds explicit json tags)."""
    for key in ("Height", "height"):
        if key in state:
            return int(state[key])
    raise AssertionError(
        f"tendermint_getCoreState response missing height: {state!r}"
    )


# --------------------------------------------------------------------
# DB + HTTP helpers
# --------------------------------------------------------------------

# psql poll retains last (rc, output) so the timeout AssertionError can
# include what psql said. Without this, "relation does not exist"
# (expected during the migration window) and "auth failed" / "could
# not connect" (real bugs) all look identical to "indexer hasn't
# caught up yet" — until you hit the deadline and have nothing to
# debug from.
last_psql = {"rc": 0, "output": ""}


def block_count_in_db():
    proc = subprocess.run(
        PSQL_ARGV + ["-c", "SELECT count(*) FROM blocks"],
        capture_output=True,
        text=True,
    )
    last_psql["rc"] = proc.returncode
    last_psql["output"] = (proc.stdout + proc.stderr).strip()
    if proc.returncode != 0:
        return 0
    return int(proc.stdout.strip())


def http_get(url, timeout=30):
    """GET url; return (status_code, body) or raise URLError."""
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8") if e.fp else ""


# --------------------------------------------------------------------
# Probe sequence
# --------------------------------------------------------------------


def log(msg):
    print(f"[probes] {msg}", flush=True)


def probe_eth_chain_id():
    """Probe 1: eth_chainId == hex(chain_id) — exact equality."""
    log(f"probe 1: eth_chainId == {CHAIN_ID_HEX}")
    got = rpc_result("eth_chainId")
    if got != CHAIN_ID_HEX:
        raise AssertionError(
            f"eth_chainId mismatch: expected {CHAIN_ID_HEX}, got {got!r}"
        )


def probe_eth_block_number_advances():
    """Probe 2: eth_blockNumber >= BLOCKS_REQUIRED — poll until threshold.

    Block period in dev is 1 s nominal; under TCG contention may degrade
    to 1.5–2 s. Block-count exit is robust to that drift. This probe
    gates everything below — probes 3+4 (consensus state) and 5+6+7
    (indexer + health) all need the chain to have advanced past startup
    transients.
    """
    log(f"probe 2: poll eth_blockNumber until >= {BLOCKS_REQUIRED}")
    deadline = time.monotonic() + 300
    while True:
        height = block_number()
        if height >= BLOCKS_REQUIRED:
            log(f"  reached height {height}")
            return
        if time.monotonic() > deadline:
            raise AssertionError(
                f"chain did not reach BLOCKS_REQUIRED ({BLOCKS_REQUIRED}) "
                f"in 300 s: got {height}"
            )
        time.sleep(2)


def probe_tendermint_committee():
    """Probe 3: tendermint_getCommittee at "0x0" — committee size == 1.

    Querying at genesis ("0x0") explicitly. `BlockChain.EpochByHeight`
    has a fast-path for height==0 returning the genesis epoch directly.
    Any other height delegates to `HeaderChain.EpochByHeight` which
    trips ErrOutOfEpochRange whenever the queried height exceeds the
    latest registered epoch header's NextEpochBlock — and in dev mode
    only the genesis epoch is registered, so anything past block 60
    fails. Genesis committee on dev is the pre-bonded dev validator,
    size 1, which is what we want to assert anyway.

    Response shape (verified empirically): `*types.Committee` struct
    serialised as `{"members": [...], ...}` — NOT a bare member list.
    """
    log("probe 3: tendermint_getCommittee at 0x0 — size == 1")
    committee = rpc_result("tendermint_getCommittee", ["0x0"])
    if not (isinstance(committee, dict) and "members" in committee):
        raise AssertionError(
            f"tendermint_getCommittee response shape unexpected: {committee!r}"
        )
    members = committee["members"]
    if not isinstance(members, list):
        raise AssertionError(f"committee.members is not a list: {members!r}")
    if len(members) != 1:
        raise AssertionError(
            f"committee.members has {len(members)} entries, "
            f"expected 1 (single-validator dev chain): {members!r}"
        )


def probe_tendermint_core_state_advances():
    """Probe 4: tendermint_getCoreState — height advances over 5 s.

    Defends against the failure mode where the chain passed the
    threshold but then stalled (consensus livelock, scheduler
    starvation under TCG, etc.).
    """
    log("probe 4: tendermint_getCoreState — height advances over 5 s")
    state_before = rpc_result("tendermint_getCoreState")
    height_before = core_height(state_before)
    time.sleep(5)
    state_after = rpc_result("tendermint_getCoreState")
    height_after = core_height(state_after)
    if height_after <= height_before:
        raise AssertionError(
            "tendermint_getCoreState height did not advance over 5 s: "
            f"before={height_before} after={height_after}"
        )
    log(f"  height advanced {height_before} -> {height_after}")


def probe_psql_block_count():
    """Probe 5: psql count(*) FROM blocks >= BLOCKS_REQUIRED.

    Belt-and-braces direct-DB probe. Catches API/DB drift (cached
    indexing-status response while underlying table is empty, or vice
    versa).

    Tolerates non-zero psql exit during the post-`wait_for_unit`
    Ecto-migration window (treats failure as count=0 and keeps
    polling). The eventual timeout AssertionError surfaces the last
    psql output so a real failure (auth, DB name, connectivity)
    doesn't get masked as "indexer didn't catch up".
    """
    log(f"probe 5: poll psql count(*) FROM blocks until >= {BLOCKS_REQUIRED}")
    deadline = time.monotonic() + 600
    while True:
        count = block_count_in_db()
        if count >= BLOCKS_REQUIRED:
            log(f"  reached {count}")
            return
        if time.monotonic() > deadline:
            raise AssertionError(
                f"indexer did not reach BLOCKS_REQUIRED ({BLOCKS_REQUIRED}) "
                f"in 600 s: got {count}; last psql rc={last_psql['rc']}, "
                f"output={last_psql['output']!r}"
            )
        time.sleep(5)


def probe_indexing_status():
    """Probe 6: GET /api/v2/main-page/indexing-status.

    With dev's 1 s block production the indexer may oscillate between
    "finished_indexing_blocks: true" and "false" as new blocks land.
    Accept either `finished_indexing_blocks: true` OR
    `indexed_blocks_ratio >= 1.0` to ride that flap.
    """
    log("probe 6: /api/v2/main-page/indexing-status — finished or ratio>=1.0")
    deadline = time.monotonic() + 300
    while True:
        try:
            status, body = http_get(f"{BACKEND_URL}/api/v2/main-page/indexing-status")
            if status == 200:
                data = json.loads(body)
                if data.get("finished_indexing_blocks") is True or float(
                    data.get("indexed_blocks_ratio") or 0
                ) >= 1.0:
                    return
        except (urllib.error.URLError, json.JSONDecodeError):
            pass
        if time.monotonic() > deadline:
            raise AssertionError(
                "indexing-status did not reach finished/ratio>=1.0 in 300 s"
            )
        time.sleep(2)


def probe_health_endpoint():
    """Probe 7: GET /api/health — 200 once chain progresses.

    Returns 200 once the indexer has at least one block recorded
    within `Explorer.Chain.Health.Monitor.healthy_blocks_period`
    (default 5 min, comfortably passes at 1 block/sec); 500 when stale.

    The route is `/api/health`, NOT `/api/v2/health` — the `/health`
    scope is mounted at the `/api` level OUTSIDE `/v2` (per
    apps/block_scout_web/lib/block_scout_web/routers/api_router.ex
    line 533). Hitting `/api/v2/health` lands on the V2
    FallbackController's `/*path` catch-all and returns 400 for unknown
    action.
    """
    log("probe 7: GET /api/health — 200")
    deadline = time.monotonic() + 300
    while True:
        try:
            status, _ = http_get(f"{BACKEND_URL}/api/health")
            if status == 200:
                return
        except urllib.error.URLError:
            pass
        if time.monotonic() > deadline:
            raise AssertionError("/api/health did not return 200 in 300 s")
        time.sleep(2)


def cross_check_envs_js():
    """Cross-check 8: envs.js is served by the frontend, and (when
    requested) contains the expected chain ID.

    The chain-ID-value assertion is gated by PROBE_VERIFY_ENVS_CHAIN_ID.
    VM context sets it because the frontend module bind-mounts a fresh
    envs.js generated from the test's chainId. Host-native mode
    doesn't replicate that overlay (the frontend serves the package's
    baked-in envs.js with the upstream MainNet placeholder); we still
    verify envs.js is served, but skip the chain-ID-value match.
    """
    verify_chain_id = os.environ.get("PROBE_VERIFY_ENVS_CHAIN_ID") == "1"
    if verify_chain_id:
        log(f"cross-check 8: envs.js served + contains chain ID {CHAIN_ID}")
    else:
        log("cross-check 8: envs.js served (chain-ID-value check skipped — host-native mode)")
    deadline = time.monotonic() + 120
    while True:
        try:
            status, body = http_get(f"{FRONTEND_URL}/assets/envs.js")
            if status == 200:
                if verify_chain_id and f'"{CHAIN_ID}"' not in body:
                    raise AssertionError(
                        f"envs.js missing chain ID '{CHAIN_ID}': {body!r}"
                    )
                return
        except urllib.error.URLError:
            pass
        if time.monotonic() > deadline:
            raise AssertionError("could not fetch envs.js in 120 s")
        time.sleep(2)


def cross_check_backend_unit_env():
    """Cross-check 9: systemctl show -p Environment contains CHAIN_ID=<id>.

    Only runs when PROBE_BACKEND_UNIT is set (VM context). Host-native
    mode runs the backend as a plain process with no systemd unit, so
    this check is skipped with a log line.
    """
    if not BACKEND_UNIT:
        log("cross-check 9: SKIPPED (PROBE_BACKEND_UNIT unset; host-native mode)")
        return
    log(f"cross-check 9: systemctl show {BACKEND_UNIT} Environment contains CHAIN_ID={CHAIN_ID}")
    proc = subprocess.run(
        ["systemctl", "show", "-p", "Environment", "--value", BACKEND_UNIT],
        capture_output=True,
        text=True,
        check=True,
    )
    backend_env = proc.stdout.strip()
    if f"CHAIN_ID={CHAIN_ID}" not in backend_env:
        raise AssertionError(
            f"backend CHAIN_ID env missing or mismatched: {backend_env!r}"
        )


# --------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------


def main():
    probes = [
        probe_eth_chain_id,
        probe_eth_block_number_advances,
        probe_tendermint_committee,
        probe_tendermint_core_state_advances,
        probe_psql_block_count,
        probe_indexing_status,
        probe_health_endpoint,
        cross_check_envs_js,
        cross_check_backend_unit_env,
    ]
    log(
        f"starting probe sequence: rpc={RPC_URL} backend={BACKEND_URL} "
        f"frontend={FRONTEND_URL} chain_id={CHAIN_ID} "
        f"blocks_required={BLOCKS_REQUIRED} backend_unit={BACKEND_UNIT or '(unset)'}"
    )
    for probe in probes:
        probe()
    log("ALL PROBES PASSED")


if __name__ == "__main__":
    main()
