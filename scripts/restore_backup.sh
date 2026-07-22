#!/usr/bin/env bash
# Restore a production pg_dump -Ft archive into the local full_circle_dev DB.
#
# Why not plain `pg_restore -c`?
# Local schema often has newer tables (e.g. trading_*) that are not in the
# backup. Those FKs block DROP of companies/contacts/goods/… so -c leaves a
# half-restored mess (duplicate keys, missing FKs).
#
# This script drops and recreates the target database, restores into a clean
# schema, then optionally runs mix ecto.migrate for migrations newer than the
# dump.
#
# Usage:
#   ./scripts/restore_backup.sh backup_at_20260721130001.tar
#   ./scripts/restore_backup.sh backup_at_20260721130001.tar --no-migrate
#
# Env (defaults match config/dev.exs):
#   PGHOST=localhost  PGUSER=full_circle  PGPASSWORD=…  PGDATABASE=full_circle_dev

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BACKUP="${1:-}"
shift || true
RUN_MIGRATE=1
for arg in "$@"; do
  case "$arg" in
    --no-migrate) RUN_MIGRATE=0 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
  esac
done

if [[ -z "$BACKUP" || ! -f "$BACKUP" ]]; then
  echo "Usage: $0 <backup_at_YYYYMMDDHHMMSS.tar> [--no-migrate]"
  echo "Example: $0 backup_at_20260721130001.tar"
  exit 1
fi

export PGHOST="${PGHOST:-localhost}"
export PGUSER="${PGUSER:-full_circle}"
export PGDATABASE="${PGDATABASE:-full_circle_dev}"
export PGPASSWORD="${PGPASSWORD:-nyhlisted}"

echo "==> Target: ${PGUSER}@${PGHOST}/${PGDATABASE}"
echo "==> Backup: $BACKUP"
# Avoid SIGPIPE/pipefail from `head` closing pg_restore -l early
pg_restore -l "$BACKUP" 2>/dev/null | sed -n '1,8p' || true
echo "…"

# 1) Kick connections and recreate empty DB
echo "==> Terminating sessions on ${PGDATABASE}"
psql -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${PGDATABASE}'
  AND pid <> pg_backend_pid();
SQL

echo "==> Dropping and recreating ${PGDATABASE}"
dropdb --if-exists "$PGDATABASE"
createdb -O "$PGUSER" "$PGDATABASE"

# 2) Restore (no --clean: DB is empty). --no-owner so local roles own objects.
#    --if-exists is irrelevant without --clean; keep errors visible.
echo "==> pg_restore (this can take a few minutes)…"
set +e
pg_restore \
  --no-owner \
  --no-acl \
  --verbose \
  -h "$PGHOST" \
  -U "$PGUSER" \
  -d "$PGDATABASE" \
  -F tar \
  "$BACKUP" 2>&1 | tee /tmp/full_circle_pg_restore.log
RESTORE_RC=${PIPESTATUS[0]}
set -e

ERR_COUNT=$(grep -c 'pg_restore: error:' /tmp/full_circle_pg_restore.log || true)
echo "==> pg_restore exit=$RESTORE_RC  errors=$ERR_COUNT (log: /tmp/full_circle_pg_restore.log)"

# Soft errors only (missing roles/ACLs etc.) are ok; hard COPY failures are not.
if grep -q 'COPY failed' /tmp/full_circle_pg_restore.log; then
  echo "FATAL: COPY failed during restore — see log"
  exit 1
fi

# 3) Ensure query role can read (QueryRepo)
echo "==> Granting read access to full_circle_query (if role exists)"
psql -d "$PGDATABASE" -v ON_ERROR_STOP=0 <<'SQL'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'full_circle_query') THEN
    EXECUTE 'GRANT CONNECT ON DATABASE ' || current_database() || ' TO full_circle_query';
    GRANT USAGE ON SCHEMA public TO full_circle_query;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO full_circle_query;
    GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO full_circle_query;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO full_circle_query;
  END IF;
END$$;
SQL

# 4) Apply migrations newer than the dump (trading_*, egg_stock_*, …)
if [[ "$RUN_MIGRATE" == "1" ]]; then
  echo "==> mix ecto.migrate (bring schema up to current app)"
  mix ecto.migrate
else
  echo "==> Skipping migrate (--no-migrate)"
fi

# 5) Sanity checks
echo "==> Sanity counts"
psql -d "$PGDATABASE" -c "
SELECT 'companies' AS t, count(*) FROM companies
UNION ALL SELECT 'contacts', count(*) FROM contacts
UNION ALL SELECT 'goods', count(*) FROM goods
UNION ALL SELECT 'invoices', count(*) FROM invoices
UNION ALL SELECT 'schema_migrations', count(*) FROM schema_migrations
ORDER BY 1;
"

if [[ "$ERR_COUNT" -gt 0 ]]; then
  echo
  echo "NOTE: pg_restore reported $ERR_COUNT non-fatal error(s)."
  echo "Common benign ones: DROP … does not exist, role \"deployer\" does not exist."
  echo "Review: grep error: /tmp/full_circle_pg_restore.log"
fi

echo "Done."
