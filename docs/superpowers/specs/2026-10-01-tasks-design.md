# Tasks in FullCircle — Design (Notes & Tasks sub-project 2)

Date: 2026-10-01
Status: approved in brainstorming; awaiting written-spec review.
Parent: `docs/superpowers/specs/2026-09-29-notes-and-tasks-design.md` (§2 roadmap
and agreed Task model). Builds on Notes (sub-project 1, `.claude/skills/notes.md`).

## 1. Intent

The "what is due" half of company memory. Uses, in priority order (user,
2026-10-01):

1. **Recurring duties** — road tax per lorry, EPF/SOCSO, LHDN, foreign worker
   permits, licences. Mostly fixed-calendar, repeating.
2. **Job tracking** — maintenance work, a licence renewal in progress: a
   timeline of progress notes with photos/PDFs until it is done.
3. **Todos and reminders** — one-off items, sometimes undated.

Success: nothing dated slips because the nav badge and the Tasks list surface
it before it is due; each cycle of a recurring duty keeps its own proof (notes,
attachments, who closed it, when).

### Decisions (brainstorming 2026-10-01)

- Per-item renewals are **one task per item, created by hand**, linked to its
  record (e.g. "Permit – Rahim" linked to the Employee). No templates, no
  dates derived from record fields.
- Job tracking = **progress notes only** (no status field, no checklist). The
  list shows each task's latest note.
- Next cycle date is stepped **from the old due date** (fixed calendar), never
  from the completion date. A one-off different date is an edit of that cycle.
- **One row per cycle** (approach A); rejected: a cycles child table (every read
  joins through it) and rolling one row forward (loses per-cycle history).
- Visibility uses **the same chips as notes** (creator picks roles); the
  assignee and creator always see the task.
- Assignee may only **Done, Skip and add notes** — not edit fields.
- **Reopen** by admin, manager or creator; the next cycle is removed only if
  untouched.
- First release surfaces: Tasks list, task page, nav badge. **Not** on record
  pages, dashboard or command palette (later).
- No task version history, no email/push, no urgency tiers, no collaborators
  (from the parent spec).

## 2. Scope

In: `tasks` table and `FullCircle.Tasks` context; `Task` as a Linkable type;
one added rule in `Notes.visible_to/3`; authorization actions; `/tasks` list,
task page, Done/Skip dialog, reopen; sticky nav badge; gettext en + zh.

Out: calendar (sub-project 3), mobile app (4), voice API (5), tasks panel on
record pages, dashboard tile, command palette search/actions, templates.

## 3. Data model

### `tasks` (one row per cycle)

`binary_id` PK via `FullCircle.Schema`; `company_id` NOT NULL
`on_delete: :delete_all`; `timestamps(type: :utc_datetime)`.

| column | type | notes |
|---|---|---|
| company_id | FK companies | |
| series_id | binary_id, NOT NULL | first cycle's own id; shared by every cycle of the series |
| title | string(120), NOT NULL | |
| descriptions | text, nullable | plain text |
| due_date | date, nullable | nil = "someday" |
| recur_unit | string, nullable | `day` `week` `month` `year` |
| recur_every | integer, nullable | ≥ 1; set iff `recur_unit` is set |
| reminder_before_days | integer, nullable | ≥ 0; due soon from `due_date - n` |
| documents_needed | text, nullable | soft prompt on close |
| assignee_id | FK users, nullable | must belong to the company |
| visibility | `{:array, :string}`, nullable | same values/rules as `notes.visibility` |
| status | string, NOT NULL default `open` | `open` `done` `skipped` |
| closed_at | utc_datetime, nullable | set iff status ≠ open |
| closed_by_id | FK users, nullable | |
| creator_id | FK users, NOT NULL | |
| lock_version | integer default 0 | optimistic locking; 0 = never edited |
| deleted_at / deleted_by_id | nullable | soft delete |

Check constraints:
- `recur_unit IS NULL OR (recur_every >= 1 AND due_date IS NOT NULL)` and
  `(recur_unit IS NULL) = (recur_every IS NULL)`
- `status = 'open' OR closed_at IS NOT NULL`
- `visibility IS NULL OR cardinality(visibility) > 0`

Indexes: `(company_id, status, due_date)`, `(company_id, assignee_id, status)`,
`(company_id, series_id)`, GIN `gin_trgm_ops` on `title`.

Progress notes are ordinary `notes` rows with `subject_type = "Task"`,
`subject_id = task.id`. Linked records are `record_links` rows with
`from_type = "Task"`.

## 4. Visibility & authorization

### Task visibility — `Tasks.visible_to(query, company, user)`

