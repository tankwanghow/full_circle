# Accounting Period Lock — Design

**Date:** 2026-08-09
**Status:** Approved

## Problem

Nothing in Full Circle stops a user posting or editing a document dated into a prior
financial year. `closing_day` / `closing_month` on `companies` are used only to derive
financial-year boundaries for reporting (`accounting.ex:353`,
`reporting/profit_loss_forecast.ex`); they impose no restriction on writes. A clerk can
edit a two-year-old invoice today and silently change an audited P&L. With LHDN
e-invoicing, an amended historical document is a compliance problem, not merely a
reporting one.

The only close-like guard that exists is the pay-slip void deadline
(`pay_slip_op.ex:600`), which is specific to payroll.

## What already exists

A substantial part of the enforcement chain is built but idle:

- `transactions.closed` — a boolean column.
- `Accounting.assert_doc_editable/4` (`accounting.ex:30`) returns `{:error, :closed}`
  when any of a document's transactions is closed.
- All six document forms already render that error (invoice, pur_invoice, receipt,
  payment, credit_note, debit_note).
- `billing.ex:369` and `debcre.ex:684` classify the Postgres exception raised by the
  DB trigger into `{:error, :closed}`.
- A `BEFORE DELETE` trigger on `transactions` raises when a closed transaction is
  deleted (`priv/repo/migrations/20230421072511_create_transaction_trigger.exs`).

Two gaps in that existing machinery:

1. **Nothing ever sets `closed = true` except the seeder.** `seeding.ex:521` and `:571`
   flag opening-balance journals (`old_data => true`, `doc_type => "Journal"`). In
   production `closed` therefore means "seeded opening balance", not "in a closed
   period". The chain above never fires for ordinary documents.

2. **The `BEFORE UPDATE` trigger was never created.** Migration `20230421072511`
   defines a function named `cannot_update_or_delete_closed_transaction` whose message
   reads "Cannot update or delete a CLOSED transaction!", but only ever creates
   `BEFORE DELETE`. No `BEFORE UPDATE` trigger on `transactions` exists in that
   migration or any other. A direct UPDATE of a closed transaction succeeds silently.
   This is a latent bug independent of period locking, and is fixed as part of this work.

## Design decisions

| Decision | Choice |
|---|---|
| Mechanism | A cutoff date on the company, not a per-row flag sweep |
| Who sets it | An administrator, explicitly. Never derived, never advanced by a job |
| Scope | Core accounting documents + Journal. Payroll and trading deferred |
| Admin bypass | None. The cutoff is a hard block for every role |
| Non-GL edits | Still allowed where the code already allows them |

### Why a cutoff date rather than a flag sweep

A flag sweep (`UPDATE transactions SET closed = true WHERE doc_date <= ...`) would
engage the trigger and `assert_doc_editable` that already exist, but it cannot stop a
*new* backdated document from being created — the rows it would flag don't exist yet.
A cutoff date governs creation, amendment and deletion from one value, and reopening a
period is a single edit rather than an un-flagging pass.

The existing `closed` flag is left alone. It continues to mean "seeded opening balance".

## Part 1 — Storage and the administrator action

### Storage

`company.settings["period"]["closed_through"]` — an ISO 8601 date string, absent when
no period has been closed. No migration: the `settings` map already exists, and the
bank-reconciliation LLM configuration already uses this exact namespacing pattern
through `Sys.get_company_settings/2` and `Sys.update_company_settings/3`
(`sys.ex:262`, `sys.ex:267`).

### New functions in `FullCircle.Sys`

**`period_closed_through(company) :: Date.t() | nil`**

Reads `settings["period"]["closed_through"]` and parses it. Returns `nil` when unset or
unparseable — an unreadable setting must not lock the company out of its own books.

**`close_period_through(company, date, user)`**

The administrator action. `update_company_settings/3` as it stands neither authorizes
nor logs, so this is a wrapper rather than a direct call:

- Rejects unless `user_role_in_company(user.id, com.id) == "admin"`, returning
  `:not_authorise` to match the convention in the document contexts.
- Rejects a date in the future — a period that has not finished cannot be closed.
  "Future" is evaluated against today in the **company's** `timezone`, not the server's.
- Accepts `nil` to clear the cutoff entirely.
- Writes the setting and a `Sys.Log` row in one `Ecto.Multi`, action `"close_period"`,
  with a delta carrying the previous and new values so that reopening a period is as
  visible in the log as closing one.

