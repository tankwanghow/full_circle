---
name: optimistic-locking
description: Use when adding or changing a document header / master-data schema, writing a loader with an explicit `select: %Schema{}`, adding an `update_all` that writes to invoices, pur_invoices, receipts, payments, credit_notes, debit_notes, deposits, return_cheques, journals, contacts or goods, or when a save unexpectedly returns `{:error, :stale}` / raises `Ecto.StaleEntryError` / `CaseClauseError` on save. Covers the lock_version contract, the update_all bypass, and the partial-select trap.
---

# Optimistic Locking

Eleven tables carry a `lock_version` integer so two users editing the same record can't
silently overwrite each other. The second save is refused with `{:error, :stale}`.

**Locked tables:** `invoices`, `pur_invoices`, `receipts`, `payments`, `credit_notes`,
`debit_notes`, `deposits`, `return_cheques`, `journals`, `contacts`, `goods`.

Added by `priv/repo/migrations/20260808090000_add_lock_version_to_co_edited_records.exs`.

## How it is wired

`FullCircle.StdInterface.changeset/5` applies `Ecto.Changeset.optimistic_lock/2` to **any**
schema whose fields include `:lock_version`. There is no per-schema wiring — the check is
`if :lock_version in klass.__schema__(:fields)`.

Every changeset for these schemas funnels through that one function, including the five
`make_changeset/5` wrappers (`billing.ex`, `debcre.ex`, `cheque.ex`, `receive_fund.ex`,
`bill_pay.ex`), which pick `:changeset` vs `:admin_changeset` and then delegate.

**So to lock a new schema: add the column and the field. That is all.** Do not call
`optimistic_lock/2` in the schema module.

`StdInterface.delete/6` deliberately calls `unlocked_changeset/5` instead. Deleting is
**not** blocked by someone else's concurrent edit — that was a scope decision, not an
oversight. Don't "fix" it without also handling `Ecto.StaleEntryError` in every delete
handler.

## The `{:error, :stale}` contract

`Ecto.StaleEntryError` is **raised**, not returned, and escapes `Repo.transaction`. Every
update entry point rescues it:

```elixir
rescue
  Ecto.StaleEntryError ->
    {:error, :stale}

  e in Postgrex.Error ->
    classify_postgrex_error(e)
end
```

The stale clause must come **first** — `Postgrex.Error` won't match it, but keeping the
order consistent makes the intent obvious.

Covered entry points: `StdInterface.update/7`, `Billing.update_invoice/5`,
`Billing.update_pur_invoice/5`, `ReceiveFund.update_receipt/4`, `BillPay.update_payment/4`,
`DebCre.update_credit_note/4`, `DebCre.update_debit_note/4`, `Cheque.update_deposit/4`,
`Cheque.update_return_cheque/4`, `JournalEntry.update_journal/4`.

The `*_multi/5` variants do **not** rescue — they're only composed inside their own
wrapper. If you ever call a `_multi` from a new outer transaction, that caller must rescue.

Every LiveView `case` on these functions needs the clause, or a real conflict becomes a
`CaseClauseError` crash instead of a flash:

```elixir
{:error, :stale} ->
  {:noreply,
   socket
   |> put_flash(
     :error,
     gettext("This record was changed or deleted by someone else. Please reload and try again.")
   )}
```

Note this also fires when the row was **deleted**, not just changed — that path crashed
LiveViews before locking existed.

## Trap 1: `update_all` bypasses the lock entirely

`Repo.update_all` / `Multi.update_all` do not run changesets, so they never bump
`lock_version`. A machine write that skips the bump is invisible to anyone holding the
record open, and their save overwrites it.

Any `update_all` touching a locked table **must** bump the counter:

```elixir
update: [set: [e_inv_uuid: ^uuid, e_inv_internal_id: ^internal_id], inc: [lock_version: 1]]
```

