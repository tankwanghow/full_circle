# Accounting Period Lock — Design

**Date:** 2026-08-09
**Revised:** 2026-08-13 (review: session-stale cutoff, UPDATE trigger `RETURN NEW`, map `:period_closed` at the public API, drop Receipt/Payment delete, drop false e-invoice write-back risk; later the same day: `Multi.update` is style not a txn fix; place the form clause above any generic `{:error, _}`)
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
- Invoice, PurInvoice, Receipt, Payment, CreditNote and DebitNote forms already render
  that error. Journal, Deposit and ReturnCheque do not — they have no `{:error, :closed}`
  clause.
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

   The function cannot be reused unchanged. It `RETURN OLD` on the success path, which
   is correct for `BEFORE DELETE` and **wrong for `BEFORE UPDATE`**: PostgreSQL writes
   the old row and reports success, so bank-rec `update_all` of `match_group_id` /
   `reconciled` and Journal `cast_assoc` updates would silently no-op. The function
   must `RETURN NEW` on UPDATE and keep `RETURN OLD` on DELETE.

## Design decisions

| Decision | Choice |
|---|---|
| Mechanism | A cutoff date on the company, not a per-row flag sweep |
| Who sets it | An administrator, explicitly. Never derived, never advanced by a job |
| Scope | Core accounting documents + Journal. Payroll, trading, FA depreciation deferred |
| Admin bypass | None. The cutoff is a hard block for every role |
| Non-GL edits | Still allowed where the code already allows them |
| Document delete | None. Receipt/Payment must not be deletable, same as Invoice/Journal/notes |

### Why a cutoff date rather than a flag sweep

A flag sweep (`UPDATE transactions SET closed = true WHERE doc_date <= ...`) would
engage the trigger and `assert_doc_editable` that already exist, but it cannot stop a
*new* backdated document from being created — the rows it would flag don't exist yet.
A cutoff date governs creation and amendment from one value, and reopening a
period is a single edit rather than an un-flagging pass.

The existing `closed` flag is left alone. It continues to mean "seeded opening balance".

### Receipt and Payment are not deletable documents

Invoice, PurInvoice, CreditNote, DebitNote, Journal, Deposit and ReturnCheque have no
document-level delete. Receipt and Payment have leftover `handle_event("delete")`
clauses that call `StdInterface.delete/6`, but they are not a feature:

- Neither form renders a delete control.
- There is no `:delete_receipt` / `:delete_payment` clause in `authorization.ex`, so
  the handler would `FunctionClauseError` if invoked.
- Neither LiveView handles `{:deleted, _}`.
- There are no delete tests.
- `transactions.doc_id` is not an FK to the header, so a successful header delete
  would orphan GL rows or hit `transaction_matchers` `ON DELETE RESTRICT`.

The right correction for a wrong receipt is another document (or an edit while the
period is still open), not a hole in the gapless number sequence.

This work does **not** add delete wrappers. It does **not** rip the dead handlers out
either — that cleanup is a follow-up. Period lock only guards create and update.

## Part 1 — Storage and the administrator action

### Storage

`company.settings["period"]["closed_through"]` — an ISO 8601 date string, absent when
no period has been closed. No migration: the `settings` map already exists, and the
bank-reconciliation LLM configuration already uses this exact namespacing pattern
through `Sys.get_company_settings/2` and `Sys.update_company_settings/3`
(`sys.ex:262`, `sys.ex:267`).

### New functions in `FullCircle.Sys`

**`period_closed_through(company) :: Date.t() | nil`**

Re-reads `companies.settings` from the database by `company.id`, then parses
`settings["period"]["closed_through"]`. Returns `nil` when unset or unparseable —
an unreadable setting must not lock the company out of its own books.

It must **not** trust `company.settings` on the struct it was passed. `current_company`
is the Company stuffed into the session (`FullCircleWeb.ActiveCompany`) and is only
reloaded when the user switches company or posts `update_active_company`. Reading the
in-memory map would leave every open session unlocked after an admin sets the cutoff.

**`close_period_through(company, date, user)`**

The administrator action. `update_company_settings/3` as it stands neither authorizes
nor logs, so this is a wrapper rather than a direct call:

- Rejects unless `user_role_in_company(user.id, com.id) == "admin"`, returning
  `:not_authorise` to match the convention in the document contexts.
- Rejects a date in the future — a period that has not finished cannot be closed.
  "Future" is evaluated against today in the **company's** `timezone`, not the server's.
  Today in that timezone is allowed (the day can be closed once it has begun).
