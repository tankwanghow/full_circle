---
name: xero-import
description: Use when working on the Xero → Full Circle import — anything under lib/full_circle/xero_import/* (apply, snapshot, reconcile, mapper, http_client, credentials, gapless), the mix task full_circle.import_xero (--auth/--snapshot/--dry-run/--apply/--reset/--reconcile), conversion balances, Xero OAuth/refresh tokens, snapshot fixtures, or the Golden Husbandry migration.
---

# Xero Import

One-time replay of a Xero organisation into a fresh FC company as live documents.
Code: `lib/full_circle/xero_import/*`, task `lib/mix/tasks/full_circle.import_xero.ex`.
Plan doc `docs/superpowers/plans/2026-08-18-xero-import-golden-husbandry.md` predates the
2026-08-19 review fixes — this file is the as-built truth where they differ.

## Pipeline

```
--auth → --snapshot (pull JSON dir) → --dry-run (plan, no DB) → --apply [--reset [--yes]] → --reconcile
```

Default snapshot dir `priv/xero_import/golden_husbandry`; creds `priv/xero_import/.credentials`
(dotenv, chmod 0600); user via `--user` or `FC_IMPORT_USER`. Optional `overrides.json` in the
snapshot dir: `{"control_accounts": {xero_name: fc_name}, "account_types": {...}, "disposal_account": ...}` —
honored by **both** apply and reconcile.

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
A Xero Payment without an `"Invoice"` key (credit-note refund, over/prepayment payment)
errors `{:missing_allocation_target, ...}` — unsupported by design; dry-run flags it first.

**Guards.** Non-reset apply refuses a company that has transactions, invoices, **contacts,
or goods** (`:company_not_empty`). `--reset` prompts `Mix.shell().yes?` unless `--yes`.
Caveat: `Sys.delete_company` currently FK-crashes on `transaction_matchers_transaction_id_fkey`
for a company with matched documents, so `--reset` of a completed import needs that fixed first.

**Reconcile is independent of import arithmetic** — expected sides come from Xero itself:
TB report (parsed header-aware, **YTD Debit/YTD Credit** columns, cells positional — never
filter blank cells), contact `Balances.*.Outstanding` for aged, invoice `Total` for doc totals,
asset `BookValue` for NBV. Live aged = contact-grouped sum of control-account transactions
(matchers are aging metadata, NOT balance — do not add them when comparing to Xero contact
Outstanding; unallocated credit notes net in). Tolerance is strictly `< 0.01` — an exact
1-cent drift FAILS, locked by test.

**HTTP.** Xero refresh tokens are single-use: a mid-pull 401 refresh persists the rotated
token to the creds file immediately and keeps it in the client agent (state
`%{token, credentials}`). Contacts are pulled with `includeArchived=true` — archived contacts
still own historical invoices. 429 honors Retry-After, else 2/4/8s backoff, 5 attempts.
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
88 tests in `test/full_circle/xero_import/` as of 2026-08-19.