Current bumpers, all findable with `grep -rn 'inc: \[lock_version: 1\]' lib`: the `EInvMetas`
submit path (`Multi.update_all(:update_invoice, ...)`), `EInvMetas.match/4` and
`EInvMetas.unmatch/3`, and `Accounting.learn_contact_identifiers/5` (via `learn_identifier/4`).

`bank_reconciliation.ex` has many `update_all` calls but only touches `transactions` and
`bank_statement_lines` — neither is locked, so it needs nothing. Re-check that if it ever
starts writing document headers.

## Trap 2: a partial `select:` silently substitutes the schema default

A loader that builds an explicit struct drops any field it doesn't list — and the struct
comes back carrying the schema **default** for that field, not `nil`. For `lock_version`
that default is `0`.

Meanwhile `StdInterface.create/6` also applies the lock, so `incrementer.(0)` runs on
insert and a **freshly created row is already at `lock_version: 1`**.

So the filter becomes `WHERE lock_version = 0` against a row holding `1`: zero rows
matched, `StaleEntryError`, and **every save from that loader fails as stale** from the
very first edit. Total breakage, not an intermittent edge case.

The default is what makes this nasty. Ecto only warns you about the *nil* case —
`optimistic_lock/2` logs "the current value of `lock_version` is `nil` and will not be
used as a filter" and skips filtering entirely. A defaulted `0` produces **no warning at
all**, just a wrong filter value. Don't go looking for that log line; it never appears.

Measured on `goods` with the select line removed: struct `lock_version` `0`, DB row `1`,
changeset filters `%{lock_version: 0}`, save → `{:error, :stale}`.

On a database that already has rows this is even harder to read: rows predating the
migration sit at `0`, so their **first** edit succeeds (filter `0` matches row `0`) and
bumps them to `1` — after which they jam forever. Rows created after the deploy jam
immediately. Old records editable exactly once, new records never, which looks like a data
problem rather than a query problem.

This bit `Product.good_query/2`:

```elixir
select: %Good{
  id: good.id,
  name: good.name,
  # ...
  lock_version: good.lock_version,   # REQUIRED — omit this and every goods save breaks
  inserted_at: good.inserted_at
}
```

Loaders using `select: doc` plus `select_merge:` for virtuals are fine — the full struct
carries the column.

**`Good` is not the only schema built this way — it is only the locked one.** There are
four explicit-struct loaders in `lib`, three of them attached to schemas that are *not*
locked yet and will break the moment someone locks them:

| Loader | Schema | Locked today? |
|---|---|---|
| `product.ex:554` `good_query/2` | `Good` | yes — carries `lock_version` |
| `accounting.ex:512` `fixed_asset_query/2` | `FixedAsset` | no |
| `accounting.ex:259` | `TaxCode` | no |
| `hr.ex:911` | `Advance` | no |

**Before locking any new schema, run this and check whether its loader is on the list:**

```bash
grep -rnE "select: %[A-Z][A-Za-z]*\{" lib
```

## Verifying

`test/full_circle/stale_entry_test.exs` covers, per schema: a delete-then-save, a
concurrent two-user save, and the three `update_all` writers.
`test/full_circle_web/live/stale_save_live_test.exs` covers the LiveView round trip —
including a plain single-user save, which is what catches the partial-`select:` trap.

To confirm a new schema is genuinely wired, add both a concurrent-save test **and** a
normal-save test. The normal-save test is the one that fails when the loader drops the
column.

## Common mistakes

| Mistake | Result |
|---|---|
| Calling `optimistic_lock/2` in the schema's `changeset/2` | Double increment; `StdInterface` already applies it |
| Adding the column but not the `field` | No locking at all, silently |
| `update_all` without `inc: [lock_version: 1]` | Machine writes silently overwritten |
| Explicit `select: %Schema{}` omitting `lock_version` | Struct gets the schema default `0`, DB row is `1` — every save from that loader fails as stale, with no Ecto warning |
| New form `case` without `{:error, :stale}` | `CaseClauseError` crash on conflict |
