# Contributing

## Conventions

- **Signed commits** are required. `git commit -S`.
- **Conventional Commits** on all commit + PR + issue titles: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `ci:`, `refactor:`, `spike:`.
- **Title emojis at the end**, never at the start: ⛵ stable change, ⚓ ops, 🔐 security, 🐙 epic, 🔍 spike, 🐛 fix. Emojis before the Conventional Commit type break commitlint.
- **Branch naming**: `<type>/<issue>-<description>` — e.g. `feat/4-autonity-module`, `docs/12-readme-scope`. Lowercase kebab only.
- **`Refs #N`** in commit bodies, never `Closes #N`. Closing an issue is a deliberate post-merge decision, not a side-effect of a merge commit.
- **Draft PRs by default**. CI passing does not mean ready to merge.
- **Never** push to `main`. Never force-push or amend published commits — stack separate signed commits and squash-merge at PR close.

## Module authoring

New NixOS service modules MUST follow the patterns below. Full rationale and the detailed hardening matrix live in the upstream `nix-modules-hardening` Claude skill; this section is the operator-level summary.

- **Options**: `enable` via `mkEnableOption`, `package` via `mkPackageOption`, `settings` / `extraArgs` as escape hatches so operators never need to fork the module to set a config value.
- **Users**: `DynamicUser = true;` by default. Use a static UID only if the service owns persistent on-disk state that must survive rebuilds with stable ownership (e.g. PostgreSQL).
- **Binding**: loopback only (`127.0.0.1`) unless the service is explicitly externally-facing (nginx on 80/443, Autonity P2P on 30303).
- **Internal networking**: TCP-localhost between data-plane services. Both PostgreSQL and Redis pivoted off UNIX sockets after surfacing parser-level limitations in Blockscout's Elixir clients: Postgrex parses URL host:port for the actual TCP connect (ignores libpq's `?host=` query for socket overrides), and Redix's `Redix.URI.to_start_options/1` rejects the `unix://` scheme outright (only `redis://`, `valkey://`, `rediss://` accepted). Where UNIX sockets ARE used (e.g. PostgreSQL's standard socket exposed for ad-hoc operator access via `psql`), cross-service access is granted via `SupplementaryGroups` on the consumer, never via `BindReadOnlyPaths` on the directory.
- **Defense-in-depth systemd hardening**: `ProtectSystem = "strict"`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, `LockPersonality`, `CapabilityBoundingSet = [ "" ]` (empty) unless specific caps are required, narrow `RestrictAddressFamilies`, `SystemCallFilter` with the standard deny groups (`~@cpu-emulation @debug @keyring @memlock @mount @obsolete @privileged @resources @setuid`).
- **Secrets**: ingest via `LoadCredential=name:/path`. Application reads from `$CREDENTIALS_DIRECTORY/name`, NEVER from the source path. Never `Environment=` or `EnvironmentFile=` with plaintext paths. Avoid `export`-ing credentials into process environment unless the application cannot accept a file path (see the skill for the three-pattern preference order).
- **`MemoryDenyWriteExecute`**: `true` by default. JIT runtimes (BEAM, V8, LuaJIT, JVM, ONNX, PyPy) opt out with an inline comment explaining the runtime. Go and Rust do NOT need an opt-out.
- **Unit ordering**: `after=` on every dependency. `requires=` only when the dependency failing should propagate. `wants=` for soft dependencies.

## Hardening matrix validation

Every PR runs `checks.<system>.hardening` (defined by `tests/hardening-matrix.nix`) as part of `nix flake check`. The check renders a stub NixOS system with all six service modules enabled at sane defaults, walks each unit's merged `serviceConfig`, and compares against an expected-shape table encoded inline. Any drift — a key with a different value, or an expected key gone missing — fails the build with a per-unit per-key error report.

The expected-shape table is the **as-shipped** state, not an aspirational uniform baseline. nixpkgs' upstream nginx / postgresql / redis units differ from the data-plane modules in several places (`CapabilityBoundingSet` shape, `SystemCallFilter` style, `AF_NETLINK` presence). The check enforces the *current* shipped values; nixpkgs upstream choices are nixpkgs' problem.

**Maintenance contract**: when a module change legitimately requires updating one of these expectations — adding a new module, introducing a new per-unit deviation (e.g. another JIT runtime joining the `MemoryDenyWriteExecute = false` list), or absorbing a nixpkgs upstream change to a wrapped unit — update the relevant `expected.<unit>` entry in `tests/hardening-matrix.nix` in the same PR, with the reasoning captured both in a code comment on the deviating unit's `serviceConfig` and in the PR description. Without that paper trail, the check stops being meaningful: it would just be a rubber stamp for whatever the tree happens to ship.

The check covers `serviceConfig` keys only. ExecStart paths, `Environment=` values, `LoadCredential=` entries, and similar are validated by per-module `config.assertions` (option-set time) and by the full-stack `nixosTest` (behavioural validation, see below).

## Full-stack VM integration test

`checks.<system>.integration` (defined by `tests/integration.nix`) boots all six service modules inside a single `pkgs.testers.nixosTest` VM and exercises real cross-service connectivity: loopback TCP between Autonity / backend / frontend / nginx, TCP-localhost connections to PostgreSQL (password-authenticated) and Redis, the `BindReadOnlyPaths` envs.js overlay on the frontend, the nginx reverse-proxy paths (with `forceSSL`-enforced HTTP→HTTPS redirect via a self-signed cert), and restart resilience of the backend against Postgres + Redis + Autonity.

The check runs as part of `nix flake check` alongside `fmt` and `hardening`, but it's significantly slower (4 GiB VM, ~5+ minutes on a cold cache) so iteration loops on this check should be local — `nix build .#checks.x86_64-linux.integration --print-build-logs` for full failure visibility.

**Scope**: behavioural connectivity + reverse-proxy + restart paths. **Out of scope**:

- Real chain sync — Autonity runs `--nodiscover --maxpeers=0` so it stays a single-node chain at genesis. Real MainNet sync is M3 OVH-deployment territory.
- Real ACME / Let's Encrypt — a self-signed cert is wired directly into the nginx vhost; live HTTP-01 validation against a public DNS name is M3.
- Performance / load testing.

## PR workflow

1. Open an issue describing the change.
2. Branch from `main` as `<type>/<issue>-<description>`.
3. Make signed commits with Conventional-Commit titles and `Refs #N` bodies.
4. Open a draft PR. Fill the PR template.
5. Address review comments in new signed commits. Never amend, never force-push.
6. Once reviews land clean and checks pass, the PR is ready for squash-merge. Reviewer closes the PR; the post-merge acceptance-criteria review on the linked issue is a deliberate separate step.
