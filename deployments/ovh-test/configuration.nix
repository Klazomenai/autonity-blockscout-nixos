# M3 OVH test-bed host configuration.
#
# Composes the six service modules from `modules/default.nix` + disko
# disk layout. Host-specific overlays are merged in at the flake
# level (NOT imported from this file) via `builtins.getEnv` reads
# requiring `--impure`:
#
#   - `hardware-configuration.nix` — generated per-instance by
#     `nixos-anywhere --generate-hardware-config` on first install;
#     gitignored. Absolute path read from `PHAROS_HARDWARE_CONFIG`
#     env var; imported by `flake.nix` when set + the file exists.
#
#   - `serverName` + `acme.email` overlay — read from
#     `PHAROS_SERVER_NAME` + `PHAROS_ACME_EMAIL` env vars, populated
#     by `make` from the operator's `~/.config/pharos-secrets/`
#     files. Applied by `flake.nix` when both are set.
#
# ## Runtime-fed values: two mechanisms, by consumer constraint
#
# Two of the four operator-specific values can be read at unit start
# via systemd `LoadCredential`:
#
#   - `secret_key_base`  → blockscout-backend at start
#   - `database_password` → blockscout-postgresql role setup + blockscout-backend DATABASE_URL composition
#
# Both modules already wire LoadCredential internally — this file
# just points `*File` options at `/var/lib/pharos-secrets/<name>`,
# and `make install` ships those files via `nixos-anywhere
# --extra-files` so they land at the right host paths before
# services start.
#
# The other two values are consumed at Nix evaluation, not at runtime:
#
#   - `server_name` (blockscout-nginx vhost identity + ACME cert SAN)
#   - `acme_email`  (Let's Encrypt registration contact)
#
# nginx renders its vhost config when Nix builds the system closure,
# so `LoadCredential` doesn't apply — there is no service binary
# that reads from `$CREDENTIALS_DIRECTORY` and templates the nginx
# config. Approaches that try to patch the rendered config via
# `extraConfig` or activation scripts can't change `server_name`
# itself, because that string IS the vhost identity in NixOS.
#
# The workable mechanism: `make` reads the operator's
# `~/.config/pharos-secrets/{server_name,acme_email}` files and
# exports them as `PHAROS_SERVER_NAME` / `PHAROS_ACME_EMAIL` env
# vars before invoking `nixos-anywhere` / `nixos-rebuild` with the
# `--impure` flag. The flake's `nixosConfigurations.ovh-test` reads
# them via `builtins.getEnv` at evaluation time. Because the closure
# is built on the operator's machine before being shipped to the
# target, the operator's values land in the system config baked
# into the closure that gets installed. The target host never sees
# the env vars directly — only what nginx config rendering encodes.
#
# An earlier draft tried a gitignored `pharos-runtime.nix` imported
# via `builtins.pathExists`, but Nix's flake source-tree is
# VCS-filtered — gitignored files are excluded from the store copy
# `pathExists` queries, so the overlay never applied. `--impure` +
# `getEnv` sidesteps the source-filter entirely.
#
# This is "runtime" in the sense of "passed in at deploy time, not
# committed to the repo." Rotating `server_name` or `acme_email`
# requires re-running `make deploy` so the env vars re-export and
# the closure rebuilds.
#
# The placeholders below (`deployment.invalid` / `ops@deployment.invalid`)
# satisfy the `services.blockscout-nginx` option-type regexes so
# `nix flake check` (which runs in pure mode where `getEnv`
# returns `""`) evaluates cleanly. They are `lib.mkDefault` so the
# operator overlay overrides them without `mkForce`.
{ config, lib, ... }:

let
  pharosSecretsDir = "/var/lib/pharos-secrets";
