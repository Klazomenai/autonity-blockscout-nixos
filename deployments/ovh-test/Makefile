# M3 OVH test-bed Makefile — provision → install → deploy → test → halt.
#
# Operator brings env vars (see README.md Prerequisites). Each recipe
# validates its required vars at entry.
#
# All recipes are designed to run from inside `devenv shell` (or with
# the equivalent toolchain on PATH: nixos-anywhere, ovh-cli, gcloud,
# ssh, jq, curl, python3, openssl).

# SHELL must be a single executable path per GNU Make. The
# `/usr/bin/env bash` shorthand looks tempting but Make would try to
# exec a literal `/usr/bin/env bash` file (with embedded space) and
# fail at recipe execution time — `make -n` checks miss this
# because dry-run doesn't invoke SHELL.
#
# Standard idiom: SHELL=/usr/bin/env, SHELLFLAGS prepends `bash` so
# the actual command becomes `/usr/bin/env bash -euo pipefail -c
# <recipe>` at runtime. `/usr/bin/env` is universally present on
# Linux including NixOS hosts; bash is on PATH from `devenv shell`.
SHELL := /usr/bin/env
.SHELLFLAGS := bash -euo pipefail -c
.DEFAULT_GOAL := help

# ----------------------------------------------------------------------
# Defaults — overridable by env or `make VAR=value`.
# ----------------------------------------------------------------------

OVH_REGION   ?= UK1
OVH_FLAVOR   ?= b3-8
OVH_IMAGE    ?= NixOS 25.05
DOMAIN_TTL   ?= 300

SECRETS_DIR  := $(HOME)/.config/pharos-secrets
STAGING_DIR  := $(CURDIR)/.staging
HARDWARE_CFG := $(CURDIR)/hardware-configuration.nix

# Env-var injection for flake-eval-time operator values. The flake's
# nixosConfigurations.ovh-test reads PHAROS_SERVER_NAME +
# PHAROS_ACME_EMAIL + PHAROS_HARDWARE_CONFIG via builtins.getEnv,
# requiring `--impure` for non-empty values. This sidesteps Nix's
# VCS-filtered source tree (which excludes gitignored operator-local
# files). $$(cat …) is evaluated at recipe-run time, not Make-parse
# time, so the secret files only need to exist when the recipe runs.
RUNTIME_ENV = \
  PHAROS_SERVER_NAME="$$(cat "$(SECRETS_DIR)/server_name")" \
  PHAROS_ACME_EMAIL="$$(cat "$(SECRETS_DIR)/acme_email")" \
  PHAROS_HARDWARE_CONFIG="$(HARDWARE_CFG)"

# SSH options for ephemeral test-bed instances. The pair below is
# the trade-off between non-interactive automation and MITM
# resistance:
#
#   StrictHostKeyChecking=accept-new
#     First contact with a fresh OVH instance accepts its host key
#     without prompting (automation can't pause). Subsequent
#     connects within the same cycle VERIFY against the stored
#     key — if the key changes mid-cycle (e.g. someone MitM'd the
#     instance), SSH aborts rather than silently accepting the
#     new key. Far better than StrictHostKeyChecking=no which
#     accepts ANY key on every connect.
#
#   UserKnownHostsFile=$(CURDIR)/.known_hosts
#     Per-deployment known_hosts file scoped to this directory
#     (gitignored). Keeps test-bed host keys out of the operator's
#     ~/.ssh/known_hosts. `make halt` removes this file so the
#     next cycle's `make install` starts fresh — avoids the
#     "instance IP reused with new key" abort that would otherwise
#     occur cross-cycle.
#
# The remaining two (ConnectTimeout / ServerAliveInterval) keep
# the SSH session alive across OVH's "instance up but cloud-init
# still finishing" window during install.
#
# Production deployments (out of scope per #49) would invert to
# `StrictHostKeyChecking=yes` against a managed known_hosts file
# populated out-of-band, eliminating the first-contact TOFU
# window entirely.
SSH_TESTBED_OPTS := -o StrictHostKeyChecking=accept-new \
                    -o UserKnownHostsFile=$(CURDIR)/.known_hosts \
                    -o ConnectTimeout=30 \
                    -o ServerAliveInterval=30

