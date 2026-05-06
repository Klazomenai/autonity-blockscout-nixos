#!/usr/bin/env bash
# Host-native end-to-end smoke harness for the Autonity + Blockscout
# stack. Spawns the same 5 services that `tests/integration-sync.nix`
# boots in a NixOS VM — autonity (--dev), postgres, redis, blockscout
# backend, blockscout frontend — as plain background processes in a
# scratch state dir, then runs the shared probe sequence
# (`tests/probes.py`) against them.
#
# This is supplementary to the VM check, not a replacement:
#
#   * VM check (`nix flake check`'s `integration-sync`) is
#     authoritative — it exercises real systemd hardening (DynamicUser,
#     LoadCredential, ProtectSystem, RestrictAddressFamilies, etc.) and
#     real cross-service UNIX socket access via SupplementaryGroups.
#   * This harness gives a much faster iteration loop for everything
#     that's NOT systemd-shape: probe vocabulary, JSON-RPC payloads,
#     indexer behaviour, frontend rendering, env-var contract drift.
#     Wall-clock target ~3.5–5 min on a warm cache vs ~20 min for the VM.
#
# Invoked via `nix run .#e2e`. The `flake.nix` `apps.<system>.e2e`
# entry uses `pkgs.writeShellApplication` with `runtimeInputs` so the
# binary tools (postgres, redis-server, autonity, blockscout, node,
# python3, curl, openssl) are on $PATH without absolute store-path
# wiring inside this script.

set -euo pipefail

# --------------------------------------------------------------------
# Configuration (overridable via env)
# --------------------------------------------------------------------

CHAIN_ID="${E2E_CHAIN_ID:-65111111}"
BLOCKS_REQUIRED="${E2E_BLOCKS_REQUIRED:-70}"
PG_PORT="${E2E_PG_PORT:-5432}"
REDIS_PORT="${E2E_REDIS_PORT:-6379}"
RPC_PORT="${E2E_RPC_PORT:-8545}"
WS_PORT="${E2E_WS_PORT:-8546}"
P2P_PORT="${E2E_P2P_PORT:-30303}"
BACKEND_PORT="${E2E_BACKEND_PORT:-4000}"
FRONTEND_PORT="${E2E_FRONTEND_PORT:-3000}"

# --------------------------------------------------------------------
# Port-conflict pre-flight
#
# Many dev machines already have postgres / redis / similar listening
# on the standard service ports the harness defaults to. Detect that
# up front and exit with a targeted message naming the offending port
# AND the env var that overrides it — much cheaper to debug than
# letting an in-flight service fail with a cryptic "bind: address in
# use" deep in its own log file.
#
# `ss -ltnH "( sport = :<port> )"` (iproute2) emits one line per
# matching listening socket and nothing if the port is free; pipe
# through `grep -q .` to set exit status from "non-empty" without
# parsing the line itself. ss's filter-expression form covers
# IPv4 + IPv6 + every loopback / wildcard bind shape uniformly,
# so we don't need an awk pass over the textual output.
# --------------------------------------------------------------------

check_port_free() {
  local port=$1
  local var=$2
  if ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q . ; then
    echo "[e2e] port $port already in use; override via $var=<free-port>" >&2
    return 1
  fi
}

port_conflict=0
check_port_free "$PG_PORT" E2E_PG_PORT || port_conflict=1
check_port_free "$REDIS_PORT" E2E_REDIS_PORT || port_conflict=1
check_port_free "$RPC_PORT" E2E_RPC_PORT || port_conflict=1
check_port_free "$WS_PORT" E2E_WS_PORT || port_conflict=1
check_port_free "$BACKEND_PORT" E2E_BACKEND_PORT || port_conflict=1
check_port_free "$FRONTEND_PORT" E2E_FRONTEND_PORT || port_conflict=1
if [ $port_conflict -ne 0 ]; then
  echo "[e2e] aborting; resolve port conflicts above before retrying" >&2
  exit 1
fi

# --------------------------------------------------------------------
# State dir + cleanup trap
# --------------------------------------------------------------------

STATE_DIR=$(mktemp -d -t run-e2e.XXXXXX)
echo "[e2e] state dir: $STATE_DIR"
PIDS=()

