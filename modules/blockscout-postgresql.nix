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
        `ensureDBOwnership = true`.

        This wrapper does NOT set a role password and does NOT
        configure `pg_hba.conf`. PostgreSQL authentication is a
        separate concern from socket filesystem access and is left to
        the consumer:

        - The Blockscout backend module (upcoming PR) will either set
          a role password from `LoadCredential=` at startup and add a
          matching `scram-sha-256` entry in
          `services.postgresql.authentication`, or configure a
          `pg_ident.conf` username map if `peer` auth is preferred.
        - Operators bypassing the backend module can configure
          authentication themselves via
          `services.postgresql.authentication`.

        Nixpkgs' default `pg_hba.conf` uses `peer` auth for local
        socket connections, which requires the OS username to match
        the PostgreSQL role name — incompatible with the
        `DynamicUser = true` pattern the backend uses (random OS
        username per run), so additional wiring is always needed.
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

      # UNIX-socket-only by default. Two independent layers are at
      # play here; this wrapper handles only the first:
      #   1. Socket FILESYSTEM access. /run/postgresql/.s.PGSQL.5432
      #      is group-owned by `postgres`; consumers grant themselves
      #      read/write access by joining that group via
      #      SupplementaryGroups on their own systemd unit.
      #   2. PostgreSQL AUTHENTICATION (pg_hba.conf). Controls whether
      #      PostgreSQL trusts the connecting role once the socket has
      #      been reached. Nixpkgs' default for `local` is `peer` — OS
      #      username must match the PG role name — which breaks under
      #      DynamicUser=true (random OS username). The Blockscout
      #      backend module (or operator host config) must set up
      #      either scram-sha-256 + a role password from LoadCredential,
      #      or a pg_ident.conf username map. This wrapper deliberately
      #      stays out of that second layer; see the upcoming
      #      blockscout-backend module for the full auth wiring.
      #
      # `mkDefault` on each setting so operators who genuinely need TCP
      # (external monitoring, remote admin tools) can override.
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
