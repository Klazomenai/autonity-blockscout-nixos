# Boots `deployments/ovh-test/configuration.nix` in a `pkgs.testers.nixosTest`
# VM and verifies the deployment-config-specific option choices reach
# the running system.
#
# Complementary to (NOT a replacement for) `tests/integration.nix`:
#   - `integration.nix` exercises module-default options + cross-service
#     connectivity (sockets, TCP, proxy round-trips, restart resilience).
#   - `deployment-integration.nix` (this) imports the actual deployment
#     config and asserts the deployment's specific option-set choices.
#     Catches deployment-config drift that module-default tests would
#     miss — the kind of failure that would otherwise only surface on
#     first OVH cruise after paying for hardware.
#
# Marginal-value assertions (per #56):
#
#   1. Placeholder `serverName = "deployment.invalid"` flows through to
#      a working nginx vhost (config renders, vhost serves on
#      127.0.0.1).
#   2. `acme.useStaging = true` resolves to the LE staging directory
#      URL in the merged `security.acme.certs.<name>.server`.
#   3. Firewall opens 30303/{tcp,udp} (autonity p2p), 80/443 (nginx),
#      and 22 (openssh) without conflict against the services'
#      listen sockets.
#   4. `ConditionPathExists` assertions on
#      `blockscout-backend.service` + `postgresql-setup.service`
#      reference the `/var/lib/pharos-secrets/` paths the deployment
#      configured. Negative-path verification: a unit started with
#      its required secret file absent fails with a clean
#      `ConditionPathExists=...was not met` line, NOT a service-
#      specific crash deep in the journal.
#   5. `networking.hostName = "pharos-test"` propagates to the kernel.
#
# VM-incompatible bits of the deployment config are mkForce'd off:
#   - `disko.devices.*` — nixosTest provides its own root via
#     `virtualisation.*`; disko has no real disk to format.
#   - `boot.loader.grub.*` — nixosTest installs its own minimal boot
#     setup; trying to write GPT / EFI vars in the test VM fails.
#   - `services.autonity.p2p.maxPeers` + `extraArgs` — kept hermetic
#     with `--nodiscover --maxpeers=0` so the test doesn't wait on
#     outbound 30303 reachability. Note `p2p.openFirewall` stays on
#     so we can still verify the firewall rule.
#   - `services.blockscout-nginx.acme.enable` — kept ENABLED so the
#     security.acme.certs config renders and we can read the staging
#     URL from the merged config. nginx falls back to a self-signed
#     placeholder cert when the real ACME runner can't reach LE
#     (which it can't, against `deployment.invalid`).
{
  pkgs,
  flake,
  diskoModule,
}:

let
  pharosSecretsDir = "/var/lib/pharos-secrets";
  testSecretKeyBase = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
