---
name: notes
description: Use when working on FullCircle Notes (company memory) or the Linkable registry — note visibility, versions, attachments, record_links, the notes panel/count on record pages, or adding a new linkable record type.
---

# Notes & Linkable — contract

Spec: `docs/superpowers/specs/2026-09-29-notes-and-tasks-design.md`.
Note page: `docs/superpowers/specs/2026-10-02-note-page-redesign-design.md`.

## Visibility is one query
`Notes.visible_to/3` is the only read gate: company via `Sys.user_company/2`,
`deleted_at IS NULL`, then `visibility IS NULL OR role = ANY(visibility) OR
author = me` (admin skips the role test; no `:view_notes` → empty). Every read —
index, search, panel, counts, backlinks, versions, attachment download — must
compose it. A new read path that queries `notes` directly is a leak.

Plus one rule for tasks: a note with `subject_type "Task"` is also readable by
anyone who can see that task (`Tasks.visible_to/3`), and `list_versions/3`
applies that rule per version, using the version's own subject (not the note's
current one). On write, `create_note/3` and `update_note/4` copy that task's
`visibility` (`follow_task_visibility/2`); the writer does not pick a role.
The copy is read inside the note's transaction with `FOR SHARE` on the task
row (`read_task_visibility/3`), keyed on the changeset's subject, so an edit
that sends only a forged `visibility` is overridden (and is a no-op save).
Lock order: task row, then its notes — in `update_note/4` the task read runs
before `snapshot`'s note `FOR UPDATE` (see `.claude/skills/tasks.md`).
The composer hides Everyone, Private and the role chips whenever the subject
is a Task. Changing the task's visibility updates those notes. See
`.claude/skills/tasks.md`.

## Visibility values
nil = public (Everyone). Otherwise a non-empty list; `[]` is invalid (DB
check). The chips are one shared `visibility_chips/1` (note page, feed post
box, notes panel quick-add): **Everyone · 🔒 Private · `Note.choosable_roles()`**
(manager supervisor cashier clerk auditor).

- **No admin chip:** admins read every note regardless (`visible_to/3` skips the
  role test). **No guest chip:** guests have no `:view_notes`.
- **Private is stored as `["admin"]`** (`Note.private_visibility/0`,
  `Note.private?/1`): only admins and the writer read it. "admin" only means
  something alone — `normalize/1` in `Notes` drops it next to real roles, so
  ticking a role while Private is on replaces Private.
- Forms send a hidden `""` so unticked groups still submit; normalize turns
  `["", ...]` into the list or nil. While Private is on, the chips render a
  hidden `admin` input so it survives the next phx-change.
- The composer handles `visibility_everyone` / `visibility_private` clicks by
  re-running its change with the stored form params.

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
3. `FullCircleWeb.RecordAside.record_aside` placed **after the record's card**
   (the outer `<div class="w-N/12 mx-auto …">` or the fit-width
   `w-fit min-w-[64rem]` card), not inside it, with `class` matching that
   card and the `:edit and @id != "new"` guard. The aside is notes on the
   left and tasks linked to the record on the right; the columns sit side by
   side once the row is 56rem wide (`@4xl`), and stack on a narrower card.
   The index notes modal stays the notes panel alone. The task page's
   progress notes stay the notes panel under the task, inside the task
   column, not this aside.
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
Plain HTTP (`NoteAttachmentController`, `PhoneUploadController`), never
LiveView uploads — phones lose socket uploads when the camera backgrounds the
page. Type sniffed from magic bytes. **Removal from a saved note hides the
file** (`get_readable/3` filters `removed_at`) but keeps it on disk — a
removed file is usually the wrong upload, so an old link must not keep
serving it. Spec: `docs/superpowers/specs/2026-10-04-note-attach-from-phone-design.md`.

