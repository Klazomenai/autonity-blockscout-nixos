# NixOS service module for the Blockscout frontend (Next.js standalone
# server, packaged by the `klazomenai/blockscout-frontend` flake).
#
# Cross-service contract:
#   - Backend: queried over loopback TCP at the URL composed from
#     publicEnv.NEXT_PUBLIC_API_{HOST,PROTOCOL,PORT}. The frontend's SSR
#     pipeline hits this URL during page rendering; the browser hits it
#     directly for client-side navigation. Defaults match the
#     blockscout-backend module's loopback :4000 binding.
#   - Listen address: `127.0.0.1:3000` by default. External exposure is
#     terminated by the `blockscout-nginx` module (upcoming PR), which
#     reverse-proxies from 0.0.0.0:443 to this loopback port. Like the
#     backend, the NixOS firewall drops external reach to the frontend
#     port by default (it's not in `allowedTCPPorts`).
#
# Runtime configuration (NEXT_PUBLIC_*):
#   The Blockscout frontend reads runtime config in two places:
#   1. Server-side (SSR, API routes): `process.env.NEXT_PUBLIC_*`.
#      Provided here via `systemd.services.*.environment` (direct
#      `Environment=` entries).
#   2. Client-side (browser): `window.__envs`, populated by a
#      synchronously-loaded `/assets/envs.js` script in the page head.
#      The package ships a placeholder envs.js generated at flake build
#      time from a hardcoded placeholder publicEnv attrset; this module
#      generates a real envs.js at NixOS evaluation time from the
#      operator's `publicEnv` and uses systemd `BindReadOnlyPaths` to
#      overlay it onto the package's path inside the unit's mount
#      namespace. Same source-of-truth attrset feeds both layers, so
#      server and client cannot disagree.
#
# The `klazomenai/blockscout-frontend` flake is wired into pkgs via a
# nixpkgs.overlays entry on the glue-repo's nixosModules.default (see
# ../flake.nix), so `pkgs.blockscout-frontend` resolves to the Next.js
# standalone derivation.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.blockscout-frontend;
  inherit (lib)
    mkEnableOption
    mkOption
    mkPackageOption
    mkIf
    types
    mapAttrsToList
    ;

  # NEXT_PUBLIC_* — same regex Next.js itself uses to decide which env
  # vars are inlined into the client bundle. Everything else stays
  # server-only. Enforced at config.assertions time so a typo'd or
  # deliberately non-public key (e.g. an API token) cannot end up in
  # the client-readable envs.js by accident.
  publicEnvKeyRegex = "^NEXT_PUBLIC_[A-Z0-9_]+$";

  # envs.js generated at Nix evaluation time. The frontend's
  # `pages/_document.tsx` loads this synchronously in the page head;
  # the browser exposes the values as `window.__envs`. JSON serialisation
  # via `builtins.toJSON` handles quoting so values containing quotes,
  # backslashes, or non-ASCII characters round-trip safely.
  envsJs = pkgs.writeText "blockscout-frontend-envs.js" ''
    window.__envs = ${builtins.toJSON cfg.publicEnv};
  '';
