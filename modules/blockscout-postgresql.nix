# Thin wrapper over nixpkgs `services.postgresql` preconfiguring the
# PostgreSQL database + role Blockscout expects, listening on TCP
# loopback. The actual `listen_addresses` setting is `"localhost"`
# (matching upstream Blockscout's docker-compose deployment shape),
# which resolves to both `127.0.0.1` and `::1` via /etc/hosts on
# dual-stack systems — Postgres binds whichever loopback addresses
# `localhost` resolves to. The asymmetric symbol-vs-literal choice
# between this wrapper (`listen_addresses = "localhost"`) and
# `blockscout-redis` (`bind = "127.0.0.1"`) is deliberate: Postgres
# binds every resolved address so name-based `localhost` is safe,
# whereas Redis binds only what's literally configured, so the
# matching `redisHost` default uses the literal `127.0.0.1` to dodge
# v6-resolution-first failures.
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
#   `passwordFile` (REQUIRED whenever `enable = true`): the wrapper
#   appends an `ALTER ROLE … WITH PASSWORD …` statement to
#   `systemd.services.postgresql-setup.script` (NOT
#   `postgresql.service.postStart`). nixpkgs runs `ensureUsers` and
#   `ensureDatabases` inside the separate `postgresql-setup.service`
#   one-shot unit, so attaching to `postStart` would fire BEFORE the
#   role exists and ALTER ROLE would fail with `role "blockscout"
#   does not exist`. `mkAfter` orders the appended SQL after the
#   `generateUserSetupScript` block that creates the role.
#
#   No optional / null path: the wrapper is purpose-built for the
#   Blockscout backend, which connects via TCP-localhost with
#   password auth (peer auth on the local UNIX socket would not
#   help because Blockscout's Postgrex layer connects via TCP).
#   Without a password the role would have no credential the
#   backend could authenticate against, so the option is mandatory
#   — `types.str` without a default. Operators not comfortable with
#   the surface this implies should configure `services.postgresql`
#   directly rather than going through this wrapper.
#
#   The `blockscout-backend` module sets the matching
#   `databasePasswordFile` to the same file via `LoadCredential=`.
#   Both options expect an absolute path NOT under `/nix/store/`
#   (enforced via `config.assertions`).
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
      # Lowercase-only by design. nixpkgs `ensureUsers` /
      # `ensureDatabases` issues unquoted CREATE statements, which
      # PostgreSQL folds to lowercase per SQL standard. This wrapper
      # later issues `ALTER ROLE "${cfg.username}" …` with double
      # quotes (case-sensitive identifier), so a mixed/upper-case
      # value here would land in the SQL as e.g. `ALTER ROLE
      # "Blockscout"` while the role nixpkgs created is named
      # `blockscout` → `role "Blockscout" does not exist` at unit
      # start. Constraining to lowercase at option-set time avoids
      # the hazard.
      type = types.strMatching "^[a-z_][a-z0-9_]*$";
      default = "blockscout";
      description = ''
        Name of the PostgreSQL database the Blockscout indexer and API
        connect to. Created on first service start via
        `services.postgresql.ensureDatabases`. Lowercase-only — see
        the inline comment above this option for the case-folding
        rationale that drives the regex.
      '';
    };

    username = mkOption {
      # Same lowercase-only constraint as `databaseName` for the
      # same SQL identifier case-folding reason — nixpkgs creates the
      # role with an unquoted CREATE (folds to lowercase) but our
      # wrapper later double-quotes the value in `ALTER ROLE`,
      # making `Blockscout` ≠ `blockscout`.
      type = types.strMatching "^[a-z_][a-z0-9_]*$";
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
        REQUIRED whenever `services.blockscout-postgresql.enable =
        true`. Absolute path to a file containing the password for
        the `username` role. The option is `types.str` with no
        default — module evaluation fails fast if the operator
        forgets to set it. (See the module header docstring for why
        a `nullOr`-with-null-default isn't offered: there's no
        coherent passwordless mode for Blockscout's TCP-Postgrex
        client.)

        The wrapper appends an `ALTER ROLE … WITH PASSWORD …` step to
        `systemd.services.postgresql-setup.script`
        (NOT `postgresql.service.postStart` — nixpkgs runs
        `ensureUsers` / `ensureDatabases` inside the separate
        `postgresql-setup.service` one-shot unit, which is also where
        this password change has to land or the role won't exist
        yet). The password is therefore applied during the
        `postgresql-setup.service` run, before
        `blockscout-backend.service` starts and connects via TCP
        loopback with the matching password (the backend module's
        `databasePasswordFile` should point at the same file).

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
    # by appending to the `postgresql-setup.service` script. nixpkgs'
    # `ensureUsers` and `ensureDatabases` run inside that one-shot
    # unit (NOT in `postgresql.service.postStart` — that distinction
    # changed in nixpkgs at some point and earlier drafts of this
    # module attached the hook in the wrong place, with `mkAfter` on
    # `postStart` running BEFORE the role was created and ALTER ROLE
    # failing with `role "blockscout" does not exist`). `mkAfter` on
    # the setup-service `script` appends our ALTER ROLE AFTER the
    # `generateUserSetupScript` block that creates the role, so the
    # role is guaranteed to exist when our hook fires.
    #
    # The setup unit runs as `User=postgres` with the upstream
    # PostgreSQL package on its `path`, so `psql` resolves on PATH;
    # we use an explicit path (`config.services.postgresql.package`)
    # anyway for clarity, since this wrapper has no `cfg.finalPackage`
    # surface of its own.
    #
    # Password handling — three constraints:
    #
    #   1. POSIX shell only. nixpkgs runs the setup script under
    #      systemd's default `/bin/sh` (POSIX, not bash). Bash
    #      extensions like `$(< file)` silently expand to nothing
    #      under POSIX. Use standard shell features only.
    #
    #   2. No password in argv. Passing `-v "pw=$value"` to psql
    #      would put the password in psql's argv, visible via
    #      `ps -ef` to anyone on the host. Use psql's `\set name
    #      \`shell-command\`` syntax inside a QUOTED heredoc
    #      instead: psql itself runs the shell command (with
    #      `cat <file>` as its argv — the password is never in any
    #      argv) and captures stdout into the `:pw` variable.
    #
    #   3. Safe SQL string-literal escaping. `:'pw'` interpolates the
    #      value as an SQL string literal with proper escaping
    #      (quotes, backslashes, embedded single-quotes round-trip
    #      safely) so we don't hand-write any escape logic.
    #
    # `<<'EOF'` (quoted heredoc) prevents the OUTER shell from
    # interpreting `$`, backticks, etc. Nix `${...}` interpolation
    # happens at build time (before the shell ever sees the script),
    # so password file path and username are baked in.
    # `lib.escapeShellArg` handles all shell-metacharacter cases
    # (whitespace, globs, single quotes via the `'\''` idiom) for
    # the path; relying on a single hand-written `'…'` wrapper would
    # break on a path containing a literal single quote. psql then
    # parses the heredoc body itself, including the backticks which
    # it (psql) executes via its own shell to capture the password
    # file contents into `:pw`.
    #
    # `-v ON_ERROR_STOP=1` makes psql fail with non-zero exit if the
    # ALTER ROLE doesn't apply, so the setup unit surfaces the
    # failure to systemd instead of swallowing it.
    systemd.services.postgresql-setup.script = lib.mkAfter ''
      ${config.services.postgresql.package}/bin/psql --no-psqlrc -d postgres -v ON_ERROR_STOP=1 <<'EOF'
      \set pw `cat ${lib.escapeShellArg cfg.passwordFile} | tr -d '\n'`
      ALTER ROLE "${cfg.username}" WITH PASSWORD :'pw';
      EOF
    '';
  };
}
