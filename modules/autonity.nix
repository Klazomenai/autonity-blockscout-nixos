# NixOS service module for Autonity — a hardened systemd unit that runs
# the Autonity blockchain node (Go, geth-derived). Defense-in-depth
# hardening follows the matrix documented in the `nix-modules-hardening`
# Claude skill; see `../CONTRIBUTING.md` for the per-repo summary.
#
# The `klazomenai/autonity` flake is wired into `pkgs` via a
# `nixpkgs.overlays` entry on the glue-repo's `nixosModules.default`
# (see `../flake.nix`), so `pkgs.autonity` resolves to the minimal ELF
# variant and `pkgs.autonity-portable` to the bash-wrapped one.
# Operators can override `services.autonity.package` to pick either.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.autonity;
  inherit (lib)
    mkEnableOption
    mkOption
    mkPackageOption
    mkIf
    types
    concatStringsSep
    ;

  # CLI flag attrset → shell string via lib.cli. Null values are dropped,
  # so flags only appear when an option is active.
  argAttrs = {
    datadir = cfg.dataDir;
    syncmode = cfg.syncMode;
    gcmode = cfg.gcMode;
    cache = cfg.cache;
    ipcdisable = true;
    port = cfg.p2p.port;
    maxpeers = cfg.p2p.maxPeers;
    nat = if cfg.p2p.natExtIp != null then "extip:${cfg.p2p.natExtIp}" else null;
    # MainNet is the upstream default (no flag); only Bakerloo testnet
    # needs an explicit switch.
    bakerloo = cfg.network == "bakerloo";

    http = cfg.http.enable;
    "http.addr" = if cfg.http.enable then cfg.http.addr else null;
    "http.port" = if cfg.http.enable then cfg.http.port else null;
    "http.api" =
      if cfg.http.enable && cfg.http.apis != null then concatStringsSep "," cfg.http.apis else null;
    "http.vhosts" =
      if cfg.http.enable && cfg.http.vhosts != null then concatStringsSep "," cfg.http.vhosts else null;

    ws = cfg.ws.enable;
    "ws.addr" = if cfg.ws.enable then cfg.ws.addr else null;
    "ws.port" = if cfg.ws.enable then cfg.ws.port else null;
    "ws.api" = if cfg.ws.enable && cfg.ws.apis != null then concatStringsSep "," cfg.ws.apis else null;

    bootnodes = if cfg.bootnodes != null then concatStringsSep "," cfg.bootnodes else null;

    metrics = cfg.metrics.enable;
  };

  args = lib.cli.toGNUCommandLineShell { } argAttrs;