# ----------------------------------------------------------------------
# Required-var guards. Each recipe lists which vars it needs.
# ----------------------------------------------------------------------

define require_var
$(if $($(1)),,$(error $(1) is not set; see README.md Prerequisites))
endef

# ----------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------

.PHONY: help
help:
	@echo "M3 OVH test-bed recipes"
	@echo ""
	@echo "  make provision           Spin up an OVH instance (writes IP=... line + .last-instance-id)"
	@echo "  make dns-up IP=<ip>      Add A record DOMAIN -> IP via Cloud DNS"
	@echo "  make install IP=<ip>     nixos-anywhere install with --extra-files staging"
	@echo "  make deploy IP=<ip>      nixos-rebuild switch --target-host (after install)"
	@echo "  make test IP=<ip>        Run M3 probe contract via SSH-tunneled ports"
	@echo "  make logs IP=<ip>        Stream journalctl of the 6 services"
	@echo "  make snapshot IP=<ip>    (TBD) capture state for forensics"
	@echo "  make halt                Destroy the instance recorded in .last-instance-id"
	@echo "  make dns-down            Remove the A record DOMAIN -> *"
	@echo "  make cruise              Full cycle: provision -> dns-up -> install -> test -> halt -> dns-down (deploy omitted; redundant after fresh install)"
	@echo ""
	@echo "Required env vars (subset per recipe):"
	@echo "  OVH_TOKEN OVH_PROJECT_ID         (provision, halt)"
	@echo "  GCLOUD_PROJECT DNS_ZONE DOMAIN   (dns-up, dns-down)"
	@echo "  IP                               (install, deploy, test, logs, snapshot)"

# ----------------------------------------------------------------------
# check-runtime-env — verify the operator-local files that drive the
# flake's getEnv-based runtime overlay are present. Called before
# install / deploy so a missing file fails fast with a clear message
# instead of yielding an empty PHAROS_* value that silently falls
# through to the placeholders.
# ----------------------------------------------------------------------

.PHONY: check-runtime-env
check-runtime-env:
	@$(call require_var,DOMAIN)
	@if [ ! -f "$(SECRETS_DIR)/server_name" ]; then \
	  echo "[runtime] missing $(SECRETS_DIR)/server_name; see secrets.example.md"; exit 1; fi
	@if [ ! -f "$(SECRETS_DIR)/acme_email" ]; then \
	  echo "[runtime] missing $(SECRETS_DIR)/acme_email; see secrets.example.md"; exit 1; fi
	@server_name=$$(cat "$(SECRETS_DIR)/server_name"); \
	 if [ "$$server_name" != "$(DOMAIN)" ]; then \
	   echo "[runtime] WARNING: server_name ($$server_name) != DOMAIN ($(DOMAIN))"; \
	   echo "[runtime]          ACME HTTP-01 will validate against DOMAIN; mismatch breaks issuance."; \
	 fi
	@echo "[runtime] env-var sources OK; flake will read PHAROS_SERVER_NAME + PHAROS_ACME_EMAIL via --impure"

# ----------------------------------------------------------------------
# Staging dir for --extra-files. Mirrors the on-host layout exactly
# (--extra-files copies the path contents to / on the target).
#
# Ships the LoadCredential-style secrets (read by services at unit
# start) + the operator's SSH authorized_keys for root@. Does NOT
# ship server_name / acme_email — those are consumed at Nix-eval
# time on the operator's machine via the flake's
# `builtins.getEnv` reads of PHAROS_SERVER_NAME / PHAROS_ACME_EMAIL
# (with `--impure`), so they end up baked into the closure rather
# than transferred to the target as files.
# ----------------------------------------------------------------------

.PHONY: stage
stage: check-runtime-env
	@for f in secret_key_base database_password root_authorized_keys; do \
	  if [ ! -f "$(SECRETS_DIR)/$$f" ]; then \
	    echo "[stage] missing $(SECRETS_DIR)/$$f; see secrets.example.md"; exit 1; fi; \
	done
	@rm -rf "$(STAGING_DIR)"
	@install -d -m 0700 "$(STAGING_DIR)/var/lib/pharos-secrets"
	@install -m 0600 "$(SECRETS_DIR)/secret_key_base"   "$(STAGING_DIR)/var/lib/pharos-secrets/secret_key_base"
	@install -m 0600 "$(SECRETS_DIR)/database_password" "$(STAGING_DIR)/var/lib/pharos-secrets/database_password"
	@install -d -m 0700 "$(STAGING_DIR)/root/.ssh"
	@install -m 0600 "$(SECRETS_DIR)/root_authorized_keys" "$(STAGING_DIR)/root/.ssh/authorized_keys"
	@echo "[stage] $(STAGING_DIR) ready ($$(find "$(STAGING_DIR)" -type f 2>/dev/null | wc -l) files)"

