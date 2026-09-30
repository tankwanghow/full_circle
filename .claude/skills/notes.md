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

- **`snapshot` locks the note row (`FOR UPDATE`) and compares `lock_version`
  before numbering.** Without the lock, two simultaneous saves both compute
  `max(version)+1`; the loser hits the unique index and gets a `NoteVersion`
  changeset back, which crashes the form. With it, the loser gets `:stale`.
- **History is filtered per version, by that version's own `visibility`.**
  `list_versions/3` shows a past version only to users who could have read it
  *as it was*; admin and the note's author see all. Filtering by the note's
  current visibility leaks: a manager-only note later made public would show
  clerks its restricted text. `version_changes/2` must be fed the filtered
  list, so each diff compares against the next *visible* state.
- **The subject is validated only when set or changed.** An unchanged subject
  that has since been deleted must not block fixing a typo in the body.

## Rights
For notes already known to be readable (anything from `visible_to/3`), take
`rights/2` once and use `may_edit?/3` / `may_delete?/3`. `can_edit?/3` and
`can_delete?/3` re-run the visibility query per note — fine for one note, ~5
queries per row in a list.

## Linkable
References are `(type, id)` with no FK. `Linkable` is the whitelist and scopes
every resolve to the company; foreign ids are `:not_found`. Records and posted
documents are visible to **any company member**, as their pages are.
Documents resolve through `transactions`. **Do not gate on the palette's
`update_*` actions** — they are about editing; gating on them stopped clerks
noting journals and cashiers noting credit/debit notes and return cheques.
`:restricted` happens only for `Note` targets when the user lacks `:view_notes`.

### Adding a linkable type
1. Entry in `@records` (table with `company_id` + title column) or add it to
   `CommandPalette.Types.type_specs` if it is a posted document.
2. `type_label/1` clause in `NoteComponents` (gettext).
3. Panel snippet after `</.form>` in its edit LiveView (`:edit` guard).
4. Index: alias + `NotesIndex.init(type, RowComponent, key: …, stream: …)` in
   mount (`key`/`stream` default to `:id`/`:objects`), `NotesIndex.count/3`
   before `stream(`, `note_count=` on the row component, `<NotesIndex.modal>`.
   `init` attaches the `open_notes`/`close_notes` event and
   `{:notes_changed, ...}` info hooks itself — **no handler clauses in the
   index**. Row component gets `assign_new(:note_count, ...)` and
   `<.notes_count_badge>`.

## Index-page gotchas (LiveView streams)
- **Drop the list's `:if={Enum.count(@streams.objects) > 0 or @page > 1}`.**
  Once rows read `@note_counts`, any re-render re-evaluates that `:if` against
  an already-flushed stream (count 0) and removes the whole list from the page.
- **`NotesIndex.changed/4` must not assign `@note_counts`.** Re-rendering the
  stream comprehension drops the row's `send_update`. It recounts and
  `send_update`s the row only; row components must `assign(assigns)` (merge).
- Rows that are not the record (Deposit/ReturnCheque rows are transactions):
  `NotesIndex.init(type, RowComponent, key: :deposit_id | :return_id)`; `notes_rows` maps each
  document id to its row ids for updates; hide the badge when the key is nil.
- In LiveView tests, a quick-add's count reaches the row via two messages;
  call `:sys.get_state(lv.pid)` twice before `render(lv)`.

## Attachments
Plain HTTP (`NoteAttachmentController`), never LiveView uploads — phones lose
socket uploads when the camera backgrounds the page. Type sniffed from magic
bytes. **Removal hides the file from the note and from download**
(`get_readable/3` filters `removed_at`) but keeps it on disk — a removed file is
usually the wrong upload, so an old link must not keep serving it.

**Templates never build file addresses or read `content_type`.** Get the
address from `Attachments.url(att, :original | :thumb)` and choose how to show
a file by `Attachments.kind(att)` (`:image | :pdf | :other`), normally via the
`file_thumb/1` component. `:thumb` serves the original until real renditions
exist — that function, `kind/1` and `file_thumb/1` are where generated
thumbnails, video posters and audio slot in. The feed shows the first 4 files
of any kind (PDFs as tiles) then "+n more"; the note page shows every file.

`note_attach.js`:
- Re-encodes only photo formats to JPEG; PNG/WebP/GIF keep transparency.
- Announces a finished upload by dispatching `note-attach:done` to the element
  carrying the button's id *now*, whose hook pushes to its own component.
  Pushing from the original (possibly re-rendered, detached) element reaches
  the host LiveView instead, which has no handler and crashes.
- Never forces a reload when the socket is down (it would lose unsaved input).

## Counts
`Notes.count_by_records/4` = notes about ∪ notes linking, each note once,
visibility applied, two queries per call.

## Feed (`/notes`)
The index is an x.com-style feed (`NoteLive.Index` + `note_post/1`). Per-post
extras — subject, links, 💬 reply count — come from
`Notes.feed_details(notes, company, user)`: four queries for the whole page.
Never call `list_links/3` or `count_by_records/4` per post. A freshly posted
note goes in with `stream_insert(..., at: 0)` built from
`feed_details([note], …)`.

## Two note forms on one page
The note page hosts its own note form *and* the notes panel; the feed has the
post box. `to_form/1` defaults every one of them to input ids like
`note_body`, and duplicate ids make the browser patch/focus the wrong
textarea (LiveViewTest raises on them). So:
- `NotesPanelComponent` builds its form with `to_form(cs, id: "#{id}_note")`.
- The feed's post box uses `to_form(cs, id: "compose_note")`, and its
  textarea id carries a revision counter bumped after each post so the box
  actually clears (the browser keeps typed text on a same-id textarea).
Any new place that renders a note form next to another must do the same.

## Note page
There is no show page: `/notes/:id` and `/notes/:id/edit` both render
`NoteLive.Form`, read-only when `can_edit?` is false. Title/body/visibility/
subject save with Save; files and links on a saved note apply immediately
(links on a new note are queued until the first save). The notes panel sits
under the note with `record_type: "Note"` for follow-up notes.

## Translations
Do not run `mix gettext.extract --merge` for new strings: the catalogs lag the
code and a merge marks ~200 existing translations fuzzy (disabling them).
Append new `msgid`/`msgstr` entries to `priv/gettext/zh/LC_MESSAGES/default.po`.

## Pages not covered
None. All 12 record types: Employee, Contact, Good + 9 posted documents (Journal has
no test fixture; its index is smoke-rendered only).
