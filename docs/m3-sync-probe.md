# M3 post-deploy sync probe — design lock

This document captures the locked probe contract for verifying that the
production Autonity node is catching up with MainNet during the M3
deployment. It is the post-deploy counterpart to the M2.5 local sync
test (`tests/integration-sync.nix` + `tests/probes.py`) and shares no
implementation with it — under `--dev` the local test asserts boolean
chain liveness via `eth_blockNumber` advancement, while M3's MainNet
target needs the richer `eth_syncing` shape.

## Problem

The M2.5 local sync test exercises Autonity in `--dev` mode (single
validator, 1 s block period, in-memory chain DB). Under `--dev`, the
node IS the chain source — there is no notion of "catching up." The
right liveness probe is `eth_blockNumber` advancing; `eth_syncing`
returns boolean `false` tautologically because
`progress.CurrentBlock >= progress.HighestBlock` always holds (see
`internal/ethapi/api.go:126-132` in the autonity tree).

Production deployment is the inverse: a freshly-installed node
connects to MainNet peers, downloads headers and state, and
**genuinely** catches up. `eth_syncing` returns rich object data
during this window, then transitions to boolean `false` once the head
matches the network. The M3 probe asserts on both states.

## Empirical verification (2026-05-07)

Before locking the M3 design, the assumption "`eth_syncing` returns
`false` under `--dev` at all sample points" was empirically verified
against the `klazomenai/autonity` v1.1.2 build. Boot autonity in
`--dev` with HTTP RPC bound on `127.0.0.1:8545`, sample at four
points:

| Sample        | wall-clock | `eth_blockNumber` | `eth_syncing`       |
|---------------|------------|-------------------|---------------------|
| RPC ready     | t = 0 s    | `0x0`             | `false`             |
| after block 1 | t = 1 s    | `0x1`             | `false`             |
| t = 10 s      | t = 10 s   | `0xa`             | `false`             |
| t = 60 s      | t = 60 s   | `0x3c`            | `false`             |

Block production is steady at 1 block/s as expected. No transient
object returns observed at any sample, including across the epoch
transition at block 60 (`EpochPeriod = 60` per
`core/genesis.go:944-995`). Result confirms the assumption: under
`--dev`, `eth_syncing` is uninformative and is correctly excluded
from the M2.5 probe vocabulary.

## M3 probe contract (locked)

The M3 post-deploy probe asserts the following:

### Probe shape: state-presence, not rate-of-progress

The probe answers one question: "is the node making progress towards
the network head, or has it reached it?" Rate-of-progress
(blocks-per-minute, blocks-per-second) is diagnostics-grade and
belongs in Grafana, not the gating probe.

### Catch-up state

When `progress.CurrentBlock < progress.HighestBlock`, `eth_syncing`
returns a JSON object with at least `startingBlock`, `currentBlock`,
`highestBlock`. The probe asserts the response is an **object** (any
object — schema may vary across Autonity releases), not a boolean.

### Caught-up state

When `progress.CurrentBlock >= progress.HighestBlock`, `eth_syncing`
returns boolean `false`. The probe asserts boolean equality.

### Progress assertion (during catch-up only)

While in the catch-up state, the probe takes two samples of
`currentBlock` separated by a probe window (`probeWindowSeconds`,
default 60), and asserts:

```
sample2.currentBlock - sample1.currentBlock >= progressBlocks
```

`progressBlocks` defaults to **10** and is configurable via the M3
host config (e.g. `services.autonity.m3SyncProbe.progressBlocks`).

The default is conservative: under typical MainNet catch-up rates and
typical network conditions, ten blocks across a 60-second window
corresponds to roughly 6 blocks/min — well below the cap a
non-degraded node sustains and well above zero (a stalled node).
Operators may tighten under known good conditions.

### Explicit non-goals

- **No wall-clock rate** (blocks-per-minute / blocks-per-second). Just
  minimum delta over the probe window. Diagnostics-grade rate metrics
  live in Grafana, not in the gating probe.
- **No assertion on `startingBlock` / `highestBlock` shape**. Schemas
  vary across releases; the gate is "object vs boolean," not field
  membership.
- **No catch-up timeout**. The probe does not assert "node will be
  caught up by time T." That's an SLO concern, not a probe concern.

## Configuration surface (sketch — implementation lands with M3 host config)

```nix
services.autonity.m3SyncProbe = {
  enable = mkEnableOption "M3 post-deploy sync probe";
  progressBlocks = mkOption {
    type = types.ints.positive;
    default = 10;
    description = "Minimum currentBlock delta over probeWindowSeconds during catch-up.";
  };
  probeWindowSeconds = mkOption {
    type = types.ints.positive;
    default = 60;
    description = "Sample interval for the progress assertion.";
  };
};
```

The probe itself is implemented as a one-shot systemd timer or a
runbook smoke command — not a long-lived health check. Once `eth_syncing`
returns `false`, the probe exits 0 and the operator is free to enable
production traffic.

## Probe vocabulary parity with M2.5

The M2.5 local probe (`tests/probes.py`) and the M3 probe share the
**vocabulary** but not the **assertions**:

| Probe                       | M2.5 (`--dev`)                     | M3 (MainNet) |
|-----------------------------|------------------------------------|--------------|
| `eth_chainId`               | exact equality (`0x3e18447`)       | exact equality (mainnet chainId) |
| `eth_blockNumber`           | poll until `>= blocksRequired`     | not used (subsumed by `eth_syncing`) |
| `eth_syncing`               | **excluded** (tautologically false)| object → boolean transition + progress delta |
| `tendermint_getCommittee`   | size == 1, dev validator           | size == network committee, role-of-this-node check |
| `tendermint_getCoreState`   | height advances over 5 s           | height advances over probe window |
| `/api/v2/main-page/indexing-status` | finished or ratio >= 1.0   | same (Blockscout indexer caught up) |
| `count(*) FROM blocks`      | `>= blocksRequired`                | matches Autonity's `eth_blockNumber` (within tolerance) |
| `/api/health`               | 200                                | same |

The M2.5 probe's design lock at issue #38 commits to keeping these
two surfaces in vocabulary lockstep so M3's runbook reuses the
operator mental model from local development.

## References

- Empirical sample run: 2026-05-07, `klazomenai/autonity` v1.1.2, host kernel 6.17.0
- Source: `internal/ethapi/api.go:126-132` (`eth_syncing` predicate)
- Source: `core/genesis.go:944-995` (`DeveloperGenesisBlock`)
- M2.5 sync test: `tests/integration-sync.nix` + `tests/probes.py`
- M2.5 design lock: issue #38 (umbrella epic)
- This document: filed to resolve issue #36
