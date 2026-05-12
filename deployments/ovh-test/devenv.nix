# Devenv shell scoped to deployments/ovh-test/.
#
# Operator opts in by `cd deployments/ovh-test && devenv shell`. The
# OVH + Cloud DNS tooling intentionally does NOT bleed into the root
# devenv (which is contributor-facing — Nix formatting / linting only).
#
# All Make recipes in this directory call CLIs that this shell
# provides. Operators are still expected to bring their own API
# credentials via env vars (OVH_TOKEN, OVH_PROJECT_ID, GCLOUD_PROJECT,
# DNS_ZONE, DOMAIN); see ./README.md "Prerequisites".
{ pkgs, ... }:

{
  packages = with pkgs; [
    # NixOS install + system management
    nixos-anywhere
    disko

    # SSH for nixos-rebuild --target-host (closure copies host→host
    # over SSH), journalctl streaming, port forwarding for the
    # probe step. NOT used to ship pharos-runtime.nix — that file
    # is operator-local and consumed at Nix-eval time on the
    # operator's machine; the closure is built locally and pushed
    # to the target via the standard nixos-rebuild mechanism.
    openssh

    # Probe runner — tests/probes.py is plain stdlib.
    python3

    # JSON parsing in Make recipes (parsing OVH API responses).
    jq

    # HTTP poking from the host, e.g. preflight DNS checks before
    # calling nixos-anywhere.
    curl

    # `dig` for the dns-up propagation poll loop. nixpkgs ships dig
    # as part of `bind` (the dnsutils suite); split out so the
    # closure doesn't drag in the full bind server binaries.
    bind.dnsutils

    # Local secret-file generation.
    openssl

    # OVH Public Cloud lifecycle automation.
    # CLI is in nixpkgs as `ovh-cli`; operator's API token lives in
    # OVH_TOKEN env var, project ID in OVH_PROJECT_ID.
    ovh-cli

    # Cloud DNS automation.
    # gcloud lives at pkgs.google-cloud-sdk; operator's auth state is
    # whatever they set up via `gcloud auth login` / service account
    # JSON. Project lives in GCLOUD_PROJECT env var, zone in DNS_ZONE.
    google-cloud-sdk
  ];

  # Friendly env-var preflight on shell entry. Doesn't fail the shell —
  # informational targets (`make logs`, `make snapshot`) work without
  # provisioning credentials, so operators may legitimately enter the
  # shell with only the host-side vars set.
  enterShell = ''
    missing=()
    for v in OVH_TOKEN OVH_PROJECT_ID GCLOUD_PROJECT DNS_ZONE DOMAIN; do
      if [ -z "''${!v:-}" ]; then
        missing+=("$v")
      fi
    done
    if [ ''${#missing[@]} -gt 0 ]; then
      echo "[devenv] Unset env vars: ''${missing[*]}"
      echo "[devenv]   See deployments/ovh-test/README.md \"Prerequisites\"."
      echo "[devenv]   Compute targets (provision, halt) need OVH_*; DNS targets need GCLOUD_PROJECT + DNS_ZONE + DOMAIN."
      echo "[devenv]   Informational targets (logs, snapshot) only need IP."
    fi
  '';

  scripts.check-secrets.exec = ''
    set -euo pipefail
    secrets_dir="$HOME/.config/pharos-secrets"
    required=(secret_key_base database_password acme_email server_name root_authorized_keys)
    missing=0
    for f in "''${required[@]}"; do
      path="$secrets_dir/$f"
      if [ ! -f "$path" ]; then
        echo "[check-secrets] MISSING: $path"
        missing=$((missing + 1))
        continue
      fi
      perms=$(stat -c '%a' "$path")
      if [ "$perms" != "600" ]; then
        echo "[check-secrets] WRONG PERMS: $path is $perms, expected 600"
        missing=$((missing + 1))
      fi
    done
    if [ $missing -gt 0 ]; then
      echo "[check-secrets] $missing problem(s); see deployments/ovh-test/secrets.example.md"
      exit 1
    fi
    echo "[check-secrets] OK: 5 files present, all 0600"
  '';
}
