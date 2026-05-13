# Secrets and runtime-fed values for `deployments/ovh-test/`

The deployment is fully reproducible from a public flake — **no operator-specific value lands in committed config**. Secrets and DNS-shape values are fed at deploy time from your local environment.

## Where values live

| File | Consumed by | When | Mechanism |
|---|---|---|---|
| `~/.config/pharos-secrets/secret_key_base` | `blockscout-backend` (Phoenix cookie signing) | runtime, host | shipped to `/var/lib/pharos-secrets/secret_key_base` via `nixos-anywhere --extra-files`, ingested by systemd `LoadCredential` |
| `~/.config/pharos-secrets/database_password` | `blockscout-postgresql` (role setup) + `blockscout-backend` (DATABASE_URL) | runtime, host | same path; same `LoadCredential` mechanism |
| `~/.config/pharos-secrets/server_name` | `blockscout-nginx` (vhost identity, ACME cert SAN) | Nix eval (`--impure`), **operator's machine** | `make` reads + exports as `PHAROS_SERVER_NAME` env var; the flake reads it via `builtins.getEnv` at eval time |
| `~/.config/pharos-secrets/acme_email` | `blockscout-nginx` (ACME registration) | Nix eval (`--impure`), **operator's machine** | same shape — `PHAROS_ACME_EMAIL` env var |
| `~/.config/pharos-secrets/root_authorized_keys` | OpenSSH (root login) | install, host | shipped to `/root/.ssh/authorized_keys` via `nixos-anywhere --extra-files` at first install |

The `runtime, host` rows use systemd's standard credentials path: file ships to `/var/lib/pharos-secrets/<name>` via `--extra-files`, the relevant module ingests via `LoadCredential=<name>:/var/lib/pharos-secrets/<name>`, the service reads from `$CREDENTIALS_DIRECTORY/<name>` at unit start.

The `Nix eval (--impure), operator's machine` rows are read by `make` locally and exported as `PHAROS_SERVER_NAME` / `PHAROS_ACME_EMAIL` env vars before invoking nixos-anywhere / nixos-rebuild. The flake's `nixosConfigurations.ovh-test` reads these via `builtins.getEnv` at evaluation time, which requires the `--impure` flag (the Makefile passes it). Because the closure is built on the operator's machine before being shipped to the target, the operator's values land in the closure that gets installed; the target host never sees the values directly outside what nginx config rendering encodes.

Without the env vars set (e.g. CI's `nix flake check`), `builtins.getEnv` returns `""` and the deployment falls back to the fail-closed `lib.mkDefault` placeholders in `configuration.nix` (`deployment.invalid` / `ops@deployment.invalid`). This keeps the public flake pure while letting operator-customised builds inject the values cleanly.

**An earlier draft used a gitignored `pharos-runtime.nix` file imported via `builtins.pathExists` — but Nix's flake source-tree is VCS-filtered, so gitignored files are excluded from the store copy and `pathExists` always returned false. The current `--impure` + `getEnv` approach sidesteps the source-filter entirely.**

## Why two mechanisms

nginx renders `server_name` and `acme.email` at Nix evaluation, not at unit start time. There is no `LoadCredential` path for those values — they have to be present when Nix builds the system closure. `--impure` + `builtins.getEnv` injects them at eval time without committing the values to the public flake.

`secret_key_base` and `database_password` are read by their consuming services at unit start, so the standard `LoadCredential` path works cleanly. They ship via `--extra-files` to `/var/lib/pharos-secrets/`.

## Generating each file

Run these once (per fresh operator workstation) and re-run only when rotating values:

```bash
mkdir -p ~/.config/pharos-secrets
chmod 0700 ~/.config/pharos-secrets

# Phoenix secret_key_base — 64 bytes of randomness per the
# blockscout-backend module's stated expectation. The base64
# encoding produces ~88 ASCII characters; what Phoenix consumes
# is the random bytes, not the encoded length.
openssl rand -base64 64 > ~/.config/pharos-secrets/secret_key_base
chmod 0600 ~/.config/pharos-secrets/secret_key_base

# Postgres role password — 32 bytes base64
openssl rand -base64 32 > ~/.config/pharos-secrets/database_password
chmod 0600 ~/.config/pharos-secrets/database_password

# Let's Encrypt contact email — operator's chosen alias
printf 'me@example.org' > ~/.config/pharos-secrets/acme_email
chmod 0600 ~/.config/pharos-secrets/acme_email

# Public explorer hostname — must match $DOMAIN env var + your DNS A record
printf 'explorer.example.org' > ~/.config/pharos-secrets/server_name
chmod 0600 ~/.config/pharos-secrets/server_name
```

The `printf` form (no trailing newline) is the recommended hygiene even though both consumers strip trailing whitespace defensively:

- The Makefile reads these files via bash command substitution `$$(cat …)`, which strips trailing newlines from the substituted value before it lands in the `PHAROS_SERVER_NAME` / `PHAROS_ACME_EMAIL` env vars consumed by the flake's `builtins.getEnv`.
- Even with that stripping, a `printf` source-of-truth is easier to reason about than "trust the shell to clean up after `echo`" — leading whitespace, internal control characters, or multi-line content wouldn't be caught by command substitution alone. The principle is "store exactly what you mean" rather than relying on downstream sanitisation.

## Failure modes

| Missing / malformed | Symptom |
|---|---|
| `secret_key_base` missing | `blockscout-backend.service` fails: `ConditionPathExists=/var/lib/pharos-secrets/secret_key_base was not met` |
| `database_password` missing | `postgresql-setup.service` fails: `ConditionPathExists=/var/lib/pharos-secrets/database_password was not met`. (The blockscout-postgresql wrapper extends the upstream `postgresql-setup` unit with the role + password injection — there is no `blockscout-postgresql.service`.) Also fails on `blockscout-backend.service` via its own `ConditionPathExists`. |
| `server_name` missing during `make install` / `make deploy` | `make` aborts before invoking nixos-anywhere with a clear "missing pharos-secrets file" message |
| `server_name` malformed (not a DNS hostname) | Nix evaluation fails with the `services.blockscout-nginx.serverName` `types.strMatching` regex error |
| `acme_email` missing during `make install` / `make deploy` | Same shape as `server_name` missing |
| `acme_email` malformed (not email-shaped) | Nix evaluation fails with the `services.blockscout-nginx.acme.email` regex error |

## Permissions

- Directory `~/.config/pharos-secrets/`: mode 0700.
- Each operator-local file: mode 0600.
- On the target host, `secret_key_base` + `database_password` land at `/var/lib/pharos-secrets/<name>` mode 0600 owned root:root (preserved by `--extra-files`'s tar transfer).
- On the target host, `root_authorized_keys` lands at `/root/.ssh/authorized_keys` mode 0600 owned root:root.
- `server_name` and `acme_email` are NOT transferred to the host as files. The Makefile reads them from `~/.config/pharos-secrets/` and exports them as `PHAROS_SERVER_NAME` / `PHAROS_ACME_EMAIL` env vars; the flake reads those via `builtins.getEnv` at Nix-eval time on the operator's machine (requires `--impure`, which the Makefile passes). The closure built from that evaluation is what `nixos-anywhere` / `nixos-rebuild` ships to the target — so the operator's values are baked in, but never leave the operator's machine as files.
