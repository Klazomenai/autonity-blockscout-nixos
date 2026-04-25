# NixOS service module for the Blockscout reverse proxy. Composes
# nixpkgs `services.nginx` to terminate TLS in front of the
# `blockscout-backend` (loopback :4000) and `blockscout-frontend`
# (loopback :3000) services, with Let's Encrypt-issued certificates
# managed by `security.acme`.
#
# This is the only externally-binding service module in the data plane
# besides Autonity P2P (port 30303): the rest of the stack listens on
# loopback only. The defense-in-depth posture is layered:
#   - the data-plane services are firewalled (their ports are NOT in
#     `networking.firewall.allowedTCPPorts`);
#   - this module opens 80 + 443 and reverse-proxies the public traffic
#     onto loopback, where the upstream services see only loopback
#     connections.
#
# Cross-service contract:
#   - Frontend: `127.0.0.1:3000` by default (matches
#     `services.blockscout-frontend`'s default bind). All traffic that
#     does not match a backend prefix routes here. WebSocket upgrade
#     headers are preserved (Next.js dev mode + future feature parity).
#   - Backend: `127.0.0.1:4000` by default (matches
#     `services.blockscout-backend`'s `http.port`). Path prefixes:
#       /api, /api/v2 — REST and JSON-RPC endpoints
#       /socket       — Phoenix WebSocket channel for live updates
#       /health, /metrics — Blockscout introspection
#   - TLS: Let's Encrypt via HTTP-01 by default. `useStaging` toggles
#     to LE's staging directory for first-run validation (production
#     LE has a strict rate limit; running staging first avoids burning
#     it on dry-run errors).
#
# This module does NOT override `systemd.services.nginx`. nixpkgs ships
# the nginx unit with `CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ]`
# (needed to bind 80/443 as a non-root service), `ProtectSystem = strict`,
# and the rest of the hardening matrix; the wrapper composes routes via
# `services.nginx.virtualHosts` and leaves the unit's serviceConfig
# alone — same thin-wrapper pattern as `blockscout-postgresql` and
# `blockscout-redis`.
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.blockscout-nginx;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    optionalAttrs
    ;