in
{
  options.services.autonity = {
    enable = mkEnableOption "Autonity blockchain node";

    package = mkPackageOption pkgs "autonity" { };

    dataDir = mkOption {
      # Regex enforces `/var/lib/<segment>(/<segment>)*` where each
      # segment starts with a non-`.` non-`/` char. This rejects
      # traversal (`/var/lib/../tmp`), current-dir (`/var/lib/./foo`),
      # hidden names (`/var/lib/.hidden`), trailing slashes, and empty
      # segments (`/var/lib//foo`) at option-set time, so the
      # `removePrefix` below and the documented "under /var/lib/"
      # guarantee are both actually safe.
      type = types.strMatching "^/var/lib/[^./][^/]*(/[^./][^/]*)*$";
      default = "/var/lib/autonity";
      description = ''
        Chain-data directory. Must be an absolute path under `/var/lib/`,
        with segments that do not start with `.` and contain no `..`
        traversal (enforced via the option type). The relative part of
        the path is used as the systemd `StateDirectory`, so the
        directory is created, owned, and permission-hardened by systemd
        on each service start — no manual `mkdir` or `chown` needed on
        the host. Paths outside `/var/lib/` are not supported by this
        module: `ProtectSystem = "strict"` would block writes there, so
        an operator needing a custom location must provide their own
        systemd override rather than just changing this option.
      '';
    };

    network = mkOption {
      type = types.enum [
        "mainnet"
        "bakerloo"
      ];
      default = "mainnet";
      description = ''
        Autonity network to join. MainNet is the upstream default (no
        flag); selecting Bakerloo (testnet) passes `--bakerloo` to the
        binary.
      '';
    };

    syncMode = mkOption {
      type = types.enum [
        "full"
        "snap"
      ];
      default = "full";
      description = ''
        Chain sync mode. Blockscout's trace indexing requires
        `debug_traceTransaction`, so keep `full` (paired with
        `gcMode = "archive"`) when this node backs Blockscout.
      '';
    };

    gcMode = mkOption {
      type = types.enum [
        "archive"
        "full"
      ];
      default = "archive";
      description = ''
        Storage pruning mode. Blockscout historical-state queries
        require `archive`.
      '';
    };

    cache = mkOption {
      type = types.ints.positive;
      default = 4096;
      description = "In-memory cache size (MiB) for state and block data.";
    };

    http = {
      enable = mkEnableOption "the JSON-RPC HTTP server" // {
        default = true;
      };
      addr = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Listen address for the HTTP JSON-RPC server. Defaults to
          loopback — do not broadcast externally without a TLS reverse
          proxy and authentication in front of it.
        '';
      };
      port = mkOption {
        type = types.port;
        default = 8545;
      };
      apis = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = [
          "eth"
          "net"
          "web3"
          "debug"
        ];
        description = ''
          List of APIs to expose on HTTP (joined with `,` and passed as
          `--http.api`). `null` lets Autonity use its default set.
        '';
      };
      vhosts = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          List of virtual hostnames the HTTP server will accept. Setting
          this REPLACES the default set (including `localhost`) —
          include `localhost` explicitly if in-container health checks
          target it, otherwise the probes will be rejected.
        '';
      };
    };

    ws = {
      enable = mkEnableOption "the JSON-RPC WebSocket server" // {
        default = true;
      };
      addr = mkOption {
        type = types.str;
        default = "127.0.0.1";
      };
      port = mkOption {
        type = types.port;
        default = 8546;
      };
      apis = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
      };
    };

    p2p = {
      port = mkOption {
        type = types.port;
        default = 30303;
        description = ''
          P2P discovery (UDP) and RLPx (TCP) port. Autonity binds this
          externally on all interfaces by design; it is the only
          non-loopback port this module configures Autonity to bind.
        '';
      };
      maxPeers = mkOption {
        type = types.ints.unsigned;
        default = 50;
      };
      natExtIp = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          When set, passed as `--nat extip:<value>` so Autonity
          advertises this external IP in its enode. Without this,
          Autonity advertises the interface IP as seen inside its
          network namespace (often a private/NATed or container
          interface address — RFC1918 in the typical case), and
          peers cannot reach the node.
        '';
      };
      openFirewall = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Open the P2P port in the host firewall. Peer discovery needs
          both UDP (discovery) and TCP (RLPx) on the same port number,
          so both families are opened when this is true.
        '';
      };
    };

    bootnodes = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = ''
        Override the baked-in bootnode list (joined with `,` and passed
        as `--bootnodes`). `null` uses Autonity's defaults.
      '';
    };

    staticNodes = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      example = [
        "enode://0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef@1.2.3.4:30303"
        "enode://fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210@5.6.7.8:30303"
      ];
      description = ''
        Pinned peers that the node always tries to maintain a
        connection to, in addition to peers acquired through
        discovery. Useful when bootnodes are unavailable or when an
        operator wants a guaranteed link between two specific nodes.

        When non-null, the list is JSON-serialised at Nix evaluation
        time and written to `static-nodes.json` in the service's
        `StateDirectory` (`''${cfg.dataDir}/static-nodes.json`) at
        unit start — this is the legacy Geth-family file convention,
        which Autonity still reads verbatim. Autonity does not
        expose a direct `--staticnodes` CLI flag; this module uses
        the `static-nodes.json` path rather than TOML-based config,
        which upstream Geth-family nodes also support (Autonity logs
        a deprecation warning recommending the TOML form, but reads
        the JSON file regardless). The file is staged in the Nix
        store via `pkgs.writeText` and copied into the StateDirectory
        by an `ExecStartPre=` step (mode 0600, owned by the unit's
        dynamic user), so the staged-in-store version is
        world-readable but the in-state-dir version is not. The
        enode URIs are NOT secrets — they're public node-identity
        hints — so the store-resident staged copy carries no secrecy
        concern.

        When `null` (default), no `ExecStartPre=` fires and no JSON
        file is written; Autonity reads no static-peers list and
        relies entirely on `bootnodes` + discovery.
      '';
    };

    metrics.enable = mkEnableOption "the Autonity Prometheus metrics endpoint";

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Additional CLI arguments passed verbatim to the `autonity`
        binary. Escape hatch for flags this module does not yet expose
        as options.
      '';
    };
  };

  config = mkIf cfg.enable {
    # `dataDir` is validated at the option-type layer (`types.strMatching`)
    # — no runtime assertion needed. The type-level check fails earlier
    # and with a clearer error than `config.assertions`.

    networking.firewall = mkIf cfg.p2p.openFirewall {
      allowedTCPPorts = [ cfg.p2p.port ];
      allowedUDPPorts = [ cfg.p2p.port ];
    };

    systemd.services.autonity = {
      description = "Autonity blockchain node";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/autonity ${args} ${lib.escapeShellArgs cfg.extraArgs}";

        # Stage `static-nodes.json` into StateDirectory at unit start
        # when `staticNodes` is non-null. The file is the Geth-family
        # convention for pinned peers — Autonity does not accept a
        # `--staticnodes` CLI flag, so the on-disk file is the only
        # supported input. `install -m 0600` overwrites any existing
        # file, ensuring rebuilds with a changed list always take
        # effect on the next start (not just on first boot). When
        # `staticNodes` is null, the list `lib.optional` below
        # evaluates to `[]` and no ExecStartPre fires.
        ExecStartPre = lib.optional (cfg.staticNodes != null) (
          "${pkgs.coreutils}/bin/install -m 0600 -T "
          + "${pkgs.writeText "static-nodes.json" (builtins.toJSON cfg.staticNodes)} "
          + "\${STATE_DIRECTORY}/static-nodes.json"
        );

        Restart = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
        # Derived from cfg.dataDir so overriding dataDir also moves the
        # systemd-managed state directory. The `dataDir` option's
        # `types.strMatching` constraint enforces that cfg.dataDir lives
        # under /var/lib/, so this removePrefix is always defined.
        StateDirectory = lib.removePrefix "/var/lib/" cfg.dataDir;
        StateDirectoryMode = "0700";

        # Defense-in-depth hardening. See `nix-modules-hardening` skill
        # for the full matrix and the per-option rationale.
        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true; # Go has no runtime JIT.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        PrivateUsers = true;
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
        # AF_NETLINK is required: Autonity (go-ethereum derived) uses
        # netlink sockets to enumerate network interfaces for NAT and
        # discovery address selection. Removing this family makes the
        # P2P subsystem fail at startup with
        # "operation not supported by protocol".
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
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

    # Surface a warning if an operator broadens the JSON-RPC or WS bind
    # beyond loopback — the default is 127.0.0.1 for both, and exposure
    # should be a conscious decision (typically mediated via nginx). The
    # loopback-safe set includes both IPv4 (`127.0.0.1`) and IPv6 (`::1`)
    # loopback addresses plus the `localhost` hostname so IPv6-only dev
    # setups do not trip a false-positive warning.
    warnings =
      let
        loopbackSafe = [
          "127.0.0.1"
          "::1"
          "localhost"
        ];
      in
      lib.optional (cfg.http.enable && !builtins.elem cfg.http.addr loopbackSafe)
        "services.autonity.http.addr is `${cfg.http.addr}` — the HTTP JSON-RPC server will be reachable beyond loopback. Ensure a TLS reverse proxy and authentication in front of it."
      ++
        lib.optional (cfg.ws.enable && !builtins.elem cfg.ws.addr loopbackSafe)
          "services.autonity.ws.addr is `${cfg.ws.addr}` — the WebSocket server will be reachable beyond loopback. Ensure a TLS reverse proxy and authentication in front of it.";
  };
}
