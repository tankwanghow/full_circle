-- Move Kim Poh Sitt Tat Feedmill Sdn Bhd to proper double entry.
--
-- Background: the books used the SQL-Account-style periodic-inventory
-- convention — each Jan 1 a deliberately ONE-SIDED journal debited the
-- "Opening Stock - *" COGS accounts, with no credit to Inventory, because
-- FullCircle's balance sheet used to expire prior-year Inventory by date
-- slicing. This script adds the missing Cr "Purchases - Closing Stock"
-- line to each of those journals and fixes three small unbalanced warts,
-- so every date nets to zero and cash flow / TB / BS tie exactly.
--
-- MUST be deployed together with the code change that removes the
-- Inventory special-slicing from FullCircle.Reporting.balance_sheet_query
-- (they are two halves of the same convention change).
--
-- The 2026-01-01 opening-stock journal is NOT posted here — post it through
-- the FullCircle journal form (it is an open period):
--   Dr Opening Stock - Pigs      3,045,730.00
--   Dr Opening Stock - Feeds     1,285,489.10
--   Dr Opening Stock - Chicken     642,527.73
--   Dr Opening Stock - Medicine    133,177.00
--   Dr Opening Stock - Eggs        103,975.50
--   Cr Purchases - Closing Stock 5,210,899.33
--
-- Usage (idempotent — safe to re-run; aborts and rolls back on any
-- failed verification):
--   dev : PGPASSWORD=... psql -h localhost -U full_circle -d full_circle_dev  -f scripts/fix_kpst_double_entry.sql
--   prod: take a backup first, then run the same against the prod database.

\set ON_ERROR_STOP on

BEGIN;

-- The rows of legacy journals are flagged closed; the period-lock trigger
-- blocks UPDATE on them, so stand it down inside this transaction only.
ALTER TABLE transactions DISABLE TRIGGER update_closed_transaction_trigger;

-- 1. The ten missing opening-stock credits -------------------------------
-- One Cr "Purchases - Closing Stock" per Jan-1 journal, equal to the
-- prior-year closing stock that journal expensed. Doc metadata (doc_type,
-- doc_id, flags) is copied from an existing line of the same journal.
WITH com AS (
  SELECT id FROM companies WHERE name = 'Kim Poh Sitt Tat Feedmill Sdn Bhd'
),
inv_acc AS (
  SELECT a.id FROM accounts a, com
  WHERE a.company_id = com.id
    AND a.name = 'Purchases - Closing Stock'
    AND a.account_type = 'Inventory'
),
fixes(doc_date, doc_no, credit) AS (
  VALUES
    ('2016-01-01'::date, '416',       3785481.35),
    ('2017-01-01'::date, '506',       2101669.18),
    ('2018-01-01'::date, '569',       3200357.53),
    ('2019-01-01'::date, '636',       2835271.24),
    ('2020-01-01'::date, '705',       2440458.37),
    ('2021-01-01'::date, '764',       3259273.98),
    ('2022-01-01'::date, '843',       3442597.16),
    ('2023-01-01'::date, 'JS-000043', 2795511.95),
    ('2024-01-01'::date, 'JS-000146', 4726187.47),
    ('2025-01-01'::date, 'JS-000277', 4564328.40)
),
templates AS (
  SELECT DISTINCT ON (t.doc_date, t.doc_no)
         t.doc_date, t.doc_no, t.doc_type, t.doc_id, t.company_id,
         t.closed, t.old_data
  FROM transactions t
  JOIN com ON com.id = t.company_id
  JOIN fixes f ON f.doc_date = t.doc_date AND f.doc_no = t.doc_no
)
INSERT INTO transactions
  (id, doc_type, doc_date, particulars, contact_particulars, amount,
   doc_no, doc_id, reconciled, closed, old_data, account_id, company_id,
   inserted_at)
SELECT gen_random_uuid(),
       tpl.doc_type,
       f.doc_date,
       'Opening stock ' || extract(year FROM f.doc_date)::int ||
         ' transferred out of inventory (double-entry correction)',
       NULL,
       -f.credit,
       f.doc_no,
       tpl.doc_id,
       false,
       tpl.closed,
       tpl.old_data,
       inv_acc.id,
       tpl.company_id,
       now()
FROM fixes f
JOIN templates tpl ON tpl.doc_date = f.doc_date AND tpl.doc_no = f.doc_no
CROSS JOIN inv_acc
WHERE NOT EXISTS (
  SELECT 1 FROM transactions x
  WHERE x.company_id = tpl.company_id
    AND x.doc_no = f.doc_no
    AND x.doc_date = f.doc_date
    AND x.account_id = inv_acc.id
    AND x.amount < 0
);

-- 2. Journal 764 (2021-01-01) was RM0.50 short of the actual 2020 closing
-- stock (3,259,273.48 vs 3,259,273.98). Add the missing 50 sen of opening
-- stock so the journal balances against the full credit posted above.
WITH com AS (
  SELECT id FROM companies WHERE name = 'Kim Poh Sitt Tat Feedmill Sdn Bhd'
),
pigs_acc AS (
  SELECT a.id FROM accounts a, com
  WHERE a.company_id = com.id AND a.name = 'Opening Stock - Pigs'
),
tpl AS (
  SELECT DISTINCT ON (t.doc_no)
         t.doc_type, t.doc_id, t.company_id, t.closed, t.old_data
  FROM transactions t
  JOIN com ON com.id = t.company_id
  WHERE t.doc_no = '764' AND t.doc_date = '2021-01-01'
)
INSERT INTO transactions
  (id, doc_type, doc_date, particulars, contact_particulars, amount,
   doc_no, doc_id, reconciled, closed, old_data, account_id, company_id,
   inserted_at)
