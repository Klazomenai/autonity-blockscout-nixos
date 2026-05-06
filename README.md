# autonity-blockscout-nixos

NixOS-native deployment framework for an Autonity MainNet RPC node + Blockscout explorer, running as pure systemd services on a single machine with defense-in-depth hardening.

## Scope

- Single machine. No multi-host, no HA orchestration.
- `x86_64-linux` only.
- Declarative, reproducible deployment via NixOS modules.
- Each service isolated via systemd hardening: `DynamicUser`, `ProtectSystem`, narrow `CapabilityBoundingSet`, `RestrictAddressFamilies`, `SystemCallFilter`.
- Internal networking via UNIX sockets and loopback wherever possible. Only the TLS reverse proxy (80/443) and the Autonity P2P port (30303) bind externally.

## Non-goals

- Kubernetes or any container orchestration.
- Multi-host / HA topologies.
- Docker / OCI images.
- blockscout-rs microservices (verifier, stats, visualiser) — tracked as a separate follow-up.

## Services composed

The glue repo provides NixOS modules for:

- `autonity` — Go binary; JSON-RPC + WS + P2P; archive mode; MainNet default.
- `blockscout-postgresql` — primary store, UNIX-socket only.
- `blockscout-redis` — cache, UNIX-socket only.
- `blockscout-backend` — Elixir/Phoenix API + indexer; UNIX socket to PostgreSQL and Redis; localhost TCP to Autonity.
- `blockscout-frontend` — Next.js standalone server; localhost TCP only.
- `blockscout-nginx` — TLS termination and reverse proxy; the only unit that binds 80/443.

Service modules land in subsequent PRs after this bootstrap merges. The current `modules/default.nix` is an intentionally empty aggregate.

## Quickstart

```sh
# Minimal developer environment from the flake — just nixfmt, statix,
# deadnix on PATH. No hook installation.
nix develop

# Fuller environment via devenv — same linters PLUS pre-commit hooks
# (nixfmt / statix / deadnix) installed into .git/hooks/.
devenv shell

# Run the flake checks (currently: Nix formatting across all tracked
# .nix files; VM integration tests land with the first service module).
nix flake check
```

Service-module composition, operator host-config patterns, and VM integration-test runbooks will be documented here as they land.

## Running locally

Two complementary harnesses for exercising the 5-service core stack (autonity, postgres, redis, blockscout backend + frontend) outside CI. Nginx + TLS-termination paths are NOT covered by these — that surface lives only in the VM check at `checks.<system>.integration-sync`:

### `nix run .#e2e` — one-shot host-native smoke

Spawns autonity (`--dev`), postgres, redis, blockscout backend, blockscout frontend as background processes in a tmpdir, runs the shared probe sequence (`tests/probes.py`), exits 0 on success or non-zero on first probe failure. Wall-clock target ~3.5–5 minutes on a warm cache.

```sh
nix run .#e2e
```

Tunable via env vars (defaults shown):

```sh
E2E_CHAIN_ID=65111111 E2E_BLOCKS_REQUIRED=70 nix run .#e2e

# Keep the state dir for debugging instead of cleaning up on exit.
E2E_KEEP_STATE=1 nix run .#e2e
```

### `devenv up` — long-lived stack for interactive debugging

Brings the same 5 services up under process-compose; tail logs in a single TUI; `Ctrl-C` to stop. Useful when iterating on the indexer or frontend rendering.

```sh
devenv up
# In another shell:
e2e-probes        # Run the probe sequence against the running stack
curl http://127.0.0.1:4000/api/health
```

### Authoritative VM check

Both above harnesses are SUPPLEMENTARY to the nixosTest VM check at `checks.<system>.integration-sync`. The VM check exercises real systemd hardening (`DynamicUser`, `LoadCredential`, `RestrictAddressFamilies`, `SystemCallFilter`, etc.) and `SupplementaryGroups` cross-service socket access — none of which the host-native harnesses reproduce. The VM is the contract; `nix run .#e2e` and `devenv up` are debugging conveniences.

```sh
nix flake check                          # Includes integration-sync on push-to-main + nightly
nix build .#checks.x86_64-linux.integration-sync -L   # Run the VM check directly
```

Probe LOGIC is shared via `tests/probes.py`; both the VM testScript and the host-native runner invoke the same Python script with different env-var contracts, so probes don't drift between contexts.

## License

GPL-3.0-only. See [`LICENSE`](./LICENSE).
