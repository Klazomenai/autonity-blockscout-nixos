# Static-analysis flake check that validates the systemd hardening
# `serviceConfig` shipped on each of the six service units composed by
# this repo's `nixosModules.default`. Renders a stub NixOS system at
# sane defaults, walks each unit, and compares the final merged
# `serviceConfig` against the expected-shape table below. Any
# difference (key with a different value, or expected key missing)
# fails the check with a per-unit per-key error report.
#
# Why a flake check rather than a behavioural VM test?
#   - This catches drift cheaply. The full-stack nixosTest
#     (separate, upcoming) exercises behavioural correctness — real
#     syscall denials, real namespace restrictions. This check
#     exercises "the unit file would render as expected" — a much
#     weaker claim, but one that catches the common regression mode
#     where a future module change silently flips a hardening flag.
#   - It runs as part of `nix flake check`, so it gates every PR on
#     `flake-check.yml` automatically. No new workflow needed.
#
# Maintenance contract:
#   When a module change legitimately requires updating one of these
#   expectations (new module, new deviation, nixpkgs upstream change to
#   a wrapped unit), update the relevant `expected.<unit>` entry in
#   the same PR. The PR description must explain WHY the change is
#   safe — e.g. "nixpkgs 25.05 added `ProtectHostname` to the redis
#   service-unit baseline; updating expectation accordingly". Without
#   that paper trail, the check stops being meaningful.
#
# Scope note:
#   - The check encodes the *as-shipped* state, not an idealised
#     uniform baseline. nixpkgs' upstream nginx/postgresql/redis
#     hardening choices differ from this repo's data-plane modules in
#     several places (CapabilityBoundingSet shape, SystemCallFilter
#     style, AF_NETLINK presence). The check enforces the *shipped*
#     values; nixpkgs' upstream choices are nixpkgs' problem.
#   - The check covers `serviceConfig` keys only. ExecStart paths,
#     Environment values, LoadCredential entries, etc. are validated
#     by the per-module assertions (option-set time) and by the
#     full-stack VM test (upcoming).
{
  pkgs,
  nixpkgs,
  flake,
  system,
  # Optional list of additional NixOS modules merged into the stub
  # system. Production use (the `checks.<system>.hardening`
  # output) leaves this empty. Regression-test use sites pass override
  # modules to inject deliberate perturbations and confirm the diff
  # detection fires correctly without requiring a temporary edit to
  # the expected-shape table.
  extraModules ? [ ],
}:

