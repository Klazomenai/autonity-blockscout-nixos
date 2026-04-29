# Thin wrapper over nixpkgs `services.redis.servers.<name>` preconfiguring
# Blockscout's Redis instance with TCP-localhost binding. Blockscout
# backend connects via `redis://127.0.0.1:<port>` — the wrapper binds
# IPv4 loopback only, and the matching `services.blockscout-backend.
# redisHost` default uses the IPv4 literal for the same reason (avoids
# `localhost` resolving to `::1` first on dual-stack systems where
# Redis isn't listening).
#
# Connection mode rationale:
#   Blockscout's Redix client uses `Redix.URI.to_start_options/1` to
#   parse the connection URL, and that parser only accepts the
#   `redis://`, `valkey://`, and `rediss://` schemes — `unix:///path`
#   URIs are rejected with `ArgumentError`. An earlier draft of this
#   wrapper defaulted to UNIX-socket-only (`port = 0`,
#   `unixSocket = ...`) on the assumption that Redix would handle the
#   socket form natively, but that path was architecturally
#   incompatible with the Elixir Redix client.
#
#   This module now defaults to TCP-localhost — matching upstream
#   Blockscout's docker-compose deployment shape, and mirroring the
#   same TCP-localhost pivot already applied to `blockscout-postgresql`
#   for the analogous Postgrex limitation.
#
# Hardening of `redis-<name>.service` itself is inherited from the
# upstream nixpkgs module (static `redis-<name>` user/group rather
# than DynamicUser; ProtectSystem=strict, MemoryDenyWriteExecute=true
# — Redis has no runtime JIT — and the rest of the defense-in-depth
# systemd block). This wrapper only adds the Blockscout-specific
# surface on top. Re-applying or weakening that hardening is
# deliberately avoided.
#
# Authentication: Redis on loopback with no `requirePass` configured.
# Authentication remains a separate layer the consumer module or
# operator host config can wire up (`requirePass` from a
# LoadCredential file, ACL file, etc.) — same socket-vs-auth
# separation of concerns established by `blockscout-postgresql`.
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
      # Regex enforces a POSIX-safe identifier so the value is valid
      # across all three downstream interpolations (filesystem path,
      # systemd unit name, auto-created system group): starts with a
      # lowercase letter or digit, followed by lowercase letters,
      # digits, underscores, or hyphens. Rejects paths (`foo/bar`),
      # spaces, shell metacharacters, uppercase names (POSIX group
      # names are lowercase), and leading underscores.
      type = types.strMatching "^[a-z0-9][a-z0-9_-]*$";
      default = "blockscout";
      description = ''
        Name of the nixpkgs `services.redis.servers.<name>` instance.
        Determines the runtime directory (`/run/redis-<name>/`) and
        the systemd unit name (`redis-<name>.service`).

        Must match `^[a-z0-9][a-z0-9_-]*$` — lowercase alphanumeric,
        underscore, and hyphen only; first character alphanumeric.
        Enforced at option-set time via `types.strMatching` so the
        downstream interpolations (path, unit) never receive unsafe
        characters.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 6379;
      description = ''
        TCP port the Redis server listens on (loopback). The
        `blockscout-backend` module's `redisPort` defaults to the
        same value; override both sides if changed.
      '';
    };

    extraSettings = mkOption {
      # Scalar-only. Matches the type used by the `blockscout-postgresql`
      # wrapper for the same escape-hatch role, so both wrappers reject
      # garbage (functions, derivations, paths, nested attrsets) at
      # option-set time rather than failing deep in config rendering.
      # Multi-value Redis options like `save` can be passed as a single
      # space-separated string — Redis accepts both forms.
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.int
          types.str
        ]
      );
      default = { };
      example = {
        maxmemory = "2gb";
        maxmemory-policy = "allkeys-lru";
      };
      description = ''
        Redis settings forwarded verbatim to
        `services.redis.servers.<name>.settings`. The wrapper sets
        `bind` and `port` as sibling options on the nixpkgs module,
        not entries in `settings`. Escape hatch for any `redis.conf`
        option this wrapper does not expose directly.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.redis.servers.${cfg.serverName} = {
      enable = true;

      # TCP-localhost binding. Blockscout's Redix client uses
      # `Redix.URI.to_start_options/1` which only accepts the
      # `redis://`, `valkey://`, and `rediss://` URL schemes — so
      # `unix:///path` URIs are rejected at startup. Same shape as
      # the Postgrex limitation that drove the equivalent pivot in
      # `blockscout-postgresql`.
      #
      # `mkDefault` on each setting so operators who need a different
      # bind address (e.g. multi-host setups) can override.
      bind = mkDefault "127.0.0.1";
      port = mkDefault cfg.port;

      settings = cfg.extraSettings;
    };
  };
}
