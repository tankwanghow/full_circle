---
name: notes
description: Use when working on FullCircle Notes (company memory) or the Linkable registry — note visibility, versions, attachments, record_links, the notes panel/count on record pages, or adding a new linkable record type.
---

# Notes & Linkable — contract

Spec: `docs/superpowers/specs/2026-09-29-notes-and-tasks-design.md`.

## Visibility is one query
`Notes.visible_to/3` is the only read gate: company via `Sys.user_company/2`,
`deleted_at IS NULL`, then `visibility IS NULL OR role = ANY(visibility) OR
author = me` (admin skips the role test; no `:view_notes` → empty). Every read —
index, search, panel, counts, backlinks, versions, attachment download — must
compose it. A new read path that queries `notes` directly is a leak.

## Visibility values
nil = public. A list of roles otherwise; `[]` is invalid (DB check). Forms send
a hidden `""` so unticked groups still submit — `normalize/1` in `Notes` turns
`["", ...]` into the list or nil.

## Versions
`update_note/4` snapshots the *current DB row* into `note_versions`, then
updates the *struct the editor loaded* with `optimistic_lock` — the loaded
`lock_version` is what detects a concurrent save (`{:error, :stale}`). No-op
edits return early and write no version. Delete is soft and also snapshots.

## Linkable
References are `(type, id)` with no FK. `Linkable` is the whitelist and scopes
every resolve to the company; foreign ids are `:not_found`, types the user may
not view are `:restricted`. Documents resolve through `transactions` using the
command palette's per-type `update_*` permission.

### Adding a linkable type
1. Entry in `@records` (table with `company_id` + title column) or add it to
   `CommandPalette.Types.type_specs` if it is a posted document.
2. `type_label/1` clause in `NoteComponents` (gettext).
3. Panel snippet after `</.form>` in its edit LiveView (`:edit` guard).
4. Index: alias + `NotesIndex.init(type[, key])` in mount, `NotesIndex.count/3`
   before `stream(`, `note_count=` on the row component, `<NotesIndex.modal>`,
   `open_notes`/`close_notes`/`{:notes_changed, ...}` clauses; row component
   gets `assign_new(:note_count, ...)` and `<.notes_count_badge>`.

## Index-page gotchas (LiveView streams)
- **Drop the list's `:if={Enum.count(@streams.objects) > 0 or @page > 1}`.**
  Once rows read `@note_counts`, any re-render re-evaluates that `:if` against
  an already-flushed stream (count 0) and removes the whole list from the page.
- **`NotesIndex.changed/4` must not assign `@note_counts`.** Re-rendering the
  stream comprehension drops the row's `send_update`. It recounts and
  `send_update`s the row only; row components must `assign(assigns)` (merge).
- Rows that are not the record (Deposit/ReturnCheque rows are transactions):
  `NotesIndex.init(type, :deposit_id | :return_id)`; `notes_rows` maps each
  document id to its row ids for updates; hide the badge when the key is nil.
- In LiveView tests, a quick-add's count reaches the row via two messages;
  call `:sys.get_state(lv.pid)` twice before `render(lv)`.

## Attachments
Plain HTTP (`NoteAttachmentController`), never LiveView uploads — phones lose
socket uploads when the camera backgrounds the page. Type sniffed from magic
bytes; removal hides but keeps the file (history may refer to it).

## Counts
`Notes.count_by_records/4` = notes about ∪ notes linking, each note once,
visibility applied, two queries per call.

## Translations
Do not run `mix gettext.extract --merge` for new strings: the catalogs lag the
code and a merge marks ~200 existing translations fuzzy (disabling them).
Append new `msgid`/`msgstr` entries to `priv/gettext/zh/LC_MESSAGES/default.po`.

## Pages not covered
None. All 12 record types: Employee, Contact, Good + 9 posted documents (Journal has
no test fixture; its index is smoke-rendered only).
