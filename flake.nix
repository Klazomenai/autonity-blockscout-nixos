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
      flakeOverlay = final: _prev: {
        autonity = autonity.packages.${final.stdenv.hostPlatform.system}.default;
        autonity-portable = autonity.packages.${final.stdenv.hostPlatform.system}.autonity-portable;
        blockscout = blockscout.packages.${final.stdenv.hostPlatform.system}.default;
        blockscout-frontend = blockscout-frontend.packages.${final.stdenv.hostPlatform.system}.default;
      };
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
          #
          # `hwPath` from `getEnv` is a string; `builtins.pathExists`
          # requires a Nix path value, so convert string→path via
          # `/. + hwPath` BEFORE the pathExists check. Without the
          # conversion, evaluation would fail with "value is a
          # string while a path was expected" the moment
          # PHAROS_HARDWARE_CONFIG is set under `--impure`. Pure-
          # mode CI short-circuits on `hwPath != ""` so the bug
          # was invisible there.
          hwPathAsPath = /. + hwPath;
          hwOverlay = nixpkgs.lib.optional (hwPath != "" && builtins.pathExists hwPathAsPath) (
            import hwPathAsPath
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

        # statix — Nix anti-pattern linter. Walks every tracked `.nix`
        # file from the repo root and exits non-zero on findings.
        # Repo-level lint config lives at `statix.toml` (no leading
        # dot — statix searches for the unprefixed name); that file
        # documents the rationale for any globally-disabled rules.
        # Cheap (~few seconds), runs on every PR via the
        # `check-pr` job in `.github/workflows/flake-check.yml`.
        checks.statix =
          pkgs.runCommand "check-statix"
            {
              nativeBuildInputs = [ pkgs.statix ];
            }
            ''
              cd ${self}
              statix check .
              touch $out
            '';

        # deadnix — finds unused symbols (let-bindings, lambda
        # patterns, function arguments). `--fail` exits non-zero on
        # findings so CI surfaces them. Convention for keeping
        # unused-but-intentional lambda patterns is the `_` prefix
        # (e.g. `_prev` in overlay signatures); deadnix recognises
        # the prefix and skips those sites.
        checks.deadnix =
          pkgs.runCommand "check-deadnix"
            {
              nativeBuildInputs = [ pkgs.deadnix ];
            }
            ''
              cd ${self}
              deadnix --fail .
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
          inherit pkgs;
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
          inherit pkgs;
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
        # The deployment's operator-specific values
        # (PHAROS_SERVER_NAME / PHAROS_ACME_EMAIL /
        # PHAROS_HARDWARE_CONFIG) are injected at eval time via
        # `builtins.getEnv` and require `--impure`. In CI's pure
        # mode `getEnv` returns "" and the deployment falls back
        # to the `lib.mkDefault` placeholders in
        # `configuration.nix` — which is exactly what this check
        # validates evaluates cleanly.
        checks.deployment-eval = pkgs.writeText "deployment-eval-marker" (
          "deployment ovh-test evaluates: "
          + self.nixosConfigurations.ovh-test.config.system.name
          + " (host="
          + self.nixosConfigurations.ovh-test.config.networking.hostName
          + ")"
        );

        # Env-var contract check for `nixosConfigurations.ovh-test`.
        # Verifies that PHAROS_SERVER_NAME + PHAROS_ACME_EMAIL flow
        # through `--impure` + `builtins.getEnv` to the consuming
        # `services.blockscout-nginx.{serverName,acme.email}` options.
        #
        # Failure mode this catches: if a future refactor mistyped
        # one of the env-var names in `nixosConfigurations.ovh-test`
        # (e.g. `PHAROS_SERVERNAME` vs `PHAROS_SERVER_NAME`), or if
        # the runtimeOverlay's gate condition drifted, the placeholders
        # in `deployments/ovh-test/configuration.nix` would silently
        # apply and ACME issuance would fail mid-cruise — after the
        # OVH instance was provisioned and DNS was set up. Asymmetric:
        # silent-pass at eval time, loud-fail at runtime against paid
        # hardware. This check converts the silent-pass to a build-
        # time error.
        #
        # Evaluation behaviour:
        #
        #   - Pure mode (default `nix flake check`, no env vars set):
        #     emits a `skipped` sentinel explaining how to exercise
        #     the check. The skip is intentional — without `--impure`
        #     and env vars, there's nothing to verify against.
        #
        #   - Impure mode, both env vars set: asserts exact-string
        #     match between PHAROS_* values and the resolved option
        #     values. Mismatch throws with a diagnostic naming both
        #     expected and actual (catches placeholder leak-through
        #     when `--impure` was forgotten on the wrapping invocation).
        #
        #   - Impure mode, only one env var set: throws with a
        #     pointer to the runtimeOverlay's gate (which requires
        #     BOTH set, by design — half-configured environments
        #     fall through to placeholders to avoid partial-config
        #     errors during eval).
        #
        # PHAROS_HARDWARE_CONFIG is not asserted here directly: that
        # value is a path import, not a string comparison, and the
        # full-closure `deployment-build` check catches its read-
        # path failures under `--impure` with the env var set.
        #
        # CI invocation (in `.github/workflows/flake-check.yml`'s
        # `check-full` job): a dedicated step exports test values
        # and runs the check under `--impure`, exercising the
        # "verified" path. Pure-mode CI in `check-pr` exercises the
        # "skipped" path (no env vars set, no `--impure`).
        checks.env-var-contract =
          let
            expectedServerName = builtins.getEnv "PHAROS_SERVER_NAME";
            expectedEmail = builtins.getEnv "PHAROS_ACME_EMAIL";
            bothSet = expectedServerName != "" && expectedEmail != "";
            bothUnset = expectedServerName == "" && expectedEmail == "";
            cfg = self.nixosConfigurations.ovh-test.config.services.blockscout-nginx;
            actualServerName = cfg.serverName;
            actualEmail = cfg.acme.email;
          in
          if bothUnset then
            pkgs.writeText "env-var-contract-skipped" ''
              env-var-contract: skipped (pure-mode evaluation; PHAROS_SERVER_NAME + PHAROS_ACME_EMAIL not set).

              To exercise this check locally:
                PHAROS_SERVER_NAME=test.example.org \
                PHAROS_ACME_EMAIL=ops@test.example.org \
                  nix build --impure .#checks.x86_64-linux.env-var-contract --print-build-logs

              CI exercises the verified path under `check-full`; this skip is the
              expected outcome under PR-time pure-mode evaluation.
            ''
          else if !bothSet then
            throw ''
              env-var-contract: only one of PHAROS_SERVER_NAME / PHAROS_ACME_EMAIL is set.
                PHAROS_SERVER_NAME = ${if expectedServerName == "" then "(unset)" else expectedServerName}
                PHAROS_ACME_EMAIL  = ${if expectedEmail == "" then "(unset)" else expectedEmail}
              The flake's runtimeOverlay only applies when BOTH are set; with one
              set and one unset, the unset half falls back to its placeholder.
              Set both, or set neither (and let the skipped-sentinel path run).
            ''
          else if actualServerName != expectedServerName then
            throw ''
              env-var-contract FAILED: serverName mismatch.
                expected = ${expectedServerName}  (from PHAROS_SERVER_NAME)
                actual   = ${actualServerName}
              Placeholder leak-through suggests the runtimeOverlay's getEnv read
              didn't apply. Confirm `--impure` was passed; if it was, the env-var
              name in `nixosConfigurations.ovh-test` may have drifted from the
              PHAROS_SERVER_NAME spelling.
            ''
          else if actualEmail != expectedEmail then
            throw ''
              env-var-contract FAILED: acme.email mismatch.
                expected = ${expectedEmail}  (from PHAROS_ACME_EMAIL)
                actual   = ${actualEmail}
              Placeholder leak-through suggests the runtimeOverlay's getEnv read
              didn't apply. Confirm `--impure` was passed; if it was, the env-var
              name in `nixosConfigurations.ovh-test` may have drifted from the
              PHAROS_ACME_EMAIL spelling.
            ''
          else
            pkgs.writeText "env-var-contract-verified" ''
              env-var-contract verified:
                services.blockscout-nginx.serverName  = ${actualServerName}
                services.blockscout-nginx.acme.email  = ${actualEmail}
            '';

        # Disko install test for `deployments/ovh-test/disk-config.nix`.
        # Boots a QEMU VM, formats the virtio disks per the disko
        # spec, and runs `nixos-install` (which also runs the GRUB
        # installer via `switch-to-configuration boot`). Powered by
        # disko's `makeDiskoTest` framework, which automatically
        # rewrites the spec's `/dev/nvme0n1` to `/dev/vda` for the
        # test VM.
        #
        # Scope: disk-config + install phase only — service modules
        # + hardware config are NOT loaded, and `testBoot = false`
        # skips the post-install boot phase. Catches GPT layout
        # typos, missing ESP + mountpoint wiring, mkfs / fstab
        # errors, and GRUB install failures (the bootloader install
        # runs as part of `nixos-enter ... switch-to-configuration
        # boot`, BEFORE the boot phase). Service-composition
        # validation in a fuller VM is **planned** under issue #56
        # (full-VM integration of `deployments/ovh-test/configuration.nix`),
        # which has not yet shipped — until it does, boot-time
        # failures (vmlinuz path drift, initrd composition, post-
        # boot fstab mount, post-boot systemd unit failures) are
        # NOT covered by any automated check. They surface only on
        # first real-OVH cycle.
        #
        # `testBoot = false` decision rationale (empirical): with
        # `testBoot = true` (the framework default) the boot phase
        # tests pass quickly under TCG software emulation (no KVM
        # available in the local builder sandbox) — ~7 min wallclock
        # for the test script, both `mountpoint /` and `mountpoint
        # /boot` succeed cleanly. BUT the framework's VM teardown
        # then hangs in ACPI poweroff for 15+ more minutes before
        # the build artifact materialises (QEMU CPU drops to ~7%
        # but the nixos-test-driver keeps waiting on the QMP
        # shutdown handshake that never completes cleanly). Skipping
        # the boot phase cuts wallclock from 20+ min (hung in
        # shutdown) to 4.1 min clean. Re-enabling `testBoot = true`
        # can be revisited if (a) #56 lands and supersedes this
        # check's boot-time coverage, or (b) a CI environment
        # becomes available offering reliable nested-virt KVM
        # acceleration.
        #
        # `efi = true` matches `boot.loader.grub.efiSupport = true`
        # in `deployments/ovh-test/configuration.nix`. The 1 MiB
        # BIOS-boot partition in the spec elicits a non-fatal
        # `sgdisk --align-end --new=1:0:+1M` warning during the
        # install phase (alignment vs minimum-size conflict on the
        # test VM's small disk geometry); disko continues past it
        # and the partition gets created in the fallback path.
        # Real OVH B3 instances ship 80+ GiB disks where the
        # alignment math always succeeds, and they boot UEFI so
        # the BIOS-boot partition is contingency-only and never
        # actually consulted.
        #
        # CI policy: lives in the flake checks set so `check-full`
        # (push to `main` + nightly cron) picks it up automatically.
        # Not added to `check-pr`'s explicit named-check list — the
        # install phase still takes ~4 min under TCG.
        checks.disko-install = disko.lib.testLib.makeDiskoTest {
          inherit pkgs;
          name = "ovh-test-disk-install";
          disko-config = ./deployments/ovh-test/disk-config.nix;
          efi = true;
          testBoot = false;
        };

        # Full-closure build check for `nixosConfigurations.ovh-test`.
        # Where `deployment-eval` (above) catches type errors,
        # assertion failures, and broken imports at evaluation time,
        # this check FORCES realisation of the system closure —
        # catching derivation build failures, missing dependencies,
        # package compile errors, and overlay conflicts that eval
        # can't see.
        #
        # CI policy: runs only under `check-full` (push-to-main +
        # nightly cron, per `.github/workflows/flake-check.yml`) —
        # deliberately excluded from `check-pr` to keep PR feedback
        # fast. The M2.5 `integration-sync` split set the precedent
        # for this PR-vs-main split. Run locally before pushing
        # hardware-touching changes: `nix build
        # .#checks.x86_64-linux.deployment-build --print-build-logs`.
        # Wall-clock ~5-15 minutes cold; faster on warm cache.
        #
        # The production module list defers `fileSystems."/"` and the
        # boot-initrd module list to the per-instance
        # `hardware-configuration.nix` loaded from
        # PHAROS_HARDWARE_CONFIG under `--impure`. To make the
        # closure buildable in pure-mode CI (where no hardware-config
        # is loaded), this check layers
        # `tests/stub-hardware-config.nix` on top via `extendModules`.
        # The stub's `lib.mkDefault` priority ensures real
        # hardware-configurations win the automatic merge when both
        # are present.
        checks.deployment-build =
          let
            buildable = self.nixosConfigurations.ovh-test.extendModules {
              modules = [ ./tests/stub-hardware-config.nix ];
            };
          in
          buildable.config.system.build.toplevel;

        # Behavioural full-stack VM check for `deployments/ovh-test/
        # configuration.nix`. Boots the actual deployment config in a
        # `pkgs.testers.nixosTest` VM (with mkForce overrides for
        # disko / boot.loader.grub / autonity p2p discovery, which
        # have no nixosTest analogue) and asserts the deployment-
        # specific option choices reach the running system:
        # placeholder serverName flows to the nginx vhost, ACME
        # staging URL resolves, firewall opens 80/443 + 22
        # (listener-probed) and 30303/{tcp,udp} (iptables-rule-only;
        # autonity p2p not bound under hermetic override), and
        # ConditionPathExists on backend + postgresql-setup units
        # both statically references and dynamically enforces the
        # /var/lib/pharos-secrets/ paths (negative-path test removes
        # the secret and asserts a clean condition-failure in the
        # journal).
        #
        # Complementary to `checks.<system>.integration` (NOT a
        # replacement): that one exercises module-default options +
        # cross-service connectivity; this one exercises the
        # deployment's option-set choices specifically. Without this
        # check, a deployment-config-specific drift (placeholder
        # serverName broken, firewall rule conflict, ConditionPathExists
        # mistyped) would only surface on first OVH cruise after
        # paying for hardware.
        #
        # CI policy: lives in the flake checks set so `check-full`
        # (push to `main` + nightly cron) picks it up automatically.
        # NOT added to `check-pr`'s explicit named-check list — wall-
        # clock is in the same band as `integration` (~22 min cold)
        # and per-PR feedback already includes that check; the
        # marginal value here lands on push-to-main and on nightly,
        # not on every PR commit.
        checks.deployment-integration = import ./tests/deployment-integration.nix {
          inherit pkgs;
          flake = self;
          diskoModule = disko.nixosModules.disko;
        };

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
        # `test`, `halt`, `dns-down` — `deploy` is omitted from
        # cruise because it's redundant immediately after a fresh
        # `install`) are each checked individually below; the
        # orchestrator's quoting is checked by inspection during
        # PR review.
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