**Tray (hold until Save).** Every write box (`ComposerComponent`) owns a
`tray_id`, fresh on each open/Save/Cancel (`reset/1` → `new_tray/1`). Files
picked (📎 `#{id}-attach`, several at once), dropped or pasted (`NoteDrop`
hook on `#{id}-tray`) or sent from the phone go into that tray
(`note_attachments.tray_id`, `note_id` empty — the `note_xor_tray` check) and
show as `#{id}-tray-files`. The `note_trays` row (owner, later the note) is
created by `Trays.open/3` on the first desktop upload (`create_tray` route) or
when the phone QR opens. Save passes `"tray_id"` to `Notes.create_note` /
`update_note`, which `Trays.claim/5` inside the note's transaction (a
files-only edit still claims; a stale/invalid save does not). Cancel
hard-deletes the tray's files (`Trays.cancel/3`). A saved tray follows: a
late phone upload attaches to its note; a cancelled one answers 409
"closed". `TrayPruner` deletes trays and scan folders older than 24 h. Files
already on a note keep the immediate soft remove (✕ on `#note-files`).
- **Never trust the tray as read.** An upload copies the file (up to 10 MB)
  *after* reading the tray, so Save/Cancel can commit in between. The insert
  goes through `Attachments.store_in_tray/4`, which re-reads the tray row
  `FOR SHARE` (claim and cancel take `FOR UPDATE`) and lands in the open
  tray, follows a saved one to its note, or refuses. Without that, the FK
  check simply waited for the claim and inserted into a closed tray: ✓ on
  the phone, never on the note, pruned a day later.
- **Tray files are readable by their owner** (`get_readable/3` left-joins
  `note_trays` on owner + company): the box shows them as `file_thumb`
  tiles before Save. Nobody else gets them (404).
- **Text is optional when there are files** — attached or in the tray.
  `Note.changeset/3` takes `files?: true` (body stored as `""`, the column is
  NOT NULL); the composer passes it on validate too. A files-only note's
  `display_title/1` is "📎 Files". `update_note` returns `{:error, cs}` for an
  invalid changeset *before* its "nothing changed" check: `validate_required`
  drops the blanked field from `changes`, so an invalid edit used to look
  like a no-op and returned `{:ok, current}`.

**Phone (`/up/:token`).** `FullCircleWeb.PhoneUpload` signs `{:tray | :note,
id}` + company + user + label; 600 s idle — every success returns a fresh
token and the page swaps it into the URL. Every request re-checks the user is
active in the company; note uploads re-check `may_edit?`. The page is a plain
controller page (`put_layout(false)`, own esbuild entry `phone_upload.js`),
no LiveView. Scans upload page by page (`Notes.Scans`,
`<uploads>/<company>/scans/<scan_id>/NNN.jpg`, max 30) and `ScanPdf` builds
the PDF on Done (JPEGs embedded as DCTDecode, no re-encode). The 📱 button is
`PhoneQrComponent` (QR made on open from `Endpoint.url()` — in dev set
`PHX_HOST` to the LAN IP or the QR says localhost). `window.__phoneUpload`
exposes `addPage/sendFile/startScan` for checking the page without a camera
(Chrome automation may only reach `localhost`, not the LAN IP).
- **Scan ids are a path segment: canonical 36-char UUIDs only.**
  `Ecto.UUID.cast/1` also accepts any 16-byte binary, so `"../../../../tmp/"`
  passed it and `finish/2` wrote outside the uploads dir. `Scans` checks the
  regex in every public function. Pages are numbered after the highest
  existing one and written `:exclusive`, so racing uploads never overwrite;
  the page also allows one scan request at a time (`busy`).
- **The phone page is not a secure context in dev** (`http://<LAN IP>`):
  `crypto.randomUUID` does not exist there — `uuid()` falls back to
  `getRandomValues`. Its script URL is undigested in dev and cached, so a
  phone may keep an old `phone_upload.js`; use a private tab.