Moving the date backwards to reopen a period is the same call, subject to the same
authorization and producing the same log entry.

### UI

A block on the company form (`live/company_live/form.ex`), rendered only when the
current user is an admin, positioned near the existing `closing_month` / `closing_day`
fields. It must carry a short explanatory note distinguishing it from those fields —
"closing day" already means something different in this form, and conflating the two
would be easy.

The block shows the current cutoff, a date input, and a confirmation step, since moving
the date forward locks work and moving it back unlocks it.

## Part 2 — Enforcement

### The rule

> A save is blocked when it would **write** GL rows dated on or before the cutoff, or
> **delete** GL rows dated on or before the cutoff.

Nothing else is blocked. In particular:

- **Which date governs:** the document's own posting date — the value that becomes
  `Transaction.doc_date`. A `due_date` or `load_date` falling inside a closed period is
  irrelevant and blocks nothing.
- **Matching against closed-period documents stays allowed.** A receipt dated today can
  still settle last year's invoice. That writes new `TransactionMatcher` rows without
  altering the old transactions, and blocking it would make prior-year receivables
  uncollectable.

### Placement

Every document context has the same shape: `create_X_multi` builds transactions, and
`update_X_multi` issues a `Multi.delete_all` over the document's transactions and then
rebuilds them. The guard is a `Multi.run` step placed immediately before those two
operations — the precise points at which GL rows are written or removed:

| Context | Functions |
|---|---|
| `billing.ex` | `create_invoice_multi/4`, `update_invoice_multi/5`, and the PurInvoice equivalents (via the shared `update_doc_multi/9`, `create_doc_transactions/5`) |
| `bill_pay.ex` | `create_payment_multi/4`, `update_payment_multi/5` |
| `receive_fund.ex` | the Receipt create path and `update_doc_multi/8` |
| `debcre.ex` | `create_credit_note_multi/4`, `update_credit_note_multi/5`, `create_debit_note_multi/4`, `update_debit_note_multi/5` |
| `cheque.ex` | `create_deposit_multi/4`, `update_deposit_multi/5`, `create_return_cheque_multi/4`, `update_return_cheque_multi/5` |
| `journal_entry.ex` | `create_journal_multi/4`, `update_journal_multi/5` |

`make_changeset/5` is deliberately **not** the hook. Whether a save touches the GL is
decided in the multi, not in the changeset, and a changeset-level validation would
reject non-GL edits that the code presently permits on purpose (see below).

On update the guard checks **both** dates — the date of the rows being deleted and the
date of the rows being written — so that neither moving a document out of a closed
period nor moving one into it is possible.

### New function

**`Accounting.assert_period_open(dates, company) :: :ok | {:error, :period_closed}`**

`dates` is a list of `Date.t() | nil` — the posting dates involved in the write. On
create that is the single new document date; on update it is the old and new dates.
`nil` entries are ignored.

Reads the cutoff via `Sys.period_closed_through/1` and returns `{:error, :period_closed}`
if any date falls on or before it. Returns `:ok` when no cutoff is set, and `:ok` for an
empty or all-`nil` list.

Posting date field per schema: `:invoice_date`, `:pur_invoice_date`, `:receipt_date`,
`:payment_date`, `:deposit_date`, `:return_date`, `:note_date` (CreditNote and
DebitNote), `:journal_date`.

### Deletes

Only **Receipt** and **Payment** can be deleted as documents. Invoice, PurInvoice,
CreditNote, DebitNote and Journal have no document-level delete — their forms expose
only line deletion (`delete_detail` / `delete_trans`), and emptying a document's lines is
an ordinary GL-affecting save that the guard above already blocks.

Receipt and Payment delete through `StdInterface.delete/6` directly from their forms
(`receipt_live/form.ex:513`, `payment_live/form.ex:509`), which does **not** pass through
either context's multi and is therefore not covered by the guard above.

Two thin context wrappers close this, keeping the rule in the context layer where
`assert_doc_editable/4` already lives:

- `ReceiveFund.delete_receipt(receipt, com, user)`
- `BillPay.delete_payment(payment, com, user)`

Each calls `assert_period_open/2` on the document's posting date, then delegates to
`StdInterface.delete/6`. The two forms call these instead of `StdInterface.delete/6`.

### Error surfacing

