---
name: bank-recon-matching
description: Use when working on Bank Reconciliation matching — statement lines vs book transactions, match groups, carry-forward of unmatched items, and the "Create Payment / Create Receipt from statement line" flow (online-banking payments/receipts the clerk never documented). Covers the recon prefill payload contract, the auto-match-on-save amount guard, and why Book Entry / Dismiss are wrong for supplier and customer payments.
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

## Tests

`test/full_circle_web/live/recon_doc_prefill_live_test.exs` (form seeding,
match, mismatch guard), `bank_reconciliation_live_test.exs` (buttons, payload),
`bank_reconciliation_test.exs` (`find_doc_transaction/3`). Driving a full doc
save in tests: `element("#object-form") |> render_submit(%{"payment" => attrs})`
with fixture attrs — the `form()` helper can't fill autocomplete/nested inputs.
