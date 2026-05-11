# `deployments/ovh-test/` — OVH Public Cloud test-bed

Short-lived test-cruise harness for the M3 (Maiden Voyage) milestone. Provisions an OVH B3-class instance in UK1, installs the six service modules from this repo via `nixos-anywhere`, runs the M3 probe contract against the live host, halts the instance.

**This is not a production deployment.** The cycle is provision → test → halt; instances live for the duration of one test-cruise. Permanent production deployment is out of scope and will be a future milestone if/when it becomes a goal.

---

## Prerequisites

### One-time per workstation

1. **OVH Public Cloud account** with API credentials. Set:
   ```
   export OVH_TOKEN=...           # API token (consumer key)
   export OVH_PROJECT_ID=...      # Cloud Project ID
   ```
   Optionally override:
   ```
   export OVH_REGION=UK1          # default; other regions per OVH catalogue
   export OVH_FLAVOR=b3-8         # default; size up if your discoveries say so
   export OVH_IMAGE='NixOS 25.05' # default; matches host stateVersion
   ```

2. **Cloud DNS** (Google Cloud DNS) zone where you can add A records. Set:
   ```
   export GCLOUD_PROJECT=...      # GCP project hosting the DNS zone
   export DNS_ZONE=...            # zone name (e.g. klazomenai-dev)
   export DOMAIN=...              # full hostname (e.g. explorer.klazomenai.dev)
   ```
   Authenticate `gcloud` once (`gcloud auth login` or service-account JSON).

3. **Operator-local secret files** under `~/.config/pharos-secrets/` (mode 0700 dir, 0600 files). See [`secrets.example.md`](secrets.example.md) for the generation commands. Five files:
   - `secret_key_base` — Phoenix cookie signing
   - `database_password` — Postgres role
   - `acme_email` — Let's Encrypt registration contact
   - `server_name` — public explorer hostname (must match `$DOMAIN`)
   - `root_authorized_keys` — your SSH public key(s) for `root@` access

4. **Toolchain** — enter `devenv shell` from this directory:
   ```
   cd deployments/ovh-test
   devenv shell
   ```
   Provides `nixos-anywhere`, `disko`, `ovh-cli`, `gcloud`, `ssh`, `python3`, `jq`, `curl`, `openssl`. The shell warns at entry if any required env vars are unset.

### Per cycle

You'll typically run from `cd deployments/ovh-test && devenv shell`. The Makefile recipes assume that working directory.

---

## Test cruise: end-to-end

The happy path. Either drive each step manually or use `make cruise` for the full chain.

```bash
# 0. Verify your local secrets are in good shape.
check-secrets   # devenv script; reports missing files / wrong perms

# 1. Provision an OVH instance. Writes IP=... line + .last-instance-id.
make provision
# → e.g. IP=51.222.333.444

# 2. Export the IP for downstream recipes.
export IP=51.222.333.444

# 3. Add the DNS A record for $DOMAIN -> $IP. Polls until propagated.
make dns-up

# 4. Install NixOS via nixos-anywhere. Generates pharos-runtime.nix
#    locally from your secrets, stages all credentials at .staging/,
#    ships everything via --extra-files. Runs ~10-15 min on a fresh
#    OVH B3 (kexec + NixOS install + first activation).
make install

# 5. (Optional, for code-change iteration) Re-deploy without
#    reinstalling. Re-renders pharos-runtime.nix locally, scp's it
#    to the host, runs `nixos-rebuild switch --target-host`.
make deploy

# 6. Run the M3 probe contract via SSH-tunneled ports. Exits 0 on
#    pass, non-zero on first failure with a one-line diagnostic.
make test

# 7. Tear down. ALWAYS run halt + dns-down — paid hardware time
#    accumulates if you forget.
make halt
make dns-down
```

