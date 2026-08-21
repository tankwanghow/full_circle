---
name: periodic-inventory-double-entry
description: Use when touching journals, inventory accounts, the balance sheet / trial balance / cash flow queries, or KPST year-end stock entries — the books are strict double entry as of 2026-08-21 and several reports depend on every posting date netting to zero.
---

# Periodic inventory & strict double entry

**As of 2026-08-21 the ledger is strict double entry.** Every journal must
balance (`Journal.compute_balance/1` rejects `journal_balance != 0`), and the
reporting layer depends on it:

- `Reporting.cash_flow/3` (Financial Statements → Cash Flow) computes each
  non-cash account's flipped movement; rows sum to the cash movement ONLY
  because every posting date nets to zero.
- `Reporting.balance_sheet_query` carries **full transaction history for
  Inventory** — the old special-case that sliced Inventory to the current
  fiscal year (`doc_date > prev_close_date`) was removed together with the
  data correction below. Do not reintroduce it.

## Year-end stock convention (periodic inventory)

- Dec 31: `Dr Purchases - Closing Stock (Inventory) / Cr Closing Stock - * (COGS)`
- Jan 1: `Dr Opening Stock - * (COGS) / Cr Purchases - Closing Stock (Inventory)`
  — the credit line is REQUIRED. Historically it was omitted (SQL-Account
  convention) and the balance sheet compensated by slicing; that era is over.
- Mid-year the Inventory balance is legitimately zero (stock sits in P&L as
  opening stock until the next year-end count).

## The KPST history correction

`scripts/fix_kpst_double_entry.sql` (idempotent, self-verifying, rolls back on
any failed invariant) added the ten missing Jan-1 inventory credits
(2016–2025), fixed doc 850's zero bad-debt line, journal 764's RM0.50
understatement, and JS-000270's one-sen imbalance. Run against dev DONE
2026-08-21; **must be run on prod in the same release as the code change**
(they are two halves of one convention switch). After running, post the
2026-01-01 opening journal through the UI — exact lines are in the script
header.

## Gotchas

- The `update_closed_transaction_trigger` blocks UPDATEs on `closed=t` rows;
  data migrations must `ALTER TABLE transactions DISABLE TRIGGER` inside
  their transaction (the script shows the pattern).
- `journals` is header-only; journal lines ARE `transactions` rows
  (`doc_type='Journal'`, `doc_id` → journals.id), so SQL line amendments keep
  the UI view consistent.
- FC's TB only sums to zero when prior years are closed into equity
  (XCLOSE / manual closing journals). An unclosed prior year shows as a TB
  residual — that is the accountant's year-end task, not a bug.
- The Xero import already posts only balanced journals (manual journals,
  XCATCHUP, XCLOSE) — no import change was needed for this convention.