A `Multi.run` returning `{:error, :period_closed}` aborts the transaction and yields
`{:error, :assert_period_open, :period_closed, _changes}`. Each document context maps
that to `{:error, :period_closed}` at its public entry point, alongside the existing
`{:error, :closed}` and `{:error, :stale}` returns. The six forms gain a clause beside
their existing `{:error, :closed}` clause, flashing a message naming the cutoff date,
e.g. "Accounting period is closed on or before 2025-12-31."

Flash kind must be `:warn` — `:warning` renders nothing.

### Trigger fix

A migration adds the `BEFORE UPDATE` trigger on `transactions` that
`20230421072511`'s function name and error message already promise. The function itself
is unchanged and already handles the `OLD.closed = true` case; only the trigger is
missing. This protects the seeded opening balances that `closed` currently guards, and
is independent of the cutoff date.

## Known asymmetry

The `doc_transactions_unchanged?` fast path — which skips the transaction
delete-and-rebuild when no GL-affecting field changed — exists only in `billing.ex:283`
(Invoice, PurInvoice) and `debcre.ex:640` (CreditNote, DebitNote). Its comment states it
was added so users could edit non-GL fields "on closed-period docs without hitting the
BEFORE DELETE trigger".

Payment, Receipt, Deposit, ReturnCheque and Journal rewrite their transactions on every
save. Placing the guard before the rewrite therefore preserves non-GL editability only
on the four documents that have the fast path; on the other five, every save into a
closed period is blocked.

The practical gap is narrow, because those five have almost nothing non-GL to edit:

| Document | Non-GL persisted fields |
|---|---|
| Receipt | `descriptions` |
| Payment | `descriptions` |
| ReturnCheque | `return_reason` |
| Deposit | none |
| Journal | none |

The cost is that a typo in a receipt's description cannot be fixed after the period
closes. Closing this gap means extending the fingerprint fast path into four more
contexts — touching the save path of every money document — which is out of scope here
and recorded as a follow-up.

## Risks

**E-invoice write-back onto a closed-period Receipt.** Receipt carries `e_inv_uuid` and
`e_inv_internal_id`, written back by the LHDN flow, and has no fingerprint fast path. A
write-back onto a receipt dated inside a closed period would be blocked. Unlikely in
practice — submission happens long before a period is closed — but if it occurs the
symptom is an e-invoice status that will not update, and the remedy is to reopen the
period briefly. Worth watching after rollout.

**Existing data.** Setting a cutoff on a live company immediately locks historical
documents. The confirmation step in the UI is the mitigation; there is no migration or
backfill, and clearing the cutoff fully restores the previous behaviour.

## Testing

Context tests (`test/full_circle/`):

- `Sys.close_period_through/3` — admin succeeds; non-admin returns `:not_authorise`;
  a future date is rejected; `nil` clears the cutoff; a `Log` row is written on both
  close and reopen.
- `Sys.period_closed_through/1` — unset returns `nil`; a malformed stored value returns
  `nil` rather than raising.
- `Accounting.assert_period_open/2` — boundary behaviour: a document dated exactly on
  the cutoff is blocked; the day after is allowed; `:ok` when no cutoff is set.
- Per document type (all nine): creating into a closed period is rejected; creating
  after the cutoff succeeds; editing a GL field on a closed-period document is rejected;
  moving a document's date from an open period into a closed one is rejected, and the
  reverse likewise.
- Receipt and Payment only: deleting a closed-period document is rejected, and deleting
  one dated after the cutoff still succeeds.
- Invoice and CreditNote specifically: a description-only edit on a closed-period
  document still succeeds, confirming the fast path is preserved.
- Receipt and Payment specifically: a description-only edit is rejected, documenting the
  known asymmetry so a future change to it is a deliberate one.
- Matching a new receipt against a closed-period invoice succeeds.

Migration test: updating a transaction with `closed = true` raises after the new
trigger, and a transaction with `closed = false` updates normally.

LiveView test (`test/full_circle_web/live/`): the company form shows the cutoff control
to an admin and not to a clerk; a blocked save surfaces the flash naming the cutoff.

## Follow-ups (not in this work)

1. Extend the `doc_transactions_unchanged?` fingerprint to `bill_pay`, `receive_fund`,
   `cheque` and `journal_entry`, removing the asymmetry above.
2. Extend the cutoff to payroll (`PaySlip`, `SalaryNote`, `Advance`) and trading
   (`TradingSales`, `TradingSupply`, `TradingTrip`). Payroll needs a decision on how the
   cutoff interacts with the existing `void_deadline` (`pay_slip_op.ex:600`) when the
   two disagree.
