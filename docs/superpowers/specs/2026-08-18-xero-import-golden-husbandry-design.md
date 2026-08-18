# Xero → Full Circle Import (Golden Husbandry) — Design

**Date:** 2026-08-18
**Scope:** One-time conversion of the Xero organisation for **Golden Husbandry Sdn. Bhd.**
into a fresh Full Circle company. Full authorised history becomes live Full Circle
documents. No LiveView, no multi-tenant wizard.

## Problem

Golden Husbandry’s books live in Xero. Full Circle has no Xero connector. The existing
`/seeds` CSV path can load masters, opening balances, and historical `old_data`
transactions, but it does **not** create printable, matchable invoices, bills, receipts,
or payments. The operator wants those as real documents, with Xero numbers kept, plus a
fixed-asset register that can keep depreciating after go-live.

## Decisions

| Topic | Choice |
|---|---|
| Target company | `Golden Husbandry Sdn. Bhd.` |
| Company state | Fresh unused books (create, or `--reset` and recreate) |
| Shape | Mix task + `FullCircle.XeroImport` context |
| Source | Xero API snapshot on disk, then apply offline |
| History | Entire authorised Xero history as live documents |
| Seeded GL | Xero **conversion balances** only |
| Document numbers | Keep Xero numbers; bump gapless counters after apply |
| Fixed assets | Register + past charges; abort if any diminishing-value |
| Dates | Import runs as a Full Circle **admin**; `admin_changeset` already skips the ±60-day window. Period stays unlocked until reconcile passes |
| Out of scope | Attachments, tracking categories, payroll, **bank reconciliation** (statement lines, Xero ticks, and setting `transactions.reconciled` on imported bank lines), repeating-invoice templates, multi-currency, a reusable in-app wizard |

Bank rec starts in Full Circle **after go-live**. The import brings the cash book (receipts, payments, spend/receive, transfers) and checks bank **balances** in reconcile. It does not import Xero statement lines or mark historical bank `transactions` as reconciled. The first Full Circle recon should use a period starting at the snapshot date so old book lines are not treated as the current statement.

Do **not** also seed current-year (or any post-conversion) GL as `old_data` transactions.
Live documents post the GL. Double-posting is a hard fail in reconcile.

## Existing pieces reused

- `Sys.create_company/2` — company, default accounts, `NoSTax` / `NoPTax`, gapless counters.
  Default account names **Account Receivables**, **Account Payables**, **Sales Tax Payable**,
  **Purchase Tax Receivable** are load-bearing in Billing, ReceiveFund, BillPay, DebCre.
- `Billing.make_changeset/5` (and ReceiveFund / BillPay / DebCre / Journal equivalents) —
  admin role → `admin_changeset` (no date window).
- Document create Multis (`create_invoice_multi`, etc.) — period guard + GL `insert_all`.
  Import wrappers copy these but **do not** call `get_gapless_doc_id/5`; they pass the
  Xero number through.
- `FullCircle.Seeding` — conversion `Balances` and `FixedAssetDepreciations` with
  `is_seed: true` (no second GL from depreciation rows).
- Period lock (`Sys.period_closed_through/1`) — must be unset during apply.

Normal `create_invoice/3` always mints `INV-000001` via `Helpers.get_gapless_doc_id/5`.
That is why import needs wrappers; admin date access is already solved.

## Architecture

```
Xero API  →  snapshot (JSON on disk)  →  transform/map  →  Full Circle contexts  →  reconcile
```

No dashboard entry. Operator commands:

```bash
mix full_circle.import_xero --auth          # web-app OAuth only; writes gitignored tokens
mix full_circle.import_xero --snapshot
mix full_circle.import_xero --dry-run
mix full_circle.import_xero --apply
mix full_circle.import_xero --apply --reset
mix full_circle.import_xero --reconcile
```

