# NixOS service module for Autonity — a hardened systemd unit that runs
# the Autonity blockchain node (Go, geth-derived). Defense-in-depth
# hardening follows the matrix documented in the `nix-modules-hardening`
# Claude skill; see `../CONTRIBUTING.md` for the per-repo summary.
#
# Expects `autonityPkgs` to be passed via `_module.args` from the flake
# output (see `../flake.nix`). `autonityPkgs.default` is the minimal ELF
# variant; operators wanting the bash-wrapped `autonity-portable` can
# set `services.autonity.package` explicitly.
{
  config,
  lib,
  pkgs,
  autonityPkgs,
  ...
}:

let
  cfg = config.services.autonity;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    literalExpression
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

    package = mkOption {
      type = types.package;
      default = autonityPkgs.default;
      defaultText = literalExpression "autonityPkgs.default";
      description = ''
        The Autonity package to run. Defaults to the `klazomenai/autonity`
        flake input's `packages.<system>.default` (minimal ELF variant).
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/autonity";
      description = ''
        Chain-data directory, surfaced via systemd `StateDirectory`. The
        path is managed by systemd and does not need to exist on the host
        ahead of service start.
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
          non-loopback port this module opens.
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
          network namespace (often `127.0.0.1` behind NAT), and peers
          cannot reach the node.
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
    systemd.services.autonity = {
      description = "Autonity blockchain node";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/autonity ${args} ${lib.escapeShellArgs cfg.extraArgs}";
        Restart = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
        StateDirectory = "autonity";
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
    # should be a conscious decision (typically mediated via nginx).
    warnings =
      lib.optional (cfg.http.enable && cfg.http.addr != "127.0.0.1" && cfg.http.addr != "localhost")
        "services.autonity.http.addr is `${cfg.http.addr}` — the HTTP JSON-RPC server will be reachable beyond loopback. Ensure a TLS reverse proxy and authentication front it."
      ++
        lib.optional (cfg.ws.enable && cfg.ws.addr != "127.0.0.1" && cfg.ws.addr != "localhost")
          "services.autonity.ws.addr is `${cfg.ws.addr}` — the WebSocket server will be reachable beyond loopback. Ensure a TLS reverse proxy and authentication front it.";
  };
}
