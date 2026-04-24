# Thin wrapper over nixpkgs `services.redis.servers.<name>` preconfiguring
# Blockscout's Redis instance with UNIX-socket-only binding. Blockscout
# backend connects via `/run/redis-<name>/redis.sock` and joins the
# `redis-<name>` group on its own systemd unit (via `SupplementaryGroups`)
# for socket access.
#
# Hardening of `redis-<name>.service` itself is inherited from the
# upstream nixpkgs module (DynamicUser=true, ProtectSystem=strict,
# MemoryDenyWriteExecute=true — Redis has no runtime JIT, full
# defense-in-depth systemd block). This wrapper only adds the
# Blockscout-specific surface on top. Re-applying or weakening that
# hardening is deliberately avoided.
#
# Same socket-vs-auth separation of concerns established by
# `blockscout-postgresql`: the wrapper handles socket filesystem access
# (via `unixSocketPerm = 660` + the `redis-<name>` group auto-created
# by the upstream module). Redis authentication (`requirePass`, ACL
# files) is a separate layer, left to the consumer module or operator
# host config.
{ config, lib, ... }:

let
  cfg = config.services.blockscout-redis;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkDefault
    types
    ;
in
{
  options.services.blockscout-redis = {
    enable = mkEnableOption "Blockscout's Redis (thin wrapper over services.redis.servers.<name>)";

    serverName = mkOption {
      type = types.str;
      default = "blockscout";
      description = ''
        Name of the nixpkgs `services.redis.servers.<name>` instance.
        Determines the runtime directory (`/run/redis-<name>/`), the
        socket path (`/run/redis-<name>/redis.sock`), the auto-created
        system group (`redis-<name>`) that consumers join via
        `SupplementaryGroups`, and the systemd unit name
        (`redis-<name>.service`).
      '';
    };

    extraSettings = mkOption {
      type = types.attrsOf types.anything;
      default = { };
      example = {
        maxmemory = "2gb";
        maxmemory-policy = "allkeys-lru";
      };
      description = ''
        Additional Redis settings merged into the underlying
        `services.redis.servers.<name>.settings` on top of this
        wrapper's defaults. Operator-supplied values win over wrapper
        defaults. Escape hatch for any setting this wrapper does not
        expose directly.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.redis.servers.${cfg.serverName} = {
      enable = true;

      # UNIX-socket-only. Two independent layers are at play; this
      # wrapper handles only the first:
      #   1. Socket FILESYSTEM access. /run/redis-<name>/redis.sock is
      #      group-owned by `redis-<name>` (auto-created by the
      #      upstream module). Consumers grant themselves read/write
      #      access by joining that group via SupplementaryGroups on
      #      their own systemd unit.
      #   2. Redis AUTHENTICATION (requirePass, ACL file). Controls
      #      whether Redis trusts the connecting client once the
      #      socket has been reached. This wrapper deliberately stays
      #      out of that second layer — the Blockscout backend module
      #      (or operator host config) can wire requirePass from a
      #      LoadCredential file or provide an ACL file.
      #
      # `mkDefault` on each setting so operators can override in their
      # host config (e.g. a monitoring host that needs TCP can set
      # `services.redis.servers.blockscout.port = 6379;`).
      port = mkDefault 0;
      unixSocket = mkDefault "/run/redis-${cfg.serverName}/redis.sock";
      unixSocketPerm = mkDefault 660;

      settings = cfg.extraSettings;
    };
  };
}
