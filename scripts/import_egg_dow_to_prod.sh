#!/usr/bin/env bash
# Import egg stock weekly books into production DB via SSH tunnel.
#
# Prod Postgres listens on 127.0.0.1 only, and mix run uses MIX_ENV=dev by
# default (which ignores DATABASE_URL). This script:
#   1. SSHs to the server (password via LINODE_PWD or interactive)
#   2. Opens a local tunnel 15432 → server:5432
#   3. Rewrites DATABASE_URL host to 127.0.0.1:15432
#   4. Runs the seed (seed reconfigures Repo from DATABASE_URL)
#
# Usage:
#   LINODE_PWD='…' ./scripts/import_egg_dow_to_prod.sh
#   EGG_DOW_DRY_RUN=1 LINODE_PWD='…' ./scripts/import_egg_dow_to_prod.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEPLOY_CONF="${DEPLOY_CONF:-$ROOT/deploy.conf}"
SEED="$ROOT/priv/repo/seeds/import_ods_egg_dow.exs"
JSON="${EGG_DOW_JSON:-$ROOT/priv/repo/seeds/egg_dow_books.json}"
LOCAL_PORT="${EGG_DOW_TUNNEL_PORT:-15432}"

if [[ ! -f "$JSON" ]]; then
  echo "Missing $JSON"
  exit 1
fi

if [[ ! -f "$DEPLOY_CONF" ]]; then
  echo "Missing $DEPLOY_CONF"
  exit 1
fi

# shellcheck disable=SC1090
source "$DEPLOY_CONF"
CONTAINER="${DOCKER_CONTAINER_NAME:-fc-app}"
HOST="${LINODE_IP:?LINODE_IP missing in deploy.conf}"

if [[ -z "${LINODE_PWD:-}" ]]; then
  if [[ -t 0 ]]; then
    stty -echo
    echo -n "Server root password: "
    read -r LINODE_PWD
    stty echo
    echo
  else
    echo "Set LINODE_PWD for non-interactive SSH"
    exit 1
  fi
fi

SSH=(sshpass -p "$LINODE_PWD" ssh -o StrictHostKeyChecking=no "root@${HOST}")

echo "Fetching DATABASE_URL from ${HOST} container ${CONTAINER}..."
RAW_URL="$("${SSH[@]}" "docker exec ${CONTAINER} printenv DATABASE_URL")"
# postgres://user:pass@localhost:5432/fullcircle → tunnel to 127.0.0.1:LOCAL_PORT
TUNNELED_URL="$(
  python3 - <<PY
import re, os
url = """${RAW_URL}"""
port = os.environ.get("LOCAL_PORT", "${LOCAL_PORT}")
url = re.sub(r"@[^/]+:\d+/", f"@127.0.0.1:{port}/", url)
url = re.sub(r"@localhost(?=[:/])", f"@127.0.0.1", url)
# if no port in host after rewrite, ensure port
if re.search(r"@127\.0\.0\.1/", url):
    url = url.replace("@127.0.0.1/", f"@127.0.0.1:{port}/")
print(url)
PY
)"

echo "Tunnel: localhost:${LOCAL_PORT} → ${HOST}:5432"
# Drop stale listeners on the tunnel port
pkill -f "ssh.*${LOCAL_PORT}:127.0.0.1:5432" 2>/dev/null || true
sleep 0.3
sshpass -p "$LINODE_PWD" ssh -f -N \
  -o StrictHostKeyChecking=no \
  -o ExitOnForwardFailure=yes \
  -L "${LOCAL_PORT}:127.0.0.1:5432" \
  "root@${HOST}"

cleanup() {
  pkill -f "ssh.*${LOCAL_PORT}:127.0.0.1:5432" 2>/dev/null || true
}
trap cleanup EXIT

export DATABASE_URL="$TUNNELED_URL"
export EGG_DOW_JSON="$JSON"
export LOCAL_PORT

echo "Seed: $SEED"
echo "JSON: $JSON"
if [[ "${EGG_DOW_DRY_RUN:-}" == "1" ]]; then
  echo "DRY RUN only"
fi

# Confirm we are not talking to local full_circle_dev by mistake
python3 - <<'PY'
import os, urllib.parse
u = os.environ["DATABASE_URL"]
# hide password
print("DATABASE_URL host:", urllib.parse.urlparse(u).hostname, "port:", urllib.parse.urlparse(u).port, "db:", urllib.parse.urlparse(u).path)
PY

mix run "$SEED"
echo "Import finished."
