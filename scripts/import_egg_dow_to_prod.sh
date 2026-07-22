#!/usr/bin/env bash
# Import egg stock weekly books (sales 1–7 / purchase P1–P7) into production DB.
#
# Production runs a Mix release (no `mix` inside the container), so this script
# runs the seed from the dev tree against the production DATABASE_URL.
#
# Usage:
#   # Auto-fetch DATABASE_URL from the running container via deploy.conf:
#   ./scripts/import_egg_dow_to_prod.sh
#
#   # Or pass URL / dry-run:
#   DATABASE_URL='ecto://...' ./scripts/import_egg_dow_to_prod.sh
#   EGG_DOW_DRY_RUN=1 ./scripts/import_egg_dow_to_prod.sh
#
# Optional:
#   EGG_DOW_COMPANY='Kim Poh Sitt Tat'
#   EGG_DOW_JSON=priv/repo/seeds/egg_dow_books.json
#   DEPLOY_CONF=deploy.conf

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEPLOY_CONF="${DEPLOY_CONF:-$ROOT/deploy.conf}"
SEED="$ROOT/priv/repo/seeds/import_ods_egg_dow.exs"
JSON="${EGG_DOW_JSON:-$ROOT/priv/repo/seeds/egg_dow_books.json}"

if [[ ! -f "$JSON" ]]; then
  echo "Missing $JSON"
  echo "Generate with:"
  echo "  python3 priv/repo/seeds/parse_egg_ods_to_json.py \"/path/to/Egg Est Left.ods\""
  exit 1
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  if [[ ! -f "$DEPLOY_CONF" ]]; then
    echo "Set DATABASE_URL or provide $DEPLOY_CONF"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$DEPLOY_CONF"
  CONTAINER="${DOCKER_CONTAINER_NAME:-fc-app}"
  HOST="${LINODE_IP:?LINODE_IP missing in deploy.conf}"
  echo "Fetching DATABASE_URL from ${HOST} container ${CONTAINER}..."
  DATABASE_URL="$(ssh "root@${HOST}" "docker exec ${CONTAINER} printenv DATABASE_URL")"
  export DATABASE_URL
fi

echo "Using DATABASE_URL host: $(echo "$DATABASE_URL" | sed -E 's#.*@([^/]+)/.*#\1#')"
echo "Seed: $SEED"
echo "JSON: $JSON"
if [[ "${EGG_DOW_DRY_RUN:-}" == "1" ]]; then
  echo "DRY RUN only"
fi

export EGG_DOW_JSON="$JSON"
mix run "$SEED"
