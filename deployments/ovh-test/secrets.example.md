# Secrets and runtime-fed values for `deployments/ovh-test/`

The deployment is fully reproducible from a public flake — **no operator-specific value lands in committed config**. Secrets and DNS-shape values are fed at deploy time from your local environment.

## Where values live

| File | Consumed by | When | Mechanism |
|---|---|---|---|
| `~/.config/pharos-secrets/secret_key_base` | `blockscout-backend` (Phoenix cookie signing) | runtime, host | shipped to `/var/lib/pharos-secrets/secret_key_base` via `nixos-anywhere --extra-files`, ingested by systemd `LoadCredential` |
| `~/.config/pharos-secrets/database_password` | `blockscout-postgresql` (role setup) + `blockscout-backend` (DATABASE_URL) | runtime, host | same path; same `LoadCredential` mechanism |
| `~/.config/pharos-secrets/server_name` | `blockscout-nginx` (vhost identity, ACME cert SAN) | Nix eval, **operator's machine** | `make` reads, renders to local `./pharos-runtime.nix` (this dir, gitignored), the flake `import`s it conditionally when present |
| `~/.config/pharos-secrets/acme_email` | `blockscout-nginx` (ACME registration) | Nix eval, **operator's machine** | same as `server_name` |
| `~/.config/pharos-secrets/root_authorized_keys` | OpenSSH (root login) | install, host | shipped to `/root/.ssh/authorized_keys` via `nixos-anywhere --extra-files` at first install |

The `runtime, host` rows use systemd's standard credentials path: file ships to `/var/lib/pharos-secrets/<name>` via `--extra-files`, the relevant module ingests via `LoadCredential=<name>:/var/lib/pharos-secrets/<name>`, the service reads from `$CREDENTIALS_DIRECTORY/<name>` at unit start.

The `Nix eval, operator's machine` rows are read by `make` locally and rendered into `./pharos-runtime.nix` (this directory, gitignored). The flake's `nixosConfigurations.ovh-test` conditionally `import`s that file via `lib.optional (builtins.pathExists ./deployments/ovh-test/pharos-runtime.nix) ./deployments/ovh-test/pharos-runtime.nix`. Because `nixos-anywhere` / `nixos-rebuild` builds the system closure on the operator's machine before shipping it to the target, the operator's values land in the closure that gets installed. The target host never sees `pharos-runtime.nix` itself — only the values it configured. Without `pharos-runtime.nix` present, `nix flake check` evaluates against the fail-closed placeholders in `configuration.nix` (`deployment.invalid` / `ops@deployment.invalid`).

## Why two mechanisms

nginx renders `server_name` and `acme.email` at Nix evaluation, not at unit start time. There is no `LoadCredential` path for those values — they have to be present when Nix builds the system closure. The `pharos-runtime.nix` overlay solves this without committing them.

`secret_key_base` and `database_password` are read by their consuming services at unit start, so the standard `LoadCredential` path works cleanly.

## Generating each file

Run these once (per fresh operator workstation) and re-run only when rotating values:

```bash
mkdir -p ~/.config/pharos-secrets
chmod 0700 ~/.config/pharos-secrets

# Phoenix cookie signing key — 64 bytes base64
openssl rand -base64 48 > ~/.config/pharos-secrets/secret_key_base
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

The `printf` form (no trailing newline) is deliberate — `acme_email` and `server_name` are read with `cat` and embedded into Nix string literals. A trailing `\n` would land inside the string and break `server_name`'s DNS-label regex on the next eval.

## Failure modes

| Missing / malformed | Symptom |
|---|---|
| `secret_key_base` missing | `blockscout-backend.service` fails: `ConditionPathExists=/var/lib/pharos-secrets/secret_key_base was not met` |
| `database_password` missing | Same shape, on `blockscout-postgresql.service` setup OR `blockscout-backend.service` |
| `server_name` missing during `make install` / `make deploy` | `make` aborts before invoking nixos-anywhere with a clear "missing pharos-secrets file" message |
| `server_name` malformed (not a DNS hostname) | Nix evaluation fails with the `services.blockscout-nginx.serverName` `types.strMatching` regex error |
| `acme_email` missing during `make install` / `make deploy` | Same shape as `server_name` missing |
| `acme_email` malformed (not email-shaped) | Nix evaluation fails with the `services.blockscout-nginx.acme.email` regex error |

## Permissions

- Directory `~/.config/pharos-secrets/`: mode 0700.
- Each file: mode 0600.
- On the host, files land at `/var/lib/pharos-secrets/<name>` mode 0600 owned root:root (preserved by `--extra-files`'s tar transfer).
- `pharos-runtime.nix` lands at `/etc/pharos-runtime.nix` mode 0600 owned root:root.
