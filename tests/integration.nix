# Behavioural full-stack VM integration test. Boots all six service
# modules in a single `pkgs.nixosTest` VM, then exercises real
# cross-service connectivity (loopback TCP + UNIX sockets), unit
# ordering, the bind-mounted envs.js overlay on the frontend, and
# nginx reverse-proxy paths.
#
# Complementary to `checks.<system>.hardening`:
#   - `hardening` is static-analysis-only — fast, fails on serviceConfig
#     drift, runs on every PR. Doesn't actually run the units.
#   - `integration` (this) boots the units and asserts behaviour. Slow,
#     memory-hungry, but catches the whole class of "config rendered
#     fine but the service can't actually reach its dependency"
#     regressions that static analysis can't see.
#
# Scope:
#   - Behavioural connectivity: cross-service sockets, loopback TCP,
#     Phoenix/Next.js liveness, nginx reverse-proxy round-trips,
#     restart resilience.
#   - NOT chain-sync validation: Autonity runs `--nodiscover
#     --maxpeers=0` so it stays a single-node chain at genesis. Real
#     MainNet sync is M3 OVH-deployment territory.
#   - NOT real ACME: a self-signed cert is wired directly into the
#     nginx vhost via `services.nginx.virtualHosts.<name>.{
#     sslCertificate, sslCertificateKey }` so `forceSSL = true` works
#     without HTTP-01 challenge round-trips against a public DNS name.
{
  pkgs,
  flake,
  system,
}:

let
  hostName = "explorer.test";

  # Self-signed cert generated at Nix evaluation time. The test isn't
  # validating CA-trust or HTTPS chain-of-trust — it's validating that
  # nginx terminates TLS and reverse-proxies onto loopback. Self-signed
  # is sufficient for that, and `curl -k` skips the trust check.
  selfSignedCerts =
    pkgs.runCommand "self-signed-${hostName}"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        mkdir -p $out
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
          -keyout $out/key.pem \
          -out $out/cert.pem \
          -subj "/CN=${hostName}" \
          -addext "subjectAltName=DNS:${hostName}"
      '';

  # Test secret: a fixed 64-byte hex string standing in for Phoenix's
  # `secret_key_base`. Real deployments would source this from sops-nix
  # / agenix; for the VM test we just need ANY value at a path that
  # satisfies the module's "absolute and not under /nix/store/"
  # assertion. `environment.etc` writes to `/etc/<name>` (managed
  # outside the Nix store), so `/etc/test-secrets/skb` qualifies.
  testSecretKeyBase = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
