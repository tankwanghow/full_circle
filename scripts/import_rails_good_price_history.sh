#!/usr/bin/env bash
# Import historical goods sales/purchase unit prices from full_circle_rails
# (legacy Rails dump) into full_circle_dev.good_price_histories.
#
# Sources:
#   sale     ← invoice_details + cash_sale_details
#   purchase ← pur_invoice_details
#
# Mapping: lower(trim(product.name1)) → goods.name for the target company,
# with a small manual alias map for known renames/typos.
#
# Usage:
#   ./scripts/import_rails_good_price_history.sh
#   COMPANY_ID=... SOURCE_DB=full_circle_rails TARGET_DB=full_circle_dev ./scripts/import_rails_good_price_history.sh
#   ./scripts/import_rails_good_price_history.sh --replace   # delete existing rails-sourced rows first
#
# Env (defaults match config/dev.exs):
#   PGHOST=localhost  PGUSER=full_circle  PGPASSWORD=nyhlisted
#   SOURCE_DB=full_circle_rails  TARGET_DB=full_circle_dev
#   COMPANY_ID=<Kim Poh Sitt Tat uuid>

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PGHOST="${PGHOST:-localhost}"
export PGUSER="${PGUSER:-full_circle}"
export PGPASSWORD="${PGPASSWORD:-nyhlisted}"
SOURCE_DB="${SOURCE_DB:-full_circle_rails}"
TARGET_DB="${TARGET_DB:-full_circle_dev}"
COMPANY_ID="${COMPANY_ID:-a2edcb0f-e9fb-4a8d-888b-61cd334210ba}"

REPLACE=0
for arg in "$@"; do
  case "$arg" in
    --replace) REPLACE=1 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
  esac
done

WORKDIR="${TMPDIR:-/tmp}/fc_price_history_$$"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Source: ${SOURCE_DB}  Target: ${TARGET_DB}  Company: ${COMPANY_ID}"

# Ensure table exists
if ! psql -d "$TARGET_DB" -At -c "SELECT to_regclass('public.good_price_histories')" | grep -q good_price_histories; then
  echo "ERROR: good_price_histories does not exist. Run: mix ecto.migrate"
  exit 1
fi

# Confirm company
COM_NAME=$(psql -d "$TARGET_DB" -At -c "SELECT name FROM companies WHERE id = '${COMPANY_ID}'" || true)
if [[ -z "$COM_NAME" ]]; then
  echo "ERROR: company ${COMPANY_ID} not found in ${TARGET_DB}"
  exit 1
fi
echo "==> Company: ${COM_NAME}"

if [[ "$REPLACE" == "1" ]]; then
  echo "==> Deleting existing rows for company (all sources)…"
  psql -d "$TARGET_DB" -v ON_ERROR_STOP=1 -c \
    "DELETE FROM good_price_histories WHERE company_id = '${COMPANY_ID}';"
fi

echo "==> Exporting price lines from ${SOURCE_DB}…"
psql -d "$SOURCE_DB" -v ON_ERROR_STOP=1 -c "
COPY (
  SELECT
    'sale'::text AS side,
    i.doc_date,
    d.unit_price,
    d.quantity,
    COALESCE(d.discount, 0) AS discount,
    p.unit,
    p.name1 AS good_name,
    'invoice'::text AS source,
    i.id::bigint AS source_doc_id,
    d.id::bigint AS source_line_id,
    lower(trim(p.name1)) AS name_key
  FROM invoice_details d
  JOIN invoices i ON i.id = d.invoice_id
  JOIN products p ON p.id = d.product_id
  WHERE d.unit_price > 0
    AND d.quantity <> 0
    AND i.doc_date IS NOT NULL

  UNION ALL

  SELECT
    'sale',
    cs.doc_date,
    d.unit_price,
    d.quantity,
    COALESCE(d.discount, 0),
    p.unit,
    p.name1,
    'cash_sale',
    cs.id::bigint,
    d.id::bigint,
    lower(trim(p.name1))
  FROM cash_sale_details d
  JOIN cash_sales cs ON cs.id = d.cash_sale_id
  JOIN products p ON p.id = d.product_id
  WHERE d.unit_price > 0
    AND d.quantity <> 0
    AND cs.doc_date IS NOT NULL

  UNION ALL

  SELECT
    'purchase',
    pi.doc_date,
    d.unit_price,
    d.quantity,
    COALESCE(d.discount, 0),
    p.unit,
    p.name1,
    'pur_invoice',
    pi.id::bigint,
    d.id::bigint,
    lower(trim(p.name1))
  FROM pur_invoice_details d
  JOIN pur_invoices pi ON pi.id = d.pur_invoice_id
  JOIN products p ON p.id = d.product_id
  WHERE d.unit_price > 0
    AND d.quantity <> 0
    AND pi.doc_date IS NOT NULL
) TO STDOUT WITH (FORMAT csv, HEADER false)
" > "$WORKDIR/lines.csv"

