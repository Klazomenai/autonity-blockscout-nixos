# Behavioural full-stack VM integration test. Boots all six service
# modules in a single `pkgs.testers.nixosTest` VM, then exercises real
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

  # Single source of truth for the chain ID this VM exercises. With
  # `services.autonity.network` at its default ("mainnet") the running
  # binary returns chain ID 65000000 from `eth_chainId`, so this value
  # must match. Future fixtures running against `network = "dev"` (#34)
  # change the binary's compiled-in chain to 65111111 and re-bind this
  # `let` to that value; everything downstream — backend `chain.id`,
  # frontend `publicEnv.NEXT_PUBLIC_NETWORK_ID`, and the test
  # assertion — re-evaluates from the same one place.
  #
  # `chainIdHex` is computed at Nix eval time via `lib.toHexString`
  # (which emits uppercase hex without a `0x` prefix). Geth-family
  # JSON-RPC returns lowercase hex, so we normalise via `lib.toLower`
  # before prefixing. The literal hex string never appears anywhere
  # in the source — `git grep` for `0x3dfd240` should find no hits.
  chainId = 65000000;
  chainIdHex = "0x" + pkgs.lib.toLower (pkgs.lib.toHexString chainId);

  # Self-signed cert generated at build time by `pkgs.runCommand`,
  # with the result stored in the Nix store. The test isn't validating
  # CA-trust or HTTPS chain-of-trust — it's validating that nginx
  # terminates TLS and reverse-proxies onto loopback. Self-signed is
  # sufficient for that, and `curl -k` skips the trust check.
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

  # Test secret: a fixed 32-byte (64 hex chars) string standing in
  # for Phoenix's `secret_key_base`. Real deployments source this
  # from sops-nix / agenix. The fixture is materialised at system-
  # activation time onto a `/run/test-secrets/` tmpfs (see the
  # `system.activationScripts.test-secrets` block below), which
  # imitates the sops-nix / agenix shape (`/run/secrets/` tmpfs)
  # closely enough that the runtime secret-path check (#25) accepts
  # it. The whole point of this fixture is determinism, not secrecy
  # — for real deployments use sops-nix / agenix.
  testSecretKeyBase = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
