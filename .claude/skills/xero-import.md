---
name: xero-import
description: Use when working on the Xero → Full Circle import — anything under lib/full_circle/xero_import/* (apply, snapshot, reconcile, mapper, http_client, credentials, gapless), the mix task full_circle.import_xero (--auth/--snapshot/--dry-run/--apply/--reset/--reconcile), conversion balances, Xero OAuth/refresh tokens, snapshot fixtures, or the Golden Husbandry migration.
---

# Xero Import

**OAuth gotchas (2026):** Xero's WAF 403s any redirect_uri containing a literal
`127.0.0.1` — use `http://localhost:4099/callback` (registered in the Xero app too).
Apps created on/after 2026-03-02 accept **granular scopes only** (broad
`accounting.transactions[.read]` / `accounting.reports.read` → `invalid_scope`);
`Credentials.scopes/0` holds the granular set (settings/contacts/invoices/payments/
banktransactions/manualjournals/reports.trialbalance `.read` + `assets.read`,
`offline_access` added for the web flow).

One-time replay of a Xero organisation into a fresh FC company as live documents.
Code: `lib/full_circle/xero_import/*`, task `lib/mix/tasks/full_circle.import_xero.ex`.
Plan doc `docs/superpowers/plans/2026-08-18-xero-import-golden-husbandry.md` predates the
2026-08-19 review fixes — this file is the as-built truth where they differ.

## Pipeline

```
--auth → --snapshot (pull JSON dir) → --dry-run (plan, no DB) → --apply [--reset [--yes]] → --reconcile
```

Default snapshot dir `priv/xero_import/golden_husbandry`; creds `priv/xero_import/.credentials`
(dotenv, chmod 0600); user via `--user` or `FC_IMPORT_USER`. Optional `overrides.json`:
`{"control_accounts": {xero_name: fc_name}, "account_types": {...}, "disposal_account": ...}` —
honored by **both** apply and reconcile. Put it at `priv/xero_import/overrides.json` (the
fallback path, committed): a copy inside the snapshot dir is DELETED by every `--snapshot`
pull (atomic dir swap). GH ships `"Retained Earnings" -> "Retained Profits"` to match KPST
naming; the retained-earnings name is resolved through this override everywhere (account
seed, closings, catch-up exclusion, conversion rebalance, reconcile bucketing).

| Module | Role |
|--------|------|
| `Snapshot` | read/pull JSON files (atomic `.tmp`→dest swap); `fill_reports` fallbacks |
| `Mapper` | pure Xero→FC attr mapping (account types, tax codes, contacts, assets) |
| `Apply` | `plan/2` (dry-run ops+errors, no DB) and `run/3` (the real import) |
| `Reconcile` | `run/4` — 7 checks, Xero-report expected vs live FC queries |
| `HttpClient` / `Credentials` | Req client w/ 429 retry + 401 refresh; OAuth dotenv |
| `Gapless` | after import, bump `gapless_doc_ids.current` past `PREFIX-\d+` numbers |

## Non-obvious contracts

**Atomicity.** `Apply.run` wraps *everything* (company create/reset included) in one
`Repo.transaction(timeout: :infinity)`. Any `{:error, _}` rolls back the whole import —
no half-imported company, no stranded gapless counters. Errors are therefore safe to be loud.

**Conversion balances are debit-positive** (AR +, AP −, from Xero `/Setup`).
`conversion_invoice?/2` = number starts `CONV-` **or** date ≤ conversion date (Xero setup
enters open invoices with original pre-conversion dates). Those invoices are imported as
live documents AND their totals are stripped from the AR/AP conversion line — AR strips via
`Decimal.sub`, AP via `Decimal.add` (toward zero from its own side). Get the sign wrong and
AP triples.

**Line pricing** (`Apply.line_pricing/3`) reproduces Xero's tax-exclusive LineAmount under
FC's `qty * unit_price + discount` formula:
- Xero discounts → FC `discount` (validated ≤ 0) on invoice/bill details;
- note details have **no** discount field and `unit_price ≥ 0`, so discount folds into unit_price;
- qty ≤ 0 (returns/corrections) → qty 1 with signed unit_price = the line amount
  (FC validates `quantity > 0`; invoice detail unit_price may be negative, note detail may not);
- `LineAmountTypes == "Inclusive"` divides by `(1 + tax_rate)` first;
- missing LineAmount is implied from qty×UnitAmount minus DiscountAmount/DiscountRate.

**Matchers.** Xero payments/allocations become `transaction_matchers` on the FC control
transaction found by doc_no + doc_type + hardcoded FC control names
("Account Receivables"/"Account Payables" — FC posting uses these regardless of overrides).
`signed_match_amount/2`: matcher sign is the negation of the header txn's sign.
A payment against an over/prepayment invoice is a cash refund (AP side → Receipt crediting
AP; AR side → Payment debiting AR); a payment with no `"Invoice"` key at all still errors.

**Real-data quirks (all from the live GH run, each locked by a test):**
- Dates: payments/manual journals carry ONLY .NET `/Date(ms)/` — `parse_date` handles it.
- Bills may have blank or **duplicate** numbers → fallback Reference → InvoiceID, then
  ` (2)` dedupe suffixes; payments always number by PaymentID (References collide en masse).
- Zero-total invoices: all-zero lines are skipped; self-cancelling cross-account lines
  (POS float moves) become a Journal.
- Negative-total SPEND/RECEIVE bank txns flip direction with negated lines (funds > 0).
- Blank `Reference` strings must go through `presence/1` — `"" || fallback` keeps `""`.
- Chart may lack a disposal account → `ensure_disposal_account` seeds "Gain on Disposal".
- GET `/Setup` 404s (write-only endpoint) → empty conversion balances, not an error.

**Rounding.** Xero's document `Total` is authoritative; FC recomputes from lines, so
`align_doc_total` appends an explicit "Xero rounding" line when they differ (≤ 1.00,
else `{:error, {:doc_total_mismatch, ...}}`). This keeps AR/AP per document exact.

**Multi-year catch-up.** Xero posts payroll/depreciation via system journals the API
can't expose (accounting.journals.read is not grantable to new apps). Coverage:
- `Snapshot.pull` fetches a TrialBalance per financial year end into
  `reports["trial_balance_by_year"]` (+ current date as final period).
- `Apply.post_catchup_journals` posts one `XCATCHUP-<date>` journal per period:
  balance-sheet accounts as cumulative diffs, P&L accounts as per-year YTD diffs
  (Retained Earnings excluded both sides); residual > 0.02 → `{:error, {:catchup_unbalanced, ...}}`.
- `Apply.post_aged_attribution` then posts zero-sum `XCATCHUP-AGED` moving contact-less
  AR/AP catch-up onto the contacts named by Xero aged balances (journal lines carry contact_id).
- `Apply.post_closing_journals` finally posts `XCLOSE-<fye>` per **completed** FY in the
  **KPST convention**: exactly two lines — the year's net through a P&L-typed contra
  "Net Profit for The Year" (Revenue) against "Retained Earnings" (Equity). NEVER reverse
  individual P&L accounts: the contra being P&L-typed makes prior years self-cancel in
  aggregate (TB balances at any date) while every account keeps its history, so the P&L
  report for a closed year shows full detail plus the Net Profit line netting to zero
  (identical to KPST's manual JS closings, e.g. JS-000275).
- Retained Earnings is excluded from catch-up deltas (Xero's TB RE row is computed, FC's
  is posted); any residual in a catch-up journal IS the RE difference and balances to RE.
- Conversion seeding re-balances the stripped AR/AP against RE (`balance_conversion_seed`)
  because the imported conversion documents re-post P&L that Xero kept inside RE.
- Fixed-asset `DepreciationHistory` rows dated after the conversion date post
  `XDEP-<assetid>-<n>` journals (depre expense / accum. depre); rows on/before it are
  already inside the conversion balances — seed rows only, no GL.
- Xero's Assets API exposes no per-period history: `HttpClient.synthesize_history` emits
  ONE cumulative lump dated at the depreciation start date. At apply time
  `Mapper.expand_depreciation_history/3` expands that lump into per-period rows
  (asset's `depre_interval`, closing-day-anchored dates, Decimal-exact — last row absorbs
  the remainder so seed sums match Xero BookValue for reconcile). Only the synthesized
  shape (single row dated at start/purchase date) expands; hand-dated or multi-row
  histories pass through. Without expansion, `Accounting.depreciation_dates` would resume
  the schedule right after the lump's start date and double-depreciate.
- Straight-line assets entered by life in Xero have a nil `DepreciationRate`; the mapper
  derives rate = 1/`EffectiveLifeYears` (`Mapper.straight_line_rate`). Assets that still
  end up with rate 0 are guarded in `Accounting.depreciation_dates` (no schedule, no loop).

**Guards.** Non-reset apply refuses a company that has transactions, invoices, **contacts,
or goods** (`:company_not_empty`). `--reset` prompts `Mix.shell().yes?` unless `--yes`.
Company deletion: cascade order = FK creation order, which is parent-before-child for all
company_id tables, and the closed-transaction trigger's escape hatch (companies row already
gone) admits the cascade. Only **grandchild** tables (no company_id: matchers, the six
document detail tables, employee_salary_types, trading trip junctions) get pre-deleted in
`delete_non_cascadeable_records()` (migration `20260820090000`). Never pre-delete
company_id-scoped tables there — direct deletes run while the company row still exists and
trip the closed-transaction guard.

**Reconcile is independent of import arithmetic** — expected sides come from Xero itself:
TB report (parsed header-aware, **YTD Debit/YTD Credit** columns, cells positional — never
filter blank cells; names carry " (Code)" suffixes, stripped via `Mapper.strip_code_suffix`),
contact `Balances.*.Outstanding` for aged, invoice `Total` for doc totals (zero-total docs
excluded on both sides), asset `BookValue` for NBV (live groups ` (n)` dupes under the base
name). TB check: balance-sheet accounts per-account; P&L + Retained Earnings only in
aggregate (Xero TB is current-FY YTD, FC holds full history). Live aged = contact-grouped
sum of control-account transactions (matchers are aging metadata, NOT balance; unallocated
credit notes net in). Tolerance is strictly `< 0.01` — an exact 1-cent drift FAILS.

**HTTP.** Xero refresh tokens are single-use: a mid-pull 401 refresh persists the rotated
token to the creds file immediately and keeps it in the client agent (state
`%{token, credentials}`). Contacts are pulled with `includeArchived=true` — archived contacts
still own historical invoices. 429 honors Retry-After, else 2/4/8s backoff, 5 attempts —
but a Retry-After above 120s is Xero's DAILY tenant limit: the client returns
`{:error, {:rate_limited, seconds}}` instead of sleeping for hours, and the mix task
prints the wait time (`describe_error`).
Aged reports are NOT pulled (`AgedReceivablesByContact` 400s without contactID);
`Snapshot.fill_reports` builds them from contact Outstanding instead.

**Masters idempotence quirks.** Accounts reuse an existing FC account by remapped or raw
name; contacts/fixed-assets get ` (2)` name suffixes on collision; sales-only items default
the missing purchase side (and vice versa) — `Seeding.fill_changeset("Goods", ...)`
`Map.fetch!`s all four names. Assets missing any of the four `*_ac_name`s return
`{:error, {:unmapped_asset_account, name, field}}`. Every good gets a default packaging
(`__xero_line__` is the catch-all good for item-less lines).

## Testing

Fixture snapshot: `test/support/fixtures/xero_import/snapshot/*.json`
(`XeroImport.fixture_dir()`); tests mutate the loaded `snap` map per scenario and run
`Apply.run(snap, user, company_name: unique_name)`. HTTP tests stub with
`Req.Test` (`plug: {Req.Test, stub}`); `Snapshot.pull` tests use a `FakeClient` behaviour.
Mix-task tests use `Mix.Task.rerun` (+ `Mix.Shell.Process` for the `--reset` prompt).
123 tests in `test/full_circle/xero_import/` as of 2026-08-21.

## Status

2026-08-20: full live rehearsal on the real Golden Husbandry organisation (3,414
invoices / 6,999 payments / 3,554 bank txns / 1,154 transfers / 43 assets, 2019–2026)
applies in ~44s and **reconciles clean on all seven checks**. Live data and credentials
live in `priv/xero_import/` (nested .gitignore keeps them out of git).
