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
# Developer environment (nixfmt, statix, deadnix, pre-commit hooks)
nix develop
# or, with devenv installed:
devenv shell

# Run the flake checks
nix flake check
```

Service-module composition, operator host-config patterns, and VM integration-test runbooks will be documented here as they land.

## Licence

GPL-3.0-only. See [`LICENSE`](./LICENSE).
