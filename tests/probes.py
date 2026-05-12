"""End-to-end probe sequence for the Autonity + Blockscout sync test.

This script is the single source of truth for probe LOGIC across three
test-running contexts:

  - VM (`tests/integration-sync.nix`'s nixosTest testScript invokes it
    via `machine.succeed("python3 /etc/probes.py", environment={...})`
    after the VM's units are up). PROBE_MODE=dev (default).
  - Host-native (`tests/run-e2e.sh` invokes it after spinning up the
    5-service stack as background processes). PROBE_MODE=dev (default).
  - Real-hardware OVH test-bed (`deployments/ovh-test/Makefile`'s
    `make test` invokes it over SSH-tunneled ports). PROBE_MODE=m3.

The contexts differ in HOW they reach localhost:port and in WHICH probe
shape is appropriate for the chain under test. In `dev` mode the node IS
the chain source (single-validator --dev, deterministic 1s blocks, no
catch-up notion), so the probe asserts on block-count thresholds. In
`m3` mode the node is catching up with MainNet, so the probe asserts on
`eth_syncing`'s object→boolean transition plus a minimum block-delta
over a configurable window. The contract is documented in
`docs/m3-sync-probe.md`.

The probes themselves use plain `subprocess` + `urllib` and read
connection details from environment variables, so the same Python file
runs unmodified in every context.

Env-var contract:

  PROBE_MODE                 Default "dev". One of:
                               "dev" — single-validator --dev chain;
                                       probes assert on
                                       `eth_blockNumber >= BLOCKS_REQUIRED`,
                                       committee size == 1.
                               "m3"  — real-MainNet catch-up;
                                       probes assert on `eth_syncing`
                                       object→boolean transition +
                                       minimum block-delta over a
                                       probe window; committee size
                                       > 0; psql count within
                                       tolerance of eth_blockNumber.
                             The PROBE_MODE=m3 contract is locked in
                             `docs/m3-sync-probe.md`.
  PROBE_PROGRESS_BLOCKS      M3-only. Default 10.
                             Minimum eth_syncing.currentBlock delta
                             over PROBE_WINDOW_SECONDS during
                             the catch-up phase.
  PROBE_WINDOW_SECONDS M3-only. Default 60.
                             Sample interval between two
                             currentBlock readings for the
                             progress assertion.
  PROBE_BLOCKS_TOLERANCE     M3-only. Default 5.
                             Allowed lag between psql block count
                             and eth_blockNumber. Blockscout's
                             indexer trails Autonity slightly under
                             normal operation; demanding equality
                             would flap on every block.
  PROBE_M3_TRANSIENT_BUDGET  M3-only. Default 60.
                             Maximum consecutive `eth_syncing`
                             transient failures (URLError /
                             ConnectionError / JSONDecodeError)
                             before the probe gives up with a
                             "RPC unreachable" error. Resets on
                             any successful response. NOT a
                             catch-up deadline — the locked
                             contract in `docs/m3-sync-probe.md`
                             explicitly excludes catch-up
                             timeouts ("That's an SLO concern,
                             not a probe concern"). Operators
                             who want an ops-side deadline wrap
                             this script with shell `timeout`.
  PROBE_M3_STALL_TIMEOUT     M3-only. Default 120 (2x
                             PROBE_WINDOW_SECONDS).
                             Maximum wall-clock seconds without
                             `currentBlock` advancement during
                             post-progress-check polling. Catches
                             the failure mode where RPC stays
                             responsive but the chain stops
                             producing blocks. NOT a catch-up
                             deadline — it asserts liveness
                             (block production), not a target
                             completion time.
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
                             Examples (matching the actual harnesses):
                               VM:    "runuser -u postgres -- psql -At -d blockscout"
                               host:  "psql -h $STATE_DIR/pg-sock -p 5432 -U blockscout -At -d blockscout"
                             The host-native runner injects $STATE_DIR
                             (a mktemp -d path) and uses a Unix socket
                             dir under it; PGPASSWORD is set in the
                             same env. The script appends `-c '<query>'`.
  PROBE_BACKEND_UNIT         Optional. If set, the systemctl-show
                             cross-check runs to assert
                             CHAIN_ID=<chain_id> is in the unit's
                             Environment= directive. Skipped (with a
                             log line) when the backend isn't a
                             systemd unit (host-native mode).
  PROBE_DEV_VALIDATOR_CONSENSUS_KEY
                             Optional. If set, asserts that the
                             single committee member returned by
                             tendermint_getCommittee carries this
                             exact `consensusKey` value. The dev
                             chain pins
                             `params.TestValidatorConsensusKey` at
                             `cmd/utils/flags.go:1614` — the
                             consensus pubkey is identical across
                             every dev launch (unlike etherbase
                             which rotates per
                             `flags.go:1599-1606`), so the
                             assertion is stable. Empirically the
                             value serialises as a 0x-prefixed
                             96-byte hex string (BLS public key,
                             96 bytes = 192 hex chars). Default
                             unset → only the committee size is
                             asserted.
  PROBE_VERIFY_ENVS_CHAIN_ID Optional. If set to "1", additionally
                             asserts that the rendered envs.js
                             contains the expected chain ID. Both
                             the VM testScript and the host-native
                             runner set this to "1" — VM places a
                             fresh envs.js via the frontend module's
                             BindReadOnlyPaths overlay, host-native
                             does the equivalent via a writable
                             symlink-tree mirror in the state dir.
                             Default (unset) is the escape hatch for
                             running probes.py against a stack that
                             serves the package's baked-in
                             placeholder envs.js — only the "envs.js
                             is served" half of the assertion then
                             runs.

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
DEV_VALIDATOR_CONSENSUS_KEY = os.environ.get("PROBE_DEV_VALIDATOR_CONSENSUS_KEY")  # may be None

try:
    CHAIN_ID = int(os.environ["PROBE_CHAIN_ID"])
except KeyError:
    sys.exit("PROBE_CHAIN_ID env var is required (decimal integer)")
except ValueError:
    sys.exit(f"PROBE_CHAIN_ID must be a decimal integer, got: {os.environ['PROBE_CHAIN_ID']!r}")

CHAIN_ID_HEX = f"0x{CHAIN_ID:x}"  # lowercase hex per geth-family convention

# Same parse-error reporting shape as PROBE_CHAIN_ID — surface a
# concise one-liner rather than letting Python's traceback frighten
# operators away from the env-var override path.
_blocks_required_raw = os.environ.get("PROBE_BLOCKS_REQUIRED", "70")
try:
    BLOCKS_REQUIRED = int(_blocks_required_raw)
except ValueError:
    sys.exit(
        f"PROBE_BLOCKS_REQUIRED must be a decimal integer, "
        f"got: {_blocks_required_raw!r}"
    )

PSQL_CMD = os.environ.get("PROBE_PSQL_CMD")
if PSQL_CMD is None:
    sys.exit("PROBE_PSQL_CMD env var is required (e.g. 'psql -At -d blockscout')")
PSQL_ARGV = shlex.split(PSQL_CMD)

# Mode selection — `dev` (single-validator, deterministic) vs `m3`
# (real MainNet catch-up, eth_syncing-driven). Default `dev` keeps
# every existing call site (VM testScript + host-native run-e2e.sh)
# unchanged.
PROBE_MODE = os.environ.get("PROBE_MODE", "dev")
if PROBE_MODE not in ("dev", "m3"):
    sys.exit(f"PROBE_MODE must be 'dev' or 'm3', got: {PROBE_MODE!r}")


def _parse_positive_int(name, default):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError:
        sys.exit(f"{name} must be a decimal integer, got: {raw!r}")
    if value <= 0:
        sys.exit(f"{name} must be positive, got: {value}")
    return value


def _parse_non_negative_int(name, default):
    """Like _parse_positive_int but accepts 0. Used for tolerance-style
    knobs where 0 is a valid (strict-equality) configuration."""
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError:
        sys.exit(f"{name} must be a decimal integer, got: {raw!r}")
    if value < 0:
        sys.exit(f"{name} must be non-negative, got: {value}")
    return value


# M3-only knobs. Parsed unconditionally so misconfiguration surfaces
# at startup regardless of mode (no surprise failures partway through
# a probe sequence). Only consumed by the M3 probe variants.
PROGRESS_BLOCKS = _parse_positive_int("PROBE_PROGRESS_BLOCKS", 10)
PROBE_WINDOW_SECONDS = _parse_positive_int("PROBE_WINDOW_SECONDS", 60)
# Tolerance allows 0 (strict head==count) for debugging configurations
# where the indexer is known to be in lockstep with the chain.
BLOCKS_TOLERANCE = _parse_non_negative_int("PROBE_BLOCKS_TOLERANCE", 5)
M3_TRANSIENT_BUDGET = _parse_positive_int("PROBE_M3_TRANSIENT_BUDGET", 60)
M3_STALL_TIMEOUT = _parse_positive_int("PROBE_M3_STALL_TIMEOUT", 2 * PROBE_WINDOW_SECONDS)

# Window over which `probe_tendermint_core_state_advances` samples
# the tendermint height. Dev mode uses a tight 5s window (1 block/s
# nominal cadence; 5s comfortably exceeds the noise floor). M3 mode
# uses the full probe window (60s default) per the locked contract
# in docs/m3-sync-probe.md — real MainNet block cadence is slower
# and more variable than dev's deterministic ticks.
CORE_STATE_WINDOW = PROBE_WINDOW_SECONDS if PROBE_MODE == "m3" else 5


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
    """rpc_call but return .result.

    Raises AssertionError with the underlying JSON-RPC error code +
    message when the response carries an `error` key (e.g. method
    not found, invalid params, or a server-side -32000 returned by
    Autonity for things like "the inserting height is out of epoch
    range"). Without surfacing the error payload, all such failures
    look identical to "no result field" — much harder to diagnose.

    Falls back to a generic "no result field" message when neither
    `error` nor `result` is present in the response (malformed /
    truncated JSON-RPC envelope).
    """
    resp = rpc_call(method, params)
    if "error" in resp:
        err = resp["error"]
        if isinstance(err, dict):
            raise AssertionError(
                f"{method} returned JSON-RPC error: "
                f"code={err.get('code')!r}, message={err.get('message')!r}"
            )
        raise AssertionError(f"{method} returned JSON-RPC error: {err!r}")
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
    # 10 s per-call cap. libpq has no enforced default for connect-hangs
    # on a stuck Unix socket, so without this an outer 600 s deadline
    # could be eaten by a single call that never returns. TimeoutExpired
    # is treated as a transient miss (returns 0) so the outer poll loop
    # retries; persistent stalls hit the deadline + retain last_psql for
    # the AssertionError message.
    try:
        proc = subprocess.run(
            PSQL_ARGV + ["-c", "SELECT count(*) FROM blocks"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired as exc:
        last_psql["rc"] = -1
        last_psql["output"] = f"psql timed out after {exc.timeout}s"
        return 0
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
    """Probe 1: eth_chainId == hex(chain_id) — exact equality.

    Both harnesses gate on "JSON-RPC port is open" before invoking
    probes (via `wait_for_open_port` / curl-or-tcp checks), but a
    listening socket doesn't guarantee the JSON-RPC handler
    goroutines are warm yet. Retry on connection-shaped exceptions
    (URLError, ConnectionError) for up to 60 s; raise immediately on
    a real protocol mismatch (rpc_result's AssertionError) — that's
    the handler answering coherently with the wrong value, no point
    waiting.
    """
    log(f"probe 1: eth_chainId == {CHAIN_ID_HEX}")
    deadline = time.monotonic() + 60
    while True:
        try:
            got = rpc_result("eth_chainId")
            break
        except (urllib.error.URLError, ConnectionError, json.JSONDecodeError) as e:
            if time.monotonic() > deadline:
                raise AssertionError(
                    f"eth_chainId could not be reached within 60 s: {e!r}"
                )
            time.sleep(2)
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

    Connection-shaped exceptions inside the loop (URLError /
    ConnectionError / JSONDecodeError — autonity briefly unresponsive,
    a single dropped request, malformed transient response, etc.) are
    treated the same as "not yet at threshold": keep polling until
    the deadline. Same pattern as `probe_eth_chain_id`. Without this,
    a single transient hiccup would propagate up through `main()`'s
    catch-all and abort the whole run with `probe ... raised
    URLError`, even though the chain is healthy and would have
    answered the next sample.
    """
    log(f"probe 2: poll eth_blockNumber until >= {BLOCKS_REQUIRED}")
    deadline = time.monotonic() + 300
    height = None
    while True:
        try:
            height = block_number()
        except (urllib.error.URLError, ConnectionError, json.JSONDecodeError):
            height = None
        if height is not None and height >= BLOCKS_REQUIRED:
            log(f"  reached height {height}")
            return
        if time.monotonic() > deadline:
            raise AssertionError(
                f"chain did not reach BLOCKS_REQUIRED ({BLOCKS_REQUIRED}) "
                f"in 300 s: last sample {height!r}"
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
    # Optional identity assertion — when PROBE_DEV_VALIDATOR_CONSENSUS_KEY
    # is set, verify the single member's consensusKey matches. The
    # dev chain pins `params.TestValidatorConsensusKey`, so the
    # consensus pubkey is stable across every launch (the etherbase
    # address rotates per launch and is NOT a stable assertion
    # target). Default unset → only the size assertion runs.
    if DEV_VALIDATOR_CONSENSUS_KEY:
        got_key = members[0].get("consensusKey")
        if got_key != DEV_VALIDATOR_CONSENSUS_KEY:
            raise AssertionError(
                f"committee.members[0].consensusKey mismatch: "
                f"expected {DEV_VALIDATOR_CONSENSUS_KEY!r}, got {got_key!r}"
            )


def probe_tendermint_core_state_advances():
    """Probe 4: tendermint_getCoreState — height advances over the
    configured window.

    Defends against the failure mode where the chain passed the
    threshold but then stalled (consensus livelock, scheduler
    starvation under TCG, etc.). The sample window is mode-aware:

      - dev (M2.5): 5 s — block cadence is deterministic 1 block/s,
        any longer wastes wall-clock.
      - m3: PROBE_WINDOW_SECONDS (default 60 s) — real MainNet block
        production is slower and more variable; 60 s gives the chain
        time to produce a few blocks even under network hiccups,
        matching the locked contract in docs/m3-sync-probe.md.

    Window comes from the module-level CORE_STATE_WINDOW constant
    (set at startup from PROBE_MODE).
    """
    log(
        f"probe 4: tendermint_getCoreState — height advances over {CORE_STATE_WINDOW} s"
    )
    state_before = rpc_result("tendermint_getCoreState")
    height_before = core_height(state_before)
    time.sleep(CORE_STATE_WINDOW)
    state_after = rpc_result("tendermint_getCoreState")
    height_after = core_height(state_after)
    if height_after <= height_before:
        raise AssertionError(
            f"tendermint_getCoreState height did not advance over {CORE_STATE_WINDOW} s: "
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
    Both VM and host-native runners now place a fresh envs.js with
    the test's chainId (VM via BindReadOnlyPaths overlay; host-native
    via a writable symlink-tree mirror in the state dir), so this
    gate is set to "1" in both contexts. The escape hatch remains:
    leave it unset to run probes.py against a stack serving the
    package's baked-in placeholder envs.js.
    """
    verify_chain_id = os.environ.get("PROBE_VERIFY_ENVS_CHAIN_ID") == "1"
    if verify_chain_id:
        log(f"cross-check 8: envs.js served + contains chain ID {CHAIN_ID}")
    else:
        log("cross-check 8: envs.js served (chain-ID-value check skipped — gate unset)")
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
# M3-mode probe variants (PROBE_MODE=m3)
#
# Implement the contract locked in `docs/m3-sync-probe.md`:
#
#   - `eth_syncing` returns an object during catch-up
#     ({startingBlock, currentBlock, highestBlock, ...}) and
#     transitions to boolean `false` once the head matches the
#     network. The probe asserts both states.
#   - During catch-up, two samples of `currentBlock` separated by
#     PROBE_WINDOW_SECONDS must show >= PROGRESS_BLOCKS delta.
#   - Committee size > 0 (real MainNet has multiple validators;
#     the dev-mode size==1 assertion does not apply).
#   - psql block count within BLOCKS_TOLERANCE of eth_blockNumber
#     (Blockscout indexer trails Autonity slightly under steady state;
#     demanding equality would flap on every block).
#
# These are separate functions rather than mode-conditional branches
# inside the existing dev probes, to keep the dev probe call sites
# (VM testScript + host-native run-e2e.sh) unchanged.
# --------------------------------------------------------------------


def _current_block(syncing):
    """Extract the currentBlock value from an eth_syncing object response.

    Tolerates both `currentBlock` (the canonical key) and
    `current_block` (defensive: in case a future Autonity release
    re-tags JSON fields). Returns the value as an int; treats both
    hex strings (`"0x123"`) and integers as valid inputs.

    Returns None if neither key is present — the caller decides how
    to react (raise AssertionError or treat as transient).
    """
    for key in ("currentBlock", "current_block"):
        if key in syncing:
            v = syncing[key]
            return int(v, 16) if isinstance(v, str) else int(v)
    return None


def probe_eth_syncing_caught_up():
    """M3 Probe 2: eth_syncing transitions object → boolean false,
    with a minimum block-delta over the probe window during catch-up
    AND continuous liveness (no stall) during post-verification
    polling.

    Polls eth_syncing on a 10s cadence until either:
      (a) Response is boolean `false` — node is caught up; assert
          done.
      (b) Response is an object — node is still catching up; record
          a baseline `currentBlock`, sleep PROBE_WINDOW_SECONDS,
          sample again, assert delta >= PROGRESS_BLOCKS, then
          continue polling with stall detection (see below).

    NO catch-up deadline is enforced — the locked contract in
    `docs/m3-sync-probe.md` excludes catch-up timeouts as an SLO
    concern, not a probe concern. The probe will poll indefinitely
    as long as the chain is making progress. Operators who want an
    ops-side deadline wrap this script with shell `timeout`.

    `M3_TRANSIENT_BUDGET` bounds consecutive RPC failures so the
    probe can't loop forever against an unreachable node. The
    budget resets on any successful eth_syncing response — it
    tolerates transient hiccups but exits cleanly on persistent
    outage.

    `M3_STALL_TIMEOUT` bounds the post-progress-check polling phase
    against the failure mode where RPC stays responsive but the
    chain stops producing blocks (currentBlock unchanged forever
    while `eth_syncing` keeps returning an object). The tracker
    advances on every observed `currentBlock` increase; if no
    increase is seen within STALL_TIMEOUT seconds, the probe exits
    with a chain-stall AssertionError. NOT a catch-up deadline —
    asserts liveness (block production), not target completion.
    """
    log(
        f"M3 probe 2: eth_syncing caught-up "
        f"(progress >= {PROGRESS_BLOCKS} blocks over {PROBE_WINDOW_SECONDS}s window, "
        f"transient budget {M3_TRANSIENT_BUDGET} consecutive failures, "
        f"stall timeout {M3_STALL_TIMEOUT}s)"
    )
    progress_checked = False
    transient_failures = 0
    last_advance_block = None
    last_advance_time = None
    while True:
        try:
            syncing = rpc_result("eth_syncing")
            transient_failures = 0  # reset on success
        except (urllib.error.URLError, ConnectionError, json.JSONDecodeError) as exc:
            transient_failures += 1
            if transient_failures >= M3_TRANSIENT_BUDGET:
                raise AssertionError(
                    f"eth_syncing unreachable: {transient_failures} consecutive "
                    f"transient failures (budget {M3_TRANSIENT_BUDGET}). "
                    f"Last error: {exc!r}"
                )
            log(
                f"  eth_syncing transient {transient_failures}/{M3_TRANSIENT_BUDGET}: "
                f"{exc!r}; retrying in 10s"
            )
            time.sleep(10)
            continue
        if syncing is False:
            log("  eth_syncing == false — node is caught up")
            return
        if not isinstance(syncing, dict):
            raise AssertionError(
                f"eth_syncing returned unexpected shape: {syncing!r} "
                f"(expected dict during catch-up or boolean false once caught up)"
            )
        # Object response: record baseline, sample again after window,
        # assert progress. Only run the progress check ONCE per
        # invocation — subsequent polling uses the continuous
        # stall-detection logic below.
        if not progress_checked:
            baseline = _current_block(syncing)
            if baseline is None:
                raise AssertionError(
                    f"eth_syncing object missing currentBlock field: {syncing!r}"
                )
            log(
                f"  catch-up in progress (currentBlock={baseline}); "
                f"checking progress over {PROBE_WINDOW_SECONDS}s"
            )
            time.sleep(PROBE_WINDOW_SECONDS)
            # Follow-up sample uses the same transient-retry shape as
            # the outer loop. A bare `rpc_result()` call here would
            # treat any URLError / ConnectionError as a hard failure,
            # making the probe brittle against a single transient
            # hiccup during the progress window. Retry up to
            # M3_TRANSIENT_BUDGET times with a 2s back-off; only fail
            # if the budget is exhausted (matching the outer loop's
            # "RPC unreachable" semantics).
            follow_up_failures = 0
            while True:
                try:
                    syncing2 = rpc_result("eth_syncing")
                    break
                except (urllib.error.URLError, ConnectionError, json.JSONDecodeError) as exc:
                    follow_up_failures += 1
                    if follow_up_failures >= M3_TRANSIENT_BUDGET:
                        raise AssertionError(
                            f"eth_syncing follow-up sample unreachable: "
                            f"{follow_up_failures} consecutive transient failures "
                            f"(budget {M3_TRANSIENT_BUDGET}). Last error: {exc!r}"
                        )
                    log(
                        f"  follow-up transient "
                        f"{follow_up_failures}/{M3_TRANSIENT_BUDGET}: "
                        f"{exc!r}; retrying in 2s"
                    )
                    time.sleep(2)
            if syncing2 is False:
                log("  caught up during progress window")
                return
            if not isinstance(syncing2, dict):
                raise AssertionError(
                    f"eth_syncing follow-up returned unexpected shape: {syncing2!r}"
                )
            sample2 = _current_block(syncing2)
            if sample2 is None:
                raise AssertionError(
                    f"eth_syncing follow-up missing currentBlock: {syncing2!r}"
                )
            delta = sample2 - baseline
            if delta < PROGRESS_BLOCKS:
                raise AssertionError(
                    f"chain progress too slow: {delta} blocks over {PROBE_WINDOW_SECONDS}s "
                    f"(required >= {PROGRESS_BLOCKS}); baseline={baseline}, sample={sample2}"
                )
            log(
                f"  progress OK: {delta} blocks over {PROBE_WINDOW_SECONDS}s; "
                f"continuing to poll for caught-up with stall detection"
            )
            progress_checked = True
            last_advance_block = sample2
            last_advance_time = time.monotonic()
            continue
        # Post-progress polling: continuous stall detection. The
        # chain must keep advancing — RPC alone isn't enough,
        # because a stuck consensus / scheduler starvation /
        # disk-full can leave eth_syncing returning the same
        # object forever.
        #
        # Missing currentBlock is treated as "no advancement
        # observed" — falls through to the stall check rather than
        # bypassing it. Without this fall-through, a malformed
        # object response forever would loop indefinitely (the
        # transient-failures counter is only reset on successful
        # rpc_result, which this code path already passed).
        cb = _current_block(syncing)
        if cb is not None and cb > last_advance_block:
            last_advance_block = cb
            last_advance_time = time.monotonic()
        else:
            if cb is None:
                log(f"  eth_syncing object missing currentBlock: {syncing!r}")
            stalled_for = time.monotonic() - last_advance_time
            if stalled_for > M3_STALL_TIMEOUT:
                raise AssertionError(
                    f"chain stalled: currentBlock="
                    f"{cb if cb is not None else 'missing'} unchanged for "
                    f"{stalled_for:.0f}s (timeout {M3_STALL_TIMEOUT}s). "
                    f"RPC remains responsive but no block production observed."
                )
        time.sleep(10)


def probe_tendermint_committee_present():
    """M3 Probe 3: tendermint_getCommittee at "0x0" — size > 0.

    Real MainNet has a multi-validator committee (dynamic size
    depending on stake distribution); the dev-mode `size == 1`
    assertion does not apply. Asserting `size > 0` catches the
    "committee empty / chain not initialised" failure mode without
    pinning the exact validator count.
    """
    log("M3 probe 3: tendermint_getCommittee at 0x0 — size > 0")
    committee = rpc_result("tendermint_getCommittee", ["0x0"])
    if not (isinstance(committee, dict) and "members" in committee):
        raise AssertionError(
            f"tendermint_getCommittee response shape unexpected: {committee!r}"
        )
    members = committee["members"]
    if not isinstance(members, list):
        raise AssertionError(f"committee.members is not a list: {members!r}")
    if len(members) == 0:
        raise AssertionError(
            f"committee.members is empty: {committee!r}"
        )
    log(f"  committee size = {len(members)}")


def probe_psql_block_count_matches_eth():
    """M3 Probe 5: psql count(*) FROM blocks within BLOCKS_TOLERANCE of eth_blockNumber.

    Replaces the dev-mode `count >= BLOCKS_REQUIRED` threshold. Under
    M3 the indexer trails Autonity slightly during steady-state
    operation (one block period of lag is typical, sometimes more
    under DB write pressure); BLOCKS_TOLERANCE absorbs that.

    The assertion is `eth_blockNumber - count <= BLOCKS_TOLERANCE`,
    NOT `abs(diff) <= tolerance` — count > eth_blockNumber would
    indicate a corrupted index and is itself a failure to surface.

    NO wall-clock catch-up deadline (mirrors probe_eth_syncing_caught_up
    per the locked contract in docs/m3-sync-probe.md — catch-up
    deadlines are SLO concerns, not probe concerns). Operators
    wanting an ops-side deadline wrap the script with shell
    `timeout`.

    Stall detection: tracks the highest psql block count observed.
    If the count fails to advance for M3_STALL_TIMEOUT seconds
    while the chain head IS advancing, the indexer has stalled and
    the probe exits with a clear error. Catches indexer-stuck-mid-
    catch-up — the symmetric failure mode that probe_eth_syncing's
    stall detector catches on the chain side.
    """
    log(
        f"M3 probe 5: psql count(*) FROM blocks within {BLOCKS_TOLERANCE} of "
        f"eth_blockNumber (stall timeout {M3_STALL_TIMEOUT}s, "
        f"transient budget {M3_TRANSIENT_BUDGET} consecutive head failures)"
    )
    last_count_advance_value = -1
    last_count_advance_time = time.monotonic()
    last_head_advance_value = -1
    last_head_advance_time = time.monotonic()
    head_transient_failures = 0
    while True:
        try:
            head = block_number()
            head_transient_failures = 0  # reset on success
        except (urllib.error.URLError, ConnectionError, json.JSONDecodeError) as exc:
            head = None
            head_transient_failures += 1
            # Bound the head-unreachable loop. If the RPC stays down,
            # the stall detector below would never fire (it gates on
            # head_advancing, which is False when head is None), so
            # the probe would loop forever. Mirrors
            # probe_eth_syncing_caught_up's transient-budget logic.
            if head_transient_failures >= M3_TRANSIENT_BUDGET:
                raise AssertionError(
                    f"eth_blockNumber unreachable: {head_transient_failures} "
                    f"consecutive transient failures (budget "
                    f"{M3_TRANSIENT_BUDGET}). Last error: {exc!r}. "
                    f"Cannot evaluate indexer catch-up without head."
                )
        count = block_count_in_db()
        if head is not None:
            lag = head - count
            if 0 <= lag <= BLOCKS_TOLERANCE:
                log(f"  caught up: head={head}, count={count}, lag={lag}")
                return
            if lag < 0:
                raise AssertionError(
                    f"psql count > eth_blockNumber (count={count}, head={head}); "
                    f"index appears corrupted"
                )
            # Track head advancement (chain side).
            if head > last_head_advance_value:
                last_head_advance_value = head
                last_head_advance_time = time.monotonic()
        # Track count advancement (indexer side).
        count_advanced = count > last_count_advance_value
        if count_advanced:
            last_count_advance_value = count
            last_count_advance_time = time.monotonic()

        # Stall detection — two failure modes covered, both gated on
        # the head having been seen at least once (otherwise the
        # transient-budget above is the only meaningful guard).
        if last_head_advance_value > 0:
            now = time.monotonic()
            count_stalled_for = now - last_count_advance_time
            head_stalled_for = now - last_head_advance_time

            # Indexer-only stall: count stuck while head still moving.
            # Catches the indexer falling behind under DB pressure
            # while the chain itself is healthy.
            if (
                not count_advanced
                and count_stalled_for > M3_STALL_TIMEOUT
                and head_stalled_for < M3_STALL_TIMEOUT
            ):
                raise AssertionError(
                    f"indexer stalled: psql count={count} unchanged for "
                    f"{count_stalled_for:.0f}s (timeout {M3_STALL_TIMEOUT}s) "
                    f"while chain head advanced to {head}. "
                    f"Last psql rc={last_psql['rc']}, output={last_psql['output']!r}"
                )

            # Both-stalled: head AND count both stuck. eth_syncing
            # probe passed earlier (otherwise we wouldn't be in
            # probe 5), so the chain WAS healthy at some point —
            # but it has since gone silent. Without this branch the
            # probe would hang forever when lag > BLOCKS_TOLERANCE
            # and neither side is moving.
            if (
                head_stalled_for > M3_STALL_TIMEOUT
                and count_stalled_for > M3_STALL_TIMEOUT
            ):
                lag_value = (head - count) if head is not None else "unknown"
                raise AssertionError(
                    f"chain stalled during indexer catch-up: head={head} "
                    f"stalled for {head_stalled_for:.0f}s AND count={count} "
                    f"stalled for {count_stalled_for:.0f}s "
                    f"(both > {M3_STALL_TIMEOUT}s); lag={lag_value} will not close. "
                    f"eth_syncing probe passed earlier but the chain has since gone silent."
                )
        time.sleep(5)


# --------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------


def main():
    if PROBE_MODE == "m3":
        probes = [
            probe_eth_chain_id,
            probe_eth_syncing_caught_up,
            probe_tendermint_committee_present,
            probe_tendermint_core_state_advances,
            probe_psql_block_count_matches_eth,
            probe_indexing_status,
            probe_health_endpoint,
            cross_check_envs_js,
            cross_check_backend_unit_env,
        ]
    else:
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
        f"starting probe sequence: mode={PROBE_MODE} rpc={RPC_URL} backend={BACKEND_URL} "
        f"frontend={FRONTEND_URL} chain_id={CHAIN_ID} "
        f"blocks_required={BLOCKS_REQUIRED} backend_unit={BACKEND_UNIT or '(unset)'}"
    )
    for probe in probes:
        # Convert all probe failures into a one-line stderr message
        # via sys.exit, naming the probe + the message. AssertionError
        # is the "expected" failure shape (the probe raised its own
        # diagnostic); the catch-all also covers URLError /
        # ConnectionError / ValueError / etc. that escaped the
        # probe's own retry loop. Either way, the operator is best
        # served by a concise summary — the script header docstring
        # promises "concise stderr message on first failure", and a
        # Python traceback contradicts that promise. Anyone hacking
        # on probe internals can run `python3 tests/probes.py`
        # directly to get the unfiltered traceback.
        try:
            probe()
        except AssertionError as exc:
            sys.exit(f"probe {probe.__name__} failed: {exc}")
        except Exception as exc:
            sys.exit(
                f"probe {probe.__name__} raised {type(exc).__name__}: {exc}"
            )
    log("ALL PROBES PASSED")


if __name__ == "__main__":
    main()