cleanup() {
  rc=$?
  echo "[e2e] cleanup (rc=$rc, killing ${#PIDS[@]} children)"
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  # Give children 10s to exit cleanly, then kill -9
  for _ in $(seq 1 10); do
    alive=0
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    [ $alive -eq 0 ] && break
    sleep 1
  done
  for pid in "${PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  # Stop postgres cleanly if it's still up; pg_ctl knows how.
  if [ -d "$STATE_DIR/pg" ] && [ -f "$STATE_DIR/pg/postmaster.pid" ]; then
    pg_ctl -D "$STATE_DIR/pg" stop -m immediate 2>/dev/null || true
  fi
  if [ "${E2E_KEEP_STATE:-}" = "1" ]; then
    echo "[e2e] state dir kept at $STATE_DIR (E2E_KEEP_STATE=1)"
  else
    rm -rf "$STATE_DIR"
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------
# 1. Postgres
# --------------------------------------------------------------------

echo "[e2e] starting postgres on port $PG_PORT"
PGDATA="$STATE_DIR/pg"
initdb -D "$PGDATA" --auth-local=trust --auth-host=md5 --no-locale --encoding=UTF8 --username=postgres >/dev/null
# Listen on loopback only; unix socket directory under STATE_DIR so
# the harness doesn't collide with a host-installed postgres on
# /run/postgresql.
mkdir -p "$STATE_DIR/pg-sock"
cat >> "$PGDATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = $PG_PORT
unix_socket_directories = '$STATE_DIR/pg-sock'
# Blockscout's Ecto connection pool exhausts the postgres default
# (100). The blockscout-postgresql NixOS module sets 250; match that
# so the indexer doesn't trip "FATAL: sorry, too many clients
# already" mid-catchup.
max_connections = 250
fsync = off
synchronous_commit = off
full_page_writes = off
EOF
pg_ctl -D "$PGDATA" -l "$STATE_DIR/pg.log" -w start
PG_PID=$(head -n 1 "$PGDATA/postmaster.pid")
PIDS+=("$PG_PID")

# Create the blockscout user + DB. Password matches what the backend
# wrapper script expects to find in $CREDENTIALS_DIRECTORY/DATABASE_PASSWORD.
DB_PASSWORD="test-password-not-for-production"
psql -h "$STATE_DIR/pg-sock" -p "$PG_PORT" -U postgres -d postgres <<SQL
CREATE USER blockscout WITH SUPERUSER PASSWORD '$DB_PASSWORD';
CREATE DATABASE blockscout OWNER blockscout;
SQL

# --------------------------------------------------------------------
# 2. Redis
# --------------------------------------------------------------------

echo "[e2e] starting redis on port $REDIS_PORT"
redis-server --port "$REDIS_PORT" --bind 127.0.0.1 --dir "$STATE_DIR" \
  --logfile "$STATE_DIR/redis.log" --daemonize no &
PIDS+=($!)

# --------------------------------------------------------------------
# 3. Autonity (--dev)
# --------------------------------------------------------------------

echo "[e2e] starting autonity --dev on port $RPC_PORT"
mkdir -p "$STATE_DIR/autonity"
autonity \
  --dev \
  --datadir "$STATE_DIR/autonity" \
  --maxpeers 0 \
  --nodiscover \
  --port "$P2P_PORT" \
  --http \
  --http.addr 127.0.0.1 \
  --http.port "$RPC_PORT" \
  --http.api net,web3,eth,aut,tendermint \
  --ws \
  --ws.addr 127.0.0.1 \
  --ws.port "$WS_PORT" \
  --ipcdisable \
  >"$STATE_DIR/autonity.log" 2>&1 &
PIDS+=($!)

wait_for_port() {
  local port=$1
  local timeout=${2:-120}
  local label=${3:-port}
  local deadline=$((SECONDS + timeout))
  while ! curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null \
        && ! (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    if [ $SECONDS -gt $deadline ]; then
      echo "[e2e] timeout waiting for $label on port $port" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_port "$RPC_PORT" 60 "autonity RPC"
echo "[e2e]   autonity up"

# --------------------------------------------------------------------
# 4. Blockscout backend
#
# Mirrors the systemd ExecStart wrapper at
# `modules/blockscout-backend.nix:192-368`:
#   * Reads SECRET_KEY_BASE + DATABASE_PASSWORD from files in a fresh
#     tmpfs-shaped credentials dir (here: $STATE_DIR/creds).
#   * Composes DATABASE_URL with percent-encoded password.
#   * Runs migrations via `bin/blockscout eval 'Explorer.ReleaseTasks.migrate([])'`.
#   * Exec's `bin/blockscout start`.
# Same env-var contract (CHAIN_ID, ETHEREUM_JSONRPC_HTTP_URL, ECTO_USE_SSL,
# PORT, etc.) as the module's `environment = { ... };` block at lines
# 1000-1027 of blockscout-backend.nix.
# --------------------------------------------------------------------

echo "[e2e] preparing blockscout-backend secrets"
mkdir -p "$STATE_DIR/creds"
chmod 700 "$STATE_DIR/creds"
# Fixed test secret key — same value as `tests/integration-sync.nix`'s
# testSecretKeyBase. Real deployments source this from sops-nix or
# agenix; here the determinism is the point.
printf '%s' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' > "$STATE_DIR/creds/SECRET_KEY_BASE"
printf '%s' "$DB_PASSWORD" > "$STATE_DIR/creds/DATABASE_PASSWORD"
chmod 600 "$STATE_DIR/creds/"*

# Percent-encode the DB password byte-by-byte (RFC 3986 unreserved
# pass through). Same logic as blockscout-backend.nix:241-268. The
# fixed test password contains only unreserved characters so this
# loop is a no-op for the default; kept for fidelity with production.
#
# LC_ALL=C so `${raw:i:1}` slices by BYTE rather than by Unicode
# grapheme. Without it, in a UTF-8 locale a non-ASCII password byte
# would be sliced as a multi-byte chunk and the `od -An -tx1` step
# would emit two-byte hex (e.g. `c3a9`), producing a single
# `%c3a9` instead of the correct two-percent-encoding `%c3%a9`.
# Critical only for non-ASCII passwords; mirrored from the systemd
# wrapper's same precaution.
url_encode() {
  local raw="$1"
  local out=""
  local i=0
  local len
  local c hex
  LC_ALL=C
  len=${#raw}
  while [ $i -lt $len ]; do
    c=${raw:$i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out="$out$c" ;;
      *)
        hex=$(printf '%s' "$c" | od -An -tx1 | tr -d ' \n')
        out="$out%$hex"
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

DB_PASSWORD_ENC=$(url_encode "$DB_PASSWORD")
DATABASE_URL="postgres://blockscout:${DB_PASSWORD_ENC}@127.0.0.1:${PG_PORT}/blockscout"

# blockscout binary path. nix run .#e2e wires this via runtimeInputs;
# the binary expects to find its release root via `cd "${cfg.package}"`
# in the systemd wrapper. Replicate by cd'ing into the dirname/dirname
# of the `blockscout` binary on PATH.
BLOCKSCOUT_BIN=$(command -v blockscout)
BLOCKSCOUT_ROOT=$(dirname "$(dirname "$BLOCKSCOUT_BIN")")

# HOME for BEAM's Mix.Local archive directory; matches the
# StateDirectory pattern from blockscout-backend.nix:212-216.
mkdir -p "$STATE_DIR/backend-home"

# Backend env. Same contract as `services.blockscout-backend`'s
# `environment = { ... }` block at blockscout-backend.nix:1000-1027.
backend_env() {
  HOME="$STATE_DIR/backend-home"
  SECRET_KEY_BASE="$(cat "$STATE_DIR/creds/SECRET_KEY_BASE")"
  DATABASE_URL="$DATABASE_URL"
  ACCOUNT_DATABASE_URL="$DATABASE_URL"
  ACCOUNT_REDIS_URL="redis://127.0.0.1:${REDIS_PORT}"
  RELEASE_COOKIE="$(openssl rand -hex 24)"
  ECTO_USE_SSL="false"
  ETHEREUM_JSONRPC_VARIANT="geth"
  ETHEREUM_JSONRPC_HTTP_URL="http://127.0.0.1:${RPC_PORT}"
  ETHEREUM_JSONRPC_WS_URL="ws://127.0.0.1:${WS_PORT}"
  ETHEREUM_JSONRPC_TRACE_URL="http://127.0.0.1:${RPC_PORT}"
  CHAIN_ID="$CHAIN_ID"
  COIN="ATN"
  COIN_NAME="Auton"
  NETWORK="Autonity"
  SUBNETWORK="MainNet"
  PORT="$BACKEND_PORT"
  BLOCKSCOUT_HOST="localhost"
  BLOCKSCOUT_PROTOCOL="http"
  export HOME SECRET_KEY_BASE DATABASE_URL ACCOUNT_DATABASE_URL \
    ACCOUNT_REDIS_URL RELEASE_COOKIE ECTO_USE_SSL \
    ETHEREUM_JSONRPC_VARIANT ETHEREUM_JSONRPC_HTTP_URL \
    ETHEREUM_JSONRPC_WS_URL ETHEREUM_JSONRPC_TRACE_URL CHAIN_ID \
    COIN COIN_NAME NETWORK SUBNETWORK PORT BLOCKSCOUT_HOST \
    BLOCKSCOUT_PROTOCOL
}

echo "[e2e] running blockscout migrations"
(
  cd "$BLOCKSCOUT_ROOT"
  backend_env
  "$BLOCKSCOUT_BIN" eval 'Explorer.ReleaseTasks.migrate([])'
)

echo "[e2e] starting blockscout-backend on port $BACKEND_PORT"
(
  cd "$BLOCKSCOUT_ROOT"
  backend_env
  exec "$BLOCKSCOUT_BIN" start
) >"$STATE_DIR/backend.log" 2>&1 &
PIDS+=($!)

wait_for_port "$BACKEND_PORT" 600 "blockscout-backend"
echo "[e2e]   backend up"

# --------------------------------------------------------------------
# 5. Blockscout frontend
# --------------------------------------------------------------------

echo "[e2e] starting blockscout-frontend on port $FRONTEND_PORT"
# Locate server.js inside the frontend package. The Blockscout fork's
# pnpm/Next.js build flattens the standalone tree directly into the
# package root (`<store>/server.js` rather than the upstream
# Next.js convention of `<store>/.next/standalone/server.js`), so
# `command -v blockscout-frontend` followed by walking up to the
# package root + checking for `./server.js` is the right path.
# Hard-fail with a clear error if the layout ever changes upstream.
FRONTEND_BIN=$(command -v blockscout-frontend)
FRONTEND_PKG=$(dirname "$(dirname "$FRONTEND_BIN")")
SERVER_JS="${FRONTEND_PKG}/server.js"
if [ ! -f "$SERVER_JS" ]; then
  echo "[e2e] could not locate server.js at $SERVER_JS" >&2
  echo "[e2e]   blockscout-frontend package layout may have changed upstream" >&2
  exit 1
fi
NEXT_DIR="$FRONTEND_PKG"
# We don't bind-mount a fresh envs.js (that's the systemd unit's
# BindReadOnlyPaths overlay); the host-native frontend serves the
# package's baked-in MainNet placeholder. probes.py's envs.js
# cross-check is gated by PROBE_VERIFY_ENVS_CHAIN_ID, which we leave
# unset here so only the "envs.js is served" half of the assertion
# runs in host-native mode.
(
  HOSTNAME=127.0.0.1
  PORT="$FRONTEND_PORT"
  NEXT_PUBLIC_NETWORK_ID="$CHAIN_ID"
  NEXT_PUBLIC_API_HOST="localhost"
  NEXT_PUBLIC_API_PROTOCOL="http"
  NEXT_PUBLIC_API_PORT="$BACKEND_PORT"
  NEXT_PUBLIC_APP_HOST="localhost"
  NEXT_PUBLIC_APP_PROTOCOL="http"
  NEXT_PUBLIC_APP_PORT="$FRONTEND_PORT"
  export HOSTNAME PORT NEXT_PUBLIC_NETWORK_ID NEXT_PUBLIC_API_HOST \
    NEXT_PUBLIC_API_PROTOCOL NEXT_PUBLIC_API_PORT NEXT_PUBLIC_APP_HOST \
    NEXT_PUBLIC_APP_PROTOCOL NEXT_PUBLIC_APP_PORT
  cd "$NEXT_DIR"
  exec node "$SERVER_JS"
) >"$STATE_DIR/frontend.log" 2>&1 &
PIDS+=($!)

wait_for_port "$FRONTEND_PORT" 120 "blockscout-frontend"
echo "[e2e]   frontend up"

# --------------------------------------------------------------------
# 6. Run the shared probe sequence
# --------------------------------------------------------------------

echo "[e2e] all services up; running probes"
PROBES_PY="${E2E_PROBES_PY:-${BASH_SOURCE%/*}/probes.py}"

PROBE_RPC_URL="http://127.0.0.1:${RPC_PORT}" \
PROBE_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}" \
PROBE_FRONTEND_URL="http://127.0.0.1:${FRONTEND_PORT}" \
PROBE_CHAIN_ID="$CHAIN_ID" \
PROBE_BLOCKS_REQUIRED="$BLOCKS_REQUIRED" \
PROBE_PSQL_CMD="psql -h $STATE_DIR/pg-sock -p $PG_PORT -U blockscout -At -d blockscout" \
PGPASSWORD="$DB_PASSWORD" \
python3 "$PROBES_PY"

echo "[e2e] all probes passed"
