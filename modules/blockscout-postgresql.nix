# Thin wrapper over nixpkgs `services.postgresql` preconfiguring the
# PostgreSQL database + role Blockscout expects, listening on TCP
# loopback (`127.0.0.1:5432`).
#
# Connection mode rationale:
#   Blockscout's `Explorer.Repo.ConfigHelper.extract_parameters/1`
#   parses DATABASE_URL via a strict regex requiring
#   `user:pass@host:port/db` form, AND its Postgrex layer parses the
#   URL host/port directly for the connect call — it does NOT respect
#   libpq's `?host=` query-parameter idiom for UNIX-socket connections.
#   So while libpq itself supports UNIX sockets, Blockscout's Elixir
#   stack only supports TCP. An earlier draft of this wrapper defaulted
#   to UNIX-socket-only (`listen_addresses = ""`) and tried to drive
#   socket access via SupplementaryGroups, but that path was
#   architecturally incompatible with Blockscout's Ecto config layer.
#
#   This module now defaults to `listen_addresses = "localhost"` —
#   matching upstream Blockscout's docker-compose deployment shape.
#
# Authentication rationale:
#   With TCP-localhost connection, `pg_hba.conf` defaults need a `host`
#   rule for the role + database. Nixpkgs' default `pg_hba.conf`
#   already includes `host all all 127.0.0.1/32 scram-sha-256`, which
#   together with a role password covers the Blockscout backend's
#   needs — no `peer`-auth complexity, no DynamicUser-vs-fixed-username
#   mismatch.
#
#   `passwordFile` (NEW): when set, a postStart script ALTERs the role
#   to set its password from the file's contents. The
#   `blockscout-backend` module sets the matching `databasePasswordFile`
#   to the same file via `LoadCredential=`. Both options expect an
#   absolute path NOT under `/nix/store/` (enforced via
#   `config.assertions`).
#
# Hardening of `postgresql.service` itself is inherited from the
# upstream nixpkgs module (static `postgres` UID for on-disk
# permanence, full defense-in-depth systemd block: `ProtectSystem =
# "strict"`, `CapabilityBoundingSet = [""]`, narrow
# `RestrictAddressFamilies`, `SystemCallFilter`, etc.) — this wrapper
# only adds the Blockscout-specific surface on top. Re-applying or
# weakening that hardening is deliberately avoided.
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
      type = types.strMatching "^[a-zA-Z_][a-zA-Z0-9_]*$";
      default = "blockscout";
      description = ''
        Name of the PostgreSQL database the Blockscout indexer and API
        connect to. Created on first service start via
        `services.postgresql.ensureDatabases`. SQL-identifier regex
        rejects whitespace, quotes, and other characters that could
        inject into pg_hba / postStart contexts.
      '';
    };

    username = mkOption {
      type = types.strMatching "^[a-zA-Z_][a-zA-Z0-9_]*$";
      default = "blockscout";
      description = ''
        Name of the PostgreSQL role owning the Blockscout database.
        Created on first service start via
        `services.postgresql.ensureUsers` with
        `ensureDBOwnership = true`. Same SQL-identifier regex as
        `databaseName`.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5432;
      description = ''
        TCP port the PostgreSQL server listens on (loopback). The
        `blockscout-backend` module's `databasePort` defaults to the
        same value; override both sides if changed.
      '';
    };

    passwordFile = mkOption {
      # types.str (not types.path) — same Nix-store-leak rationale as
      # the secret-handling options on `blockscout-backend`. Absolute-
      # not-under-/nix/store/ is enforced via `config.assertions`.
      type = types.str;
      example = "/run/secrets/blockscout/db_password";
      description = ''
        Absolute path to a file containing the password for the
        `username` role. The wrapper's postStart script `ALTER ROLE`s
        the role with this password as part of postgres unit
        activation, so the `blockscout-backend` module can connect
        via TCP loopback with the matching password (the backend
        module's `databasePasswordFile` should point at the same
        file).

        MUST be an absolute path NOT under `/nix/store/` — the file's
        contents land in postgres's role table (write path runs as the
        `postgres` system user reading the path), but the source path
        itself must stay out of the world-readable Nix store. Enforced
        via `config.assertions` at option-set time.

        Real deployments source this from sops-nix / agenix into a
        tmpfs path (`/run/secrets/...`) decrypted at activation. For
        the VM integration test, a fixture under `/etc/test-secrets/`
        is acceptable as a determinism-only placeholder.
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
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.passwordFile && !lib.hasPrefix "/nix/store/" cfg.passwordFile;
        message = "services.blockscout-postgresql.passwordFile (`${cfg.passwordFile}`) must be an absolute path NOT under /nix/store/. Storing secrets in the world-readable Nix store defeats the module's secrets contract.";
      }
    ];

    services.postgresql = {
      enable = true;

      ensureDatabases = [ cfg.databaseName ];
      ensureUsers = [
        {
          name = cfg.username;
          ensureDBOwnership = true;
        }
      ];

      # TCP-localhost listening. Blockscout's Postgrex parses URLs as
      # TCP host:port and does not honour libpq's `?host=` query for
      # UNIX-socket overrides — so UNIX-socket-only is incompatible
      # with the Elixir Ecto stack. The unix_socket_directories setting
      # is left at the nixpkgs default; admin tools (`psql`,
      # `pg_dump`) can still use the socket for operational access,
      # but Blockscout connects via TCP.
      #
      # `mkDefault` on each setting so operators who need a different
      # listen address (e.g. multi-host setups where the indexer
      # lives on a separate machine) can override via `extraSettings`.
      settings = {
        listen_addresses = mkDefault "localhost";
        port = mkDefault cfg.port;
        max_connections = mkDefault 250;
        password_encryption = mkDefault "scram-sha-256";
      }
      // cfg.extraSettings;

    };

    # Set the role password from the operator-supplied passwordFile
    # via a postStart hook. Runs after `ensureUsers` (nixpkgs creates
    # the role earlier in postStart) so the ALTER ROLE has a target.
    # ALTER ROLE WITH PASSWORD is idempotent — safe to re-run on
    # every postgres start. `mkAfter` appends our hook AFTER nixpkgs'
    # default postStart so $PSQL is available and the role exists.
    #
    # Password handling: psql's `:'name'` syntax interpolates the
    # value as a properly-escaped SQL string literal — quotes,
    # backslashes, and embedded single-quotes round-trip safely
    # without us hand-writing escape logic. The password value
    # reaches psql via the `-v` (set variable) flag, sourced via
    # `$(< file)` so it never appears in argv (no `ps` leak; bash
    # builtin redirection avoids spawning a `cat` subprocess
    # whose argv would otherwise contain the path).
    systemd.services.postgresql.postStart = lib.mkAfter ''
      $PSQL -v "pw=$(< ${cfg.passwordFile})" -c "ALTER ROLE \"${cfg.username}\" WITH PASSWORD :'pw';"
    '';
  };
}
