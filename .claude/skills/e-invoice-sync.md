---
name: e-invoice-sync
description: Use when working on FullCircle e-invoice (LHDN) sync, the EInvMetas context, match/unmatch of e-invoices to local documents, or debugging the "Ecto.Queryable not implemented for Atom ... Got value: nil" crash during sync.
---

# E-Invoice Sync (EInvMetas / LHDN)

Domain knowledge for `lib/full_circle/e_inv_metas.ex` and the
`lib/full_circle_web/live/e_inv_list_live/` LiveViews. These are non-obvious
contracts that have already caused production crashes.

## `fc_doc` maps are STRING-keyed

`EInvMetas.unmatch/3` and the `match/...` path read `fc_doc` with **string
keys**: `fc_doc["doc_type"]`, `fc_doc["doc_id"]`, `fc_doc["uuid"]`. This is
because the primary callers (`index_sent_component.ex`,
`index_received_component.ex`) pass `Jason.decode!(fc_doc)` straight from a
JSON blob in the DOM — JSON decode always yields string keys.

**Any internal Ecto query that builds an `fc_doc` to feed these functions MUST
`select` string keys, not atom keys**, and must include `"uuid"` (used in the
unmatch audit-log delta). Example — `get_fc_doc_by_uuid/2`:

```elixir
select: %{"doc_id" => obj.id, "doc_type" => "Invoice", "uuid" => obj.e_inv_uuid}
```

### The crash this prevents

If you build `fc_doc` with atom keys (`%{doc_id:, doc_type:}`), then
`fc_doc["doc_type"]` returns `nil`. `unmatch/3` dispatches on that value, so it
falls through to the catch-all `unmatch(klass, ...)` clause with `klass = nil`,
which runs `from(doc in nil)` and raises:

```
protocol Ecto.Queryable not implemented for Atom, the given module does not
exist ... Got value: nil
```

It only triggers when sync encounters an **invalid** (`status != "Valid"`)
e-invoice whose UUID is matched to a local document, so it is intermittent.

## `EInvoice` has no `id` column

The `EInvoice` schema is declared `@primary_key false` (its natural key is
`:uuid`, the upsert conflict target). There is **no `id` field** — any query
that does `select: ei.id` / `count(ei.id)` raises *"field `id` in `select`
does not exist in schema FullCircle.EInvMetas.EInvoice"*. Select or count by
`:uuid` instead.

## `sync_e_invoices/2` return contract

Returns `{:ok, new_count}` on a full sync, or `{:error, message}` if a window
failed. `new_count` counts **genuinely new** e-invoices only.

- Sync re-fetches a **3-day overlap** window (`last_sync - 3 days` → now) and
  upserts on the `:uuid` conflict target. Already-stored UUIDs are replaced,
  not new — so counting upserted rows would report false positives. Count new
  invoices by excluding UUIDs already present (see `count_new_e_invoices/2`).
- Each date window is committed independently; a partial sync is preserved and
  clicking Sync again resumes from where it stopped.
- After all windows succeed, `remove_uuid_from_invalid_e_invoices/4` runs the
  match/unmatch reconciliation (the path with the string-key contract above).

## LiveView sync flow

`e_inv_list_live/index.ex` runs `sync_e_invoices/2` inside `Task.async` wrapped
in `try/rescue/catch`, so any crash comes back as
`{:finished_sync, {:error, msg}}` rather than killing the LiveView. The
`handle_info({:finished_sync, result}, ...)` clause flashes:

- `{:error, msg}` → error "E-Invoice sync stopped: …"
- `{:ok, 0}` → info "no new invoices"
- `{:ok, n}` → info "N new invoice(s)"

Live progress (`"<window>: page p/pages"`, retry notices) is pushed via
PubSub topic `"#{com.id}_e_invoice_sync_status"` and shown on the spinner.

## LHDN HTTP handling

`lhdn_get/4` does its own fail-fast retry (Req's retry is disabled) and never
raises — it returns `{:ok, body}` or `{:error, message}`. `classify_lhdn_response/1`
decides retry vs. final: 429 and 5xx/408/timeout are retried; 401 and other
4xx are final errors surfaced to the user.
