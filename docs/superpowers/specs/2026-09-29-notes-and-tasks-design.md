# Notes & Tasks in FullCircle — Design

Date: 2026-09-29
Status: sub-project 1 (Foundation + Notes) specified in full; sub-projects 2–5 are
a roadmap only, each gets its own spec.

Supersedes every earlier Tugas spec/plan in `docs/superpowers/` and the
backend-only `FullCircle.Tugas` merged 2026-09-16.

## 1. Intent

A company-wide **memory and to-do system** inside FullCircle, replacing the
separate Tugas app (which is retired; **no data is migrated**).

It serves four uses, all confirmed:

1. **Decisions about people** — appraisal, bonus, warnings: management reviews
   the history of supervisor comments and skill notes on an employee.
2. **Customer dealings** — before calling, visiting or giving credit, check past
   engagement notes on a customer or supplier.
3. **Handover / memory** — knowledge stays with the company when staff leave.
4. **Finding who can do X** — search across notes ("which foreman can weld",
   "which customer pays late").

Plus a **company-wide calendar of tasks** (reminders and todos in one model)
that surfaces what is due, in-app only.

Success: a user can write a note about any employee, contact, document or
nothing at all; restrict who reads it by role; find it again by search or from
the record's own page; and see every past version of it.

## 2. Roadmap (sub-projects, build order)

| # | Sub-project | Delivers |
|---|---|---|
| 1 | **Foundation + Notes** (this spec) | Remove old Tugas backend; Linkable registry + `record_links`; Notes with visibility, versions, attachments, search; desktop UI; notes panel on every linkable record page + counts on index pages |
| 2 | Tasks | Task model (below), My Tasks, nav badge, task timeline of notes |
| 3 | Calendar | Tasks by due date + existing HR holidays |
| 4 | Mobile app | A native phone app for the Tasks side (and notes on tasks), talking to FullCircle over a token-authenticated API. **No web mobile UI** — the web pages stay desktop-first (decided 2026-09-29) |
| 5 | Voice-todo API | Token-authenticated JSON API; the voice app creates Tasks |

### Task model — agreed, built in sub-project 2

Recorded here so it is not lost; sub-project 2's spec refines it.

- One model for both reminders and todos: `title`, `descriptions`, optional
  `due_date` (nil = "someday").
- Optional recurrence (`recur_unit` day|week|month|year + `recur_every`),
  requires a `due_date`. Completing a cycle spawns the next; month/year clamp
  to month end (31 Jan + 1 month → 28 Feb).
- `reminder_before_days` (optional integer): a dated task is **due soon** from
  `due_date - reminder_before_days`. Blank = surfaces only when due/overdue.
  Copied to each spawned cycle.
- Optional single assignee. No collaborators.
- `documents_needed` (free text): a **soft** prompt shown on completion
  ("this task expects: …"). Never blocks completion.
- Done or skip. **Many notes at any time** (progress notes); they form the
  task's timeline; the completion note is simply the last one.
- Links to any records via `record_links`.
- Visibility: creator, assignee, admin, manager. **Unassigned → whole company.**
- Reminders are in-app only: My Tasks (overdue & due-soon first) and a nav badge
  = count of *my visible* tasks overdue or due soon. No jobs, no email, no push.
- No urgency tiers.

## 3. Sub-project 1 scope

In:

- Remove `FullCircle.Tugas` (context, 4 schemas, tests, authorization clauses,
  `.claude/skills/tugas-duties.md`) and BillPay's `opts[:duty_id]` /
  `maybe_link_duty`. A migration drops `duty_event_documents`,
  `duty_documents`, `duty_events`, `duties` (they hold no data we keep).
- `FullCircle.Linkable` — registry of linkable record types + `record_links`.
- `FullCircle.Notes` — notes, versions, attachments, visibility, search.
- Desktop LiveViews: notes index/search, note form, note show (with history),
  and a reusable notes panel on every linkable record's edit page plus a
  notes count on its index page (§8).
