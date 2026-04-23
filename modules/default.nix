# Aggregate NixOS module for the autonity-blockscout-nixos stack.
#
# Service modules are added to this imports list as they land in
# subsequent PRs. The bootstrap aggregate is intentionally empty so the
# glue-repo scaffolding (flake.nix, devenv.nix, CI, release-please,
# issue/PR templates, LICENCE, CONTRIBUTING.md) can be reviewed and
# merged independently of any service-module semantics.
{ ... }:

{
  imports = [
    # Service modules land here as they ship:
    #   ./autonity.nix
    #   ./blockscout-postgresql.nix
    #   ./blockscout-redis.nix
    #   ./blockscout-backend.nix
    #   ./blockscout-frontend.nix
    #   ./blockscout-nginx.nix
  ];
}
