# Thin wrapper over nixpkgs `services.postgresql` preconfiguring the
# PostgreSQL database + role Blockscout expects, with UNIX-socket-only
# binding as the default. Blockscout's backend connects via
# `/run/postgresql/.s.PGSQL.5432` and joins the `postgres` group on its
# own systemd unit (via `SupplementaryGroups`) for socket access.
#
# Hardening of `postgresql.service` itself is inherited from the
# upstream nixpkgs module (static UID for on-disk permanence, full
# defense-in-depth systemd block: `ProtectSystem = "strict"`,
# `CapabilityBoundingSet = [""]`, narrow `RestrictAddressFamilies`,
# `SystemCallFilter`, etc.) — this wrapper only adds the Blockscout-
# specific surface on top. Re-applying or weakening that hardening is
# deliberately avoided.
{ config, lib, ... }:

let
  cfg = config.services.blockscout-postgresql;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkDefault
    types
    ;
in
{
  options.services.blockscout-postgresql = {
    enable = mkEnableOption "Blockscout's PostgreSQL (thin wrapper over services.postgresql)";

    databaseName = mkOption {
      type = types.str;
      default = "blockscout";
      description = ''
        Name of the PostgreSQL database the Blockscout indexer and API
        connect to. Created on first service start via
        `services.postgresql.ensureDatabases`.
      '';
    };

    username = mkOption {
      type = types.str;
      default = "blockscout";
      description = ''
        Name of the PostgreSQL role owning the Blockscout database.
        Created on first service start via
        `services.postgresql.ensureUsers` with
        `ensureDBOwnership = true`. No password is set here — the
        Blockscout backend module's `LoadCredential=` secrets pipeline
        supplies the password at connection time.
      '';
    };

    extraSettings = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.int
          types.str
        ]
      );
      default = { };
      example = {
        shared_buffers = "2GB";
        work_mem = "64MB";
      };
      description = ''
        Additional `postgresql.conf` settings merged into the underlying
        `services.postgresql.settings` on top of this wrapper's
        defaults. Operator-supplied values win over wrapper defaults.
        Escape hatch for any setting this wrapper does not expose
        directly.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.postgresql = {
      enable = true;

      ensureDatabases = [ cfg.databaseName ];
      ensureUsers = [
        {
          name = cfg.username;
          ensureDBOwnership = true;
        }
      ];

      # UNIX-socket-only by default. Blockscout backend connects via
      # /run/postgresql/.s.PGSQL.5432; joining the `postgres` group via
      # SupplementaryGroups on its systemd unit grants socket access
      # without needing a TCP listener or password. `mkDefault` so
      # operators who genuinely need TCP (external monitoring, remote
      # admin tools) can still override in their host config.
      settings = {
        listen_addresses = mkDefault "";
        unix_socket_directories = mkDefault "/run/postgresql";
        max_connections = mkDefault 250;
        password_encryption = mkDefault "scram-sha-256";
      }
      // cfg.extraSettings;
    };
  };
}