in
{
  imports = [
    # Service modules — the six wrappers from this flake's modules/
    # aggregate. Imported at the flake level via the root flake.nix's
    # `nixosConfigurations.ovh-test` module list, not here, to keep
    # the `nixpkgs.overlays` wiring co-located with the modules
    # attribute the flake exposes.

    # Disk layout — disko.nixosModules.disko is imported at the flake
    # level alongside the service modules. The per-host disk-config
    # itself is imported here so the deployment owns it.
    ./disk-config.nix

    # NOTE: `hardware-configuration.nix` is NOT imported here.
    # The flake's `nixosConfigurations.ovh-test` reads its
    # absolute path from the `PHAROS_HARDWARE_CONFIG` env var (via
    # `builtins.getEnv` under `--impure`) and imports it
    # conditionally when both the path is set and the file
    # exists. In CI's pure mode, `getEnv` returns "" and the
    # import is skipped, so `nix flake check` evaluates without
    # the per-instance hardware probe.
    #
    # Operator runtime values (`serverName`, `acme.email`) are
    # similarly injected by the flake from `PHAROS_SERVER_NAME` /
    # `PHAROS_ACME_EMAIL` env vars; this file holds only the
    # fail-closed placeholders for pure-mode eval.
  ];

  # ----------------------------------------------------------------
  # Service modules — enable each, point secret-file options at the
  # /var/lib/pharos-secrets/ paths populated by --extra-files.
  # ----------------------------------------------------------------

  services.autonity = {
    enable = true;
    # `network = "mainnet"` is the module default; declared explicitly
    # here to make the deployment's intent obvious in the diff. The
    # chain ID (services.autonity.chainId) defaults to 65000000 via
    # the enum-driven default chain at modules/autonity.nix.
    network = "mainnet";
  };

  services.blockscout-postgresql = {
    enable = true;
    passwordFile = "${pharosSecretsDir}/database_password";
  };

  services.blockscout-redis.enable = true;

  services.blockscout-backend = {
    enable = true;
    secretKeyBaseFile = "${pharosSecretsDir}/secret_key_base";
    databasePasswordFile = "${pharosSecretsDir}/database_password";
  };

  services.blockscout-frontend.enable = true;

  # blockscout-nginx — serverName + acme.email default to placeholders
  # that satisfy the module's option-type regexes so `nix flake check`
  # evaluates cleanly in pure mode (where `builtins.getEnv` returns
  # `""` for the operator's PHAROS_SERVER_NAME / PHAROS_ACME_EMAIL).
  # Operator-driven invocations pass `--impure` and the flake's
  # `nixosConfigurations.ovh-test` reads the env vars + applies a
  # runtime overlay that overrides these via the standard module
  # merge (no `mkForce` needed because the placeholders are
  # `mkDefault`). `acme.useStaging = true` keeps Let's Encrypt's
  # production rate limit out of the iteration loop; flip to false
  # only after the staging cert validates cleanly.
  services.blockscout-nginx = {
    enable = true;
    serverName = lib.mkDefault "deployment.invalid";
    acme = {
      enable = true;
      email = lib.mkDefault "ops@deployment.invalid";
      useStaging = lib.mkDefault true;
    };
  };

  # ----------------------------------------------------------------
  # Networking
  # ----------------------------------------------------------------

  # DHCP — OVH provisions the IP via the standard cloud-init/DHCP path.
  networking.useDHCP = lib.mkDefault true;

  # `services.blockscout-nginx.openFirewall` (default true, per
  # modules/blockscout-nginx.nix:191-193) adds 80 + 443 to
  # `networking.firewall.allowedTCPPorts` via mkIf — that's what
  # opens the public web ports, not upstream `services.nginx` which
  # never touches the firewall on its own.
  #
  # 30303 (TCP) is Autonity's P2P listener; 30303 (UDP) is its
  # discovery port. Both need explicit firewall holes here because
  # the autonity module doesn't open them itself (peer-discovery
  # geometry varies per deployment).
  networking.firewall.allowedTCPPorts = [ 30303 ];
  networking.firewall.allowedUDPPorts = [ 30303 ];

  # Generic hostname — the public DNS name lives in the runtime
  # `server_name` credential, not here. The kernel hostname is
  # cosmetic for logs / `hostname` shell output.
  networking.hostName = lib.mkDefault "pharos-test";

  # ----------------------------------------------------------------
  # SSH
  # ----------------------------------------------------------------

  services.openssh = {
    enable = true;
    # Without this, port 22 isn't added to networking.firewall —
    # `services.openssh.enable` and the firewall are independent
    # toggles in nixpkgs. Every deploy / test / logs / halt step
    # reaches the host over SSH, so a closed port 22 would brick
    # the deployment after `make install` returns.
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Operator's SSH authorized_keys for root — shipped by the Makefile
  # into `--extra-files`/root/.ssh/authorized_keys at install time
  # alongside the secrets. After `make install`, `make deploy` uses
  # `nixos-rebuild switch --target-host root@<ip>` which expects this
  # key to be in place. Source file lives at
  # `~/.config/pharos-secrets/root_authorized_keys` on the operator's
  # workstation.

  # ----------------------------------------------------------------
  # Boot loader — UEFI grub. OVH Public Cloud B3-class instances
  # boot in UEFI mode; if a future SKU surfaces as legacy BIOS, the
  # operator overrides via the host-specific hardware-configuration.
  # ----------------------------------------------------------------

  boot.loader.grub = {
    enable = true;
    device = "nodev";
    efiSupport = true;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # ----------------------------------------------------------------
  # System state version — pins the option-default-compatibility
  # baseline. Matches the version assumed by the integration tests
  # in tests/integration.nix.
  # ----------------------------------------------------------------
  system.stateVersion = "25.05";

  # ----------------------------------------------------------------
  # Fail-fast guard: every consuming systemd unit asserts the
  # required secret files exist before starting. Without this, a
  # missing file surfaces as a service-specific error deep in the
  # journal; with this, the failure is a clean
  # `ConditionPathExists=...was not met` line that names the missing
  # file.
  # ----------------------------------------------------------------
  systemd.services.blockscout-backend.unitConfig.ConditionPathExists = [
    "${pharosSecretsDir}/secret_key_base"
    "${pharosSecretsDir}/database_password"
  ];
  systemd.services.blockscout-postgresql.unitConfig.ConditionPathExists = [
    "${pharosSecretsDir}/database_password"
  ];
}