# ----------------------------------------------------------------------
# OVH compute lifecycle
# ----------------------------------------------------------------------

.PHONY: provision
provision:
	@$(call require_var,OVH_TOKEN)
	@$(call require_var,OVH_PROJECT_ID)
	@name="pharos-test-$$(date -u +%Y%m%d-%H%M%S)"; \
	 echo "[provision] flavor=$(OVH_FLAVOR) image=$(OVH_IMAGE) region=$(OVH_REGION) name=$$name"; \
	 response=$$(ovh-cli cloud project $(OVH_PROJECT_ID) instance create \
	   --flavor "$(OVH_FLAVOR)" --image "$(OVH_IMAGE)" --region "$(OVH_REGION)" \
	   --name "$$name" --output json); \
	 instance_id=$$(echo "$$response" | jq -r '.id // empty'); \
	 if [ -z "$$instance_id" ]; then \
	   echo "[provision] FAILED to parse instance ID; raw response:"; echo "$$response"; exit 1; fi; \
	 echo "$$instance_id" > .last-instance-id; \
	 echo "[provision] waiting for IP (timeout 300s)..."; \
	 for _ in $$(seq 1 60); do \
	   ip=$$(ovh-cli cloud project $(OVH_PROJECT_ID) instance show --instance-id "$$instance_id" --output json 2>/dev/null \
	     | jq -r '.ipAddresses[]? | select(.type=="public" and .version==4) | .ip' | head -1); \
	   if [ -n "$$ip" ] && [ "$$ip" != "null" ]; then \
	     echo "IP=$$ip"; \
	     echo "[provision] instance $$instance_id at $$ip"; \
	     echo "[provision] export IP=$$ip in your shell, then: make dns-up && make install"; \
	     exit 0; fi; \
	   sleep 5; \
	 done; \
	 echo "[provision] timed out waiting for IP"; exit 1

.PHONY: halt
halt:
	@$(call require_var,OVH_TOKEN)
	@$(call require_var,OVH_PROJECT_ID)
	@if [ -n "$(INSTANCE_ID)" ]; then \
	  instance_id="$(INSTANCE_ID)"; \
	  echo "[halt] using INSTANCE_ID=$$instance_id (overrides .last-instance-id)"; \
	 elif [ -f .last-instance-id ]; then \
	  instance_id=$$(cat .last-instance-id); \
	 else \
	  echo "[halt] no .last-instance-id; pass instance ID via INSTANCE_ID=..."; exit 1; \
	 fi; \
	 echo "[halt] destroying instance $$instance_id"; \
	 ovh-cli cloud project $(OVH_PROJECT_ID) instance delete --instance-id "$$instance_id"; \
	 if [ -z "$(INSTANCE_ID)" ]; then rm -f .last-instance-id; fi; \
	 rm -f .known_hosts; \
	 echo "[halt] done (cleared .known_hosts so next cycle starts fresh)"

# ----------------------------------------------------------------------
# Cloud DNS
# ----------------------------------------------------------------------

.PHONY: dns-up
dns-up:
	@$(call require_var,GCLOUD_PROJECT)
	@$(call require_var,DNS_ZONE)
	@$(call require_var,DOMAIN)
	@$(call require_var,IP)
	@echo "[dns-up] $(DOMAIN) -> $(IP) (zone $(DNS_ZONE), ttl $(DOMAIN_TTL))"
	@gcloud auth print-identity-token >/dev/null 2>&1 || { \
	  echo "[dns-up] gcloud not authenticated; run 'gcloud auth login' or activate a service account"; exit 1; }
	@gcloud dns record-sets create "$(DOMAIN)." \
	  --rrdatas="$(IP)" --type=A --ttl=$(DOMAIN_TTL) \
	  --zone="$(DNS_ZONE)" --project="$(GCLOUD_PROJECT)"
	@echo "[dns-up] propagation poll (5 min cap)..."
	@for _ in $$(seq 1 30); do \
	  resolved=$$(dig +short "$(DOMAIN)" @8.8.8.8 | head -1); \
	  if [ "$$resolved" = "$(IP)" ]; then echo "[dns-up] propagated"; exit 0; fi; \
	  sleep 10; \
	done; \
	echo "[dns-up] WARNING: not propagated within 5 min; install may need to retry ACME"

