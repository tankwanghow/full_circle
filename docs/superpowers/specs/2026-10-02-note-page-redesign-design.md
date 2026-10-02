# Note page redesign — Design

Date: 2026-10-02
Status: design agreed in chat (user picked inline edit); awaiting written-spec review.
Context: `.claude/skills/notes.md` (Feed, One post component, Two note forms on one page,
Record chips). Parent spec: `docs/superpowers/specs/2026-09-29-notes-and-tasks-design.md`.

## 1. Problem

The notes feed (`/notes`) is an x.com-style timeline: one narrow slate column, posts
with avatar · author · time, chips, body, 💬 🔗 📎 counts, and a "Write a note…" box with
`about…` / `Everyone ▾` pills. The note's own page (`/notes/:id`, `NoteLive.Form`) is a
classic FullCircle form — a wide brown/yellow card with labelled Title/Note inputs, a
"Readable by" chip row, an "About & links" row, then separate Files, Notes panel and
History boxes. Opening a post feels like leaving the app. The user wants the two to look
like one product.

## 2. Decisions (2026-10-02)

- The note page becomes an **x.com single-post page** in the feed's column.
- **Inline edit in place**: ✎ Edit turns the post into the feed's write box, prefilled;
  Save / Cancel return to the post view. (Rejected: always-open editor for writers;
  separate edit page.)
- One **write box** everywhere: the feed, a new note, editing a note, replying on the
  note page, and the quick-add in every record's notes panel.
- Files and history live inside the post; the separate boxes go.
- Saving, versions, optimistic locking, files, links and permissions behave exactly as
  today — this is a UI change only.

## 3. Layout

```
┌──────────── max-w-xl column, same frame as the feed ────────────┐
│ ←  Note                                                          │
├──────────────────────────────────────────────────────────────────┤
│ (KP) kpsittat · 30 Sep 2026 14:14            [✎ Edit] [⋯]        │
│ [Contact · Ali Welding] [Invoice · INV-0112]      🔒 manager     │
│ Title (bold, larger)                                             │
│ Body — larger text, no line clamp                                │
│ [file grid — every file]                                         │
│ 💬 2  🔗 1  📎 3   📎 Attach              Edited · History ▸     │
├──────────────────────────────────────────────────────────────────┤
│ (KP) Post your reply…           [Everyone ▾]           [Reply]   │
├──────────────────────────────────────────────────────────────────┤
│ replies and linking notes, as feed posts (↩ linked tag)          │
└──────────────────────────────────────────────────────────────────┘
```

- **← Note** bar: back to `/notes` (same tab; record pages still open notes in new tabs).
- **Post view** (`note_post` with a new `detail` variant): full body, all files (no
  "+n more"), full timestamp, edited-by line in the History toggle, chips for subject and
  links, visibility pill. Shown to everyone who can read the note.
- **Actions**: ✎ Edit and 📎 Attach when `can_edit`; `⋯` menu with Delete when
  `can_delete` (confirm dialog, as today).
- **Edit mode**: the post area is replaced by the write box in `:edit` mode — title
  input, body, `about…` (subject) chip, link chips with ✕ and "+ link a record", the
  visibility pills, Cancel / Save. Links on a saved note still apply immediately; title,
  body, subject and visibility save with Save. Stale save keeps the text and shows
  "someone else changed this note — reload to see their version".
- **History ▸**: expands below the post (version, who, when, field before/after) —
  same data and per-version filtering as today.
- **Replies**: the record notes panel rendered in a `thread` layout (no card frame, no
  header; the write box always open as "Post your reply…"), listing notes about or
  linking to this note with `note_post`.
- **New note** (`/notes/new`, incl. `?subject_type=&subject_id=` prefill): the column with
  "← New note" and the write box in `:new` mode, full size (title + links available).
  Post → the new note's page. Files are attached after the first save (unchanged).

## 4. Components

### `NoteLive.ComposerComponent` (new LiveComponent — the one write box)

Extracted from the feed's inline post box. Owns its own form state, so hosts stop
duplicating it.

| attr | meaning |
|---|---|
| `id` | unique; prefixes every input id (two boxes can share a page) |
| `mode` | `:new` · `:edit` · `:reply` |
| `note` | the note being edited (`:edit`) |
| `subject` | initial subject `%{type, id, title}` (`:new` prefill) |
| `fixed_subject` | `{type, id}` the note must be about (`:reply`, record panels) — no `about…` chip |
| `full` | show title input and links (`:new` page and `:edit`); the feed and replies are compact |
| `default_visibility` | e.g. Private for task panels |
| `roles` | false hides role chips (task panels, per the tasks skill) |
| `placeholder`, `submit_label` | "Write a note…" / "Post your reply…"; "Post" / "Reply" / "Save" |

Behaviour: validate on change; Everyone / Private / roles pills (folded by default, as
in the feed); subject picker and link picker (`RecordPickerComponent`); on submit it calls
`Notes.create_note/3` or `Notes.update_note/4` itself and tells the host
`{:note_saved, mode, note}` (or `{:note_edit_cancelled}`); errors render inside the box.
After a post it clears itself (the `compose_rev` trick stays inside the component).

### `note_post/1` — `detail` variant
`detail` attr: larger body, no `line-clamp`, all files, no link wrapping the body, and an
`actions` slot for Edit / ⋯ / Attach / History. The feed and panels are unchanged.

### `NotesPanelComponent` — `layout`
`layout: :card` (default, record pages, unchanged look) or `:thread` (note page). Both use
the composer for quick-add instead of the panel's own form.

### Hosts
- `NoteLive.Index` (feed): its inline post box and the `compose_*` handlers are replaced by
  the composer; it stream-inserts on `{:note_saved, :new, note}` as today.
- `NoteLive.Form` (note page): rewritten to the layout above; keeps the module name and
  routes (`/notes/new`, `/notes/:id`, `/notes/:id/edit`). `/notes/:id/edit` opens in edit
  mode when the user may edit; `/notes/:id` opens the post view.
- `Linkable.url("Note", …)` and `note_post`'s link point at `/notes/:id` (view), not
  `/edit`.

## 5. Unchanged contracts

`Notes.visible_to/3` and every read path; versions (`update_note/4` snapshot + stale);
attachments over plain HTTP (`NoteAttachmentController`, `note_attach.js`, the
`note-attach:done` hand-off to the element carrying the button id); link add/remove;
rights (`can_edit?` / `can_delete?`); task-panel Private default and no role chips; record
chips (`record_chip/1`, 20rem cap); input-id uniqueness (every box prefixes ids).

## 6. Testing

- Composer: create / edit / reply modes; validation errors shown; stale edit keeps text;
  fixed subject cannot be changed; `roles: false` hides role chips; two composers on one
  page have distinct input ids.
- Note page: post view for a reader (no Edit); Edit → write box prefilled → Save shows the
  post with the new text and writes one version; Cancel discards; Delete via ⋯; History
  toggle lists versions with the per-version filter; Attach still uploads (controller test
  unchanged); reply box posts a note about this note and it appears in the thread;
  `/notes/:id/edit` opens in edit mode for an editor and view mode for a reader;
  `/notes/new?subject_type=…` prefills.
- Feed: post box still posts, sets subject and visibility (existing tests keep passing
  with updated ids where the box's ids change).
- Record panels: quick-add still works on Contact / Employee / Invoice pages; task panel
  still defaults to Private with no role chips.
- Both themes checked in the browser.

## 7. Out of scope

Feed layout changes beyond swapping in the composer; Markdown; mentions; likes; editing
replies inline in the thread (open the reply's own page).
