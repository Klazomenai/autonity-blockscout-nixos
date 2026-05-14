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
- **Secrets**: ingest via `LoadCredential=name:/path`. Application reads from `$CREDENTIALS_DIRECTORY/name`, NEVER from the source path. Never `Environment=` or `EnvironmentFile=` with plaintext paths. Avoid `export`-ing credentials into process environment unless the application cannot accept a file path (see the skill for the three-pattern preference order). **Two-layer off-store enforcement**: every path-typed secret option (`secretKeyBaseFile`, `databasePasswordFile`, `cookieFile`, `extraPostMigrateFile`, each `secretEnvFiles.<name>.path`, the postgres wrapper's `passwordFile`) is checked TWICE against `/nix/store/` residency: (1) eval-time `lib.hasPrefix` on the literal path string (catches Nix-path literals like `./secret` and hand-written `/nix/store/...` paths); (2) runtime `ExecStartPre=+` script (`+` runs as root) that `realpath -e`s the path and rejects any whose resolved target is under `/nix/store/` (catches `/etc/`-mounted symlinks whose target IS in the store, which the eval-time check can't see — `environment.etc` is the most common producer). Both layers ship together; integration-test fixtures use a `/run/test-secrets/` tmpfs (`system.activationScripts`) imitating sops-nix / agenix shape, and production deployments source via sops-nix / agenix into `/run/secrets/...`.
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

## Disko install test

`checks.<system>.disko-install` (defined inline in `flake.nix`) verifies that `deployments/ovh-test/disk-config.nix` produces a valid install by booting a QEMU VM, formatting the virtio disks per the disko spec, and running `nixos-install` (which also installs GRUB). Powered by disko's `makeDiskoTest` framework, which automatically rewrites the spec's `/dev/nvme0n1` to `/dev/vda` for the test VM.

Scope is **disk-config + install phase only** — service modules + the per-instance hardware-config are NOT loaded, and `testBoot = false` skips the post-install boot phase. The check catches GPT layout typos, missing ESP + mountpoint wiring, mkfs / fstab errors, and GRUB install failures (the bootloader install runs as part of `switch-to-configuration boot`, before the boot phase). Service-composition correctness on the same disk-config is covered separately by `checks.<system>.deployment-integration` (see below), which boots the full deployment config in a VM. Boot-time failures specific to the post-install boot phase (vmlinuz path drift, initrd composition, post-boot fstab mount, post-boot systemd unit failures) remain uncovered by either check — they surface only on first real-OVH cycle.

The `testBoot = false` choice is empirical: under TCG software emulation (no KVM in the local builder sandbox), the boot phase tests pass quickly but the framework's VM teardown hangs in ACPI poweroff for 15+ minutes before the build artifact materialises. Skipping the boot phase lets the check ship reliably in any environment.

**CI policy**: runs under `check-full` (push to `main` + nightly cron) — not added to `check-pr`'s explicit named-check list because the install phase still takes ~4 min under TCG. Run locally before pushing disk-config changes:

```sh
nix build .#checks.x86_64-linux.disko-install --print-build-logs
```

## Deployment-build check

`checks.<system>.deployment-build` (defined inline in `flake.nix`) forces realisation of the system closure for `nixosConfigurations.ovh-test`. Where the fast `deployment-eval` check above evaluates the option tree (catching type errors, broken imports, and assertion failures), this check actually builds the closure — surfacing derivation build failures, missing dependencies, package compile errors, and overlay conflicts that eval can't see.

The check layers `tests/stub-hardware-config.nix` on top of the production module list via `extendModules`, supplying the minimum `fileSystems."/"` + boot-initrd declarations that NixOS asserts on at eval time. The production module list defers these to the per-instance `hardware-configuration.nix` generated at install time (loaded from `PHAROS_HARDWARE_CONFIG` under `--impure`); the stub uses `lib.mkDefault` so real hardware-configurations always win automatic merging.

**CI policy**: runs only under `check-full` (push to `main` + nightly cron, per `.github/workflows/flake-check.yml`) — deliberately excluded from `check-pr` to keep PR feedback fast. The split mirrors `integration-sync`'s precedent from M2.5. Run locally before pushing hardware-touching changes:

```sh
nix build .#checks.x86_64-linux.deployment-build --print-build-logs
```

Wall-clock: ~5-15 minutes cold on a fresh checkout, faster on warm cache or Nix-binary-cache hits.

## Full-stack VM deployment-config integration test

`checks.<system>.deployment-integration` (defined by `tests/deployment-integration.nix`) boots `deployments/ovh-test/configuration.nix` itself in a `pkgs.testers.nixosTest` VM and asserts the deployment-specific option choices reach the running system. Complementary to the generic `checks.<system>.integration` (NOT a replacement): that one exercises the six service modules at module-default options; this one exercises the deployment's option-set choices specifically.

