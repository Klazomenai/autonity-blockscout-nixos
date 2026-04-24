# Aggregate NixOS module for the autonity-blockscout-nixos stack.
#
# Composes every service module shipped by this repo via the imports
# list below. New service modules are added here as they land; the
# commented placeholders show the remaining planned additions for the
# Blockscout side of the stack. The bootstrap PR (#2) intentionally
# shipped this file empty so the glue-repo scaffolding (flake.nix,
# devenv.nix, CI, release-please, issue/PR templates, LICENSE,
# CONTRIBUTING.md) could be reviewed independently of any service-
# module semantics; this PR introduces the first real service module
# (`autonity.nix`).
{ ... }:

{
  imports = [
    ./autonity.nix
    ./blockscout-postgresql.nix
    ./blockscout-redis.nix
    # Service modules land here as they ship:
    #   ./blockscout-backend.nix
    #   ./blockscout-frontend.nix
    #   ./blockscout-nginx.nix
  ];
}