`make cruise` chains 1–7 (skipping 5, since deploy isn't needed on a fresh install). Use sparingly — every cruise burns hardware-time euros.

---

## Iteration: code change → redeploy

After `make install` succeeds once, the cycle for testing changes is:

```bash
# 1. Make code change in modules/, tests/, deployments/ovh-test/, etc.
# 2. Re-deploy WITHOUT halting + reprovisioning.
make deploy
make test

# When you're done iterating, halt:
make halt
make dns-down
```

This avoids the ~10-15 min nixos-anywhere install per iteration.

If your change requires a fresh disk (rarely needed — only for disko changes or chain-DB resets):

```bash
make halt && make dns-down
make provision
export IP=<new-ip>
make dns-up && make install && make test
```

---

## Discovered specs (the captain's log)

Append-only record of observations from real test-cruise runs. Each entry: date, cycle number, instance class, observed metrics, surprises.

> **Template** — copy this block, fill in, commit.
>
> ### YYYY-MM-DD — cycle N
>
> | Field | Value |
> |---|---|
> | Instance class | e.g. `b3-8` |
> | Observed RAM peak | e.g. `12 GiB during indexer ramp` |
> | Observed CPU peak | e.g. `~6 cores sustained mid-sync` |
> | Disk used `/var/lib/autonity` | e.g. `~180 GiB after probe pass` |
> | Disk used `/var/lib/private/postgresql` | e.g. `~75 GiB after probe pass` |
> | Time to first block | e.g. `~3 min from `make install` finish` |
> | Time to probe pass | e.g. `~45 min on warm OVH catalogue` |
> | Hourly cost (€) | e.g. `~0.30 EUR/hr` |
> | Surprises | e.g. `disk path was /dev/sda not /dev/nvme0n1; updated disk-config.nix` |

### (no entries yet — first cruise pending)

---

## Troubleshooting

Append entries here as cycles surface failures. Each entry: symptom (journal line / probe failure), root cause, fix.

> **Template** — copy this block when you hit something new.
>
> ### Symptom
>
> What did you see? Paste the journal line or probe error verbatim.
>
> ### Root cause
>
> What was actually wrong?
>
> ### Fix
>
> What change resolved it? Commit SHA / config knob.

### (no entries yet)

---

## Cost note

OVH Public Cloud B3-class instances bill hourly. A forgotten `make halt` accumulates burn at roughly the SKU's hourly rate (look it up in OVH's current catalogue — prices change). `make halt` is idempotent and `make cruise` always halts at the end, but manual cycles (provision + tinker, walk away) are where bills sneak up.

The discovery-section "Hourly cost" field captures the actual euros-per-hour for each cruise so future operators can budget cycles.

---

## Architecture notes

### Why public glue repo, not a private host repo

The deployment is fully reproducible from a public flake. Operator-specific values (secrets, DNS hostname, OVH account ID, ACME email) are all runtime-fed at deploy time and never enter committed config. See [`secrets.example.md`](secrets.example.md).

### Two runtime-fed mechanisms, by consumer constraint

- **systemd `LoadCredential`** for values read at unit start on the host (`secret_key_base`, `database_password`). Files ship via `nixos-anywhere --extra-files` to `/var/lib/pharos-secrets/<name>` on the target.
- **Nix-eval-time overlay** on the **operator's machine** for values consumed when Nix builds the system closure (`server_name`, `acme_email`). `make` renders them into local `./pharos-runtime.nix` (this directory, gitignored), and the flake's `nixosConfigurations.ovh-test` conditionally imports that file via `lib.optional (builtins.pathExists …)`. Because `nixos-anywhere` / `nixos-rebuild` builds the closure locally before shipping it to the target, the operator's values land in the closure that gets installed. The target host never sees `pharos-runtime.nix` itself — only the values it configured.

The split exists because nginx renders its vhost config at Nix evaluation, not at unit start — so `server_name` can't be read from a credential file at runtime. See the head comment in [`configuration.nix`](configuration.nix) for the full rationale.

`nix flake check` evaluates the deployment without the operator's `pharos-runtime.nix` present, falling back to the `lib.mkDefault` placeholders in `configuration.nix` (`deployment.invalid` / `ops@deployment.invalid`) which satisfy the option-type regexes.

### Probes hit loopback via SSH tunnels

`make test` opens an SSH ControlMaster session to the host and forwards `127.0.0.1:{8545,4000,3000}` from the operator's machine to the same ports on the host. Probes hit loopback URLs locally — no public-TLS dependency for the probe path. ACME issuance is verified separately (`curl -sv https://$DOMAIN/`).

This means the probe contract works even before the ACME cert validates, which is useful in the first few cycles when DNS propagation timing or LE staging-cert quirks might be in flux.

---

## Contributing

Surprises, scope-creep candidates, or design questions: file a comment on issue [#49](https://github.com/Klazomenai/autonity-blockscout-nixos/issues/49), spin off a follow-up issue, or open a Discussion. Don't bottle them up — the test-bed is meaningless if the lessons it surfaces aren't captured.

PRs welcome on this directory. The acceptance criteria from #49 still apply: no operator-specific identifier in committed config, all secret-file flows documented, runbook stays usable cold.