Company via `Sys.user_company/2`, `deleted_at IS NULL`, the user holds
`:view_tasks`, then any of:

- `visibility IS NULL` (Everyone), or the user's role is in `visibility`;
- the user's role is `admin`;
- the user is the creator;
- the user is the assignee.

Visibility values and chips are exactly the notes ones (`visibility_chips/1`:
Everyone · 🔒 Private · `Note.choosable_roles()`; Private stored as
`["admin"]`; normalised the same way). New tasks default to Everyone. Every
read — list, badge, task page, series cycles, Linkable resolve — composes
`Tasks.visible_to/3`. A task the user cannot see behaves as not found.

### Actions (new `can?/3` clauses, `allow_roles` style)

| action | roles |
|---|---|
| `:view_tasks` | admin manager supervisor cashier clerk auditor |
| `:create_task` | admin manager supervisor cashier clerk |
| `:edit_others_task` | admin manager |

Rights on a task the user can see:

| right | who |
|---|---|
| edit fields, delete | creator (holding `:create_task`), or `:edit_others_task` |
| Done / Skip, add progress notes | anyone who can see it and holds `:create_task` |
| reopen | creator, or `:edit_others_task` |

The assignee therefore closes and notes but does not edit. Auditor is
read-only; guest and disable have no access. Like `Notes.rights/2`, provide a
`Tasks.rights/2` taken once per page and pure `may_*?` checks per row.

### Progress-note visibility (change to Notes)

`Notes.visible_to/3` gains one allow-rule: a note with `subject_type = 'Task'`
is readable by anyone who can see that task (`subject_id IN` the
`Tasks.visible_to/3` ids). The note's own visibility can only widen access.
On a task, the notes panel's quick-add defaults to **Private**, which there
means "the people who can see this task (and admins)". The rule applies on
every Notes read path — feed, search, panel, counts, backlinks, attachment
download — and to `list_versions/3`'s per-version filter.

Superseded 2026-10-02: notes about a task store the task's visibility
(`follow_task_visibility`); see `.claude/skills/tasks.md`.

## 5. Behaviour — `FullCircle.Tasks`

- **`create_task(attrs, links, company, user)`** — `Ecto.Multi`: insert the
  task with `series_id` = its own id (generate the UUID first), then its
  `record_links`. Links validated through `Linkable` as notes do.
- **`update_task(task, attrs, company, user)`** — `optimistic_lock`;
  concurrent save → `{:error, :stale}`, form keeps the user's input. Only
  allowed for open tasks.
- **`close_task(task, :done | :skipped, closing_note, company, user)`** — one
  multi:
  1. `SELECT … FOR UPDATE` the row; status ≠ open → `{:error, :already_closed}`;
  2. if `closing_note` is non-blank, `Notes.create_note` with subject the task,
     Private visibility;
  3. stamp `status`, `closed_at`, `closed_by_id`;
  4. if `recur_unit` is set, insert the next cycle: same `series_id`, title,
     descriptions, recurrence, reminder, documents_needed, assignee,
     visibility, creator; `due_date = next_due_date(old, unit, every)`; copy the
     task's `record_links`.
  Returns `{:ok, %{closed: task, next: task | nil}}`.
- **`next_due_date(date, unit, every)`** — day/week add days; month/year use
  `Date.shift/2`-style month arithmetic clamped to month end (31 Jan + 1 month
  → 28/29 Feb; 29 Feb + 1 year → 28 Feb). Always from the old due date.
- **`reopen_task(task, company, user)`** — closed → open, clear `closed_*`.
  The next cycle (same series, `due_date = next_due_date(task)`, inserted by
  this close) is hard-deleted with its links if **untouched**: status open,
  `lock_version = 0`, no notes about it. Otherwise it stays and the result
  says so (`{:ok, %{reopened: task, next_kept: true}}`) for the flash.
- **`delete_task(task, company, user)`** — soft delete. Deleting the open cycle
  of a series ends the series; past cycles stay.
- **`list_tasks(company, user, filters, page)`** — filters `scope`
  (`:mine` | `:all`), `state` (`:open` | `:closed`), `terms` (title,
  descriptions, assignee name; LIKE metacharacters escaped). `:mine` =
  assigned to me, or unassigned and created by me. Open order: overdue, due
  soon, upcoming, someday, each by due date then title; closed order:
  `closed_at` desc. Each row carries its latest visible progress note
  (snippet + date) and note count, fetched for the whole page in one grouped
  query each — never per row.
- **`badge_count(company, user)`** — `:mine`, open, and overdue or due soon
  (`due_date <= today`, or `reminder_before_days` is set and
  `due_date - reminder_before_days <= today`; undated tasks never count), with
  "today" in the company's timezone. The list's Overdue / Due soon groups use
  the same rule.
