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

## UUID-based reconciliation (closes the date-window gap)

`sync_e_invoices/2` is built entirely on LHDN's **search index**
(`documents/search`, filtered on submission date, `last_sync − 3 days → now`).
That index misses documents in ways the date window can never fix:

- **Search-index gaps (the decisive one).** `documents/search` (and the
  MyInvois portal's own search) can fail to return a document that genuinely
  exists and is `Valid` — confirmed in production: a `Valid` document
  retrievable by UUID via `documents/{uuid}/raw` was absent from
  `documents/search` for its own submission window. This is an LHDN-side index
  problem; no window tweak recovers it because search never returns the row.
- Out-of-order validation beyond the 3-day overlap (stale local row).
- LHDN's **31-day** issued-within limit on the search date range.

`reconcile_e_invoices_by_uuid/2` runs as a **best-effort final pass inside
`sync_e_invoices/2`** (an LHDN failure there does not fail the sync). It:

1. Collects every non-nil `e_inv_uuid` across the six matchable document types
   (`local_matched_uuids/1`, a six-way `UNION`) whose stored `EInvoice` row is
   **missing or not `"Valid"`** (`uuids_needing_reconciliation/1`), capped at
   `@reconcile_max_per_run` per call.
2. Fetches each **directly by UUID** via the **Get Document** endpoint
   (`documents/{uuid}/raw`, `path(meta, "get_doc")`) — the *authoritative
   store*, not the search index, so it returns documents search omits and takes
   no date range. **Not** `documents/search`, which requires a date range
   (a `uuid`-only call returns HTTP 400) and hits the same faulty index.
3. `map_get_doc_to_einvoice/2` remaps the response — Get Document returns the
   **DocumentInfo** shape (`issuerTin`/`issuerName`/`receiverId`/`longID`),
   different from the **DocumentSummary** shape the search sync stores. Issuer →
   both `issuer*` and `supplier*`; receiver → both `receiver*` and `buyer*`;
   `longID` → `longId`. Summary-only fields (`submissionChannel`,
   `documentCurrency`, `receiverTIN`, `buyerTIN`, `intermediary*`) are absent
   and left null — harmless; the functional fields (`status`, `issuerTIN` for
   the Sent/Received split, dates, totals, names) are all present.
4. Upserts accurate rows (`Repo.insert_all`, conflict target `:uuid`) and
   **unmatches only rows that come back `"Invalid"`** (`Submitted`/pending stays
   matched). The set self-drains: once a doc is `Valid` it drops out.

### Rate limits (why it is throttled + capped)

Get Document is **60 RPM** per client (Search Documents is only **12 RPM** +
1 req/5s per taxpayer — do **not** build reconciliation on it). So the pass
spaces calls `@lhdn_get_doc_delay_ms` (~1.2s ⇒ ≈50/min) and attempts at most
`@reconcile_max_per_run` UUIDs per sync; a backlog drains over successive syncs.
`fetch_e_invoice_by_uuid/2` uses a raw `Req.get` (not `lhdn_get`): a **404 is
skipped** (`{:ok, nil}`), while **429/5xx halt the batch** so it backs off
entirely and resumes next sync instead of hammering a throttled endpoint.

## LHDN HTTP handling

`lhdn_get/4` does its own fail-fast retry (Req's retry is disabled) and never
raises — it returns `{:ok, body}` or `{:error, message}`. `classify_lhdn_response/1`
decides retry vs. final: 429 and 5xx/408/timeout are retried; 401 and other
4xx are final errors surfaced to the user.
