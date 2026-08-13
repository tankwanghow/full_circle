---
name: accounting-period-lock
description: Use when editing a document context's save path (create/update Multi), adding a new GL-posting document type, or debugging a `{:error, :period_closed}` rejection. Covers the cutoff source, multi-level guard, map_period_closed, fast-path asymmetry, and what is still unlocked.
---

# Accounting Period Lock

A company-level cutoff blocks saves that would **write or rebuild GL rows** dated on
or before that date. Non-GL header/detail edits may still be allowed on some doc types.

## Cutoff source

- Stored at `companies.settings["period"]["closed_through"]` (ISO date string, or empty).
- **`Sys.period_closed_through/1` always re-reads the DB.** Do not read
  `company.settings` off the session `current_company` — that snapshot can be stale.
- **`Sys.close_period_through/3` is the only writer.** Admin only. `nil` clears the
  cutoff. Future dates (company timezone) reject as `{:error, :future_date}`. Logged
  as action `close_period` with `from`/`to`.
- UI: company form period-lock section (`company_live/form.ex`).

## Guard placement

The rule is **not** in `make_changeset/5`. It sits **in the Multi**, before any
transaction `insert_all` / `delete_all` rebuild:

```elixir
|> Accounting.multi_assert_period_open(fn changes -> [doc_date, new_date] end, com)
```

Public create/update APIs pipe `Repo.transaction()` through
`Accounting.map_period_closed/1`, which collapses the Multi 4-tuple
`{:error, :assert_period_open, :period_closed, _}` to `{:error, :period_closed}`.

Helpers live in `FullCircle.Accounting`:

| Function | Role |
|---|---|
| `assert_period_open/2` | Pure check: any non-nil date `<=` cutoff → `{:error, :period_closed}` |
| `multi_assert_period_open/3` | Multi step `:assert_period_open` |
| `map_period_closed/1` | Public-API error shape |

On update, pass **both** the original doc date and the post-update date so moving a
doc *out of* a closed period still fails if the old GL rows would be deleted.

LiveViews flash `:warn` with the cutoff date via
`Sys.period_closed_through(socket.assigns.current_company)`. Put the
`{:error, :period_closed}` clause **above** any catch-all `{:error, _}`.

## Fast-path asymmetry (load-bearing)

| Types | Non-GL edit under closed period? |
|---|---|
| Invoice, PurInvoice, CreditNote, DebitNote | **Yes** — fingerprint says transactions unchanged → skip guard + rebuild |
| Receipt, Payment, Deposit, ReturnCheque, Journal | **No** — every update re-runs the guard and rebuilds GL |

Do not "fix" Payment/Receipt by copying Invoice's skip. The always-rebuild path is
intentional for matcher-owning and full-rebuild docs.

## No document-level delete

There is no supported document delete for these GL docs. Receipt/Payment
`handle_event("delete")` (if still present) is **dead leftover** — do not wrap it with
the period guard and do not build UI or tests on it.

## New GL-posting document types

Any new type that inserts or rebuilds `transactions` **must** add
`multi_assert_period_open` before the build/`delete_all`, and
`map_period_closed/1` on the public API. Missing either silently bypasses the lock.

Covered today: Invoice, PurInvoice, Receipt, Payment, CreditNote, DebitNote, Deposit,
ReturnCheque, Journal. Settlement create wrappers (`create_invoice_from_drops` /
purinvoice equivalents) map through Billing and already surface `:period_closed`.
Bank recon book-entry (via Journal) surfaces `{:error, :period_closed}` in the LiveView.

## `transactions.closed` is not the period lock

`transactions.closed == true` means **seeded opening balance**, enforced by DB triggers
(`cannot_update_or_delete_closed_transaction`). Unrelated to the company cutoff.

The UPDATE trigger **must `RETURN NEW` for open rows**. Returning `OLD` silently
drops every update to open transactions (bank recon match flags, particulars, etc.).
See migration `20260813014759_add_update_closed_transaction_trigger`.

`Accounting.assert_doc_editable/4` checks the seed flag (`:closed`) and matchers
(`:has_matchers`) — different errors from `:period_closed`.

## Not fully covered yet

These can still post or mutate GL inside a closed period until wired:

- Payroll / pay slips (separate void deadline, not this cutoff)
- Trading paths other than Settlement invoice/purinvoice create wrappers
- Fixed-asset depreciation (and similar machine writes into `transactions`)

When extending coverage, follow the Multi-guard + `map_period_closed` pattern above;
do not invent a second cutoff store.