- **`series_cycles(task, company, user)`** — other visible cycles of the
  series, newest first.
- After every write, broadcast `{:tasks_changed, company_id}` on
  `"#{company_id}_tasks"`.

## 6. Linkable

Add `"Task"` to the registry (title = task title, subtitle = due date ·
assignee). Resolve goes through `Tasks.visible_to/3`; a task the viewer cannot
see resolves `:restricted` ("Restricted record"), like `Note`. `type_label/1`
clause in `NoteComponents`. This lets notes link to tasks and the notes panel
run with `record_type: "Task"`.

## 7. UI (desktop, plain Tailwind, both themes)

### Nav badge

`✅ Tasks (n)` beside 📝 Notes in `root.html.heex`, shown with `:view_tasks`.
The root layout is not re-rendered on live navigation, so the link + count is
a **sticky nested LiveView** (`live_render(..., sticky: true)`,
`TaskLive.NavBadge`) that subscribes to `"#{company_id}_tasks"` and recounts
on `{:tasks_changed, _}`. No count shown when n = 0.

### `/companies/:company_id/tasks` — `TaskLive.Index`

Decluttered listing (`.claude/skills/decluttered-index.md`): `list_bar` with
search, Mine/All, Open/Done & skipped, and **+ New Task**; `list_table`.
Open tasks are grouped under thin headings **Overdue · Due soon · Upcoming ·
Someday**. Row: due cell (rose "12d late", amber "in 5d", else the date, "—"
for someday), title, ↻ repeat label ("yearly", "every 3 months"), assignee,
latest progress note as a muted one-line snippet (date in tooltip), 📝 count,
and Done / Skip buttons shown on row hover for users who may close. Infinite
scroll per the listing contract.

### `/tasks/new` and `/tasks/:id` — `TaskLive.Form`

No separate show page (as with notes). Fields: title, descriptions, due date,
repeat (unit select + every), remind N days before, documents needed, assignee
(select of company users), visibility chips, linked records
(`RecordPickerComponent`; queued until first save on a new task). Read-only
when the user may not edit; the assignee additionally sees Done / Skip.
Closed tasks show "Done by X on …" / "Skipped …" and Reopen when allowed.

Below the form: the notes panel (`record_type: "Task"`) as the progress
timeline, then **Past cycles** (due date, Done/Skipped, by, closed on, note
count, link) when the series has more than one cycle.

### Done / Skip dialog

Modal: "This task expects: *documents_needed*" when set; optional closing-note
textarea; for repeating tasks "Next cycle due *date*". Confirm calls
`close_task/5`; the task page then navigates to the next cycle (or stays on
the closed one for one-offs); the list removes the row and, if a next cycle
exists in view, inserts it.

## 8. Errors

- Unauthorised → `:not_authorise`; LiveViews redirect with a `:warn` flash
  (`:warning` renders nothing).
- Not visible → not found (no existence leak).
- Stale edit → keep input, "someone else changed this task — reload to see
  their version".
- `:already_closed` → flash and reload the task.
- Changeset errors: repeat without due date, `recur_every < 1`, assignee not in
  the company, empty visibility list, blank title.

## 9. Testing

Context (`test/full_circle/tasks_test.exs`):
- visibility matrix — Everyone / listed role / unlisted role / admin /
  creator / assignee — on `list_tasks`, `badge_count`, `series_cycles`, get,
  Linkable resolve;
- rights: assignee closes and notes but cannot edit; others-edit only admin /
  manager; auditor read-only;
- `next_due_date`: day, week, month clamp (31 Jan → 28 Feb and 29 Feb in a leap
  year), year from 29 Feb, `every` > 1;
- close: Done and Skip both spawn the next cycle with copied fields and links;
  one-off spawns nothing; closing note created; double close →
  `:already_closed`;
- reopen: untouched next cycle removed; edited or noted next cycle kept;
- badge: mine only, overdue + due soon, reminder window, timezone.

Notes (`test/full_circle/notes_test.exs` additions): a Private note on a task is
readable by the task's assignee and creator, not by others, across feed,
search, panel, counts, versions and attachment download.

LiveView: list grouping, filters and search; create/edit; read-only for
assignee with Done/Skip; Done dialog with documents-needed and closing note →
next cycle page; reopen; nav badge count changes after a close (PubSub);
smoke render. Light and dark themes checked by hand.

Gettext: append zh entries to `priv/gettext/zh/LC_MESSAGES/default.po`; do not
run `mix gettext.extract --merge` (see `notes.md`).