in
pkgs.testers.nixosTest {
  name = "autonity-blockscout-integration";

  nodes.machine =
    {
      config,
      lib,
      options,
      ...
    }:
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

      # Test secrets materialised on a /run tmpfs at system
      # activation time. `/run` is a real filesystem (tmpfs), not a
      # symlink farm, so paths like `/run/test-secrets/skb`
      # resolve to themselves under `realpath -e` and pass the
      # runtime secret-path check (#25) which fails any path that
      # `realpath -e`s to under `/nix/store/`.
      #
      # Earlier drafts of this fixture used `environment.etc.<name>
      # .text = …` for determinism. That works against the
      # eval-time literal-prefix assertion (the consumer-visible
      # path `/etc/test-secrets/<name>` is not literally under
      # /nix/store/), but `/etc/<name>` is a symlink into the store,
      # so the runtime check correctly rejects it. Production
      # deployments must source secrets from sops-nix / agenix into
      # a tmpfs (`/run/secrets/...`); the test fixture imitates
      # that shape with `system.activationScripts` writing
      # plaintext into `/run/test-secrets/`.
      #
      # `${...}` antiquotes the Nix value once at derivation-build
      # time, baking the literal bytes into the activation script
      # itself (which lives in `/nix/store/`). Activation then just
      # runs that pre-built script, which `printf '%s'`s the
      # already-substituted bytes onto the tmpfs without any
      # further interpretation. NOTE: this means the test-fixture
      # bytes ARE in the store as part of the script body — fine
      # for an ephemeral VM-test fixture, but a reminder that
      # `system.activationScripts` is NOT a way to keep secrets out
      # of the store. Production deployments source via sops-nix /
      # agenix, which decrypt at activation time from store-resident
      # ciphertext into a tmpfs path. The `system.activationScripts`
      # harness chains entries via `set -e` at script-render time,
      # but does NOT set `-u` — DO NOT rely on undefined-variable
      # checking in the body. Mode bits are encoded per-file below
      # (skb 0400 root, db_password 0440 postgres) — see the inline
      # comments in the script body for the per-consumer rationale.
      system.activationScripts.test-secrets = ''
        # Directory mode 0755: needs to be traversable by every unit
        # that reads a secret here, which is at minimum root
        # (systemd LoadCredential before dropping to DynamicUser) and
        # `postgres` (the postgresql-setup script's `cat` inside the
        # ALTER ROLE psql heredoc). File-level perms enforce
        # confidentiality.
        ${pkgs.coreutils}/bin/install -d -m 0755 /run/test-secrets

        # secretKeyBaseFile: only consumed by the backend via systemd
        # LoadCredential, which runs as root before dropping to
        # DynamicUser. Owner=root, mode 0400 matches sops-nix's
        # default shape for a secret consumed by a single unit.
        ${pkgs.coreutils}/bin/install -m 0400 -o root -g root /dev/null /run/test-secrets/skb
        printf '%s' ${lib.escapeShellArg testSecretKeyBase} > /run/test-secrets/skb

        # db_password: TWO consumers with different read paths:
        #   1. postgresql-setup.service runs as User=postgres and
        #      `cat`s the file from inside a psql heredoc.
        #   2. blockscout-backend.service ingests via LoadCredential
        #      (root reads before drop to DynamicUser).
        # Owner=postgres, mode 0440 satisfies both — the `postgres`
        # owner satisfies the User=postgres reader, and root reads
        # ANY file regardless of ownership for the LoadCredential
        # path. This matches the canonical sops-nix idiom of
        # `secrets.<name>.owner = "postgres"` for a postgres
        # password.
        ${pkgs.coreutils}/bin/install -m 0440 -o postgres -g postgres /dev/null /run/test-secrets/db_password
        printf '%s' 'test-password-not-for-production' > /run/test-secrets/db_password
      '';

      services.autonity = {
        enable = true;
        # Single-node, no peer discovery — keeps the VM hermetic and
        # avoids the test waiting on outbound 30303 reachability.
        p2p.maxPeers = 0;
        p2p.openFirewall = false;
        extraArgs = [ "--nodiscover" ];

        # Exercise the staticNodes ExecStartPre path. The list value
        # itself is irrelevant for behaviour (the test runs with
        # `--nodiscover --maxpeers=0`, so even the fake loopback peer
        # below is never dialled); what we want to verify is that
        # the wrapper renders `static-nodes.json` into StateDirectory
        # at unit start with mode 0600 and JSON-serialised content.
        # The enode node ID / pubkey field below is 128 hex `0`
        # characters (the full uncompressed secp256k1 pubkey width)
        # — syntactically valid, but cryptographically meaningless.
        staticNodes = [
          "enode://00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000@127.0.0.1:30303"
        ];
      };

      services.blockscout-postgresql = {
        enable = true;
        passwordFile = "/run/test-secrets/db_password";
      };
      # Test-only timeout slack for slow QEMU hosts. nixpkgs' default
      # `TimeoutSec = 120` is fine for production deployments where
      # first-boot `initdb` finishes in <10s, but on a busy laptop or
      # CI runner under contention with autonity + BEAM at the same
      # time, initdb can take 60+ seconds and trip
      # `start-pre operation timed out. Terminating.`
      systemd.services.postgresql.serviceConfig.TimeoutSec = lib.mkForce 600;
      services.blockscout-redis.enable = true;

      services.blockscout-backend = {
        enable = true;
        secretKeyBaseFile = "/run/test-secrets/skb";
        databasePasswordFile = "/run/test-secrets/db_password";
        # Single-source-of-truth threading: backend's `CHAIN_ID` env
        # var reads from the let-bound `chainId` at the top of this
        # file. The value happens to match this option's module-level
        # default (65000000) — the explicit binding makes the variable's
        # intent clear and prevents silent drift if either side is
        # bumped independently in the future (e.g. `network = "dev"`
        # under #34, which switches `chainId` to 65111111).
        chain.id = chainId;
      };

      services.blockscout-frontend = {
        enable = true;
        # Single-source-of-truth threading: frontend's
        # `NEXT_PUBLIC_NETWORK_ID` reads from the same let-bound
        # `chainId`. The module's `publicEnv` default is a non-empty
        # attrset of 14 keys; for `types.attrsOf` the merge semantics
        # treat that default as a single definition that gets fully
        # shadowed by any user-provided definition (rather than per-key
        # merged). To preserve every other default while overriding
        # only the chain ID, we explicitly read the default out of
        # `options` and `//`-override the single key — producing one
        # user definition that contains all 14 keys with the chain ID
        # re-bound to `chainId`. This pattern is robust against future
        # additions to the module's default attrset (new keys land
        # automatically; no need to re-edit the test).
        publicEnv = options.services.blockscout-frontend.publicEnv.default // {
          NEXT_PUBLIC_NETWORK_ID = toString chainId;
        };
      };

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
    import json
    import re

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
    # 1a. `services.autonity.staticNodes` ExecStartPre side-effect.
    #     The fixture above sets a one-element list; this step
    #     asserts the wrapper rendered `static-nodes.json` into
    #     StateDirectory with mode 0600 and that the file parses as
    #     a single-element JSON array of enode URIs. Parsing rather
    #     than substring-matching catches malformed JSON, accidental
    #     wrong list shape (e.g. nested), or a dropped/duplicated
    #     element. With DynamicUser the file lives at
    #     `/var/lib/private/autonity/static-nodes.json` (root has
    #     full traversal regardless of permission bits), and the
    #     symlink at `/var/lib/autonity` points there.
    # ---------------------------------------------------------------
    machine.succeed("test -f /var/lib/autonity/static-nodes.json")
    mode = machine.succeed(
        "stat -c %a /var/lib/autonity/static-nodes.json"
    ).strip()
    assert mode == "600", f"static-nodes.json mode is {mode!r}, expected 600"
    static_nodes_raw = machine.succeed("cat /var/lib/autonity/static-nodes.json")
    static_nodes_json = json.loads(static_nodes_raw)
    assert isinstance(static_nodes_json, list), (
        f"static-nodes.json is not a JSON list: {static_nodes_raw!r}"
    )
    assert len(static_nodes_json) == 1, (
        f"static-nodes.json has {len(static_nodes_json)} entries, expected 1: {static_nodes_json!r}"
    )
    assert (
        isinstance(static_nodes_json[0], str)
        and static_nodes_json[0].startswith("enode://")
    ), (
        f"static-nodes.json[0] is not an enode URI: {static_nodes_json!r}"
    )

    # ---------------------------------------------------------------
    # 2. Loopback ports listening.
    # ---------------------------------------------------------------
    machine.wait_for_open_port(8545)   # Autonity HTTP RPC
    machine.wait_for_open_port(4000)   # Blockscout backend
    machine.wait_for_open_port(3000)   # Blockscout frontend
    machine.wait_for_open_port(80)     # nginx HTTP (redirects to 443)
    machine.wait_for_open_port(443)    # nginx HTTPS

    # ---------------------------------------------------------------
    # 3. Cross-service connectivity surfaces.
    # ---------------------------------------------------------------
    # PostgreSQL still exposes its standard UNIX socket for ad-hoc
    # operator access (`psql`, `pg_dump`); the backend itself reaches
    # it over TCP-localhost because the Postgrex layer only honours
    # URL host:port for the connect call.
    machine.succeed("test -S /run/postgresql/.s.PGSQL.5432")

    # PostgreSQL TCP-localhost (matches services.blockscout-postgresql
    # default of listen_addresses="localhost").
    machine.wait_for_open_port(5432)

    # Redis TCP-localhost (matches services.blockscout-redis default
    # of bind="127.0.0.1" + port=6379). Redis pivoted off UNIX
    # sockets because Redix.URI.to_start_options/1 rejects the
    # `unix://` scheme.
    machine.wait_for_open_port(6379)

    # Backend joins no host system groups — both data-plane services
    # reached over TCP, so SupplementaryGroups should be empty.
    supp = machine.succeed(
        "systemctl show -p SupplementaryGroups --value blockscout-backend.service"
    ).strip()
    assert supp == "", f"backend should have no SupplementaryGroups, got: {supp!r}"

    # ---------------------------------------------------------------
    # 4. Backend ↔ Autonity loopback RPC. `wait_until_succeeds` not
    #    `succeed` — `wait_for_open_port(8545)` only proves the
    #    listener is bound, not that the JSON-RPC handler goroutines
    #    are answering yet. On slow/contended hosts that gap is real.
    # ---------------------------------------------------------------
    rpc = machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:8545 "
        "-H 'Content-Type: application/json' "
        '-d \'{"jsonrpc":"2.0","method":"eth_chainId","id":1}\' ',
        timeout=120,
    )
    # Tightened from a substring-only check ("\"result\"" in rpc) to
    # exact-equality against the let-bound chainIdHex. The hex literal
    # is computed at Nix eval time from the integer `chainId`, so any
    # drift between Autonity's compiled-in chain ID and the test
    # fixture's expectation surfaces here as a clear mismatch instead
    # of silently passing.
    rpc_json = json.loads(rpc)
    assert rpc_json.get("result") == "${chainIdHex}", (
        f"eth_chainId mismatch: expected ${chainIdHex}, got {rpc!r}"
    )

    # ---------------------------------------------------------------
    # 5. Backend health endpoints.
    #    /api/health/liveness — confirms BEAM + the Phoenix endpoint
    #      are listening (does not touch Postgres / Redis / Autonity).
    #    /api/health/readiness — runs a Postgres query against
    #      `last_db_block_status`, so it surfaces password-auth /
    #      TCP-localhost / migration failures.
    #    /api/v2/health — full chain-aware health check; rejected
    #      with 400 in this test because the autonity node runs with
    #      `--nodiscover --maxpeers=0`, never advances past genesis,
    #      and the indexer therefore has no recorded block to assert
    #      `is_healthy_indexing`. Real-chain readiness is M3 territory.
    # ---------------------------------------------------------------
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/health/liveness",
        timeout=120,
    )
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/health/readiness",
        timeout=120,
    )

    # ---------------------------------------------------------------
    # 6. Frontend SSR + bind-mounted envs.js. `wait_until_succeeds`
    #    not `succeed` — Next.js binds 3000 well before the SSR worker
    #    is warm; the first request can return 502/500 while the
    #    route is being compiled. On constrained CI runners that
    #    warm-up window can be tens of seconds.
    # ---------------------------------------------------------------
    envsjs = machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:3000/assets/envs.js",
        timeout=120,
    )
    assert "window.__envs" in envsjs, (
        f"envs.js does not contain window.__envs assignment: {envsjs!r}"
    )
    assert "NEXT_PUBLIC_NETWORK_NAME" in envsjs, (
        f"envs.js missing expected NEXT_PUBLIC_* keys: {envsjs!r}"
    )
    # Cross-check the chain-ID single-source-of-truth threading: the
    # let-bound `chainId` (sourced as a Nix integer) must end up in the
    # rendered envs.js as the JS string value of NEXT_PUBLIC_NETWORK_ID.
    # This catches drift between backend `CHAIN_ID` and frontend's
    # rendered envs.js — the failure mode that the threading was put
    # in place to prevent.
    assert '"${toString chainId}"' in envsjs, (
        f"envs.js missing chain ID '${toString chainId}': {envsjs!r}"
    )

    homepage = machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:3000/",
        timeout=120,
    )
    assert "envs.js" in homepage, (
        "frontend HTML does not reference envs.js — "
        "the bind-mount overlay would have nothing to load against"
    )

    # ---------------------------------------------------------------
    # 7. Nginx reverse-proxy round-trips. `curl -k` skips trust
    #    check on the self-signed cert; the assertion is "TLS
    #    terminates and the proxy_pass reaches the right upstream".
    # ---------------------------------------------------------------
    # `--resolve <hostname>:443:127.0.0.1` pins DNS resolution to
    # loopback while letting the URL itself carry the hostname — that
    # way TLS SNI carries `${hostName}` (matching the certificate's
    # CN/SAN and the nginx server-block selection key) AND the HTTP
    # `Host:` header lines up automatically. Setting `Host:` manually
    # against an IP-literal URL the way an earlier draft did would
    # leave SNI as `127.0.0.1`, which nginx server-block selection
    # doesn't match against — the request would land on whatever
    # nginx considers the default TLS vhost and inadvertently exercise
    # the wrong configuration.
    # First HTTPS round-trip uses `wait_until_succeeds` because
    # `wait_for_open_port(443)` only proves the listener is bound,
    # not that nginx has finished loading the vhost config and the
    # `proxy_pass` upstreams (frontend / backend) have completed
    # their own warmup. Subsequent curls in this section reuse
    # `succeed` — by then the proxy path is confirmed up.
    proxied_health = machine.wait_until_succeeds(
        "curl -fsSk --resolve ${hostName}:443:127.0.0.1 https://${hostName}/api/health/liveness",
        timeout=120,
    )
    # nginx /api/health/liveness and direct backend
    # /api/health/liveness must agree — proxy_pass should be
    # transparent to the response body. liveness chosen over the v2
    # full-health endpoint for the same reason as step 5: the latter
    # 400s on a fresh genesis chain.
    direct_health = machine.succeed(
        "curl -fsS http://127.0.0.1:4000/api/health/liveness"
    )
    assert proxied_health == direct_health, (
        "nginx /api/health/liveness mismatch — proxy_pass altered the body. "
        f"direct={direct_health!r} proxied={proxied_health!r}"
    )

    proxied_root = machine.succeed(
        "curl -fsSk --resolve ${hostName}:443:127.0.0.1 https://${hostName}/"
    )
    assert "envs.js" in proxied_root, (
        "nginx / does not reverse-proxy frontend correctly"
    )

    proxied_envsjs = machine.succeed(
        "curl -fsSk --resolve ${hostName}:443:127.0.0.1 https://${hostName}/assets/envs.js"
    )
    assert proxied_envsjs == envsjs, (
        "envs.js bytes differ between direct frontend and through nginx — "
        "indicates either the bind-mount overlay or the proxy is "
        "altering content"
    )

    # ---------------------------------------------------------------
    # 8. Restart resilience — backend reconnects to Postgres + Redis
    #    + Autonity without operator intervention. Readiness is the
    #    right probe here: it does the same DB query as on first boot,
    #    so a broken connection (e.g. credential not re-read on
    #    restart) would surface as a 500 instead of a 200. The full
    #    /api/v2/health is skipped for the same reason as steps 5/7
    #    (chain stays at genesis under --nodiscover).
    # ---------------------------------------------------------------
    machine.systemctl("restart blockscout-backend.service")
    machine.wait_for_unit("blockscout-backend.service")
    machine.wait_for_open_port(4000)
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:4000/api/health/readiness",
        timeout=240,
    )

    # ---------------------------------------------------------------
    # 9. HTTP → HTTPS redirect via forceSSL.
    #    Accept any 3xx status — nginx ships 301 today, but `forceSSL`
    #    is documented to issue 30x and a future nixpkgs/nginx change
    #    to 307/308 would still satisfy the intent of "redirect
    #    happened" without us needing to chase the exact code.
    # ---------------------------------------------------------------
    redirect_status = machine.succeed(
        "curl -sSI -H 'Host: ${hostName}' http://127.0.0.1/ | head -1"
    ).strip()
    assert re.search(r"^HTTP/\S+\s+3\d\d\b", redirect_status), (
        f"forceSSL HTTP→HTTPS redirect missing: {redirect_status!r}"
    )
  '';
}
