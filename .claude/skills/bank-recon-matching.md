---
name: bank-recon-matching
description: Use when working on Bank Reconciliation matching — statement lines vs book transactions, match groups, carry-forward of unmatched items, the "Create Payment / Create Receipt from statement line" flow, and the "Settle Invoices / Settle Bills" panel that creates a matcher-only RC/PV settling outstanding Invoices/PurInvoices in one shot. Covers the recon prefill payload contract, matcher sign conventions, the auto-match amount guards, and why Book Entry / Dismiss are wrong for supplier and customer payments.
---

# Bank Recon Matching & Doc Creation from Statement Lines

For statement *import/parsing* see `bank-recon-llm-parser.md`. This skill is the
matching side: `lib/full_circle/bank_reconciliation.ex` +
`lib/full_circle_web/live/bank_reconciliation_live/index.ex`.

## Matching model

- A match is a shared `match_group_id` (UUID) on N `BankStatementLine` rows and
  M bank-account `Transaction` rows; matched transactions get `reconciled: true`.
  No amount-equality constraint is enforced by `confirm_group_match/2` itself.
- Unmatched statement lines and unreconciled book transactions **carry forward**
  into every later period (`list_statement_lines` / `list_book_transactions`
  union prior items back to `effective_from_date` = earliest reconciled txn date).
- `dismiss_statement_lines/1` = match group with **no book side** (prior-period
  cheques already reconciled elsewhere). `delete_statement_lines` unreconciles
  the transactions in affected groups.

## Summary "Difference" semantics (timing, not error)

`reconciliation_summary/4` sums only movements *dated inside the queried
window* on each side, so the Difference row = (stmt − book) movements — a
movement comparison, **not** a balance check. A book txn dated in an earlier
month that clears the bank inside the window makes it non-zero on a *perfect*
recon (opening diff and movement diff cancel; closing diff = 0). The health
signal is `recon_complete?/1` in `index.ex`: unmatched counts zero AND
stmt/book closing balances equal (fallback: difference = 0 when no statement
balances were uploaded). Explained diffs render green with a "(timing)" label;
`#recon-difference` is the testable cell. A dismissed line is stored exactly
like a stranded one (stmt-only match group) — data alone can't tell them
apart.

## The missing-document scenario

A PurInvoice/Invoice never touches the bank account — only a Payment (BillPay)
or Receipt (ReceiveFund) does. Online banking paid but no doc issued ⇒ the
statement line has no book counterpart and haunts every recon until fixed.

**Wrong fixes:** Book Entry (journal bank↔contra) fixes GL but creates no
`TransactionMatcher`, so the supplier/customer aging still shows the invoice
open. Dismiss hides the line while books overstate cash + the contact balance.

**Right fix — buttons on the recon screen:** select unmatched lines (all one
sign, no txns selected) → **Create Payment** (all negative) / **Create
Receipt** (all positive). Multi-select sums into one document.

## The `recon` prefill payload contract

Button navigates to `/companies/:id/Payment/new?recon=<json>` (or Receipt).
JSON fields (built in `create_doc_from_stmt` handler; parsed by
`FullCircleWeb.Helpers.recon_link_from_params/2`):

| Field | Meaning |
|---|---|
| `stmt_ids` | selected statement line ids |
| `date` | **latest** statement date → doc date |
| `amount` | abs(total) → `funds_amount` |
| `stmt_total` | **signed** total — the auto-match guard compares this |
| `bank_account_id` / `bank_account_name` | recon bank account → funds account |
| `descriptions` | uniq-joined line descriptions |
| `return` | `{name, f_date, t_date}` to rebuild the recon URL |

Forms have a `mount_new(socket, %{"recon" => ...})` clause (before the
catch-all — clause order matters) and keep `recon_link` in assigns.

## Auto-match on save (the guard)

After `create_payment`/`create_receipt` succeeds,
`FullCircleWeb.Helpers.match_recon_after_save/3` finds the doc's transaction on
the recon bank account (`find_doc_transaction/3`) and matches **only if
`txn.amount == stmt_total` exactly** — a clerk-edited amount or switched funds
account must never silently create a false reconcile. On mismatch the doc is
kept, the user returns to recon with a `:warn` flash (never `:warning` — it
renders nothing) and matches manually.