LINE_COUNT=$(wc -l < "$WORKDIR/lines.csv")
echo "==> Exported ${LINE_COUNT} price lines"

echo "==> Staging + mapping into ${TARGET_DB}…"
psql -d "$TARGET_DB" -v ON_ERROR_STOP=1 <<SQL
BEGIN;

CREATE TEMP TABLE price_import (
  side text NOT NULL,
  doc_date date NOT NULL,
  unit_price numeric NOT NULL,
  quantity numeric NOT NULL,
  discount numeric NOT NULL,
  unit text,
  good_name text,
  source text NOT NULL,
  source_doc_id bigint,
  source_line_id bigint,
  name_key text NOT NULL
);

\\copy price_import FROM '${WORKDIR}/lines.csv' WITH (FORMAT csv)

-- Known renames / typos (Rails name_key → Elixir goods name_key)
CREATE TEMP TABLE name_aliases (
  from_key text PRIMARY KEY,
  to_key text NOT NULL
);
INSERT INTO name_aliases (from_key, to_key) VALUES
  ('ivomecting', 'ivermectin');

CREATE TEMP TABLE mapped AS
SELECT
  pi.*,
  g.id AS good_id,
  COALESCE(a.to_key, pi.name_key) AS resolved_key
FROM price_import pi
LEFT JOIN name_aliases a ON a.from_key = pi.name_key
JOIN goods g
  ON g.company_id = '${COMPANY_ID}'::uuid
 AND lower(trim(g.name)) = COALESCE(a.to_key, pi.name_key);

CREATE TEMP TABLE unmapped AS
SELECT DISTINCT pi.name_key, pi.good_name, count(*) AS lines
FROM price_import pi
LEFT JOIN name_aliases a ON a.from_key = pi.name_key
LEFT JOIN goods g
  ON g.company_id = '${COMPANY_ID}'::uuid
 AND lower(trim(g.name)) = COALESCE(a.to_key, pi.name_key)
WHERE g.id IS NULL
GROUP BY 1, 2
ORDER BY lines DESC;

\\echo Unmapped product names (skipped):
SELECT * FROM unmapped;

INSERT INTO good_price_histories (
  id, company_id, good_id, side, doc_date, unit_price, quantity, discount,
  unit, good_name, source, source_doc_id, source_line_id,
  inserted_at, updated_at
)
SELECT
  gen_random_uuid(),
  '${COMPANY_ID}'::uuid,
  m.good_id,
  m.side,
  m.doc_date,
  m.unit_price,
  m.quantity,
  m.discount,
  m.unit,
  m.good_name,
  m.source,
  m.source_doc_id,
  m.source_line_id,
  now(),
  now()
FROM mapped m
ON CONFLICT (company_id, source, source_line_id)
  WHERE source_line_id IS NOT NULL
  DO NOTHING;

COMMIT;

\\echo Import summary:
SELECT side, source, count(*) AS rows,
       min(doc_date) AS first_date, max(doc_date) AS last_date
FROM good_price_histories
WHERE company_id = '${COMPANY_ID}'::uuid
GROUP BY 1, 2
ORDER BY 1, 2;

SELECT count(*) AS total_rows,
       count(DISTINCT good_id) AS goods_with_history
FROM good_price_histories
WHERE company_id = '${COMPANY_ID}'::uuid;
SQL

echo "Done."