in
pkgs.testers.nixosTest {
  name = "autonity-blockscout-integration";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ flake.nixosModules.default ];

      # Memory-hungry workload: Blockscout backend (BEAM) + indexer
      # alone wants 1+ GiB; add Postgres + Redis + Autonity + Next.js
      # + nginx and 4 GiB is the floor that doesn't OOM the VM during
      # `mix ecto.migrate` or the indexer's startup pass.
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
      virtualisation.diskSize = 4096;

      # Nginx vhost match keys on the `Host:` header set by `curl -H`,
      # so the VM's actual hostname doesn't matter for the proxied
      # request paths. We deliberately leave `networking.hostName` at
      # the test-framework default (`virtualisation.test.nodeName`,
      # which evaluates to `"machine"` for `nodes.machine = …`):
      # overriding it would change `system.name` and trip the test
      # framework's `theOnlyMachine` heuristic into adding a duplicate
      # `machine: QemuMachine;` type hint to the generated
      # `testScriptWithTypes`, failing mypy with a name-redefinition
      # error before the script ever runs.
      #
      # `extraHosts` is added defensively in case any in-VM DNS lookup
      # of `${hostName}` is performed (currently none is — all curls
      # use `Host:` headers against the loopback IP).
      networking.extraHosts = ''
        127.0.0.1 ${hostName}
      '';

      # Pinning rather than relying on the nixpkgs default-from-release
      # fallback. The value is never observed — this VM is built only
      # for the test, never deployed.
      system.stateVersion = "24.05";

      # Test secret materialised at activation time. `/etc/<name>` is
      # outside `/nix/store/` and absolute — satisfies the
      # `secretKeyBaseFile` not-in-store assertion.
      environment.etc."test-secrets/skb".text = testSecretKeyBase;

      services.autonity = {
        enable = true;
        # Single-node, no peer discovery — keeps the VM hermetic and
        # avoids the test waiting on outbound 30303 reachability.
        p2p.maxPeers = 0;
        p2p.openFirewall = false;
        extraArgs = [ "--nodiscover" ];
      };

      services.blockscout-postgresql.enable = true;
      services.blockscout-redis.enable = true;

      services.blockscout-backend = {
        enable = true;
        secretKeyBaseFile = "/etc/test-secrets/skb";
      };

      services.blockscout-frontend.enable = true;

      services.blockscout-nginx = {
        enable = true;
        serverName = hostName;
        # Real ACME requires a public DNS name + LE reachability. The
        # self-signed cert wired below is sufficient for exercising
        # `forceSSL = true` and the reverse-proxy path on loopback.
        acme.enable = false;
      };

      # Inject the self-signed cert paths into the same vhost the
      # blockscout-nginx module composed. NixOS module merge semantics
      # combine these two partial definitions of
      # `services.nginx.virtualHosts.<name>` cleanly.
      services.nginx.virtualHosts.${hostName} = {
        sslCertificate = "${selfSignedCerts}/cert.pem";
        sslCertificateKey = "${selfSignedCerts}/key.pem";
      };
    };

  testScript = ''
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

    # ---------------------------------------------------------------
    # 2. Loopback ports listening.
    # ---------------------------------------------------------------
    machine.wait_for_open_port(8545)   # Autonity HTTP RPC
    machine.wait_for_open_port(4000)   # Blockscout backend
    machine.wait_for_open_port(3000)   # Blockscout frontend
    machine.wait_for_open_port(80)     # nginx HTTP (redirects to 443)
    machine.wait_for_open_port(443)    # nginx HTTPS

    # ---------------------------------------------------------------
    # 3. Cross-service UNIX sockets exist.
    # ---------------------------------------------------------------
    machine.succeed("test -S /run/postgresql/.s.PGSQL.5432")
    machine.succeed("test -S /run/redis-blockscout/redis.sock")

    # Auto-created groups (postgres by upstream nixpkgs postgres
    # module; redis-blockscout by upstream redis module on the named
    # server). Backend's DynamicUser joins both via SupplementaryGroups.
    machine.succeed("getent group postgres")
    machine.succeed("getent group redis-blockscout")

    # Verify SupplementaryGroups membership at the unit level.
    supp = machine.succeed(
        "systemctl show -p SupplementaryGroups --value blockscout-backend.service"
    ).strip()
    assert "postgres" in supp, f"backend missing postgres group: {supp!r}"
    assert "redis-blockscout" in supp, f"backend missing redis group: {supp!r}"

    # ---------------------------------------------------------------
    # 4. Backend ↔ Autonity loopback RPC.
    # ---------------------------------------------------------------
    rpc = machine.succeed(
        "curl -fsS http://127.0.0.1:8545 "
        "-H 'Content-Type: application/json' "
        '-d \'{"jsonrpc":"2.0","method":"eth_chainId","id":1}\' '
    )
    assert '"result"' in rpc, f"eth_chainId missing result field: {rpc!r}"

    # ---------------------------------------------------------------
    # 5. Backend health endpoint — exercises Postgres (UNIX socket
    #    via host=/run/postgresql) AND Redis (UNIX socket via
    #    redis-blockscout.sock) AND Autonity RPC. Failure of any of
    #    the three surfaces here.
    # ---------------------------------------------------------------
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/v2/health",
        timeout=120,
    )

    # ---------------------------------------------------------------
    # 6. Frontend SSR + bind-mounted envs.js.
    # ---------------------------------------------------------------
    envsjs = machine.succeed("curl -fsS http://127.0.0.1:3000/assets/envs.js")
    assert "window.__envs" in envsjs, (
        f"envs.js does not contain window.__envs assignment: {envsjs!r}"
    )
    assert "NEXT_PUBLIC_NETWORK_NAME" in envsjs, (
        f"envs.js missing expected NEXT_PUBLIC_* keys: {envsjs!r}"
    )

    homepage = machine.succeed("curl -fsS http://127.0.0.1:3000/")
    assert "envs.js" in homepage, (
        "frontend HTML does not reference envs.js — "
        "the bind-mount overlay would have nothing to load against"
    )

    # ---------------------------------------------------------------
    # 7. Nginx reverse-proxy round-trips. `curl -k` skips trust
    #    check on the self-signed cert; the assertion is "TLS
    #    terminates and the proxy_pass reaches the right upstream".
    # ---------------------------------------------------------------
    proxied_health = machine.succeed(
        "curl -fsSk -H 'Host: ${hostName}' https://127.0.0.1/api/v2/health"
    )
    # /api/v2/health and direct backend /api/v2/health must agree —
    # the proxy_pass should be transparent to the response body.
    direct_health = machine.succeed(
        "curl -fsS http://127.0.0.1:4000/api/v2/health"
    )
    assert proxied_health == direct_health, (
        "nginx /api/v2/health mismatch — proxy_pass altered the body. "
        f"direct={direct_health!r} proxied={proxied_health!r}"
    )

    proxied_root = machine.succeed(
        "curl -fsSk -H 'Host: ${hostName}' https://127.0.0.1/"
    )
    assert "envs.js" in proxied_root, (
        "nginx / does not reverse-proxy frontend correctly"
    )

    proxied_envsjs = machine.succeed(
        "curl -fsSk -H 'Host: ${hostName}' https://127.0.0.1/assets/envs.js"
    )
    assert proxied_envsjs == envsjs, (
        "envs.js bytes differ between direct frontend and through nginx — "
        "indicates either the bind-mount overlay or the proxy is "
        "altering content"
    )

    # ---------------------------------------------------------------
    # 8. Restart resilience — backend reconnects to all three of
    #    Postgres / Redis / Autonity without operator intervention.
    # ---------------------------------------------------------------
    machine.systemctl("restart blockscout-backend.service")
    machine.wait_for_unit("blockscout-backend.service")
    machine.wait_for_open_port(4000)
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/v2/health",
        timeout=120,
    )

    # ---------------------------------------------------------------
    # 9. HTTP → HTTPS redirect via forceSSL.
    # ---------------------------------------------------------------
    redirect_status = machine.succeed(
        "curl -sSI -H 'Host: ${hostName}' http://127.0.0.1/ | head -1"
    ).strip()
    assert "301" in redirect_status or "302" in redirect_status, (
        f"forceSSL HTTP→HTTPS redirect missing: {redirect_status!r}"
    )
  '';
}