## Settle Invoices / Settle Bills (matcher-only RC/PV in one shot)

When the money movement *settles known invoices*, the recon screen can skip the
form entirely: **Settle Invoices** (positive lines → Receipt) / **Settle
Bills** (negative lines → Payment) opens an inline panel (`settle_mode`,
`#recon-settle-panel`): pick contact → `Accounting.query_transactions_for_matching/5`
(rows filtered `balance > 0` for RC, `< 0` for PV; default range = min stmt
date − 366 → today) → tick docs. Allocation is FIFO in listed order
(`settle_allocations/3`): each ticked row takes its outstanding, the last is
capped; **Create is refused unless allocated == statement total** — custom
splits belong in the form flow.

`BankReconciliation.create_settling_doc(kind, stmt_ids, contact_attrs,
matchers, com, user)` (kind `:receipt | :payment`) does everything in **one
transaction** via `create_receipt_multi` / `create_payment_multi` + a
`:recon_match` step: builds a matcher-only doc (no detail lines; funds account
= the lines' bank account; `funds_amount` = |Σ lines|; date = max stmt date),
then finds the bank transaction and `confirm_group_match`es — any failure
rolls the whole thing back. Errors: `:invalid_lines` (unmatched/one-sign/one
account checks), `:allocation_mismatch`, `:bank_txn_mismatch`, changeset,
`:period_closed`, `:not_authorise`.

**Matcher sign convention** (matches the form flows): `match_amount` =
`−balance` of the matched transaction → **negative** on a Receipt (settling
AR), **positive** on a Payment (settling AP). Matcher-only docs are valid:
receipt balance = funds + matched = 0; payment balance = funds − matched = 0.

**Gotcha:** after settling, the new RC/PV's *own* AR/AP transaction appears in
`query_transactions_for_matching` with its natural balance — "settled" means
the *invoice* rows read zero, not that the contact's whole list is empty.

## Post Diff & Match (statement net of a fee)

Card settlements arrive net of merchant commission: RC-100 was issued on the
sale day, the statement later shows 98.00. Never force-match 98↔100 — the
2.00 is a real expense. **Sign-agnostic, so it covers the payment direction
too**: PV-100.00 vs statement −100.50 (cheque clearing / transfer fee) posts
bank −0.50 ↔ fee account +0.50 the same way — do not add sign gating. When both sides are selected and totals **differ**,
the selection strip grows `#recon-diff-form` (account autocomplete) +
**Post Diff & Match**: `BankReconciliation.match_with_difference(stmt_ids,
txn_ids, diff_account, com, user)` posts a Journal **dated the latest
statement date** (bank `stmt_total − txn_total` ↔ diff account the negation —
journals have no 60-day date window, so month-later recon backdates fine,
period lock permitting) and group-matches lines + transactions + the journal's
bank transaction in **one database transaction** via
`JournalEntry.create_journal_multi` + a `:recon_match` step. Errors:
`:no_difference` (equal totals → use Match Selected), `:invalid_selection`
(matched/foreign/multi-account items), `:period_closed`, changeset,
`:not_authorise` (needs `:create_journal`). Footer visibility is mutually
exclusive: zero-diff selections show **Match Selected** only, unequal totals
show **Post Diff & Match** only, and **Auto-Match / AI Match hide while any
book transaction is selected** (selection = manual-match mode).

## Tests

`test/full_circle_web/live/recon_doc_prefill_live_test.exs` (form seeding,
match, mismatch guard), `bank_reconciliation_live_test.exs` (buttons, payload),
`bank_reconciliation_test.exs` (`find_doc_transaction/3`),
`bank_reconciliation_settle_test.exs` (`create_settling_doc/6`),
`recon_settle_live_test.exs` (settle panel). Settle tests must use **recent
dates** — receipt/payment date validation allows only ~60 days back. Driving a full doc
save in tests: `element("#object-form") |> render_submit(%{"payment" => attrs})`
with fixture attrs — the `form()` helper can't fill autocomplete/nested inputs.
