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

    # Disko — declarative disk partitioning for the M3 OVH test-bed
    # `nixosConfigurations.ovh-test`. Its `nixosModules.disko` is
    # imported alongside the deployment's `configuration.nix` so
    # `disko.devices.*` options are available. Pinned `nixpkgs` to
    # this flake's input to avoid double-instantiation.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      autonity,
      blockscout,
      blockscout-frontend,
      disko,
    }:
    let
      # Scope locked to x86_64-linux for the glue repo and all service
      # modules that land in subsequent PRs. No aarch64 or darwin support
      # is planned.
      systems = [ "x86_64-linux" ];

      # Overlay wiring flake-input packages into pkgs. Defined once at
      # the outputs level so it's applied uniformly to (a) the
      # nixosModules' `nixpkgs.overlays`, and (b) the per-system pkgs
      # used by `apps.<system>.e2e` to construct a host-native runtime
      # PATH that includes the same autonity / blockscout binaries the
      # VM uses.
      flakeOverlay = (
        final: _prev: {
          autonity = autonity.packages.${final.stdenv.hostPlatform.system}.default;
          autonity-portable = autonity.packages.${final.stdenv.hostPlatform.system}.autonity-portable;
          blockscout = blockscout.packages.${final.stdenv.hostPlatform.system}.default;
          blockscout-frontend = blockscout-frontend.packages.${final.stdenv.hostPlatform.system}.default;
        }
      );
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
        nixpkgs.overlays = [ flakeOverlay ];
      };
      nixosModules.autonity-blockscout = self.nixosModules.default;

      # M3 OVH test-bed deployment (see deployments/ovh-test/README.md).
      # Consumed by `nixos-anywhere --impure --flake .#ovh-test` and
      # by `nixos-rebuild --impure --flake .#ovh-test --target-host …`.
      #
      # Operator-specific values are injected via `builtins.getEnv`
      # at evaluation time. The `--impure` flag is required for
      # `getEnv` to return non-empty values; without it (e.g. CI's
      # `nix flake check`) the overlays don't apply and the
      # deployment falls back to the fail-closed `lib.mkDefault`
      # placeholders in `configuration.nix`. This is the Nix-world
      # idiom for operator-customised flakes: the public flake
      # stays pure; per-operator values are scoped to the operator's
      # evaluation.
      #
      # An earlier draft used `builtins.pathExists` on gitignored
      # operator-local files (`pharos-runtime.nix`,
      # `hardware-configuration.nix`) — but the flake source-tree
      # is VCS-filtered, so gitignored files are excluded from the
      # store copy that `pathExists` queries. `--impure` + `getEnv`
      # sidesteps the source-filter entirely (env vars + absolute
      # paths from outside the source tree).
      #
      # Env-var contract:
      #   PHAROS_SERVER_NAME       Public hostname for nginx vhost + ACME cert SAN
      #   PHAROS_ACME_EMAIL        Operator's Let's Encrypt contact email
      #   PHAROS_HARDWARE_CONFIG   Absolute path to hardware-configuration.nix
      #                            (generated per-instance by
      #                            `nixos-anywhere --generate-hardware-config`)
      #
      # The Makefile populates all three from
      # `~/.config/pharos-secrets/` + the per-cycle hardware probe;
      # operators driving the flake directly set them in their shell.
      nixosConfigurations.ovh-test =
        let
          serverName = builtins.getEnv "PHAROS_SERVER_NAME";
          acmeEmail = builtins.getEnv "PHAROS_ACME_EMAIL";
          hwPath = builtins.getEnv "PHAROS_HARDWARE_CONFIG";

          # Runtime overlay — only applied when BOTH server-name and
          # acme-email are set, so a half-configured environment
          # falls through to the placeholders cleanly (rather than
          # half-overriding and producing a confusing partial-config
          # error during eval).
          runtimeOverlay = nixpkgs.lib.optional (serverName != "" && acmeEmail != "") {
            services.blockscout-nginx.serverName = serverName;
            services.blockscout-nginx.acme.email = acmeEmail;
          };

          # Hardware-config overlay — `import (/. + path)` requires
          # `--impure` for paths outside the flake source tree;
          # `pathExists` further guards against env-var-set-but-file-
          # absent (happens between `make provision` and the first
          # `nixos-anywhere --generate-hardware-config` run).
          hwOverlay = nixpkgs.lib.optional (hwPath != "" && builtins.pathExists hwPath) (
            import (/. + hwPath)
          );
        in
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.default
            disko.nixosModules.disko
            ./deployments/ovh-test/configuration.nix
          ]
          ++ hwOverlay
          ++ runtimeOverlay;
        };
    }
    // flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ flakeOverlay ];
        };

        e2eApp = pkgs.writeShellApplication {
          name = "run-e2e";
          runtimeInputs = [
            # Flake-input packages referenced directly. The
            # `nixpkgs.overlays` entry on the nixosModules also exposes
            # these as `pkgs.{autonity,blockscout,blockscout-frontend}`,
            # but writeShellApplication's `runtimeInputs` expects
            # derivations — referencing `flake-input.packages.<system>
            # .default` directly here is the most direct path and
            # avoids any overlay-resolution surprises.
            autonity.packages.${system}.default
            blockscout.packages.${system}.default
            blockscout-frontend.packages.${system}.default
            pkgs.postgresql
            pkgs.redis
            pkgs.nodejs_20
            pkgs.python3
            pkgs.curl
            pkgs.openssl
            pkgs.coreutils
            # The harness's port-conflict pre-flight uses `ss` from
            # iproute2 to detect bound ports cleanly without needing
            # a short-lived test connect; the result is filtered via
            # `grep -q .` which depends on gnugrep being on PATH
            # (writeShellApplication's coreutils doesn't include
            # grep). Both pinned here so the harness doesn't depend
            # on the host having either tool pre-installed.
            pkgs.iproute2
            pkgs.gnugrep
          ];
          # The script itself lives at `tests/run-e2e.sh`; spliced in
          # via store-path so the wrapper sees the canonical version.
          # `tests/probes.py` is wired through E2E_PROBES_PY so the
          # script can locate it under any invocation context.
          # Invoked via the absolute Nix-store bash path because
          # file-spliced sources land in the Nix store without the +x
          # bit (bash doesn't require it), and writeShellApplication's
          # runtimeInputs PATH doesn't include bash by default — using
          # ${pkgs.bash}/bin/bash makes the wrapper hermetic against
          # hosts that don't have bash on the system PATH (pure CI
          # shells, minimal containers).
          text = ''
            export E2E_PROBES_PY="${./tests/probes.py}"
            exec ${pkgs.bash}/bin/bash ${./tests/run-e2e.sh} "$@"
          '';
        };
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
        # service modules in a `pkgs.testers.nixosTest` VM and exercises real
        # cross-service connectivity, the bind-mounted envs.js
        # overlay, the nginx reverse-proxy paths, and restart
        # resilience. Slow + memory-hungry (4 GiB VM); runs on every
        # PR via `nix flake check` but benefits massively from caching
        # across repeated runs. Complementary to the static `hardening`
        # check: that one asserts unit files render with the right
        # `serviceConfig`; this one asserts the units actually run and
        # talk to each other.
        checks.integration = import ./tests/integration.nix {
          inherit pkgs system;
          flake = self;
        };

        # Behavioural full-stack VM SYNC test — same six-service stack
        # as `integration`, but with Autonity in `--dev` mode driving
        # real chain progression. Waits for the chain to produce >= 70
        # blocks (one epoch crossed plus a 10-block buffer) AND for
        # the Blockscout indexer to catch up to the same threshold.
        # Slower than `integration` because it exercises real chain
        # production + indexer ingestion under TCG-emulated CPU
        # contention. Probe vocabulary, default `blocksRequired`, and
        # the in-memory-chain-DB / no-account-state / block-count-only
        # design constraints are documented inline in
        # `tests/integration-sync.nix`; the M2.5 epic at #38 tracks the
        # per-PR opt-out CI policy.
        checks.integration-sync = import ./tests/integration-sync.nix {
          inherit pkgs system;
          flake = self;
        };

        # Host-native end-to-end smoke harness. Spawns the same
        # 5-service stack as `integration-sync` (autonity --dev,
        # postgres, redis, blockscout backend + frontend) as plain
        # background processes in a tmpdir, runs the shared
        # `tests/probes.py` probe sequence, and exits 0/non-zero. NOT
        # a replacement for the VM check — explicitly does NOT exercise
        # systemd hardening, namespace isolation, LoadCredential
        # ingestion, or SupplementaryGroups socket access. The killer
        # feature is the much shorter iteration loop (~3.5–5 min vs
        # ~20 min for the VM) for non-systemd-shape work — probe
        # vocabulary changes, JSON-RPC payload shape, indexer
        # behaviour, frontend rendering, env-var contract drift.
        #
        # Probe LOGIC is shared with the VM check via `tests/probes.py`
        # — single source of truth, no duplication. The VM testScript
        # at `tests/integration-sync.nix` invokes the same script after
        # the VM's units are up; this app invokes it after spawning
        # host-native processes.
        apps.e2e = {
          type = "app";
          program = "${e2eApp}/bin/run-e2e";
        };

        # Eval-only check for `nixosConfigurations.ovh-test`. Forces
        # evaluation of the deployment's full option tree by
        # interpolating `system.name` (which depends transitively on
        # every imported module + assertion) into a `writeText`
        # derivation. Catches type errors, missing options, broken
        # imports, and assertion failures on every PR (~10s eval;
        # does NOT build the system closure or boot a VM).
        # Referencing `toplevel.drvPath` directly via string
        # interpolation triggers realisation at the runCommand's
        # build time; `writeText` of a config-derived string is the
        # idiomatic eval-only equivalent.
        #
        # Operator-specific files (hardware-configuration.nix,
        # pharos-runtime.nix) are absent in CI; the deployment's
        # `lib.mkDefault` placeholders in `configuration.nix` keep
        # eval green without them.
        checks.deployment-eval = pkgs.writeText "deployment-eval-marker" (
          "deployment ovh-test evaluates: "
          + self.nixosConfigurations.ovh-test.config.system.name
          + " (host="
          + self.nixosConfigurations.ovh-test.config.networking.hostName
          + ")"
        );

        # Shellcheck pass over every non-orchestrator Makefile recipe
        # in `deployments/ovh-test/Makefile`. The recipes are the
        # highest-bug-density file in the deployment (Make + Bash
        # syntax mixing, ~270 lines of shell embedded in Make
        # context) and shell bugs fail mid-cruise on real OVH
        # hardware, where retries cost euros.
        #
        # Approach: render each recipe via `make --no-print-directory
        # -n <recipe>` with fake env vars, pipe the rendered shell
        # through `shellcheck -s bash`. `shellcheck` can't parse
        # Makefile syntax directly (Make's `$(if …)` is not a Bash
        # `if`), so the render-then-check pattern is the standard
        # workaround.
        #
        # The `cruise` aggregate recipe is excluded — its rendered
        # output under `make -n` contains submake-failure chatter
        # that confuses shellcheck (SC2317 / SC2035 cascades). The
        # subtargets it invokes (`provision`, `dns-up`, `install`,
        # `deploy`, `test`, `halt`, `dns-down`) are each checked
        # individually below; the orchestrator's quoting is checked
        # by inspection during PR review.
        checks.makefile-shellcheck =
          pkgs.runCommand "check-makefile-shellcheck"
            {
              nativeBuildInputs = [
                pkgs.gnumake
                pkgs.shellcheck
              ];
            }
            ''
              set -euo pipefail
              cd ${self}/deployments/ovh-test

              recipes="provision halt dns-up dns-down install deploy test logs snapshot check-runtime-env stage"
              failed=0
              for r in $recipes; do
                # Render the recipe via `make -n`. If `make` itself
                # fails (broken Makefile, renamed recipe, missing
                # SHELL, etc.) treat it as a check failure — without
                # this, an empty rendered string would pass
                # shellcheck silently and mask a real Makefile bug.
                if ! rendered=$(OVH_TOKEN=fake OVH_PROJECT_ID=fake \
                                GCLOUD_PROJECT=fake DNS_ZONE=fake \
                                DOMAIN=fake IP=1.2.3.4 \
                                make --no-print-directory -n "$r" 2>&1); then
                  printf 'make -n %s failed (recipe rename or Makefile parse error?):\n' "$r"
                  printf '%s\n' "$rendered"
                  printf -- '---\n'
                  failed=1
                  continue
                fi
                # Defensive: if `rendered` came back empty for any
                # other reason (recipe with no commands, comment-only,
                # etc.), flag it. Every recipe in the check list is
                # expected to emit at least one shell command.
                #
                # Use `printf '%s\n'` rather than `echo` to preserve
                # the rendered script byte-for-byte: echo can treat
                # leading `-n` as an option and may interpret
                # backslash escapes depending on shell settings,
                # mangling the input that gets piped to shellcheck.
                if [ -z "$(printf '%s' "$rendered" | tr -d '[:space:]')" ]; then
                  printf 'make -n %s produced empty output; recipe missing or comment-only\n' "$r"
                  printf -- '---\n'
                  failed=1
                  continue
                fi
                output=$(printf '%s\n' "$rendered" | shellcheck -s bash - 2>&1 || true)
                if [ -n "$output" ]; then
                  printf 'shellcheck issue in recipe %s:\n' "$r"
                  printf '%s\n' "$output"
                  printf -- '---\n'
                  failed=1
                fi
              done

              if [ $failed -eq 1 ]; then
                echo "shellcheck found real issues above — fix the Makefile recipes"
                exit 1
              fi

              printf 'all %d recipes shellcheck-clean\n' "$(printf '%s\n' "$recipes" | wc -w)"
              touch $out
            '';
      }
    );
}
