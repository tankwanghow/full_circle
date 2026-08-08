---
name: optimistic-locking
description: Use when locking a new schema with lock_version, writing or reviewing a loader with an explicit `select: %Schema{}`, adding an `update_all` that writes to invoices, pur_invoices, receipts, payments, credit_notes, debit_notes, deposits, return_cheques, journals, contacts or goods, or when saves unexpectedly fail as `{:error, :stale}` with no concurrent user involved. Covers the update_all bypass and the partial-select trap.
---

# Optimistic Locking

Eleven tables carry `lock_version` so two users editing the same record can't silently
overwrite each other: `invoices`, `pur_invoices`, `receipts`, `payments`, `credit_notes`,
`debit_notes`, `deposits`, `return_cheques`, `journals`, `contacts`, `goods`.

**The wiring is self-evident from the code — read `FullCircle.StdInterface.changeset/5`
and any locked schema.** Short version: add the column and the `field`, nothing else;
`StdInterface` applies `optimistic_lock/2` to any schema carrying it, and every update
path already rescues `Ecto.StaleEntryError` into `{:error, :stale}`. `delete/6` uses an
unlocked changeset on purpose.

This skill only covers the two things that are **not** visible from reading the code.

## Trap 1: `update_all` bypasses the lock entirely

`Repo.update_all` / `Multi.update_all` don't run changesets, so they never bump
`lock_version`. A machine write that skips the bump is invisible to anyone holding the
record open, and their save overwrites it.

Any `update_all` touching a locked table must bump the counter:

```elixir
update: [set: [e_inv_uuid: ^uuid, e_inv_internal_id: ^internal_id], inc: [lock_version: 1]]
```

Existing bumpers: `grep -rn 'inc: \[lock_version: 1\]' lib`.

`bank_reconciliation.ex` has many `update_all` calls but touches only `transactions` and
`bank_statement_lines` — neither is locked. Re-check if that ever changes.

## Trap 2: a partial `select:` substitutes the schema default, silently

A loader building an explicit struct drops any field it doesn't list, and the struct comes
back carrying the schema **default** — for `lock_version` that's `0`, **not `nil`**.

Inserts run `optimistic_lock` too, so a freshly created row is already at `1`. The filter
becomes `WHERE lock_version = 0` against a row holding `1`: zero rows matched,
`StaleEntryError`, and **every save from that loader fails as stale** from the first edit.
Deterministic, single-user, nothing to do with concurrency.

The default is what hides it. Ecto warns only on the *nil* branch ("the current value of
`lock_version` is `nil` and will not be used as a filter") and skips filtering there. A
defaulted `0` logs **nothing** and produces a wrong filter instead. Don't hunt for that
warning; it never appears.

Measured on `goods` with the select line removed: struct `0`, DB row `1`, changeset filters
`%{lock_version: 0}`, save → `{:error, :stale}`.

On a database with existing rows it reads even less like a query bug: pre-migration rows
sit at `0`, so their **first** edit succeeds and bumps them to `1`, then they jam forever;
rows created after the deploy jam immediately. Old records editable exactly once, new
records never.

### The four loaders

`Good` is not the only schema built this way — it's only the locked one. Three others will
break the moment someone locks them:

| Loader | Schema | Locked today? |
|---|---|---|
| `product.ex:554` `good_query/2` | `Good` | yes — carries `lock_version` |
| `accounting.ex:512` `fixed_asset_query/2` | `FixedAsset` | no |
| `accounting.ex:259` | `TaxCode` | no |
| `hr.ex:911` | `Advance` | no |

**Before locking a new schema, check whether its loader is one of these:**

```bash
grep -rnE "select: %[A-Z][A-Za-z]*\{" lib
```

Loaders using `select: doc` plus `select_merge:` for virtuals are fine.

## Proving a newly locked schema actually works

Add both tests to `test/full_circle/stale_entry_test.exs` /
`test/full_circle_web/live/stale_save_live_test.exs`:

1. a concurrent two-user save → `{:error, :stale}`
2. **a plain single-user save → succeeds**

The second is the one that catches Trap 2. A concurrent-only test can pass while the
loader is broken, because in that state everything is stale.
