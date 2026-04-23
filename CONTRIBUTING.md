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
- **Internal networking**: UNIX sockets where supported (PostgreSQL, Redis). Cross-service socket access via `SupplementaryGroups` on the consumer, never via `BindReadOnlyPaths` on the directory.
- **Defense-in-depth systemd hardening**: `ProtectSystem = "strict"`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, `LockPersonality`, `CapabilityBoundingSet = [ "" ]` (empty) unless specific caps are required, narrow `RestrictAddressFamilies`, `SystemCallFilter` with the standard deny groups (`~@cpu-emulation @debug @keyring @memlock @mount @obsolete @privileged @resources @setuid`).
- **Secrets**: ingest via `LoadCredential=name:/path`. Application reads from `$CREDENTIALS_DIRECTORY/name`, NEVER from the source path. Never `Environment=` or `EnvironmentFile=` with plaintext paths. Avoid `export`-ing credentials into process environment unless the application cannot accept a file path (see the skill for the three-pattern preference order).
- **`MemoryDenyWriteExecute`**: `true` by default. JIT runtimes (BEAM, V8, LuaJIT, JVM, ONNX, PyPy) opt out with an inline comment explaining the runtime. Go and Rust do NOT need an opt-out.
- **Unit ordering**: `after=` on every dependency. `requires=` only when the dependency failing should propagate. `wants=` for soft dependencies.

## PR workflow

1. Open an issue describing the change.
2. Branch from `main` as `<type>/<issue>-<description>`.
3. Make signed commits with Conventional-Commit titles and `Refs #N` bodies.
4. Open a draft PR. Fill the PR template.
5. Address review comments in new signed commits. Never amend, never force-push.
6. Once reviews land clean and checks pass, the PR is ready for squash-merge. Reviewer closes the PR; the post-merge acceptance-criteria review on the linked issue is a deliberate separate step.