| Module | Role |
|---|---|
| `Mix.Tasks.FullCircle.ImportXero` | CLI flags, logging to `priv/xero_import/golden_husbandry/last_run.log` |
| `FullCircle.XeroImport.Client` | HTTP to Xero. Behaviour so tests inject a fixture. Credentials from `priv/xero_import/.credentials` (gitignored), never from the repo |
| `FullCircle.XeroImport.Snapshot` | Pulls every needed endpoint with pagination; writes `priv/xero_import/golden_husbandry/`. Replaces the folder only when the pull **finishes** |
| `FullCircle.XeroImport.Mapper` | Xero → Full Circle types. Hard-coded tables plus optional `priv/xero_import/overrides.json` |
| `FullCircle.XeroImport.Apply` | Create/reset company; run phases; write `xero_id → full_circle_id` map next to the snapshot |
| Import create functions | Same Multi/GL as production create, supplied doc number |
| `FullCircle.XeroImport.Reconcile` | Compare snapshot-date Xero reports to Full Circle |

Snapshot path and credentials are gitignored. Test fixtures live under
`test/support/fixtures/xero_import/` and are committed.

## Authorization (operator)

Secrets stay on the operator’s machine. Do not paste Client Secret or tokens into chat.

**Preferred:** Xero **Custom Connection** (client credentials: Client ID + Client Secret,
one organisation). Create at [developer.xero.com](https://developer.xero.com/) → My Apps
→ New app → Custom connection, if the portal offers it. Authorise Golden Husbandry via
the email Xero sends. Custom Connections are a paid add-on and are documented for
AU/NZ/UK/US; Malaysia may not offer them.

**Fallback:** Web app + authorization code. Redirect URL `http://127.0.0.1:4099/callback`.
`mix full_circle.import_xero --auth` opens the browser, stores access + refresh tokens
beside the client credentials.

Read-only scopes:

- `accounting.transactions.read`
- `accounting.contacts.read`
- `accounting.settings.read`
- `accounting.reports.read`
- `assets.read`
- `offline_access` (web app only)

Do **not** request `accounting.journals.read`. We do not import Xero’s posted system
journals (that would double-count). Manual journals come from the Manual Journals
endpoint under `accounting.transactions.read`.

Credentials file (`priv/xero_import/.credentials`):

```
XERO_CLIENT_ID=...
XERO_CLIENT_SECRET=...
XERO_TENANT_ID=          # optional; resolve by organisation name if blank
```

After cutover, revoke the Xero app.

The Mix task also needs a Full Circle user (`--user email`, default from
`FC_IMPORT_USER`). That user becomes admin on the new company and is the log actor.

## Mapping

### Chart of accounts

Keep Xero account names. Map `Type` → Full Circle `account_type`:

| Xero | Full Circle |
|---|---|
| `BANK` | `Bank` |
| `CURRENT` | `Current Asset` |
| `FIXED` | `Fixed Asset` |
| `INVENTORY` | `Inventory` |
| `PREPAYMENT` | `Prepayment` |
| `NONCURRENT` | `Non-current Asset` |
| `CURRLIAB` | `Current Liability` |
| `LIABILITY` | `Liability` |
| `TERMLIAB` | `Non-current Liability` |
| `EQUITY` | `Equity` |
| `REVENUE` / `SALES` | `Revenue` |
| `OTHERINCOME` | `Other Income` |
| `DIRECTCOSTS` | `Direct Costs` |
| `EXPENSE` | `Expenses` |
| `OVERHEADS` | `Overhead` |
| `DEPRECIATN` | `Depreciation` |

Unknown type without an override is a hard error.

Xero control / tax accounts **map onto** the default Full Circle names; they are not
created as a second AR/AP/tax pair. Overrides file can name the Xero account that
means “Account Receivables” if it is not already that string.

### Tax codes

Each Xero tax rate becomes one or two Full Circle codes (`rate` as a fraction, e.g.
`0.06`). `CanApplyToRevenue` → `Sales` (account **Sales Tax Payable**).
`CanApplyToExpenses` → `Purchase` (account **Purchase Tax Receivable**). A rate that
applies to both is imported twice with a stable suffix (`-S` / `-P`) if the raw code
would collide. Keep `NoSTax` / `NoPTax`. Zero-rated Xero rates map to those defaults
when the code/rate pair matches.

### Contacts

One contact per Xero contact. `Name` unique in the company (suffix ` (2)` etc. if
needed). Customer/supplier flags → `category`. Address, email, phone, tax/reg numbers
when present. Blank country → `Malaysia` (required by changeset).

### Goods

Xero items → goods (`name`, `unit`, sales/purchase accounts and tax codes). Invoice
lines with no item post to an account only; no dummy good.

### Fixed assets

| Xero | Full Circle |
|---|---|
| Asset name (+ number if name not unique) | `name` |
| Purchase date / cost | `pur_date` / `pur_price` |
| Depreciation start | `depre_start_date` |
| Residual | `residual_value` |
| Straight line | `Straight-Line` |
| None / full at purchase already written off | `No Depreciation` |
| Averaging / type interval | `Monthly` or `Yearly` |
| Book rate | `depre_rate` as a fraction (`20%` → `0.2`) |
| Type’s four accounts | cost / accum dep / expense / disposal |
| Past depreciation lines | `FixedAssetDepreciations`, `is_seed: true` |

Any other depreciation method **aborts** the run (dry-run and apply).

Historical FA depreciation that Xero already posted as journals is imported as
**journals** (GL truth). Seeded FA charges do not post. After go-live, Full Circle
generate-depreciation continues from the last seeded charge date.

### Documents

| Xero | Full Circle |
|---|---|
| ACCREC invoice | `Invoice` |
| ACCPAY bill | `PurInvoice` |
| ACCREC credit note | `CreditNote` |
| ACCPAY credit note | `DebitNote` |
| Payment on ACCREC | `Receipt` |
| Payment on ACCPAY | `Payment` |
| Bank spend / receive (no invoice) | `Payment` / `Receipt` with account lines, no matchers |
| Overpayment / prepayment | `Receipt` / `Payment` with account lines (unallocated remainder stays on the contact) |
| Manual journal | `Journal` |
| Bank transfer | `Journal` between the two bank accounts |

`InvoiceNumber` / Xero reference is the Full Circle doc number (`invoice_no`,
`pur_invoice_no`, `receipt_no`, …).

Import statuses **AUTHORISED** and **PAID** only. **DRAFT**, **VOIDED**, **DELETED**,
and repeating-invoice templates are skipped. Tracking categories on lines are dropped.

If any imported document’s currency is not the Xero base currency (expected `MYR`),
**abort**.

`e_inv_uuid` is copied only when a clear field exists on the Xero payload. Do not invent one.

Company `closing_month` / `closing_day` and timezone come from the Xero organisation
(`FinancialYearEndMonth` / `FinancialYearEndDay`, `Asia/Kuala_Lumpur` if unset).

## Apply order

Replay Xero. There is no “opening TB at current FY start.”

1. **Create company** named exactly `Golden Husbandry Sdn. Bhd.` (country Malaysia).
   Abort if that company already has invoices or `transactions` unless `--reset`.
   `--reset` deletes that company (cascade) and recreates it. That wipes **all** data
   for the company. Allowed because this company is unused; do not `--reset` after
   ops data exists.
2. **Masters** — accounts (merge onto defaults), tax codes, contacts, goods, fixed-asset
   register + seeded past charges.
3. **Conversion balances** — Xero Setup conversion trial balance as `Seeding` `Balances`
   (`old_data`, `closed`, particulars `Balance B/F …`). If Xero also created conversion
   invoices for opening debtors/creditors, those invoices are live documents in step 4
   and their amounts are **removed from the conversion AR/AP seed** so they are not
   posted twice. A lump-sum conversion AR/AP with no invoices stays seeded.
4. **Live documents, dependency order**
   1. Invoices and bills, oldest first
   2. Credit notes and debit notes
   3. Receipts and payments, with allocations
   4. Manual journals
   5. Bank spend / receive / transfers
5. **Allocations** — Xero payment (and credit-note allocation) invoice IDs become
   `transaction_matchers` for the same amounts. Lookup via the run-local
   `xero_id → full_circle_id` map. If the target was skipped (draft/void), **abort**
   on that payment; no silent unallocated cash.
6. **Gapless counters** — parse each imported number as `PREFIX-DIGITS` (e.g. `INV-000123`).
   Full Circle prefixes are `INV` (Invoice), `PINV` (PurInvoice), `RC` (Receipt),
   `PV` (Payment), `CN` (CreditNote), `DN` (DebitNote), `JS` (Journal). If the prefix
   matches that doc type, set `gapless_doc_ids.current` to the max integer seen
   (`INV-000123` → at least `123`). Numbers that do not match (`SI-88`, `BILL-10`)
   are stored as-is and do not move the counter. After import, new invoices continue
   from `INV-` + (max+1) only when at least one imported invoice used the `INV-` shape;
   otherwise the counter stays at `0` and the next mint is `INV-000001` (safe: Xero
   numbers that were not `INV-*` cannot collide).
7. **Reconcile** (see below). Apply is not done until checks pass.

`--apply` on a partial failure leaves the company as-is. Fix mapper/overrides, then
`--apply --reset` and replay from step 1. No merge.

`--dry-run` builds every changeset from the snapshot **without writing**, prints counts
and problems, exit `1` if apply would abort.

## Errors

**Hard (abort dry-run and apply)**

- Company has invoices/transactions and `--reset` was not passed
- Fixed asset method not straight-line or none
- Account type or tax rate unmapped and no override
- Name collision that cannot be uniqued
- Payment/credit-note allocation target missing
- Invalid document changeset
- Conversion seed lines do not balance
- Non-base-currency document
- Xero API 401 after retry; 429 still failing after backoff
- Snapshot pull incomplete (do not replace the previous good snapshot)

**Soft skip:** draft, voided, deleted, repeating templates.

401/429: retry with backoff. Snapshot folder is replaced only when the pull finishes.

## Reconcile

Compares Xero reports **as at snapshot time** to Full Circle. Tolerance ±0.01 per line.

| Check | Pass |
|---|---|
| Trial balance per account (by mapped name) | Same amount |
| Aged AR / AP by contact | Same outstanding |
| Authorised+paid invoice/bill count and totals | Same |
| FA net book value per asset | Same |
| Bank account balances | Same |

Mismatches print both sides and the difference. `--reconcile` is read-only.

## Testing

No live Xero in CI. Fixture snapshot under `test/support/fixtures/xero_import/`
(small JSON: a few accounts, two contacts, one item, one straight-line asset, conversion
TB, two invoices, one bill, a receipt that allocates, a journal). `Client` is a
behaviour; tests inject the fixture. Apply uses a **fixture company name**, not
Golden Husbandry.

**Mapper**

- Account types match the table above
- Unknown type without override fails
- Tax `6%` → `0.06`; dual-apply rate becomes two codes
- Blank contact country → `Malaysia`
- Diminishing-value asset fails
- Straight-line asset + seeded charges do not post GL

**Apply**

- Default AR/AP/tax accounts are reused, not duplicated
- Conversion AR is reduced when a conversion invoice is also imported
- Invoice keeps Xero `InvoiceNumber`; GL posts via the invoice Multi
- Receipt matchers settle that invoice
- Draft/voided rows skipped
- Payment whose invoice is missing aborts
- `--apply` without `--reset` aborts if the company already has invoices
- `--reset` wipes and replays to the same TB
- Gapless `current` sits above `123` when `INV-000123` was imported; `SI-88` does not
  move the Invoice counter

**Reconcile**

- Matching fixture → pass
- One account off by 0.01 → fail with both sides printed

**Not in CI:** OAuth, Xero pagination, the real Golden Husbandry file. Those are the
operator `--snapshot` / `--dry-run` / `--apply` / `--reconcile` on this machine.

## Implementation notes (for the plan)

- Add `priv/xero_import/.gitignore` ignoring `.credentials`, `golden_husbandry/`, `last_run.log`.
- HTTP client: `Req` (already used by e-invoice and the bank-recon LLM client).
- Import create functions live next to the production create functions (e.g.
  `Billing.import_invoice/4`) rather than a parallel posting engine.
- Period lock must remain unset on the new company until the operator closes the period
  after a passing reconcile.
- After go-live, revoke the Xero app and stop `--apply --reset`.

## Success

`--reconcile` passes against the Golden Husbandry snapshot. The operator can open an
imported invoice by its Xero number, see allocations on receipts, generate the next
depreciation on an imported asset, and the next new invoice number does not collide
with imported `INV-` numbers.