- **✓ Close ends the link at once.** Each QR is one session (`s` in the
  token, carried by refreshed tokens); `PhoneUpload.finish/1` records it in
  the `PhoneUploadFinished` ETS set for the token lifetime (600 s). The set
  is started by `application.ex`, so a hot-reloaded dev server needs a
  restart; if the table is missing, Finish is a no-op and uploads still
  work. The page then tries `window.close()` (usually blocked for a tab the
  camera app opened) and, still open after 400 ms, `location.replace`s to
  `/up/done` (a static "All sent" page; routed before `/:token`).
- **QR SVG:** `QRCode.render(:svg)` emits a fixed `width`/`height` and no
  `viewBox`, so CSS sizing crops it. `PhoneQrComponent.scalable/1` swaps the
  size for a viewBox — do the same anywhere a QR is resized. The QR opens as
  a fixed, centered modal: the notes panel is `overflow-hidden` and clipped a
  popover.

**Post actions row.** Counts and ✎ Edit / 📎 Attach / 📱 Phone share one
row (`note_post/1`, an `@container`). Under 28rem (a record's notes panel)
📎 and 📱 show icons only (`@[28rem]:inline` labels, full names in `title`);
the buttons are matching `whitespace-nowrap` pills.

**Live arrival.** Every upload broadcasts `{:note_files_changed, {:tray |
:note, id}}` on `Attachments.topic(company_id)`. `FullCircleWeb.NoteFiles`
(on_mount in the company live_session) halts it and `send_update`s whoever
called `NoteFiles.listen/3` for that target (composer: its tray; notes
panel: each shown note), or sends `{:note_files, target}` to a LiveView that
called `listen_self/1` (the note page). Tests: a second `render(lv)` sees the
update (the send_update queues behind the first render call), and open the
tray (`Trays.open/3`) before `attach_to_tray/4`, as the route does.

**Templates never build file addresses or read `content_type`.** Get the
address from `Attachments.url(att, :original | :thumb)` and choose how to show
a file by `Attachments.kind(att)` (`:image | :pdf | :other`), normally via the
`file_thumb/1` component. `:thumb` is the original for images and a PDF's
rendered first page for PDFs (`?variant=thumb`) — that function, `kind/1`
and `file_thumb/1` are where further renditions, video posters and audio
slot in.

**PDF previews:** `Attachments.thumb_file/1` renders page 1 with `pdftoppm`
(poppler-utils — already in the prod Docker image) on the first request and
caches it beside the file as `<file>.thumb.jpg`; a `.thumb.failed` marker
stops an unrenderable PDF being retried on every feed load. 10s timeout,
temp-then-rename writes. The controller serves the variant behind the same
visibility check (no preview → 404, the file still downloads);
`file_thumb/1` lays the preview over the PDF badge and the `<img>` removes
itself on error. Tests needing pdftoppm are tagged `:pdftoppm` and excluded
in `test_helper.exs` when it isn't installed. The feed shows the first 4 files
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
visibility applied, two queries per call (record panels' 📝 counts). The
feed's 💬 is different: live **replies** only (`feed_details/3`), a note that
merely links here never counts.

## Replies (`reply_to_id`)
Spec: `docs/superpowers/specs/2026-10-02-note-replies-design.md`.
- A reply has `reply_to_id` = its thread's **root** (a note with no
  `reply_to_id`); replying to a reply attaches to that root. One level, never
  chains.
- A reply's `subject_type`, `subject_id` and `visibility` always equal its
  root's: `create_note/3` copies them (client values ignored) and
  `update_note/4` drops them from a reply's attrs; `reply_to_id` never changes
  after create. So a reply about a record shows in that record's panel.
- A root's save that changes subject or visibility updates its live replies
  in the same transaction (`sync_replies/3`). A task's visibility sync
  reaches replies too (they are about the task).
- **Lock order: task row → root note → reply note.** `:task_visibility`
  (task `FOR SHARE`), then `:root` (root `FOR SHARE`, `lock_root/2`), then
  `snapshot/4` (note `FOR UPDATE`). A deleted root: a new reply is refused
  (`reply_to_id: ["can't be replied to"]`); editing an existing reply keeps
  its stored values (`lock_root_or_keep/2`).
- Reads: `Notes.thread/3` (visible live replies, oldest first, as feed
  items), `Notes.root_of/3` (`:self` | `{:root, n}` | `{:deleted, nil}` |
  `{:hidden, nil}`), `feed_details/3` `reply_to:` `%{id, title, state}` for
  the "↩ reply to …" tag in `note_post/1` (hidden when `host` is the root).
- A refused target (unknown, unreadable, deleted, other company, malformed)
  is a changeset error, never a crash; the composer shows it
  (`errors/1` includes `reply_to_id`).
- **The root's author reads its replies** (third rule in `visible_to/3`:
  `reply_to_id IN (notes I wrote)`), and every version of them in
  `list_versions/3`. Without it, a clerk's Private question answered by an
  admin would hide the answer from the asker.