Without this check, a deployment-config-specific drift (placeholder `serverName` broken, firewall rule conflict, `ConditionPathExists` mistyped) would only surface on first OVH cruise after paying for hardware.

The check verifies five things:

1. Placeholder `serverName = "deployment.invalid"` flows through to a working nginx vhost — verified end-to-end via an HTTPS curl round-trip to `/api/health/liveness` with `--resolve` pinning the hostname to loopback (if nginx weren't `server_name`'d to the placeholder, server-block selection would fail to reach the upstream).
2. `acme.useStaging = true` resolves to the LE staging directory URL in `security.acme.certs."deployment.invalid".server` (eval-time assertion — the test fails at evaluation if it ever points at production LE).
3. Service reachability + firewall rule presence: 22/80/443/4000 verified as listening and reachable via `wait_for_open_port` (VM-internal probe — validates the service is up, not external inbound firewall policy); 30303/{tcp,udp} verified via `iptables-save` per-line inspection — autonity runs `--nodiscover --maxpeers=0` so no p2p listener is bound, but the production firewall rule must still be present.
4. `ConditionPathExists` set on `blockscout-backend.service` + `postgresql-setup.service` referencing `/var/lib/pharos-secrets/{secret_key_base,database_password}` — both static (option present) and dynamic (negative path: stop backend, remove `secret_key_base`, attempt restart, assert clean condition-failure in journal + unit `inactive`/`failed`, then restore + restart to prove the recovery path).
5. Closure builds with the actual deployment imports (disko module, GRUB, etc.); VM-incompatible bits are `mkForce`'d off via inline overrides documented in the test file.

**CI policy**: runs only under `check-full` (push to `main` + nightly cron). Excluded from `check-pr` because per-PR feedback already includes the generic `integration` check at similar wall-clock and the marginal value here lands on push-to-main / nightly. Run locally before pushing deployment-config changes:

```sh
nix build .#checks.x86_64-linux.deployment-integration --print-build-logs
```

Wall-clock: in the same band as `integration` (~22 min cold), faster on warm cache.

## Env-var contract check

`checks.<system>.env-var-contract` (defined inline in `flake.nix`) verifies that `PHAROS_SERVER_NAME` + `PHAROS_ACME_EMAIL` flow through `--impure` + `builtins.getEnv` to `services.blockscout-nginx.serverName` + `services.blockscout-nginx.acme.email` in `nixosConfigurations.ovh-test`. Catches a class of bug where the env-var name in `flake.nix` drifts from what `deployments/ovh-test/Makefile` exports — silent at eval time, but loud-fail at runtime when ACME tries to issue a cert for `deployment.invalid`.

The check has three eval paths:

- **Pure mode** (default `nix flake check`, no env vars set): emits a `skipped` sentinel explaining how to exercise the verified path. This is the expected outcome under PR-time evaluation.
- **Impure mode, both PHAROS_* set**: asserts exact-string match. Mismatch throws with a diagnostic naming both expected and actual values.
- **Impure mode, only one PHAROS_* set**: throws with a pointer to the runtimeOverlay's gate (it requires BOTH set, by design).

**CI invocation**: `check-full` runs a dedicated `--impure` step with test values exported (`test.example.org` / `ops@test.example.org`) exercising the verified path. The test values satisfy the option-type regexes but never reach a real ACME runtime — eval-time only.

Run locally:

```sh
PHAROS_SERVER_NAME=test.example.org \
PHAROS_ACME_EMAIL=ops@test.example.org \
  nix build --impure .#checks.x86_64-linux.env-var-contract --print-build-logs
```

## Nix lint checks

Every PR runs `checks.<system>.statix` and `checks.<system>.deadnix` via the `check-pr` job in `.github/workflows/flake-check.yml` (explicit `nix build` of the fast-path check list). `statix` catches Nix anti-patterns; `deadnix` catches unused let-bindings, lambda patterns, and function arguments (the `_` prefix marks intentionally-unused lambda patterns and is recognised as such). Repo-level statix config lives at `statix.toml` (no leading dot — statix searches for the unprefixed name) with rationale for any globally-disabled rules. Both run in a few seconds.

## PR workflow

1. Open an issue describing the change.
2. Branch from `main` as `<type>/<issue>-<description>`.
3. Make signed commits with Conventional-Commit titles and `Refs #N` bodies.
4. Open a draft PR. Fill the PR template.
5. Address review comments in new signed commits. Never amend, never force-push.
6. Once reviews land clean and checks pass, the PR is ready for squash-merge. Reviewer closes the PR; the post-merge acceptance-criteria review on the linked issue is a deliberate separate step.