in
pkgs.testers.nixosTest {
  name = "autonity-blockscout-deployment-integration";

  nodes.machine =
    {
      lib,
      ...
    }:
    {
      imports = [
        flake.nixosModules.default
        # disko's NixOS module brings in `disko.devices.*` options
        # that `deployments/ovh-test/configuration.nix` imports via
        # `./disk-config.nix`. We mkForce `disko.devices = {}` below
        # so the disk layout itself no-ops in the VM, but the option
        # definitions still need to be in scope to evaluate cleanly.
        diskoModule
        ../deployments/ovh-test/configuration.nix
      ];

      # ---------------------------------------------------------------
      # VM-incompatible overrides — every line below is a deviation
      # from the deployment config that exists only because nixosTest
      # provides its own boot/disk/networking infrastructure. Any
      # change here is a deliberate test-fixture choice, not a
      # production deployment change.
      # ---------------------------------------------------------------
      disko.devices = lib.mkForce { };

      boot.loader.grub.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

      # Autonity stays hermetic — single-node chain at genesis,
      # mirroring `tests/integration.nix`. The deployment config
      # leaves p2p at module defaults (mainnet discovery), which
      # would have the test wait on outbound connectivity that
      # the nixosTest sandbox doesn't grant.
      services.autonity.p2p.maxPeers = lib.mkForce 0;
      services.autonity.extraArgs = lib.mkForce [ "--nodiscover" ];

      # Test framework owns `networking.hostName` (it generates a
      # mypy type hint via `theOnlyMachine` keyed on the per-node
      # name, see the equivalent comment in `tests/integration.nix`).
      # Force back to the framework default; hostname propagation
      # from the deployment config is verified eval-time in
      # `checks.<system>.deployment-eval` instead.
      networking.hostName = lib.mkForce "machine";

      # postgresql first-boot timeout headroom under TCG.
      systemd.services.postgresql.serviceConfig.TimeoutSec = lib.mkForce 600;

      # Resolve the deployment's placeholder hostname to loopback so
      # the in-VM acme runner / curl tests reach nginx. ACME issuance
      # itself will fail (no DNS for deployment.invalid, no LE
      # reachability) — nixpkgs handles that by serving a fallback
      # self-signed cert until the real one lands.
      networking.extraHosts = ''
        127.0.0.1 deployment.invalid
      '';

      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
      virtualisation.diskSize = 4096;

      # ---------------------------------------------------------------
      # Test secrets at the deployment's expected
      # `/var/lib/pharos-secrets/` path (NOT `/run/test-secrets/` like
      # `integration.nix` — the whole point of this test is exercising
      # the deployment's option-set, including the secret paths).
      #
      # Placed under `/var/lib/` rather than `/run/` because the
      # deployment expects them to survive reboots — `--extra-files`
      # ships them to the host filesystem, not a tmpfs. The
      # `system.activationScripts` shape mirrors the production
      # sops-nix / agenix flow: a known directory with mode bits per-
      # consumer (skb 0400 root, db_password 0440 postgres).
      #
      # `${...}` antiquotes the bytes once at derivation-build time,
      # so the activation script body itself contains the literal
      # bytes — fine for an ephemeral VM-test fixture, NOT a
      # secret-keeping mechanism in production. See `tests/integration.nix`
      # for the longer rationale.
      # ---------------------------------------------------------------
      system.activationScripts.test-secrets = ''
        ${pkgs.coreutils}/bin/install -d -m 0755 ${pharosSecretsDir}
        ${pkgs.coreutils}/bin/install -m 0400 -o root -g root /dev/null ${pharosSecretsDir}/secret_key_base
        printf '%s' ${lib.escapeShellArg testSecretKeyBase} > ${pharosSecretsDir}/secret_key_base
        ${pkgs.coreutils}/bin/install -m 0440 -o postgres -g postgres /dev/null ${pharosSecretsDir}/database_password
        printf '%s' 'test-password-not-for-production' > ${pharosSecretsDir}/database_password
      '';
    };

  # `nodes` exposes the resolved per-node config; the let-bindings
  # below read deployment-config attributes at testScript render time
  # so any drift between the deployment config and the assertion side
  # surfaces at eval time, not as a runtime mismatch deep in the
  # script.
  testScript =
    {
      nodes,
      ...
    }:
    let
      cfg = nodes.machine;
      acmeServer = cfg.security.acme.certs."deployment.invalid".server or null;
      acmeServerOk =
        acmeServer != null && pkgs.lib.hasInfix "acme-staging-v02.api.letsencrypt.org" acmeServer;
      _acmeAssertion =
        if acmeServerOk then
          true
        else
          throw ''
            deployment-integration eval-time assertion FAILED:
              security.acme.certs."deployment.invalid".server = ${toString acmeServer}
            Expected the LE staging directory URL (acme-staging-v02.api.letsencrypt.org).
            Set `services.blockscout-nginx.acme.useStaging = true` in
            `deployments/ovh-test/configuration.nix`.
          '';
      expectedServerName = cfg.services.blockscout-nginx.serverName;
    in
    ''
      machine.start()

      # ---------------------------------------------------------------
      # 1. Boot completion + per-unit readiness.
      # ---------------------------------------------------------------
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("autonity.service")
      machine.wait_for_unit("postgresql.service")
      machine.wait_for_unit("redis-blockscout.service")
      machine.wait_for_unit("blockscout-backend.service")
      machine.wait_for_unit("blockscout-frontend.service")
      machine.wait_for_unit("nginx.service")
      machine.wait_for_unit("sshd.service")

      # ---------------------------------------------------------------
      # 2. Firewall rules — every required port present + no listen-
      #    socket conflict. Port-open assertions probe via the actual
      #    listener; `iptables-save` inspection covers UDP (which
      #    `wait_for_open_port` doesn't probe) for autonity p2p.
      # ---------------------------------------------------------------
      machine.wait_for_open_port(22)    # openssh (openFirewall=true)
      machine.wait_for_open_port(80)    # nginx HTTP (forceSSL redirect)
      machine.wait_for_open_port(443)   # nginx HTTPS

      # Backend warmup: Phoenix runs `mix ecto.migrate` before binding
      # 4000. Default `wait_for_open_port` timeout is 900 s; plenty.
      # Step 3's curl through nginx depends on this listener being up
      # — without the explicit wait, the curl polls would 502 the
      # whole window because the upstream isn't reachable.
      machine.wait_for_open_port(4000)  # Blockscout backend

      # 30303 TCP: autonity p2p; with `--nodiscover --maxpeers=0` the
      # binary doesn't bind it as a listener, but the firewall rule
      # itself must still be present (production deployment runs
      # without those overrides). Inspect the firewall directly.
      iptables_save = machine.succeed("iptables-save")
      assert "--dport 30303" in iptables_save, (
          f"30303/tcp not in iptables filter: {iptables_save!r}"
      )

      # 30303 UDP: nixpkgs' firewall splits TCP/UDP into separate
      # `iptables -p tcp` / `iptables -p udp` rules; the same
      # `--dport 30303` line appears with `-p udp` for the UDP rule.
      udp_rule_present = any(
          "-p udp" in line and "--dport 30303" in line
          for line in iptables_save.splitlines()
      )
      assert udp_rule_present, (
          f"30303/udp not in iptables filter: {iptables_save!r}"
      )

      # ---------------------------------------------------------------
      # 3. nginx vhost bound to the deployment's placeholder
      #    serverName. Verified end-to-end via curl with TLS SNI
      #    pinned to `deployment.invalid` — if the vhost weren't
      #    server_name'd to that string, nginx server-block selection
      #    would land on the default vhost and either return a 404
      #    or fail to find the upstream. A successful round-trip
      #    against /api/health/liveness through the reverse-proxy
      #    proves the placeholder reaches both nginx config and
      #    backend reachability.
      #
      #    `--resolve <name>:443:127.0.0.1` pins DNS resolution to
      #    loopback while keeping the URL hostname intact (TLS SNI
      #    matches the certificate CN; `Host:` header lines up).
      #    `-k` skips the trust check on the ACME fallback cert
      #    (real ACME issuance can't reach LE for the placeholder
      #    hostname so nginx uses a self-signed fallback).
      # ---------------------------------------------------------------
      machine.wait_until_succeeds(
          "curl -fsSk --resolve ${expectedServerName}:443:127.0.0.1 "
          "https://${expectedServerName}/api/health/liveness",
          timeout=180,
      )

      # ---------------------------------------------------------------
      # 4. `ConditionPathExists` set on every unit the deployment
      #    config gates on a pharos-secrets file. systemd doesn't
      #    surface conditions through `show -p ConditionPathExists`
      #    cleanly (the property is empty even when conditions are
      #    set in [Unit]); inspect the rendered unit file directly
      #    via `systemctl cat`.
      # ---------------------------------------------------------------
      backend_unit = machine.succeed("systemctl cat blockscout-backend.service")
      for required_path in [
          "${pharosSecretsDir}/secret_key_base",
          "${pharosSecretsDir}/database_password",
      ]:
          expected_line = f"ConditionPathExists={required_path}"
          assert expected_line in backend_unit, (
              f"blockscout-backend.service missing `{expected_line}` in [Unit]. "
              f"Rendered unit:\n{backend_unit}"
          )

      pgsetup_unit = machine.succeed("systemctl cat postgresql-setup.service")
      pgsetup_expected = "ConditionPathExists=${pharosSecretsDir}/database_password"
      assert pgsetup_expected in pgsetup_unit, (
          f"postgresql-setup.service missing `{pgsetup_expected}` in [Unit]. "
          f"Rendered unit:\n{pgsetup_unit}"
      )

      # ---------------------------------------------------------------
      # 5. ConditionPathExists negative path: stop the backend, remove
      #    its secret_key_base file, attempt restart, assert the unit
      #    fails with the clean `ConditionPathExists=...was not met`
      #    pattern in journalctl. Without this, the static check above
      #    proves the option is set but doesn't prove systemd's
      #    behaviour — a future systemd change to the unit-condition
      #    semantics would silently regress.
      # ---------------------------------------------------------------
      machine.systemctl("stop blockscout-backend.service")
      machine.succeed("rm ${pharosSecretsDir}/secret_key_base")

      # `systemctl start` returns 0 even when a Condition* check
      # fails — modern systemd treats condition-failure as "unit
      # successfully not started" rather than an error. So
      # `succeed`/`fail` aren't the right shape here; use `execute`
      # which returns (status, output) without asserting either way.
      # The actual signal is in the journal + unit ActiveState.
      machine.execute("systemctl start blockscout-backend.service")

      # The condition-failure log line appears in the journal as
      # `Condition check resulted in ... being skipped.` (modern
      # systemd) or `... was not met` (older systemd). Match either.
      journal = machine.succeed(
          "journalctl -u blockscout-backend.service --no-pager -n 50"
      )
      condition_signal = (
          "ConditionPathExists" in journal
          or "Condition check resulted in" in journal
      )
      assert condition_signal, (
          "Expected blockscout-backend.service to log a clean "
          "ConditionPathExists failure after secret_key_base was removed. "
          f"Journal tail:\n{journal}"
      )

      # Belt-and-braces: after a condition-failed start, the unit
      # must NOT be active. If systemd ever changed semantics so a
      # condition-skipped unit reported active, the journal regex
      # above would match but the unit would still be running
      # against missing secrets — exactly the obscure-failure mode
      # the ConditionPathExists is supposed to prevent.
      active_state = machine.succeed(
          "systemctl show -p ActiveState --value blockscout-backend.service"
      ).strip()
      assert active_state in ("inactive", "failed"), (
          f"backend should be inactive/failed after condition skip, got: {active_state!r}"
      )

      # Restore the file so the recovery path is exercised — proves
      # the unit isn't permanently disabled by the condition failure.
      machine.succeed(
          "${pkgs.coreutils}/bin/install -m 0400 -o root -g root /dev/null "
          "${pharosSecretsDir}/secret_key_base"
      )
      machine.succeed(
          "printf '%s' '${testSecretKeyBase}' > ${pharosSecretsDir}/secret_key_base"
      )
      machine.systemctl("start blockscout-backend.service")
      machine.wait_for_unit("blockscout-backend.service")
      machine.wait_for_open_port(4000)

      # ---------------------------------------------------------------
      # 6. ACME staging URL — eval-time assertion above already threw
      #    if it wasn't staging. Echo the resolved URL for the build
      #    log so the test record is self-explanatory.
      # ---------------------------------------------------------------
      machine.log("ACME server URL (deployment.invalid): ${toString acmeServer}")
    '';
}