- Attachment upload/download over plain HTTP controllers.

Out (later or never): tasks, calendar, mobile, API, Markdown rendering, note
categories/tags, email/push.

## 4. Data model

All tables `binary_id` PKs via `FullCircle.Schema`, `company_id` NOT NULL with
`on_delete: :delete_all`, `timestamps(type: :utc_datetime)`.

### `notes`

| column | type | notes |
|---|---|---|
| company_id | FK companies | |
| title | string(120), nullable | optional; lists fall back to the body's first line |
| body | text, NOT NULL | plain text, line breaks preserved |
| subject_type | string, nullable | a Linkable type key, e.g. `"Employee"` |
| subject_id | binary_id, nullable | both subject columns nil or both set (check constraint) |
| visibility | `{:array, :string}`, nullable | nil = public; else FullCircle role names |
| author_id | FK users | |
| updated_by_id | FK users | last editor |
| lock_version | integer | optimistic locking (see `optimistic-locking.md`) |
| deleted_at / deleted_by_id | nullable | soft delete; versions kept |

Indexes: `(company_id, subject_type, subject_id)`, `(company_id, inserted_at)`,
GIN `gin_trgm_ops` on `title` and `body`.

### `note_versions`

A snapshot of the note **before** each edit (and before delete), so the current
row plus its versions is the full history.

| column | type |
|---|---|
| note_id | FK notes, `on_delete: :delete_all` |
| version | integer, unique per note (1, 2, …) |
| title, body, subject_type, subject_id, visibility | as on notes |
| edited_by_id | FK users — who made the change that superseded this version |
| inserted_at | `:utc_datetime_usec` — several writes can share a second |

### `note_attachments`

| column | type | notes |
|---|---|---|
| company_id, note_id | FKs | |
| file_name | string | original name, display only |
| content_type | string | **sniffed from magic bytes**, never the client claim |
| byte_size | integer | |
| path | string | relative to `:uploads_dir`: `<company_id>/notes/<note_id>/<uuid><ext>` |
| uploaded_by_id | FK users | |
| removed_at / removed_by_id | nullable | removing hides it; the file is kept so history stays true |

Allowlist: `image/jpeg image/png image/webp application/pdf`; max 10_000_000
bytes, checked with `File.stat/1` before any read. Ported from the removed
`Tugas.attach_evidence/4` including orphan-file cleanup when the insert fails.

### `record_links`

A link between two records, stored once and queried from either side.

| column | type |
|---|---|
| company_id | FK |
| from_type, from_id | Linkable key + id (the side that created the link, e.g. `"Note"`) |
| to_type, to_id | Linkable key + id |
| created_by_id | FK users |

Unique `(company_id, from_type, from_id, to_type, to_id)`; indexes on both
`(company_id, from_type, from_id)` and `(company_id, to_type, to_id)` so
backlinks ("what links here") are one indexed query. No FKs on the ids — the
Linkable registry is the whitelist that keeps them honest (same reasoning as the
removed `duty_documents`).

## 5. Linkable registry

`FullCircle.Linkable` — the single place that knows what "any FullCircle record"
means. Each entry:

```elixir
%{
  type: "Employee",              # stored key
  label: "Employee",             # UI label (gettext)
  view_action: :view_employee,   # can?/3 action the viewer must pass
  get: fn company, user, id -> {:ok, %{id:, title:, subtitle:}} | :not_found end,
  search: fn company, user, terms -> [%{id:, title:, subtitle:}] end,
  url: fn company, id -> "/companies/#{company.id}/employees/#{id}/edit" end
}
```

Initial types: `Employee`, `Contact`, `Good`, `Note`, and the posted
documents already in `CommandPalette.Types` (Invoice, PurInvoice, Receipt,
Payment, CreditNote, DebitNote, Journal, Deposit, ReturnCheque) whose search
reuses `CommandPalette.DocNoSearch` and whose `view_action` reuses the palette's
per-type authorization. Adding a type later (Task in sub-project 2, PaySlip,
Trading docs, Weighing, …) is one registry entry — nothing else changes.