.PHONY: dns-down
dns-down:
	@$(call require_var,GCLOUD_PROJECT)
	@$(call require_var,DNS_ZONE)
	@$(call require_var,DOMAIN)
	@echo "[dns-down] removing A record for $(DOMAIN)"
	@output=$$(gcloud dns record-sets delete "$(DOMAIN)." --type=A \
	    --zone="$(DNS_ZONE)" --project="$(GCLOUD_PROJECT)" --quiet 2>&1); \
	 rc=$$?; \
	 if [ $$rc -eq 0 ]; then \
	   echo "[dns-down] deleted"; \
	   exit 0; \
	 fi; \
	 if echo "$$output" | grep -qiE 'NOT_FOUND|notFound|was not found'; then \
	   echo "[dns-down] no record found (already deleted)"; \
	   exit 0; \
	 fi; \
	 echo "[dns-down] gcloud failed (rc=$$rc):"; \
	 echo "$$output"; \
	 echo "[dns-down] NOT swallowed — auth / network / permission failures must surface"; \
	 exit $$rc

# ----------------------------------------------------------------------
# NixOS install + deploy
# ----------------------------------------------------------------------

.PHONY: install
install: stage
	@$(call require_var,IP)
	@echo "[install] nixos-anywhere $(IP) (flake .#ovh-test --impure, --extra-files $(STAGING_DIR))"
	@cd ../.. && $(RUNTIME_ENV) nixos-anywhere \
	  --flake '.#ovh-test' \
	  --extra-files "$(STAGING_DIR)" \
	  --generate-hardware-config nixos-generate-config \
	    "$(HARDWARE_CFG)" \
	  --build-on-remote false \
	  --extra-build-args --impure \
	  --ssh-option StrictHostKeyChecking=accept-new \
	  --ssh-option UserKnownHostsFile=$(CURDIR)/.known_hosts \
	  --ssh-option ConnectTimeout=30 \
	  --ssh-option ServerAliveInterval=30 \
	  --target-host "root@$(IP)"
	@echo "[install] done; $(HARDWARE_CFG) written (gitignored)"

.PHONY: deploy
deploy: check-runtime-env
	@$(call require_var,IP)
	@echo "[deploy] nixos-rebuild switch --flake .#ovh-test --impure --target-host root@$(IP)"
	@echo "[deploy] (operator runtime values baked into the closure via PHAROS_* env vars; not shipped separately)"
	@cd ../.. && $(RUNTIME_ENV) NIX_SSHOPTS="$(SSH_TESTBED_OPTS)" nixos-rebuild switch \
	  --flake '.#ovh-test' \
	  --impure \
	  --target-host "root@$(IP)"
	@# `--use-remote-sudo` intentionally omitted: we connect as
	@# root@ already (SSH config disallows password login, accepts
	@# only the operator's authorized_keys), and a minimal NixOS
	@# install doesn't enable sudo by default. Forcing remote
	@# commands through sudo would just add a failure mode.

# ----------------------------------------------------------------------
# Probes — M3 contract via SSH tunnels (no public TLS dependency for
# the probe path; ACME issuance is a separate concern that you verify
# by `curl -sv https://$DOMAIN/`).
# ----------------------------------------------------------------------