in
{
  options.services.blockscout-frontend = {
    enable = mkEnableOption "the Blockscout Next.js frontend";

    package = mkPackageOption pkgs "blockscout-frontend" { };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Listen address for the Next.js standalone server. Defaults to
        loopback; external exposure is terminated by the
        `blockscout-nginx` module. Setting `0.0.0.0` here without an
        explicit firewall opening or reverse proxy in front would still
        be blocked by the NixOS firewall (the port is not in
        `allowedTCPPorts` by default).
      '';
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = ''
        TCP port the Next.js standalone server binds. The
        `blockscout-nginx` module proxies from 443 to this loopback
        port.
      '';
    };

    publicEnv = mkOption {
      # Keys constrained to the NEXT_PUBLIC_* shape — same convention
      # Next.js itself uses to mark variables as safe for client
      # exposure. config.assertions below additionally cross-checks
      # each key, so the error message names the offending key.
      type = types.attrsOf types.str;
      default = {
        NEXT_PUBLIC_API_HOST = "localhost";
        NEXT_PUBLIC_API_PROTOCOL = "http";
        NEXT_PUBLIC_API_PORT = "4000";
        NEXT_PUBLIC_NETWORK_NAME = "Autonity";
        NEXT_PUBLIC_NETWORK_SHORT_NAME = "ATN";
        NEXT_PUBLIC_NETWORK_ID = "65000000";
        NEXT_PUBLIC_NETWORK_RPC_URL = "http://localhost:8545";
        NEXT_PUBLIC_NETWORK_CURRENCY_NAME = "Auton";
        NEXT_PUBLIC_NETWORK_CURRENCY_SYMBOL = "ATN";
        NEXT_PUBLIC_NETWORK_CURRENCY_DECIMALS = "18";
        NEXT_PUBLIC_APP_HOST = "localhost";
        NEXT_PUBLIC_APP_PROTOCOL = "http";
        NEXT_PUBLIC_APP_PORT = "3000";
      };
      description = ''
        Public, browser-readable runtime configuration. Every key MUST
        begin with `NEXT_PUBLIC_` and contain only uppercase letters,
        digits, and underscores. Values land in two places:

        - `process.env.${"\${name}"}` on the server (SSR, API routes),
          via `systemd.services.*.environment` directives.
        - `window.__envs.${"\${name}"}` in the browser, via a generated
          `envs.js` script bind-mounted onto the package's
          `public/assets/envs.js`.

        Both paths read from this same attrset so server and client
        configuration cannot drift.

        Defaults match Autonity MainNet for smoke testing. Production
        deployments override `NEXT_PUBLIC_API_HOST`,
        `NEXT_PUBLIC_APP_HOST`, and `NEXT_PUBLIC_*_PROTOCOL` to match
        the public domain served through the nginx reverse proxy.
      '';
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        NODE_OPTIONS = "--max-old-space-size=2048";
        NEXT_TELEMETRY_DISABLED = "1";
      };
      description = ''
        Non-`NEXT_PUBLIC_` environment variables for the Next.js
        server process — typically Node.js runtime tuning
        (`NODE_OPTIONS`, `NEXT_TELEMETRY_DISABLED`) or non-public
        config picked up by Blockscout's `instrumentation.node.ts`.
        Merged on top of `publicEnv` and the module's static
        `Environment=` entries; operator-supplied keys win on
        collision.

        **NEXT_PUBLIC_* keys belong in `publicEnv`, not here.** Only
        `publicEnv` is reflected into the browser-readable envs.js.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Validate every publicEnv key matches the NEXT_PUBLIC_* shape.
    # Catches typos (NEXT_PUBLI_*) and deliberate non-public values
    # (API tokens, secrets) that would otherwise leak into the
    # client-readable envs.js.
    assertions = mapAttrsToList (name: _: {
      assertion = builtins.match publicEnvKeyRegex name != null;
      message = "services.blockscout-frontend.publicEnv key `${name}` must match `${publicEnvKeyRegex}`. Non-public env vars belong in `extraEnv` (server-side only).";
    }) cfg.publicEnv;

    systemd.services.blockscout-frontend = {
      description = "Blockscout Next.js frontend";
      after = [
        "network-online.target"
        # Soft dependency: SSR queries the backend, but Next.js
        # handles transient upstream failures gracefully (renders the
        # error boundary). Hard `requires` would couple frontend
        # availability to backend startup ordering for no benefit.
        "blockscout-backend.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Single source of truth: publicEnv goes into both the server's
      # process.env (via these Environment= directives) and the
      # browser's window.__envs (via envsJs + BindReadOnlyPaths in
      # serviceConfig below). HOST and PORT control the bind address
      # of the Next.js standalone server (`server.js` reads
      # process.env.HOSTNAME and process.env.PORT). NEXT_TELEMETRY is
      # always disabled — telemetry collection has no place in a
      # production explorer.
      environment = {
        HOSTNAME = cfg.host;
        PORT = toString cfg.port;
        NEXT_TELEMETRY_DISABLED = "1";
      }
      // cfg.publicEnv
      // cfg.extraEnv;

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/blockscout-frontend";
        Restart = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
        StateDirectory = "blockscout-frontend";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "blockscout-frontend";
        RuntimeDirectoryMode = "0700";

        # Overlay the operator-configured envs.js onto the package's
        # placeholder. The frontend's `pages/_document.tsx` loads
        # `/assets/envs.js` synchronously; the package's flake build
        # ships a placeholder generated from a hardcoded publicEnv
        # attrset, intended to be replaced at deploy time.
        # `BindReadOnlyPaths` mounts the Nix-store-resident envsJs
        # over the placeholder inside the unit's private mount
        # namespace — the host's filesystem is unaffected, the
        # operation is reversible (unit stop reverts it), and no
        # writable scratch directory or file copy is needed.
        BindReadOnlyPaths = [
          "${envsJs}:${cfg.package}/public/assets/envs.js"
        ];

        # V8 JIT needs writable + executable memory pages — opt out
        # of MemoryDenyWriteExecute. Per the nix-modules-hardening
        # skill's JIT exception list (Node.js / V8 alongside BEAM,
        # OpenJDK, LuaJIT, PyPy, .NET).
        MemoryDenyWriteExecute = false;

        # Rest of the defense-in-depth baseline per the
        # nix-modules-hardening skill matrix. The frontend has no
        # cross-service UNIX socket dependencies (it talks to the
        # backend over loopback TCP), so PrivateUsers can be left at
        # the systemd default — unlike blockscout-backend, where
        # PrivateUsers = false is load-bearing for SupplementaryGroups
        # socket access.
        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        # No AF_NETLINK — the frontend does not enumerate interfaces
        # or read routing information.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "~@cpu-emulation @debug @keyring @memlock @mount @obsolete @privileged @resources @setuid"
        ];
        UMask = "0077";
      };
    };
  };
}