Rules:

- Writing a subject or link validates the type against the registry **and**
  resolves the id in the current company via `get` — an unknown type or a
  foreign/missing id is a changeset error.
- Rendering a link calls `get`; a target deleted since shows as
  "(deleted Invoice)" rather than crashing or disappearing.
- A user who fails the target's `view_action` sees the link as
  "Restricted record", not its title.

## 6. Visibility & authorization

### Note visibility

`visibility` is `nil` (public: every user with access to the company) or a
non-empty list drawn from `Authorization.roles/0` minus `disable`. An empty list
is a changeset error — use `nil`.

A user may read a note when **any** of:

- `visibility` is nil, or
- their role in this company is in `visibility`, or
- their role is `admin`, or
- they are the note's author.

This is one composable query function, `Notes.visible_to(query, company, user)`,
and **every** read path goes through it: index, search, subject panel, note
show, backlinks, versions, attachment download. A restricted note linked from
something public is simply absent for users outside its list.

Versions: a user who can read the current note can read all its versions. (A
version that was *narrower* than the current visibility is still shown — the
current visibility is the authority. Accepted.)

### Actions (new `can?/3` clauses, `allow_roles` style; no catch-all exists)

| action | roles |
|---|---|
| `:view_notes` | admin manager supervisor cashier clerk auditor |
| `:create_note` | admin manager supervisor cashier clerk |
| `:edit_others_note` / `:delete_others_note` | admin manager |

- Authors edit and delete their own notes (while they hold `:create_note`).
- Admin/manager may edit or delete another user's note **only if they can read
  it** under the visibility rule.
- `guest` and `disable` have no access; `auditor` is read-only.
- Attachments follow the note: add/remove = may edit the note; download = may
  read the note.

## 7. Behaviour

- **Create** — `Notes.create_note(attrs, links, company, user)`: one
  `Ecto.Multi` inserting the note and its `record_links`.
- **Edit** — `Notes.update_note(note, attrs, company, user)`: in one multi,
  insert a `note_versions` snapshot of the current row, then update with
  `lock_version` (`{:error, :stale}` on concurrent edit). A no-op edit returns
  `{:ok, note}` without writing a version.
- **Delete** — soft: snapshot a version, stamp `deleted_at/by`. Deleted notes
  vanish from every list; attachments stay on disk.
- **Links** — add/remove at any time by anyone who may edit the note; removing
  deletes the `record_links` row (the note's version history does not track
  links — accepted, links are navigation not record).
- **Search** — `Notes.search(company, user, terms, filters)` over title + body
  using the existing `similarity_order` / `ILIKE` pattern (escaping LIKE
  metacharacters), filters: subject type, subject, author, date range.
  Paginated with the same page/infinite-scroll mechanism existing FullCircle
  index pages use.
- Notes do **not** write `Sys.Log`; `note_versions` is their audit trail.

## 8. UI (desktop, FullCircle plain Tailwind — no daisyUI)

Routes under `/companies/:company_id`:

- `/notes` — `NoteLive.Index`: search box + filters, newest first, infinite
  scroll like other FullCircle indexes. Row: title/first line, subject chip,
  author, date, lock icon when restricted, paperclip when attachments.
- `/notes/new` (`?subject_type=&subject_id=` pre-fills) and
  `/notes/:id/edit` — `NoteLive.Form`: title, body textarea, subject picker
  (type select + registry search autocomplete), visibility ("Everyone" toggle,
  else role checkboxes), links picker, attachments.
- `/notes/:id` — `NoteLive.Show`: body, attachments, outgoing links, backlinks,
  and a collapsible version history (who, when, and a before/after of changed
  fields).
### Notes on every linkable record (chosen: mockups A + C, 2026-09-29)

One `NotesPanelComponent` (a `live_component`, given `record_type` +
`record_id`) is rendered in two hosts:

- **(A) Record edit page — panel under the form.** Every linkable type's edit
  LiveView renders the panel below its form. It lists, newest first, the
  visible notes **about** this record plus visible notes that **link to** it
  (marked "↩ linked"); restricted notes the viewer cannot read are simply
  absent. **+ Note** opens an inline quick-add (body, visibility; subject fixed
  to this record); after save the new note card offers 📎 attachment upload
  (attachments need a saved note — §8 below). A "Full form" link goes to
  `/notes/new?subject_type=&subject_id=` for title and links. Hidden on
  `:new` / `:copy` actions — an unsaved record has no id to attach to.
- **(C) Index pages — 📝 count per row.** Each linkable type's index row shows
  a 📝 count (or "—"). Clicking it opens the **same panel in a modal** over the
  list, so notes can be read and quick-added without opening the record.
  Counts are **visibility-aware** (a clerk's count excludes notes they cannot
  read) and come from **one grouped query per page**
  (`Notes.count_by_records(company, user, type, ids)`), never one per row.

Adding a new linkable type later = registry entry + one line in its form + one
column in its index.

First-release coverage: index + edit pages of Employee, Contact, Good,
Invoice, PurInvoice, Receipt, Payment, CreditNote, DebitNote, Journal,
Deposit, ReturnCheque. Pages that are not a simple edit form get the panel on
their equivalent detail page; any page where it does not fit is listed in the
implementation plan rather than skipped silently.
- Nav entry "Notes"; command-palette action `newnote`.
- Light and dark theme both checked.
- Gettext en + zh for all new strings.

### Attachments over plain HTTP

Uploads use a controller (`POST /companies/:company_id/notes/:note_id/attachments`)
driven by a small JS hook that opens a transient `<input type=file>` outside
LiveView's DOM and XHR-posts it; downscales images client-side; the server is
authoritative on type and size. Downloads go through
`GET /companies/:company_id/note_attachments/:id` which re-checks note
visibility. Reason: the Tugas app learned that LiveView socket uploads are lost
when a phone backgrounds the page during a camera pick; building it this way now
means the mobile app (sub-project 4) can post to the same endpoint. Attachments are added
after the note exists (the form saves first, then offers uploads).

## 9. Errors

- Unauthorized → `:not_authorise` (FullCircle convention); LiveViews redirect
  with a `:warn` flash (not `:warning` — it renders nothing).
- Visibility-denied reads → treated as not found (do not leak existence).
- Stale edit → form keeps the user's text and shows "someone else changed this
  note — reload to see their version".
- Unsupported / oversize attachment → per-file inline error, nothing written.

## 10. Testing

Context tests (`test/full_circle/notes_test.exs`, `linkable_test.exs`):

- visibility matrix: public / listed role / unlisted role / admin / author, on
  every read path including search, backlinks, versions, download;
- edit writes exactly one version; no-op writes none; stale edit returns
  `{:error, :stale}`;
- others-edit allowed only for admin/manager **who can read** the note;
- subject/link validation rejects unknown types and ids from another company;
- attachment sniffing, size limit, orphan cleanup, removed-but-kept;
- search escapes `%` and `_`.

LiveView tests for index search, form create/edit, show history, the panel
(inline on an edit page and as a modal from an index count, with counts
respecting visibility) on Employee, Contact and one document type (Invoice),
a smoke render of every covered index/edit page, and the upload/download controllers (auth + visibility).

The removal step must leave the suite green with the Tugas and BillPay
`duty_id` tests deleted.

## 11. Decisions made in brainstorming (for the record)

- Tugas app retired, start fresh, no migration.
- Heavy duties (required docs, collaborators, correction windows) dropped;
  replaced by Task + soft `documents_needed` + progress notes.
- Reminder and todo merged into one Task model.
- Notes: per-note role visibility (nil = public); no permission categories.
- Notes: free edit, full version history.
- Any record can be a subject or link target, via the registry.
- Managers = admin + manager. In-app reminders only. FullCircle styling.
  No web mobile UI; a native mobile app for Tasks after the web part. Voice API later.