- Creating a reply skips `validate_subject/3`: the subject is the root's,
  checked when the root was saved, and may since be deleted or out of the
  replier's sight. Re-checking it refused replies on notes about deleted
  tasks/documents.
- The root→reply sync (`sync_replies/3`, and a task's sync) is an
  `update_all`: replies get no `note_versions` row for the inherited change.
- A non-reply note whose subject is a note (the about… picker still offers
  notes) is not in the thread; `list_backlinks/3` returns it with notes that
  link to the note, under "Linked from". It can also return a reply that
  links to its own root; the note page (`NoteLive.Form.assign_thread/1`)
  drops anything already in the conversation, so it shows once.
- `FullCircle.Notes.ReplyBackfill.run/1` converted old note-on-note rows
  (subject = a note) in the `add_reply_to_to_notes` migration: true root via
  a recursive CTE with a cycle guard, a `note_versions` snapshot first.

## One post component: `note_post/1`
The feed and every notes panel render the same `note_post/1`, so a note
looks the same everywhere. Options:
- `host: {type, id}` — the record whose page shows the post; chips pointing
  at it are dropped (they would only link back to the page you are on).
- `relation: :linked` — adds the "↩ linked" tag (note links here, is about
  something else).
- `new_tab` — body and counts open the note in a new tab (panels).
- Progress: a note whose subject is a Task gets `.note-progress` (amber
  `#f59e0b` inset bar, amber tint) and a ✅ tick (tooltip "Progress") in `post_header`
  (`progress` attr), except where `host` is that task. Edit headers pass it too.
- Files: the feed, panels and the note page all draw `file_grid/1` (the large
  X-style grid). Feed and panels show the first 4, then "+ N more files"; the
  note page (`detail`) shows all. There is no small-thumbnail panel mode.
- `detail` — the note's own page: larger body, no line-clamp, every file,
  full timestamp, counts not wrapped in a link.
  The root element's id is the `id` attr. Feed and panels leave it off.
- `actions` slot — controls right-aligned at the end of the counts row. The
  note page puts ✎ Edit, 📎 Attach and History there; a panel puts ✎ Edit and
  📎 Attach on notes the viewer may edit (`Notes.may_edit?/3`, the item's
  `can_attach`).
Items are `%{id, note, d}` with `d` from `Notes.feed_details/3`.

### Panel create in place
＋ Note (`#{panel}-new`) opens the full write box in the panel (`full`,
`avatar`, `fixed_subject` = the panel's record): title, body, and
"+ link a record". There is no "Full form" link to `/notes/new`. With a fixed
subject every pick is a link (a pick of the record itself is ignored), the
button and picker read "link a record" / "Link other records", never
"about…". A Task subject hides the roles pill as well as the chips (task notes
take the task's visibility). Files go into the box's tray and attach on Save.
Every Linkable type hosts this one panel (records, the 9 documents, Task, and
the list pages' 📝 modal), so create/edit in place covers them all.

### Panel edit in place
A panel post's ✎ Edit (`#{panel}-edit-#{note_id}`) swaps that post for the
composer (`id` `#{panel}-edit`, `layout: :post`) inside `#{panel}-editing`,
like the note page. The panel keeps the note as it was when Edit was pressed
(`edit_note`), so a reload after an upload cannot hand the box a newer
`lock_version`. A note *about* the panel's record gets that record as
`fixed_subject`: there is no chip to clear (the post shows none either), but
"+ link a record" stays, since the composer allows links in `:edit` even with
a fixed subject. A note that only links here keeps its own subject. The files
(`#{panel}-files`) ✕ carries `target={@myself}`, because the panel's host
page has no `remove_attachment` handler. Save, Cancel and uploads all reload
the panel. Save also sends `{:notes_changed, type, id}` when `notify_parent`.

## Feed (`/notes`)
The index is an x.com-style feed (`NoteLive.Index` + `note_post/1`). Per-post
extras — subject, links, 💬 reply count — come from
`Notes.feed_details(notes, company, user)`: four queries for the whole page.
Never call `list_links/3` or `count_by_records/4` per post. A freshly posted
note goes in with `stream_insert(..., at: 0)` built from
`feed_details([note], …)`.

## Record chips (About & links)
One component, `record_chip/1` in `NoteComponents`, renders every subject/link
chip — feed posts, the note page and the task page. It is capped at 10rem
(`max-w-40`): the "Type · title" text truncates with an ellipsis and the full
text is the chip's `title` tooltip. Remove buttons (✕) go in its inner block
with `shrink-0`, outside the truncated text, so they always show. Pages build
the `target` with a local `chip_target/2`: saved links already carry a resolved
`target`; a subject or a link queued on a new record is `%{type, id, title}`.
Don't hand-write chip markup on a page.

## Two note forms on one page
The note page hosts its own write box *and* the reply box; the feed has the
post box. `to_form/1` defaults every one of them to input ids like
`note_body`, and duplicate ids make the browser patch/focus the wrong
textarea (LiveViewTest raises on them). The composer's id is the prefix:
`to_form(cs, id: "#{id}_note")`. The textarea id also carries a revision
counter bumped after each post, so the box actually clears (the browser
keeps typed text on a same-id textarea). Any new place that renders a note
form next to another must use its own composer id.

## Navigation between notes and records
Links from notes to records (About and link chips, in the feed and on the note
page) and from a record's notes panel to a note ("Open") use
`target="_blank"`, like FullCircle's `doc_link`: record pages have no "back to
where I came from" (their orange button goes to their own list), so the page
you came from stays open in its tab. Moving within Notes (feed → note page →
Back) stays in the same tab. A note's own link — `Linkable.url("Note", …)`,
the post body, the counts — goes to `/companies/:id/notes/:note_id` (the post
view), not `/edit`.

## One write box: `ComposerComponent`
`NoteLive.ComposerComponent` is the only note write box. Hosts: the feed
(`id="compose"`), the note page (`id="note"` for new/edit, `id="reply"` for
the reply box), and every notes panel (the panel's own id). It owns
the form, calls `Notes.create_note/3` or `Notes.update_note/4`, and notifies
the host. Half-typed text survives ordinary host re-renders. The box resets
on first mount, after save or cancel, and when the host passes another note
or a newer save of the same one (a different `lock_version`). That last case
matters because LiveView keeps a removed component's state if it is rendered
again before the client confirms the removal: Save, then Edit straight away,
would otherwise show the pre-save text and `lock_version`.

| attr | meaning |
|---|---|
| `id` | prefixes every input id (`#{id}_note`, `#{id}-open-picker`, …) |
| `mode` | `:new` (default) · `:edit` |
| `reply_to` | `%Note{}` root: a reply box. A box is *replying* when `reply_to` is set or it edits a note with `reply_to_id`: no about… chip, no visibility chips/pill, a `#{id}-reply-scope` line ("Visible to the same people as the note it replies to."), every pick is a link, create sends `reply_to_id` |
| `note` | the note being edited (`:edit`) |
| `initial_subject` | `%{type, id, title}` prefill for `:new` |
| `fixed_subject` | `{type, id}` the note must be about; no `about…` chip |
| `full` | title input and the link row |
| `default_visibility` | starting visibility for a new note. A note about a Task ignores it; create and update copy the task |
| `roles_open` | chips shown at first (default: `full`). A box that starts folded keeps its "Everyone ▾" pill (`#{id}-roles-toggle`) while the chips are open, and the pill folds them again |
| `roles` | `false` hides the role chips. A Task subject hides them either way (`task_subject?/2`) |
| `placeholder`, `submit_label` | "Write a note…" / "Post your reply…"; "Post" / "Reply" / "Save" |
| `cancellable` | shows Cancel |
| `notify` | `:liveview` (default) sends `{:composer, id, event}` to the host LiveView. `{module, id}` does `send_update(module, id: id, composer: {composer_id, event})`. Events are `{:saved, mode, note}` or `:cancelled` (uploads stay inside the box's tray) |
| `layout` | `:box` (default): the write box. `:post`: edit in place (note page and panels), laid out like `note_post` — author avatar, `:header` slot (`post_header`; the slot's `:let` is whether the role chips show, and `show_visibility={!roles_editable}` keeps the 🔒 tag when they do not: task notes, replies), record chips (a reply shows its subject chip without ✕), bordered title (text-xl) and body (text-lg), `:files` slot (`file_grid removable`), visibility chips, then the counts row: `:footer` slot left, `:actions` slot + Cancel/Save right. The chips and picker sit above the `<form>`, so `#note-form` holds only the fields |

A pick reaches the box through `RecordPickerComponent`'s `notify`:
`send_update(ComposerComponent, id: …, picked: {picker_id, picked})`.

## Note page
`NoteLive.Form` is an x.com single-post page in the feed's column
(`max-w-xl`). Routes stay `/notes/new`, `/notes/:id` (`:show`) and
`/notes/:id/edit`.

- `/notes/:id` is the post view: `note_post` with `detail`.
- `/notes/:id/edit` opens edit mode only when `can_edit?`. A reader gets the
  post view, with no Edit and no Delete.
- ✎ Edit (`#edit-note`) swaps the post for the composer (`layout={:post}`) in
  place, so every part stays where the post had it. The box is
  pinned to the note as it was when Edit was pressed (`edit_note`). A
  mid-edit reload — a file just uploaded — must not hand the box a newer
  `lock_version`, or the save would silently overwrite someone else's edit
  instead of coming back `:stale`.
- Delete lives in the `⋯` menu (`#delete-note`) when `can_delete?`.
- Files: the post and edit mode share `file_grid/1`. Edit mode passes
  `removable` (`#note-files`, `#att-<id>`: a ✕ and the file name on each).
  In the post view 📎 (`attach_button`, `#attach-<note id>`) and 📱
  (`#note-phone`) attach straight to the note; this LiveView handles
  `attachment_uploaded` and `{:note_files, {:note, id}}`. In edit mode the
  composer's own tray takes new files (see Attachments): a hook pushes to the
  component it sits in (`closestComponentID`), so `attachment_uploaded` reloads
  the tray. LiveViewTest does not mimic that: `element(...) |> render_hook`
  goes to the element's `phx-target` (else the LiveView). Test it with
  `with_target("#note-box")`. The existing files' ✕ has no `phx-target` and
  reaches this LiveView's `remove_attachment` directly.
- History (`#toggle-history`, `#note-history`) lists versions with the same
  per-version filter as `list_versions/3`.
- Thread, top to bottom: `#replying-to` (reply pages only: the root as a
  post in `#replying-to-post` with its own `#toggle-root-history` →
  `#root-history`; `#replying-to-gone` when the root is deleted or hidden),
  `#thread-before` (earlier replies), the note itself, `#thread-after`
  (later replies; all replies on a root page), the reply box (composer
  `id="reply"`, root `#reply-box`, form `#reply-form`, `reply_to` = the
  root; hidden without `:create_note` or when the root is gone), and
  `#linked-from` (notes that only link here, `relation: :linked`). Thread
  items are `#thread-<id>` with `host={"Note", root_id}` so they carry no
  "↩ reply to" tag. A posted reply sends `{:composer, "reply", …}` and the
  page reloads the thread and 💬 count. The history markup is one private
  `history_list/1` for both the note and the root.
- On a reply page the note itself (post or edit box) sits in `#focus-note`
  with `phx-hook="ScrollToNote"` (`assets/js/app.js`): it jumps the reply
  to the middle of the screen and adds `.note-arrived` (3s amber fade,
  `assets/css/app.css`). Root pages get no hook — the note is already on
  top. The wrapper stays put across Edit/Cancel, so the flash plays once
  per page load.
  - The hook waits **two** animation frames. After a live `navigate`,
    LiveView's `Browser.pushState` calls `window.scroll(0, 0)` in a frame of
    its own; a scroll made on `mounted()` or one frame later gets undone.
    A `#hash` on the link would also work for navigate, but only for links
    that carry it — the hook covers search, chips and pasted URLs too.
  - Instant scroll, not `behavior: "smooth"`: landing on the note reads
    better, and smooth scroll is frame-driven.
  - Checking this in Chrome automation: the MCP tab is hidden
    (`document.visibilityState === "hidden"`), so `requestAnimationFrame`
    and CSS animations never run there and it looks broken. Stub
    `window.requestAnimationFrame = cb => setTimeout(cb, 16)` before
    clicking, and set the highlight colours as inline styles to screenshot
    them.
- `/notes/new` (including `?subject_type=&subject_id=`) is the composer at
  full size. Files go into its tray and attach on Post. Posting navigates to the
  new note's page.
- Title, body, subject and visibility save with Save. Links on a saved note
  apply immediately, so Cancel still reloads the post. A stale save keeps
  the typed text and warns.

## Command palette (`CommandPalette.NoteSearch`)
- `note <words>` / `notes <words>` (case-insensitive) searches **notes only**
  via `Notes.search/5` — never query `notes` directly from the palette. Hits are
  kind `:note` (title or first line; subtitle date · author · subject title from
  `Linkable.resolve_many/3`), path `/companies/:id/notes/:note_id`.
- Note text is **not mixed into ordinary palette results**: every non-action
  search instead ends with a `:note_search` row, "Search notes for “…”", that
  opens `/notes?search[terms]=…`. It is not saved to Recent. Both are omitted
  without `:view_notes`.
- Grouped under a "Notes" section after Documents (`Groups.group/1`).

## Translations
Do not run `mix gettext.extract --merge` for new strings: the catalogs lag the
code and a merge marks ~200 existing translations fuzzy (disabling them).
Append new `msgid`/`msgstr` entries to `priv/gettext/zh/LC_MESSAGES/default.po`.

## Pages not covered
None. All 14 record types: Employee, Contact, Good, Account, FixedAsset + 9 posted
documents (Journal has no test fixture; its index is smoke-rendered only).
Account rows link to the edit page only for non-default accounts (or admins),
but the 📝 badge opens the notes modal for every row.

## Dark theme: selected states
`assets/css/app.css` remaps light colours for the dark theme with plain,
unlayered rules (`.dark .bg-white`, `.dark .border-gray-300`, …). Unlayered
CSS beats every Tailwind utility, so `dark:has-checked:…` (or any `dark:`
override of a remapped class) never shows. Choose selected/active looks on
the server instead — see `role_chip/1`, which renders a ticked role solid
blue from the form state. Check a class against the remap list before relying
on a `dark:` variant to override it.