let
  inherit (nixpkgs) lib;

  # Stub NixOS system with all six service modules enabled at sane
  # defaults — enough to render unit files, not enough to actually
  # deploy. The tmpfs root via `fileSystems` and disabled bootloader
  # are standard `eval-only` test boilerplate; the secret path is a
  # placeholder that satisfies the `secretKeyBaseFile` not-in-store
  # assertion without needing the file to exist (we never start the
  # unit).
  evaluated = lib.nixosSystem {
    inherit system;
    modules = [
      flake.nixosModules.default
      {
        nixpkgs.hostPlatform = system;
        boot.loader.grub.enable = false;
        fileSystems."/".device = "tmpfs";
        fileSystems."/".fsType = "tmpfs";
        # Pinned (rather than left at the nixpkgs default-from-release
        # fallback) purely to silence the eval-time warning on every
        # `nix flake check` run. The value is never observed — this
        # NixOS system is built only for serviceConfig inspection,
        # never deployed — so any frozen release tag works. Update
        # opportunistically on nixpkgs major bumps to match.
        system.stateVersion = "24.05";
        services.autonity.enable = true;
        services.blockscout-postgresql.enable = true;
        services.blockscout-redis.enable = true;
        services.blockscout-backend = {
          enable = true;
          secretKeyBaseFile = "/run/secrets/skb";
        };
        services.blockscout-frontend.enable = true;
        services.blockscout-nginx = {
          enable = true;
          serverName = "explorer.example.com";
          acme.email = "ops@example.com";
        };
      }
    ]
    ++ extraModules;
  };

  # Keys whose values represent set semantics (order-irrelevant). The
  # comparator sorts both sides before diffing so a future nixpkgs
  # upgrade reordering elements in `RestrictAddressFamilies` doesn't
  # spuriously fail the check.
  #
  # SystemCallFilter is included here despite a subtlety: systemd
  # treats EACH list element as an independent `SystemCallFilter=`
  # directive in the unit file, with the `~` invert-prefix scoped to
  # the directive it appears on. So `"~@cpu @debug"` (single line)
  # and `[ "~@cpu" "@debug" ]` (two lines) are NOT semantically
  # equivalent — the latter would deny @cpu but ALLOW @debug. The
  # normaliser below therefore deliberately does NOT split strings
  # on whitespace; it only lifts a bare string into a single-element
  # list (handling the redis `""` vs blockscout `[ "" ]` case for
  # CapabilityBoundingSet, where the empty string is the systemd
  # sentinel "no caps" with no whitespace to split). A real
  # representation flip on SystemCallFilter is something the operator
  # SHOULD see — it changes the semantics of the syscall filter, and
  # the maintenance contract handles it cleanly: PR fails, operator
  # confirms semantic equivalence, updates the expected entry.
  setKeys = [
    "CapabilityBoundingSet"
    "RestrictAddressFamilies"
    "SystemCallFilter"
  ];

  # Normalise: lift a bare string to a single-element list. Does NOT
  # split on whitespace (see the SystemCallFilter caveat above).
  toList = v: if builtins.isList v then v else [ v ];

  # Compare two values, normalising for set semantics on the listed
  # keys. Returns true when equal, false otherwise.
  valueEq =
    key: a: b:
    if builtins.elem key setKeys then
      builtins.sort builtins.lessThan (toList a) == builtins.sort builtins.lessThan (toList b)
    else
      a == b;

  # Diff one unit. Returns a list of diff descriptors (empty on match).
  #
  # The unit-lookup is guarded: a unit listed in `expected` but absent
  # from `evaluated.config.systemd.services` (because it was renamed,
  # removed, or its enabling option was flipped off) produces ONE
  # diff entry pointing at the unit-name level rather than letting the
  # check fail with a generic `attribute '<name>' missing` Nix trace.
  # Without the guard, the spike's actionable-error contract breaks
  # exactly when an operator most needs a clear pointer at what
  # changed. Emitting just one entry (rather than one-per-expected-key)
  # keeps the CI output focused on "the unit is gone" rather than
  # padding with N copies of the same diagnostic.
  diffUnit =
    unitName: expectedSc:
    let
      serviceMaybe = evaluated.config.systemd.services.${unitName} or null;
    in
    if serviceMaybe == null then
      [
        {
          unit = unitName;
          key = "<unit>";
          expected = "present in systemd.services";
          actual = "MISSING — unit removed, renamed, or disabled since the expected-shape table was last updated";
        }
      ]
    else
      let
        actual = serviceMaybe.serviceConfig;
        keys = builtins.attrNames expectedSc;
        mismatches = lib.filter (
          k: !(builtins.hasAttr k actual) || !(valueEq k expectedSc.${k} actual.${k})
        ) keys;
      in
      map (k: {
        unit = unitName;
        key = k;
        expected = expectedSc.${k};
        actual = actual.${k} or "MISSING";
      }) mismatches;

  # Per-unit expected `serviceConfig` slices. Encodes the ACTUAL
  # shipped state on `main` as of merging this spike — not an
  # aspirational uniform baseline. Per-unit deviations from the
  # `nix-modules-hardening` skill's matrix are commented inline so
  # future readers (and CI failures) see the rationale at a glance.
  expected = {
    # Autonity — Go binary, no JIT. Ships AF_NETLINK because devp2p
    # discovery enumerates network interfaces. Ships PrivateUsers=true
    # because no SupplementaryGroups (nothing to remap onto the host).
    autonity = {
      CapabilityBoundingSet = [ "" ];
      DynamicUser = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
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

    # Blockscout backend — Elixir/BEAM JIT (MDWX off), depends on
    # cross-service UNIX sockets via SupplementaryGroups so PrivateUsers
    # MUST be false (host GID remapping inside a user namespace would
    # break socket access). No AF_NETLINK (backend doesn't enumerate
    # interfaces).
    blockscout-backend = {
      CapabilityBoundingSet = [ "" ];
      DynamicUser = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = false;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateMounts = true;
      PrivateTmp = true;
      PrivateUsers = false;
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

    # Blockscout frontend — Node.js/V8 JIT (MDWX off). No
    # SupplementaryGroups (talks to the backend over loopback TCP), so
    # PrivateUsers can stay at the systemd default — unlike the
    # backend, where false is load-bearing. The default value isn't
    # set explicitly by the module, so we don't include PrivateUsers
    # in the expected slice (its absence is the expected state).
    blockscout-frontend = {
      CapabilityBoundingSet = [ "" ];
      DynamicUser = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = false;
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

    # nginx — nixpkgs upstream unit. Carries CAP_NET_BIND_SERVICE
    # (needed to bind 80/443 as a non-root service) and CAP_SYS_RESOURCE
    # (rlimit tuning for the high-fd-count workload). Static `nginx`
    # user (no DynamicUser). UMask differs from the data-plane modules
    # (0027 vs 0077) because nginx serves files. SystemCallFilter is a
    # different shape — fewer denies (no @memlock or @resources).
    nginx = {
      CapabilityBoundingSet = [
        "CAP_NET_BIND_SERVICE"
        "CAP_SYS_RESOURCE"
      ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
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
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid"
      ];
      UMask = "0027";
    };

    # PostgreSQL — nixpkgs upstream unit. Static `postgres` user.
    # Carries AF_NETLINK (libpq's getaddrinfo path consults netlink
    # for routing decisions). SystemCallFilter is the @system-service
    # base set minus @privileged + @resources — different style from
    # the data-plane modules' negative-only filter. UMask 0027 because
    # the data directory needs to be group-readable for the local
    # socket auth path.
    postgresql = {
      CapabilityBoundingSet = [ "" ];
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
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
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      UMask = "0027";
    };

    # Redis — nixpkgs upstream unit. CapabilityBoundingSet ships as
    # bare string "" (not [ "" ] like the data-plane modules); the
    # set-key normaliser handles this. Several keys absent that the
    # data-plane modules carry: ProcSubset, ProtectProc, RemoveIPC.
    # SystemCallFilter ships as a single string (not list).
    # DynamicUser is false (the nixpkgs
    # `services.redis.servers.<name>` unit allocates a static
    # `redis-<name>` user so that the auto-created group can be joined
    # by clients via SupplementaryGroups).
    redis-blockscout = {
      CapabilityBoundingSet = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateMounts = true;
      PrivateTmp = true;
      PrivateUsers = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = "~@cpu-emulation @debug @keyring @memlock @mount @obsolete @privileged @resources @setuid";
      UMask = "0077";
    };
  };

  diffs = builtins.concatLists (lib.mapAttrsToList diffUnit expected);

  formatDiff =
    d: "  ${d.unit}.${d.key}: expected ${builtins.toJSON d.expected}, got ${builtins.toJSON d.actual}";
in
if diffs == [ ] then
  pkgs.runCommand "hardening-matrix-ok"
    {
      meta.description = "Static-analysis check: serviceConfig hardening matrix matches expectations on all six service units";
    }
    ''
      touch $out
    ''
else
  builtins.throw ''
    Hardening matrix drift detected on ${toString (builtins.length diffs)} key(s):

    ${builtins.concatStringsSep "\n" (map formatDiff diffs)}

    See `tests/hardening-matrix.nix` for the expected-shape table and
    the maintenance contract. If this drift is intentional, update the
    relevant `expected.<unit>` entry in the same PR with a comment
    explaining why the change is safe.''