- Accepts `nil` to clear the cutoff entirely.
- Writes the setting and a `Sys.Log` row in one `Ecto.Multi`, action `"close_period"`,
  with a delta carrying the previous and new values so that reopening a period is as
  visible in the log as closing one. Prefer `Multi.update` on a settings changeset —
  it is the clearer Multi shape. `Repo.update` inside `Multi.run` is transactionally
  sound too (Ecto joins the same process's transaction); this is style, not a
  correctness fix.

Moving the date backwards to reopen a period is the same call, subject to the same
authorization and producing the same log entry.

### UI

A **sibling** block on the company edit page (`live/company_live/form.ex`), rendered
only when `@current_role == "admin"` (same gate as the LLM settings). Do **not** nest
a second `<.form>` inside `#company` — that is invalid HTML. The LLM settings are
fields *inside* the company form; the period lock is its own form **after** `#company`
closes, because it saves through a dedicated event and must not ride the company
POST.

Place it visually near `closing_month` / `closing_day` (immediately below the company
form is fine). It must carry a short explanatory note distinguishing it from those
fields — "closing day" already means something different, and conflating the two
would be easy.

The company edit route is `/edit_company/:id`, not `/companies/:id/edit`.

The block shows the current cutoff, a date input, and a confirmation step, since moving
the date forward locks work and moving it back unlocks it.

## Part 2 — Enforcement

### The rule

> A save is blocked when it would **write** GL rows dated on or before the cutoff, or
> **delete-and-rebuild** GL rows dated on or before the cutoff.

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
rebuilds them (Journal is the exception: `cast_assoc` with `on_replace: :delete`). The
guard is a `Multi.run` step placed immediately before those two operations — the
precise points at which GL rows are written or removed:

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

### New functions

**`Accounting.assert_period_open(dates, company) :: :ok | {:error, :period_closed}`**

`dates` is a list of `Date.t() | nil` — the posting dates involved in the write. On
create that is the single new document date; on update it is the old and new dates.
`nil` entries are ignored.

Reads the cutoff via `Sys.period_closed_through/1` (which re-reads the DB) and returns
`{:error, :period_closed}` if any date falls on or before it. Returns `:ok` when no
cutoff is set, and `:ok` for an empty or all-`nil` list.

Posting date field per schema: `:invoice_date`, `:pur_invoice_date`, `:receipt_date`,
`:payment_date`, `:deposit_date`, `:return_date`, `:note_date` (CreditNote and
DebitNote), `:journal_date`.

**`Accounting.multi_assert_period_open(multi, dates_fun, company)`**

Adds an `:assert_period_open` step. `dates_fun` receives the multi's changes so far.

**`Accounting.map_period_closed(result)`**

Each public `create_*` / `update_*` pipes `Repo.transaction()` through this:

```elixir
{:error, :assert_period_open, :period_closed, _} -> {:error, :period_closed}
other -> other
```

Do **not** leak the Multi 4-tuple to LiveViews. Every document form already matches
`{:error, failed_operation, changeset, _}` first and calls `to_form(changeset)` /
`changeset.errors`. A 4-tuple with `:period_closed` as the "changeset" crashes the
LiveView. Mapping to the same 2-tuple shape as `:closed` and `:stale` avoids that.

### Error surfacing

The nine document forms (Invoice, PurInvoice, Receipt, Payment, CreditNote, DebitNote,
Journal, Deposit, ReturnCheque) each gain:

```elixir
{:error, :period_closed} ->
  put_flash(:warn, gettext("Accounting period is closed on or before %{date}.",
    date: to_string(FullCircle.Sys.period_closed_through(socket.assigns.current_company))))
```

The existing `{:error, :closed}` flash talks about the seed flag ("this document is in
a closed accounting period"). The new flash **must name the cutoff date** so the two
mechanisms are distinguishable.

Journal, Deposit and ReturnCheque have no `{:error, :closed}` clause today — add the
new clause anyway. Place `{:error, :period_closed}` **above** any looser
`{:error, _}` (or `{:error, _, _, _}`) match in the same `case`. Mapping to a 2-tuple
already avoids the 4-tuple `to_form` crash; a generic `{:error, _}` would still
swallow it if it came first. On the invoice save path today the looser clauses live
in other handlers, not that `case` — still place the new clause first so an
implementer does not invent the footgun.

Flash kind must be `:warn` — `:warning` renders nothing.

### Trigger fix

A migration replaces `cannot_update_or_delete_closed_transaction` so that:

- `TG_OP = 'UPDATE'` and `OLD.closed = true` → `RAISE` the existing message
- `TG_OP = 'UPDATE'` and `OLD.closed = false` → `RETURN NEW`
- `TG_OP = 'DELETE'` keeps today's behaviour (`RAISE` if closed, else `RETURN OLD`)

and adds the missing `BEFORE UPDATE` trigger. Tests must assert that an open
transaction's updated column actually changed — `{1, _}` from `update_all` is not
enough, because the old `RETURN OLD` path would still report one row.

Matching or reconciling a `closed = true` opening-balance line in bank rec will start
raising. That is the trigger doing its job. Check after migrate whether any live recon
depends on touching those rows; do not weaken the trigger if one does — report it.

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

**Session-stale cutoff.** Mitigated by `period_closed_through/1` always re-reading
`companies.settings` from the DB. Do not regress this to a struct-field read.

**Bank rec vs `closed = true` opening balances.** After the UPDATE trigger, reconciling
a seeded opening-balance transaction raises. Opening balances are rarely bank-rec
lines; if one is, the remedy is to leave it unmatched or clear `closed` on that seed
row, not to `RETURN OLD`.

**Existing data.** Setting a cutoff on a live company immediately locks historical
documents. The confirmation step in the UI is the mitigation; there is no migration or
backfill, and clearing the cutoff fully restores the previous behaviour.

E-invoice write-back (`e_inv_metas.ex`) uses `update_all` on `e_inv_uuid` /
`e_inv_internal_id` of the document header. It does **not** go through
`update_receipt` / `update_invoice` and is not blocked by this lock.

## Testing

Context tests (`test/full_circle/`):

- `Sys.close_period_through/3` — admin succeeds; non-admin returns `:not_authorise`;
  a future date (company timezone today + 1, not `Date.utc_today() + 1`) is rejected;
  `nil` clears the cutoff; a `Log` row is written on both close and reopen.
- `Sys.period_closed_through/1` — unset returns `nil`; a malformed stored value returns
  `nil` rather than raising; a company struct whose in-memory `settings` lack the
  cutoff still reads it after another process wrote it (proves the DB reload).
- `Accounting.assert_period_open/2` — boundary behaviour: a document dated exactly on
  the cutoff is blocked; the day after is allowed; `:ok` when no cutoff is set.
- Per document type (all nine): creating into a closed period is rejected as
  `{:error, :period_closed}` (not the Multi 4-tuple); creating after the cutoff
  succeeds.
- Invoice (fast-path representative): editing a GL field on a closed-period document
  is rejected; a description-only edit still succeeds; moving a date from open into
  closed is rejected.
- CreditNote (fast-path representative): a description-only edit still succeeds.
- Receipt (no-fast-path representative): a description-only edit is rejected,
  documenting the known asymmetry. Rebuild the full attrs map (details, funds,
  cheques, matchers) — a descriptions-only map fails the changeset first.
- Matching a new receipt (dated after the cutoff) against a closed-period invoice
  succeeds. Build the matcher from the invoice's contact-bearing `Transaction` row;
  `receive_fund_test.exs` only has empty `"transaction_matchers" => %{}`.

No document-delete tests. There is no delete to guard.

Migration test: updating a transaction with `closed = true` raises after the new
trigger; a transaction with `closed = false` updates and the changed column is
visible on reload.

LiveView test (`test/full_circle_web/live/`):

- Company edit at `~p"/edit_company/#{company.id}"` shows the cutoff control to an
  admin and not to a clerk. `Sys.allow_user_to_access/4` (admin last).
- A blocked Invoice save surfaces the flash naming the cutoff.

`invoice_to_attrs/1` must include `"lock_version"`.

## Follow-ups (not in this work)

1. Extend the `doc_transactions_unchanged?` fingerprint to `bill_pay`, `receive_fund`,
   `cheque` and `journal_entry`, removing the asymmetry above.
2. Extend the cutoff to payroll (`PaySlip`, `SalaryNote`, `Advance`) and trading
   (`TradingSales`, `TradingSupply`, `TradingTrip`). Payroll needs a decision on how the
   cutoff interacts with the existing `void_deadline` (`pay_slip_op.ex:600`) when the
   two disagree. `hr.ex` (SalaryNote, Advance) and `accounting.ex` (fixed-asset
   depreciation) already write `transactions` and will remain writable into a "closed"
   year until this lands.
3. Remove the dead Receipt/Payment `handle_event("delete")` clauses. They are not
   reachable from the UI and are not authorized.
