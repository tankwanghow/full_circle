---
name: tugas-duties
description: Use when working on FullCircle's Tugas (duties) subsystem — duties, duty_events, evidence files, duty_documents links, recurrence/spawn-next, the 48h correction window, or wiring opts[:duty_id] into a document context like BillPay.
---

# Tugas (duties) — backend contract

`FullCircle.Tugas` (`lib/full_circle/tugas.ex` + `lib/full_circle/tugas/`).
Four tables, no UI as of the backend PR.

## The series model — the thing to get right

A duty row is **one cycle**, never edited into its successor.

- Every duty carries a `series_id`. A one-off duty is a series of one, so
  close/spawn and `end_series` need no special case.
- Closing a cycle (`complete_duty/4` → `done`, `skip_duty/4` → `skipped`) is
  what **spawns the next cycle**, inside the same `Ecto.Multi`.
- `duties_one_live_cycle_per_series` is a **partial unique index** on
  `series_id WHERE status = 'active'`. It is the real guarantee, not the code.

**Ordering inside the multi is load-bearing:** the close must be written
*before* the spawn, or the partial index sees two live cycles and the
transaction aborts.

### Stale close

`lock_live_duty/3` re-reads the row `SELECT ... FOR UPDATE` inside the
transaction. Two concurrent closes serialise; the loser re-reads a non-active
row and gets `{:error, :not_live}` instead of double-closing and double-spawning.

**Gotcha:** the lock query is scoped by `company_id` directly, *not* by the
usual `Sys.user_company/2` subquery join — Postgres refuses `FOR UPDATE` on a
query that joins a subquery. Membership is already established by the `can?/3`
check that runs first (it reports `"disable"` for a user with no row in the
company), so this is not a scoping hole. Do not "fix" it back to a subquery.

### end_series

Stamps `series_ended_at` on **every** row of the series (visible from any
cycle) and stops spawn-next. It deliberately **leaves the live cycle open** —
work already due still has to be finished or skipped.

### Recurrence

`recur_unit` ∈ `day|week|month|year`, paired with `recur_every >= 1`; both nil
or both set (enforced in the changeset *and* by a check constraint).

A recurring duty **requires a `due_date`** — recurrence means "advance the due
date by one interval", and with nothing to advance from every spawned cycle
would be undated.

`Duty.next_due_date/3` clamps month/year arithmetic to the end of the target
month: 31 Jan + 1 month → 28 Feb, never 3 Mar.

## Events are the record

`duty_events` is append-only; the `status` column on `duties` is only the state
derived from it. Actions: `progress done skip linked unlinked end_series`.

**`duty_events` uses `:utc_datetime_usec`, unlike the rest of the app.**
Several events are written inside one transaction (close + spawn, link +
event). At second precision the trail came back in arbitrary order because the
only tiebreaker left was a random UUID. Do not "normalise" this to
`:utc_datetime`.

`add_progress/4` refuses a closed duty (`{:error, :not_live}`) — progress on a
closed duty is nearly always meant for the cycle that has since been spawned.

`update_duty/4` **drops `status`** from the attrs. A duty leaves `active` only
through complete/skip, which also decide whether to spawn. It also
short-circuits a no-op edit and returns `{:ok, duty}` without touching the DB,
because `Sys.Log` rejects a blank `delta` and the log insert would fail the
transaction. (Same trap applies anywhere you wrap `StdInterface.update`.)

## The 48-hour correction window

`correct_duty_event/4` and `delete_duty_event/3`:

- author + within 48h → allowed with `:create_duty_event`
- otherwise (not yours **or** too old) → needs `:correct_others_duty_event`
- returns `{:error, :window_closed}` vs `{:error, :not_author}`

**Only `progress` events are correctable.** The structural ones are written by
the state machine and are what the duty row derives from; retracting a `done`
would not reopen the duty, it would only make the trail lie →
`{:error, :not_correctable}`. A correction drops `action` from the attrs.

Deleting an event removes its evidence **files** — the rows cascade from the
FK, the files do not. The `File.rm` runs *after* the transaction commits: a
file deleted ahead of a rolled-back delete leaves a row pointing at nothing.

## Evidence files

