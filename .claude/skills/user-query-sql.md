---
name: user-query-sql
description: Use when writing or editing saved Queries Listing SQL, the Generate SQL helper, fct_* query functions, fill_company_name, or a user-facing report that should be a saved query instead of a new LiveView. Covers the fct_ tenancy contract and where the generator schema card lives.
---

# User Query SQL

Saved queries are raw `SELECT`s run on `QueryRepo` (read-only). Tenancy is
`fct_<table>(company_id)`, injected by `UserQueries.fill_company_name/2`.

The Generate SQL button drafts into the textarea. It does not execute or save.

## Files

| File | Role |
|------|------|
| `priv/user_queries/schema_card.md` | **Joins, dates, virtual amounts.** Loaded into the generator prompt. Edit this when tables or FKs change. |
| `lib/full_circle/user_queries/sql_generator.ex` | Prompt + extract/validate. |
| `lib/full_circle/user_queries.ex` | `execute/3`, `fill_company_name/2`. |
| `priv/repo/migrations/20240527082203_create_queries.exs` | Original `fct_*`. |
| `priv/repo/migrations/20260817120000_add_missing_fct_query_functions.exs` | Later tables. |

Do not duplicate the join graph in this skill. The card is the source of truth.

## fct_ contract

- Write `FROM fct_invoices i` with spaces around the name. The injector is a regex;
  `fct_invoices(` or a name jammed against punctuation is **not** rewritten.
- Do **not** pass the company uuid in the SQL. The app does that.
- Header `fct_*` filter `company_id`. Detail `fct_*` return **all companies** —
  always join through the header.
- Never `FROM invoices`. Validate in `SqlGenerator.validate_sql/2` rejects raw tables
  after generation; hand-written SQL is not similarly blocked.

New domain table that queries will need: add `fct_<table>(uuid)` in a migration
(same `SECURITY DEFINER` pattern), then add its joins to the schema card.

## Generator

- Anyone who can edit a query sees Generate when company LLM settings are set.
- Draft only. User Executes, then Saves.
- Hidden from the catalog/prompt: `fct_users`, `fct_logs`, `fct_company_user`,
  `fct_gapless_doc_ids`.
- Prompt includes **stored columns** from `pg_attribute` on each `fct_*` SETOF
  type (`SqlGenerator.column_catalog/0`). Virtual fields never appear.
- After the first draft, `EXPLAIN` the injected SQL (`dry_run/2`). On a
  Postgres error, send the message back to the model **once** and keep the
  repaired SQL.

## Common mistakes

| Symptom | Cause |
|---------|--------|
| 0 rows on "trade debtors" | Invented `a.name = 'Trade Debtors'`. Use contacts + `SUM(amount)`, or the real name `Account Receivables` |
| Query returns other companies' detail rows | Used `fct_invoice_details` (etc.) without joining the header |
| `fct_invoices` not rewritten, Postgres wants a relation | Missing spaces around the name, or already wrote `fct_invoices('…')` |
| `column invoice_amount does not exist` | Header totals are virtual; use `fct_transactions.amount` or `quantity * unit_price` |
| Wrong period | Filtered `inserted_at` instead of `invoice_date` / `doc_date` |
