# Aggregate NixOS module for the autonity-blockscout-nixos stack.
#
# Composes every service module shipped by this repo via the imports
# list below. The bootstrap PR (#2) shipped this file empty so the
# glue-repo scaffolding (flake.nix, devenv.nix, CI, release-please,
# issue/PR templates, LICENSE, CONTRIBUTING.md) could be reviewed
# independently of any service-module semantics. The data-plane chain
# now flows top-to-bottom: chain (autonity) → indexer/API
# (blockscout-{postgresql,redis,backend}) → UI (blockscout-frontend) →
# TLS termination (blockscout-nginx).
{ ... }:

{
  imports = [
    ./autonity.nix
    ./blockscout-postgresql.nix
    ./blockscout-redis.nix
    ./blockscout-backend.nix
    ./blockscout-frontend.nix
    ./blockscout-nginx.nix
  ];
}
