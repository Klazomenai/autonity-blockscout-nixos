{ pkgs, ... }:

{
  packages = with pkgs; [
    nixfmt-rfc-style
    statix
    deadnix
    git
    git-lfs
  ];

  git-hooks.hooks = {
    nixfmt-rfc-style.enable = true;
    statix.enable = true;
    deadnix.enable = true;
  };

  enterShell = ''
    echo "autonity-blockscout-nixos development environment"
    echo ""
    echo "Scope: x86_64-linux only."
    echo ""
    echo "Nix:"
    echo "  nix flake check        Run flake checks (fmt today; VM tests later)"
    echo "  nix fmt                Format Nix files in-place"
    echo ""
  '';
}
