{
  description = "NixOS-native deployment framework for Autonity MainNet RPC + Blockscout explorer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # flake-utils no longer carries a nixpkgs input, so no `follows` wiring
    # is needed here.

    # Autonity node package — produced by the `klazomenai/autonity` fork's
    # flake. The NixOS autonity module defaults `services.autonity.package`
    # to this input's `packages.<system>.default` (minimal ELF variant).
    # Operators wanting the portable bash-wrapped variant can override
    # with `autonity.packages.<system>.autonity-portable`.
    autonity.url = "github:klazomenai/autonity";
    autonity.inputs.nixpkgs.follows = "nixpkgs";
    autonity.inputs.flake-utils.follows = "flake-utils";

    # Blockscout backend release (Elixir mixRelease) — produced by the
    # `klazomenai/blockscout` fork's flake. The NixOS blockscout-backend
    # module defaults `services.blockscout-backend.package` to
    # `pkgs.blockscout`, wired via the nixpkgs.overlays entry below.
    blockscout.url = "github:klazomenai/blockscout";
    blockscout.inputs.nixpkgs.follows = "nixpkgs";
    blockscout.inputs.flake-utils.follows = "flake-utils";

    # Blockscout frontend (Next.js standalone) — produced by the
    # `klazomenai/blockscout-frontend` fork's flake. The NixOS
    # blockscout-frontend module defaults
    # `services.blockscout-frontend.package` to `pkgs.blockscout-frontend`,
    # wired via the nixpkgs.overlays entry below. Runtime configuration
    # (NEXT_PUBLIC_*) is generated into envs.js via `pkgs.writeText`
    # during Nix evaluation/build time and overlaid onto the package's
    # shipped placeholder via `BindReadOnlyPaths`.
    blockscout-frontend.url = "github:klazomenai/blockscout-frontend";
    blockscout-frontend.inputs.nixpkgs.follows = "nixpkgs";
    blockscout-frontend.inputs.flake-utils.follows = "flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      autonity,
      blockscout,
      blockscout-frontend,
    }:
    let
      # Scope locked to x86_64-linux for the glue repo and all service
      # modules that land in subsequent PRs. No aarch64 or darwin support
      # is planned.
      systems = [ "x86_64-linux" ];
    in
    {
      # Top-level aggregate module. Service modules are imported from
      # `modules/default.nix`. Flake inputs that provide runtime packages
      # (autonity for now; blockscout / blockscout-frontend as they
      # integrate) are exposed via a `nixpkgs.overlays` entry so service
      # modules can use the standard `mkPackageOption pkgs "<name>" { }`
      # idiom — uniform with `CONTRIBUTING.md` and the rest of nixpkgs.
      nixosModules.default = {
        imports = [ ./modules ];
        nixpkgs.overlays = [
          (final: _prev: {
            autonity = autonity.packages.${final.stdenv.hostPlatform.system}.default;
            autonity-portable = autonity.packages.${final.stdenv.hostPlatform.system}.autonity-portable;
            blockscout = blockscout.packages.${final.stdenv.hostPlatform.system}.default;
            blockscout-frontend = blockscout-frontend.packages.${final.stdenv.hostPlatform.system}.default;
          })
        ];
      };
      nixosModules.autonity-blockscout = self.nixosModules.default;
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

        # Flake checks. Static analysis only — behavioural validation
        # (real syscall denials, namespace restrictions, cross-service
        # connectivity) lives in the upcoming full-stack `nixosTest`.
        #
        # `fmt` validates Nix formatting hygiene across every tracked
        # .nix file in the source tree. Discovery is filesystem-based
        # so new modules are covered automatically as they land — no
        # per-module maintenance on this check.
        #
        # `hardening` validates the systemd `serviceConfig` hardening
        # matrix shipped on each of the six service units, against the
        # expected-shape table in `tests/hardening-matrix.nix`. Catches
        # drift cheaply at NixOS evaluation time so a future module
        # change can't silently regress on a hardening flag — the
        # matrix is frozen across 6 modules through 18 Copilot review
        # rounds; without an automated guard, only manual sweeps would
        # catch drift.
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

        checks.hardening = import ./tests/hardening-matrix.nix {
          inherit pkgs nixpkgs system;
          flake = self;
        };

        # Behavioural full-stack VM integration test — boots all six
        # service modules in a `pkgs.nixosTest` VM and exercises real
        # cross-service connectivity, the bind-mounted envs.js
        # overlay, the nginx reverse-proxy paths, and restart
        # resilience. Slow + memory-hungry (4 GiB VM, ~5+ min on a
        # cold cache); runs on every PR via `nix flake check` but
        # benefits massively from caching across repeated runs.
        # Complementary to the static `hardening` check: that one
        # asserts unit files render with the right `serviceConfig`;
        # this one asserts the units actually run and talk to each
        # other.
        checks.integration = import ./tests/integration.nix {
          inherit pkgs system;
          flake = self;
        };
      }
    );
}
