# Disko spec for the M3 OVH test-bed: single NVMe, GPT, no LUKS.
#
# Layout:
#   /dev/nvme0n1 (entire disk)
#     ├── 1 MiB         BIOS boot (EF02) — GRUB embeds stage 1.5 here
#     │                   on systems that boot in legacy mode; harmless
#     │                   on UEFI hosts.
#     ├── 512 MiB       ESP (EF00, vfat → /boot) — UEFI loader.
#     └── remainder     root (ext4 → /)
#
# No swap. M3 test-bed targets ~16-32 GiB instances; the 5-service
# stack fits in RAM under --dev-mode iteration. Swap-thrashing would
# mask sizing issues we want surfaced as "discovered specs" entries
# in the README, not silently absorbed by the kernel.
#
# No LUKS. Test-bed instances are ephemeral (provisioned via
# `make provision`, halted via `make halt`) and the threat model
# (cloud-provider read-access to disks) isn't mitigated by
# keyfile-on-root anyway. Production deployment — if/when M3
# closes — would add LUKS via a separate `deployments/<prod-name>/`.
#
# Device path `/dev/nvme0n1` matches OVH B3-class single-NVMe
# default. If a future OVH SKU exposes the disk as `/dev/sda` or
# similar, the override has to happen HERE (or via a deployment-
# specific overlay) — `nixos-generate-config` (run by
# `nixos-anywhere --generate-hardware-config` on first install)
# does NOT set `disko.devices.*` options, only `boot.initrd`,
# `fileSystems`, etc. The generated hardware-configuration.nix
# describes the running system from the disko-installed disk's
# perspective; it doesn't drive the install layout.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          # GRUB's BIOS boot partition. 1 MiB at the start, no
          # filesystem. UEFI ignores it; legacy boot uses it.
          size = "1M";
          type = "EF02";
        };
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
