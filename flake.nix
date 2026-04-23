{
  description = "NixOS-native deployment framework for Autonity MainNet RPC + Blockscout explorer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # flake-utils no longer carries a nixpkgs input, so no `follows` wiring
    # is needed here.
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Scope locked to x86_64-linux for the glue repo and all service
      # modules that land in subsequent PRs. No aarch64 or darwin support
      # is planned.
      systems = [ "x86_64-linux" ];
    in
    {
      # Top-level aggregate module. Service modules are imported from
      # `modules/default.nix` — initially empty; filled as each service
      # module lands via its own PR.
      nixosModules.default = ./modules;
      nixosModules.autonity-blockscout = ./modules;
    }
    // flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        formatter = pkgs.nixfmt-rfc-style;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nixfmt-rfc-style
            statix
            deadnix
          ];
        };

        # Placeholder flake checks that validate Nix formatting hygiene
        # across every tracked .nix file in the source tree. Discovery
        # is filesystem-based so new modules are covered automatically
        # as they land — no per-module maintenance on this check.
        # Real VM integration tests (`nixosTest`) land with the service
        # modules they exercise.
        checks.fmt =
          pkgs.runCommand "check-fmt"
            {
              nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
            }
            ''
              find ${self} -type f -name '*.nix' -print0 \
                | xargs -0 nixfmt --check
              touch $out
            '';
      }
    );
}