.PHONY: test
test:
	@$(call require_var,IP)
	@echo "[test] opening SSH tunnels for ports 8545, 4000, 3000"
	@ssh $(SSH_TESTBED_OPTS) -o ExitOnForwardFailure=yes -fN \
	  -L 8545:127.0.0.1:8545 -L 4000:127.0.0.1:4000 -L 3000:127.0.0.1:3000 \
	  -M -S /tmp/pharos-test-$(IP).sock "root@$(IP)"
	@trap 'ssh -S /tmp/pharos-test-$(IP).sock -O exit "root@$(IP)" 2>/dev/null || true' EXIT; \
	 echo "[test] tunnels up; running probes.py PROBE_MODE=m3"; \
	 PROBE_MODE=m3 \
	 PROBE_RPC_URL=http://127.0.0.1:8545 \
	 PROBE_BACKEND_URL=http://127.0.0.1:4000 \
	 PROBE_FRONTEND_URL=http://127.0.0.1:3000 \
	 PROBE_CHAIN_ID=65000000 \
	 PROBE_PSQL_CMD="ssh -S /tmp/pharos-test-$(IP).sock root@$(IP) runuser -u postgres -- psql -At -d blockscout" \
	 python3 ../../tests/probes.py; \
	 rc=$$?; \
	 ssh -S /tmp/pharos-test-$(IP).sock -O exit "root@$(IP)" 2>/dev/null || true; \
	 trap - EXIT; \
	 exit $$rc

.PHONY: logs
logs:
	@$(call require_var,IP)
	@ssh $(SSH_TESTBED_OPTS) "root@$(IP)" \
	  'journalctl -fu autonity blockscout-backend blockscout-frontend postgresql postgresql-setup redis-blockscout nginx'

.PHONY: snapshot
snapshot:
	@$(call require_var,IP)
	@echo "[snapshot] TBD — implement on the first cruise that surfaces a bug worth investigating."
	@echo "[snapshot] For now, capture by hand:"
	@echo "  ssh root@$(IP) 'free -m && df -h && systemctl --no-pager --failed && journalctl -b --no-pager | tail -200'"

# ----------------------------------------------------------------------
# Aggregate — full test cruise. Use carefully (paid hardware time).
# ----------------------------------------------------------------------

.PHONY: cruise
cruise:
	@cleanup() { \
	   rc=$$?; \
	   set +e; \
	   echo "[cruise] cleanup (exit=$$rc): tearing down to release paid hardware"; \
	   $(MAKE) halt    || echo "[cruise]   halt failed — VERIFY OVH CONSOLE for instance in .last-instance-id"; \
	   $(MAKE) dns-down || echo "[cruise]   dns-down failed — VERIFY Cloud DNS CONSOLE for $(DOMAIN)"; \
	   exit $$rc; \
	 }; \
	 trap cleanup EXIT; \
	 echo "[cruise] WARNING: this provisions a paid OVH instance."; \
	 echo "[cruise] step 1/6: provision"; \
	 $(MAKE) provision | tee .cruise.log; \
	 ip=$$(grep -E '^IP=' .cruise.log | tail -1 | cut -d= -f2); \
	 if [ -z "$$ip" ]; then \
	   echo "[cruise] no IP captured — cleanup trap will still halt via .last-instance-id"; \
	   exit 1; \
	 fi; \
	 export IP="$$ip"; \
	 echo "[cruise] step 2/6: dns-up IP=$$ip"; $(MAKE) dns-up IP="$$ip"; \
	 echo "[cruise] step 3/6: install IP=$$ip"; $(MAKE) install IP="$$ip"; \
	 echo "[cruise] step 4/6: test IP=$$ip"; $(MAKE) test IP="$$ip"; \
	 echo "[cruise] cruise body complete; trap will halt + dns-down on EXIT (steps 5/6 + 6/6)"
	@echo "[cruise] note: 'make deploy' is omitted from cruise — redundant after a fresh install."
	@echo "[cruise]       Use 'make deploy IP=<ip>' explicitly when iterating on code without reprovisioning."
	@# Cleanup contract:
	@#   - trap installed BEFORE `make provision` so that any
	@#     instance created via provision (which writes
	@#     .last-instance-id before returning IP) is cleaned up
	@#     even if provision itself fails partway through (e.g.
	@#     IP-timeout after instance creation).
	@#   - halt uses .last-instance-id as its source of truth
	@#     (no IP needed) — so the cleanup works whether or not
	@#     we made it past provision's IP-parse step.
	@#   - dns-down handles "record not found" benignly, so
	@#     calling it even when dns-up never ran is safe.
	@#   - halt and dns-down failures inside cleanup fall through
	@#     to loud manual-cleanup warnings rather than masking
	@#     the original error; the exit code propagates so
	@#     `make cruise` returns non-zero when anything along
	@#     the way failed.