in
{
  options.services.blockscout-nginx = {
    enable = mkEnableOption "the Blockscout reverse proxy + ACME TLS termination";

    serverName = mkOption {
      # Server name regex: hostname-shape characters only. Used verbatim
      # as both the `services.nginx.virtualHosts.<name>` attribute key
      # AND interpolated into the nginx `server_name` directive — so
      # rejecting whitespace, quotes, semicolons, and other unsafe
      # nginx-config metacharacters at option-set time prevents config
      # injection regardless of where the value flows.
      type = types.strMatching "^[a-zA-Z0-9.-]+$";
      example = "explorer.example.com";
      description = ''
        Public hostname this reverse proxy serves. Must be a DNS-shape
        hostname (letters, digits, dots, hyphens). The operator is
        responsible for ensuring an A / AAAA record points at this
        host's public IP before enabling ACME — Let's Encrypt's HTTP-01
        challenge fails closed if the hostname does not resolve to the
        validating server.
      '';
    };

    acme = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to obtain a TLS certificate via Let's Encrypt
          (`security.acme`). When false, the module composes the
          virtual host without `enableACME` and the operator is
          expected to wire their own certificate via
          `services.nginx.virtualHosts.${"\${serverName}"}.sslCertificate`
          / `.sslCertificateKey` (or via a separately-managed ACME
          host).
        '';
      };

      email = mkOption {
        type = types.str;
        default = "";
        example = "ops@example.com";
        description = ''
          Account email for the Let's Encrypt registration. Required
          when `acme.enable = true` (enforced via `config.assertions`).
          LE uses this address for expiry warnings and TOS update
          notifications; an unattended deployment that never reads
          this mailbox is fine, but the registration itself requires
          a valid email format.
        '';
      };

      useStaging = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Issue certificates against Let's Encrypt's staging directory
          rather than production. Use `true` for first-run smoke
          testing of a new deployment — production LE has tight rate
          limits (50 certificates per registered domain per week, 5
          duplicate certificates per week) which are easy to exhaust
          on configuration errors. Flip back to `false` once HTTP-01
          validation reliably succeeds.

          Staging certificates are signed by a non-trusted root, so
          browsers will display a warning until the operator switches
          back to production.
        '';
      };
    };

    frontend.upstream = mkOption {
      type = types.str;
      default = "127.0.0.1:3000";
      description = ''
        `host:port` of the Blockscout frontend service. Defaults match
        `services.blockscout-frontend.{host,port}`'s defaults. All
        traffic not matching a backend prefix is proxied here.
      '';
    };

    backend.upstream = mkOption {
      type = types.str;
      default = "127.0.0.1:4000";
      description = ''
        `host:port` of the Blockscout backend service. Defaults match
        `services.blockscout-backend.http.port` on loopback. The
        `/api`, `/api/v2`, `/socket`, `/health`, and `/metrics` path
        prefixes are proxied here.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to open TCP 80 and 443 in `networking.firewall`. Most
        deployments leave this `true`. Set `false` for deployments
        sitting behind a separate load balancer that does TLS
        termination and proxies plaintext loopback traffic to nginx;
        in that case the operator opens whatever ports the LB
        forwards on directly.
      '';
    };

    extraVirtualHostConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        # Strict transport security — 1 year, include subdomains, preload
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
        # Content security policy
        add_header Content-Security-Policy "default-src 'self'; …" always;
      '';
      description = ''
        Operator-supplied nginx configuration injected verbatim into
        the virtual host's `extraConfig` block. Use for security
        headers (HSTS, CSP, X-Frame-Options), rate limiting, geo
        blocks, or any other vhost-level directive this module does
        not expose first-class.

        Inserted as-is into the generated config; the operator is
        responsible for valid nginx syntax. nginx config errors
        surface at `nginx -t` (run automatically as part of the unit's
        `ExecStartPre`), so a typo here will fail the service
        activation rather than silently load a broken config.
      '';
    };
  };

  config = mkIf cfg.enable {
    # ACME requires a contact email when enabled. The empty default on
    # `acme.email` keeps the option non-required at the type level so
    # operators evaluating with `acme.enable = false` don't have to
    # provide a placeholder; the assertion fires only when ACME is
    # actually enabled.
    assertions = [
      {
        assertion = !cfg.acme.enable || cfg.acme.email != "";
        message = "services.blockscout-nginx.acme.email must be set (non-empty) when services.blockscout-nginx.acme.enable is true. Let's Encrypt registration requires a contact email for expiry warnings and TOS updates.";
      }
    ];

    # Open the public web ports. Gated on `openFirewall` so deployments
    # behind a dedicated load balancer (where the LB is the only thing
    # touching the public IP) can leave the host's firewall closed.
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      80
      443
    ];

    # ACME terms acceptance + default email. `mkIf cfg.acme.enable`
    # ensures we don't touch `security.acme` at all when the operator
    # is wiring their own cert — same pattern blockscout-backend uses
    # for `services.postgresql.authentication`.
    security.acme = mkIf cfg.acme.enable (
      {
        acceptTerms = true;
        defaults.email = cfg.acme.email;
      }
      // optionalAttrs cfg.acme.useStaging {
        # LE staging directory. Issued certs are signed by a non-trusted
        # root, so browsers warn until the operator flips back to
        # production. Useful for first-run validation without burning
        # the production rate limit on configuration errors.
        defaults.server = "https://acme-staging-v02.api.letsencrypt.org/directory";
      }
    );

    # Compose the reverse proxy vhost. Zero overrides on
    # `systemd.services.nginx` — nixpkgs ships the nginx unit with
    # CAP_NET_BIND_SERVICE + the rest of its hardening matrix already
    # applied; this wrapper only configures routes.
    services.nginx = {
      enable = lib.mkDefault true;
      recommendedProxySettings = lib.mkDefault true;
      recommendedTlsSettings = lib.mkDefault true;
      recommendedGzipSettings = lib.mkDefault true;
      recommendedOptimisation = lib.mkDefault true;

      virtualHosts.${cfg.serverName} = {
        forceSSL = true;
        enableACME = cfg.acme.enable;

        # Default route — everything that doesn't match a backend
        # prefix lands at the frontend. proxyWebsockets sets the
        # Upgrade + Connection headers; recommendedProxySettings
        # already covers Host / X-Real-IP / X-Forwarded-For/Proto.
        locations."/" = {
          proxyPass = "http://${cfg.frontend.upstream}";
          proxyWebsockets = true;
        };

        # Backend REST + JSON-RPC.
        locations."/api" = {
          proxyPass = "http://${cfg.backend.upstream}";
        };
        locations."/api/v2" = {
          proxyPass = "http://${cfg.backend.upstream}";
        };

        # Phoenix WebSocket channel for live block / tx updates.
        # proxyWebsockets sets Upgrade + Connection headers; the
        # extended timeouts cover quiet periods between server-side
        # heartbeats. Default nginx proxy_read_timeout is 60s, which
        # would close the channel during low-block-rate stretches.
        locations."/socket" = {
          proxyPass = "http://${cfg.backend.upstream}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
          '';
        };

        # Blockscout introspection endpoints. Operators wanting to
        # restrict /metrics to internal networks should add an
        # `allow … deny all;` block via `extraVirtualHostConfig` or
        # override the location directly.
        locations."/health" = {
          proxyPass = "http://${cfg.backend.upstream}";
        };
        locations."/metrics" = {
          proxyPass = "http://${cfg.backend.upstream}";
        };

        extraConfig = cfg.extraVirtualHostConfig;
      };
    };
  };
}