SELECT gen_random_uuid(), tpl.doc_type, '2021-01-01',
       'Opening stock 2021 understated by 0.50 (double-entry correction)',
       NULL, 0.50, '764', tpl.doc_id, false, tpl.closed, tpl.old_data,
       pigs_acc.id, tpl.company_id, now()
FROM tpl CROSS JOIN pigs_acc
WHERE NOT EXISTS (
  SELECT 1 FROM transactions x
  WHERE x.company_id = tpl.company_id
    AND x.doc_no = '764'
    AND x.doc_date = '2021-01-01'
    AND x.account_id = pigs_acc.id
    AND x.amount = 0.50
);

-- 3. Doc 850 (2022-12-31): bad-debt write-off with a zero expense line
-- against Cr Account Receivables 300. The 2022 year-end closing already
-- assumed this expense (hence the -300 P&L residue), so completing the
-- debit line leaves Retained Profits untouched.
UPDATE transactions t
SET amount = 300
FROM companies c, accounts a
WHERE c.name = 'Kim Poh Sitt Tat Feedmill Sdn Bhd'
  AND t.company_id = c.id
  AND a.id = t.account_id
  AND a.name = 'Bad Debts Written Off'
  AND t.doc_no = '850'
  AND t.doc_date = '2022-12-31'
  AND t.amount = 0;

-- 4. JS-000270 (2024-12-31): biological-assets journal off by one sen.
-- The doc's P&L lines already net to what the year-end closing assumed
-- (2024 P&L residue is zero), so the sen sits on the balance-sheet side.
UPDATE transactions t
SET amount = -4964170.83
FROM companies c, accounts a
WHERE c.name = 'Kim Poh Sitt Tat Feedmill Sdn Bhd'
  AND t.company_id = c.id
  AND a.id = t.account_id
  AND a.name = 'Biological asset Current'
  AND t.doc_no = 'JS-000270'
  AND t.doc_date = '2024-12-31'
  AND t.amount = -4964170.84;

ALTER TABLE transactions ENABLE TRIGGER update_closed_transaction_trigger;

-- Verification — any failure raises and rolls the whole thing back. ------
DO $$
DECLARE
  com_id uuid;
  bad_dates int;
  inv_balance numeric;
  pl_residue numeric;
BEGIN
  SELECT id INTO STRICT com_id
  FROM companies WHERE name = 'Kim Poh Sitt Tat Feedmill Sdn Bhd';

  -- every posting date must net to zero
  SELECT count(*) INTO bad_dates FROM (
    SELECT t.doc_date
    FROM transactions t
    WHERE t.company_id = com_id
    GROUP BY t.doc_date
    HAVING abs(sum(t.amount)) > 0.001
  ) x;
  IF bad_dates > 0 THEN
    RAISE EXCEPTION 'verification failed: % posting date(s) still unbalanced', bad_dates;
  END IF;

  -- inventory must hold exactly the 2025 closing stock
  SELECT coalesce(sum(t.amount), 0) INTO inv_balance
  FROM transactions t
  JOIN accounts a ON a.id = t.account_id
  WHERE t.company_id = com_id AND a.account_type = 'Inventory';
  IF inv_balance <> 5210899.33 THEN
    RAISE EXCEPTION 'verification failed: inventory balance % <> 5210899.33', inv_balance;
  END IF;

  -- closed years 2015-2024 must have zero P&L residue
  SELECT coalesce(sum(t.amount), 0) INTO pl_residue
  FROM transactions t
  JOIN accounts a ON a.id = t.account_id
  WHERE t.company_id = com_id
    AND t.doc_date <= '2024-12-31'
    AND a.account_type IN ('Depreciation','Direct Costs','Expenses','Overhead',
                           'Other Income','Revenue','Cost Of Goods Sold');
  IF abs(pl_residue) > 0.001 THEN
    RAISE EXCEPTION 'verification failed: closed-years P&L residue %', pl_residue;
  END IF;

  RAISE NOTICE 'verified: all dates balanced, inventory = %, closed-years P&L residue = 0', inv_balance;
END $$;

-- Cash-flow tie-out per calendar year: flow (flipped non-cash movements)
-- must equal delta (cash movement). Shown for the record.
WITH com AS (
  SELECT id FROM companies WHERE name = 'Kim Poh Sitt Tat Feedmill Sdn Bhd'
)
SELECT extract(year FROM t.doc_date)::int AS yr,
       round(-sum(t.amount) FILTER (WHERE a.account_type NOT IN ('Cash or Equivalent','Bank')), 2) AS flow,
       round(sum(t.amount) FILTER (WHERE a.account_type IN ('Cash or Equivalent','Bank')), 2) AS delta
FROM transactions t
JOIN accounts a ON a.id = t.account_id
JOIN com ON com.id = t.company_id
GROUP BY 1 ORDER BY 1;

COMMIT;