`attach_evidence/4` takes `%{path:, file_name:}` — what
`consume_uploaded_entry/3` hands over.

- **`content_type` is sniffed from magic bytes. A claimed type never reaches
  the column.** Phones send `application/octet-stream` routinely, and this
  column decides how the file is served back later.
- Allowlist: `image/jpeg image/png image/webp application/pdf`. Anything else
  is `{:error, :unsupported_type}` and is **never copied**.
- Size checked with `File.stat/1` *before* any read or copy.
  `Tugas.evidence_max_bytes/0` = `10_000_000` — decimal MB, matching
  `upload_file_live`'s existing `max_file_size`.
- Path on disk: `<uploads_dir>/<company_id>/tugas/<event_id>/<uuid><ext>`.
  The row stores the path **relative to `:uploads_dir`** (same convention as
  `PunchGate`), so moving the volume does not invalidate every row.
- **Orphan cleanup:** if the insert fails after the copy, the destination file
  is removed. The row is what makes a file findable; without one it is garbage
  nothing will ever clean up.

## Document links

`duty_documents` — one duty → many documents.

- `doc_id` carries **no foreign key** on purpose. The linkable types are a
  whitelist in `Tugas.document_types/0` (currently just `["Payment"]`), not a
  nullable column per document table. `doc_type` is validated against that
  whitelist in the changeset, which is the **only** thing keeping `doc_id`
  aimed at a real row. Adding a type = adding it to that list.
- Unique on `(duty_id, doc_type, doc_id)`.
- Linking is **allowed on a closed duty** — the document that proves a duty was
  done is often posted after someone ticked it off.
- Unlinking deletes the row and leaves an `unlinked` event; the event is what
  preserves the fact. That is why unlinking is supervisory and linking is not.

### Wiring a document context to duties

`Tugas.link_document_multi/6` adds the link to the document's own multi:

```elixir
# lib/full_circle/bill_pay.ex
def create_payment(attrs, com, user, opts \\ [])
def create_payment_multi(multi, attrs, com, user, opts \\ [])

defp maybe_link_duty(multi, nil, _payment_name, _com, _user), do: multi

defp maybe_link_duty(multi, duty_id, payment_name, com, user) do
  FullCircle.Tugas.link_document_multi(multi, duty_id, "Payment", com, user, fn changes ->
    payment = Map.fetch!(changes, payment_name)
    %{doc_id: payment.id, doc_no: payment.payment_no}
  end)
end
```

The `doc_fun` receives the multi's changes because the document does not exist
yet when the steps are added.

**An unresolvable `duty_id` rolls the document back** (`{:error, :tugas_duty,
:duty_not_found, _}`). A payment raised "for" a duty that does not exist is
almost always the wrong payment; posting it silently unlinked hides the mistake.

Adds steps `:tugas_duty`, `:tugas_duty_document`, `:tugas_duty_event` — **once
per multi only**. Keep existing arities via default args.

## Authorization — allow-lists, no new role

`roles/0` is untouched; there is **no `tasker` role**. All clauses are
`allow_roles` so a role added later starts with no duty rights.

| action | roles |
|---|---|
| `:view_tugas` | admin manager supervisor clerk cashier **auditor** |
| `:create_duty` `:update_duty` `:create_duty_event` `:create_duty_event_document` `:complete_duty` `:skip_duty` `:link_duty_document` | admin manager supervisor clerk cashier |
| `:end_duty_series` `:unlink_duty_document` `:correct_others_duty_event` `:delete_others_duty_event` | admin manager supervisor |

`auditor` is view-only. `Authorization.can?/3` has **no catch-all clause** — a
missing action raises `FunctionClauseError`, so every new action needs a clause.

## Search

`search_duties/4` escapes LIKE metacharacters via
`FullCircle.CommandPalette.Types.escape_like/1`, so a user typing `100%`
searches for a literal percent sign rather than matching every duty starting
with `100`. Same for `_`.

## Not built yet

- No UI of any kind (deliberate — the UI is a separate pass).
- No file-serving HTTP controller for evidence; evidence is covered by context
  tests only.
- No `todos` table.
- Whitelist stops at `Payment`.
