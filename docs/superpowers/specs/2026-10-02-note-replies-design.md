# Note replies — Design change

Date: 2026-10-02
Status: proposed (discussed in chat); awaiting user review.
Changes: how a reply to a note is stored. Builds on
`docs/superpowers/specs/2026-10-02-note-page-redesign-design.md` (the note page's reply
thread) and `.claude/skills/notes.md`. Notes are not deployed yet, so only dev data has
old-style replies.

## 1. Problem

Today a reply is just a note whose **subject is the parent note**
(`subject_type "Note"`, posted from the note page's thread with
`fixed_subject {"Note", parent_id}`). Its 💬 count and the thread come from
`Notes.count_by_records/4` / `notes_for_record/4` on `{"Note", parent_id}` — notes about
**or linking to** the parent. That has four costs:

1. **Replies vanish from the record's page.** A note has one subject. If the parent is
   about customer Ah Seng, the reply "paid in full 3/10" is about the *note*, so it does
   not show in Ah Seng's notes panel — the place people check before calling or giving
   credit.
2. **Visibility drifts.** A reply's visibility is chosen on its own: a manager-only
   parent can get an Everyone reply (clerks read an answer to a question they cannot
   see), or a reply narrower than its parent (readers see half a conversation).
3. **Unlimited nesting, shallow page.** Replies to replies are possible; the note page
   lists only direct replies, so deeper ones get lost.
4. **Replies and links are mixed.** A note that merely *links* to a note (a "quote")
   counts as a reply and sits in the thread.

## 2. Decisions

- A reply **takes its thread's subject**: it is about whatever the thread is about (a
  record, or nothing). It therefore shows on that record's page like any other note
  about it.
- A reply **points to its thread** with a new column `reply_to_id` (the root note).
  That — not the subject, not `record_links` — is what makes it a reply.
- A reply **follows its thread's visibility** (same rule the uncommitted work applies
  to task notes): set on save, kept in sync when the root's visibility changes. The
  writer does not pick roles on a reply.
- **One level deep.** Replying to a reply joins the same thread (`reply_to_id` = the
  root). The note page of a reply shows "↩ reply to <root>" and the whole thread.
- Links stay links: a note that links to a note is shown as a link chip / "↩ linked",
  never as a reply.
- Replies stay in the feed (user decision 2026-10-02: do not hide child notes), tagged
  "↩ reply to <root title>".

## 3. Data model

`notes.reply_to_id` — `binary_id`, nullable, FK `notes(id)` `on_delete: :nilify_all`
(roots are soft-deleted, so the FK only matters for hard deletes), index
`(company_id, reply_to_id)`.

Invariants (in `Note.changeset` + `Notes`):
- `reply_to_id` points to a **root** (a note whose own `reply_to_id` is nil) in the same
  company that the writer can read.
- A reply's `subject_type/subject_id` and `visibility` equal its root's at save time.
- A note cannot reply to itself.

## 4. Behaviour

- **Create a reply** — `Notes.create_note(%{"body" => …, "reply_to_id" => id}, …)`:
  resolve the target with `get_note/3` (visibility-checked); if it is itself a reply,
  use its root; copy the root's subject and visibility; ignore any subject/visibility
  sent by the client.
- **Edit a reply** — body/title/links editable; subject and visibility are not (the
  write box hides the about… chip and the visibility pills, showing "Visible to the same
  people as the note it replies to").
- **Edit a root** — when its subject or visibility changes, `update_note/4` updates all
  its live replies to match in the same transaction (one `update_all`, like task notes;
  replies' own version history is not written for this inherited change — document it).
- **Delete a root** — soft delete as today. Its replies are not deleted: they remain
  readable on their own pages and on the record's page (they are about the record), and
  their "↩ reply to" tag reads "↩ reply to a deleted note". Nothing new can reply to a
  deleted root.
- **Reads** — unchanged gate: `Notes.visible_to/3`. Since a reply's stored visibility
  equals its root's, no new rule is needed.
- **Counts / thread** —
  - `💬 n` on a post = live replies (`reply_to_id = note.id`), visibility applied; a new
    grouped query in `feed_details/3` replaces `count_by_records(…, "Note", ids)` for
    this count.
  - Note page thread = replies of the root, oldest first (a conversation reads down).
    Notes that link to the note stay as "↩ linked" chips/backlinks, not in the thread.
- **Record pages** — a reply about Ah Seng appears in Ah Seng's notes panel, tagged
  "↩ reply to …" (link to the thread).

## 5. UI (small, on top of the page redesign)

- Composer: new `reply_to` attr (`%Note{}` root) replaces `fixed_subject {"Note", id}` on
  the thread; in reply mode no about… chip and no visibility pills — a one-line
  "Visible to: <same as the note>" instead.
- `note_post/1`: a "↩ reply to <root title>" tag (link to the root) when
  `note.reply_to_id`; on the root's own page the tag is hidden for its replies.
- Note page of a reply: shows the root first (detail), then the thread, with the reply
  highlighted (scroll-to by DOM id).

## 6. Existing data

One data migration (dev only today; safe to run in prod once): for every live note with
`subject_type = "Note"` → `reply_to_id` = root of `subject_id` (follow up while the parent
is itself a reply), `subject_type/subject_id` = the root's, `visibility` = the root's.
Snapshot a `note_versions` row for each changed note first, so history shows the move.

## 7. Testing

- reply copies the root's subject and visibility, ignoring client-sent ones;
- reply to a reply attaches to the root;
- reply appears on the record's panel (about the record) and in the root's thread, and
  the root's 💬 count is replies only (a linking note does not count);
- root visibility/subject change updates its replies; a clerk never sees a reply to a
  manager-only root;
- self-reply refused; reply to an unreadable or other-company note refused;
- migration: old note-on-note rows become replies with the root's subject/visibility and
  a version snapshot;
- note page of a reply shows the root + thread; feed shows the "↩ reply to" tag.

## 8. Out of scope

Reply notifications; reactions; editing a reply's subject or visibility independently;
nested (multi-level) threads.
