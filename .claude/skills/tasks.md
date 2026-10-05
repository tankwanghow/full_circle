---
name: tasks
description: Use when working on FullCircle Tasks — recurring duties, job tracking, todos: the tasks table, Tasks.visible_to, Done/Skip/Reopen and next-cycle rules, the Tasks list/page, the sticky nav badge, task progress notes, or the tasks panel beside notes on a record page.
---

# Tasks — contract

Spec: `docs/superpowers/specs/2026-10-01-tasks-design.md`.

## Model
- Schema `FullCircle.Tasks.CompanyTask` (never alias it `Task` — shadows `Elixir.Task`); Linkable type `"Task"`.
- One row per cycle; cycles share `series_id` (first cycle's id). `lock_version` 0 = never edited.
- Repeat needs a due date (changeset + `tasks_recurrence` check). No unit → `recur_every` forced nil.

## Visibility
`Tasks.visible_to/3` is the only read gate: notes-style chips (nil Everyone, `["admin"]` Private, roles) **plus creator and assignee always**. Rights: `rights/2` once, then `may_edit?` (creator with :create_task, or :edit_others_task), `may_close?` (:create_task — so the assignee closes), `may_reopen?/3` (creator holding :create_task, or :edit_others_task).
`search_titles/3` (command palette) lists open cycles first, then by due date.

## Progress notes (UI: "Progress")

In the UI a task's notes are called **Progress** (UI wording only; they are
Notes about the task). The notes panel picks the words from `record_type ==
"Task"`: heading "📝 Progress", "＋ Progress", "No progress yet.", placeholder
"Write progress…"; the close dialog's box reads "Progress (optional)"; 📝
counts carry a "Progress" tooltip. In the notes feed (and any panel other
than the task's own) a note about a task wears the Tasks amber
(`.note-progress`: `#f59e0b` inset bar, amber tint; no ✅ tick since 2026-10-05).

Notes with `subject_type "Task"`. `Notes.visible_to/3` lets anyone who can see the task read them. `list_versions/3` applies the task rule **per version**, using each version's own `subject_type`/`subject_id` (not the note's current subject), so re-pointing a restricted note at a task never exposes its old text.
A task note does not ask for a visibility role. `Notes.create_note/3` and `update_note/4` copy the task's `visibility` onto the note (`follow_task_visibility/2`), including a closing note; any `visibility` the client sends is overridden. Changing the task's visibility updates those notes (`sync_task_note_visibility/3`, no new note version) — only the task's own live notes in its company.
**No race, no partial write:** `update_task/4` runs the task UPDATE and the note sync in one `Multi` (a failed sync rolls the task back; `{:error, :stale}` still comes from the `StaleEntryError` rescue). The note write reads the task's visibility inside its own transaction with `FOR SHARE`, which conflicts with the task UPDATE's row lock, so a note written while the task narrows either waits and copies the new value or commits first and is caught by the sync. **Lock order: task row, then its notes.** `update_note/4` takes the task `FOR SHARE` *before* `snapshot`'s `FOR UPDATE` on the note; the reverse order deadlocks (40P01) against `update_task/4`. Any composer whose subject is a Task hides the chips, including the task panel and the full note form. Other record types keep Everyone, Private and the role chips.

## Close / reopen
- `close_task/5` locks the row (`FOR UPDATE`), adds the closing note, stamps, and picks the next cycle. Second close → `{:error, :already_closed}`.
- **Spawn/reuse rule** (`spawn_next`, via `later_cycle/3`): if the series already has any other non-deleted cycle due **after** the closed one, nothing is inserted — the earliest later **open** cycle is reused and returned as `next`; if every later cycle is closed, `next` is nil. Only when no later cycle exists is a new one inserted (copied fields + record_links). So re-closing a reopened old cycle, even after editing its due date, never yields a second open cycle in the series.
- `next_due_date/3` steps from the old due date; months clamp and **month-end stays month-end**; years keep the day (29 Feb → 28 Feb).
- `reopen_task/3` runs in one transaction with `FOR UPDATE` on the task and on the next cycle. The next cycle (`spawned_next`) is the series' earliest non-deleted cycle due after the task, **whatever its status** (ordered due_date, inserted_at, id). It is deleted only when it was **created by this close** (`inserted_at >= closed_at` of the locked row — a reused older cycle never qualifies) AND untouched: open, `lock_version` 0, no notes, no record_links added after the cycle was created (copied links are stamped with the cycle's own `inserted_at`; `add_link` does not bump `lock_version`). Otherwise it stays and the result says `next_kept: true` — also when it is a reused cycle or a later closed one. No later cycle → `next_kept: false`. Reopening an open task → `{:error, :open}` (the page flashes "This task is already open." and reloads).
- Closed tasks cannot be edited or deleted (`{:error, :closed}` from `update_task`, `delete_task`); `add_link/5` and `remove_link/4` also return `{:error, :closed}` on a closed task. The page hides Delete on a closed task; a stale page gets a flash and reloads.
- After close/reopen the page reloads through `get_task`; a nil (deleted / no longer visible) leaves for the list with "Task not found." instead of crashing.
- The assignee select always keeps the task's current assignee as an option, even when they can no longer be assigned (demoted), so a save never silently unassigns them (`validate_assignee` only checks a *changed* assignee).
- `TaskLive.Index` and `TaskLive.Form` ignore a `confirm_close` event when no dialog is open (double submit).

## Lists and badge
- Groups: overdue (`< today`), due soon (`= today` or within `reminder_before_days`), upcoming, someday; `group_of/2` and the SQL CASE in `state/3` must stay twins.
- "Mine" = assigned to me, or unassigned and created by me. Due counts = open ∧ (overdue ∨ due soon), from `Tasks.badge_counts/3` as `%{all, mine}` in one query (`mine` is a `filter(count)` twin of `scope/3`, so keep them in step). The nav badge shows `all`; each tab shows its own count (`#tab-all-count`, `#tab-mine-count`, hidden at 0), recounted on every list load including `{:tasks_changed, _}`. "Today" = `Tasks.today(company)` (company timezone).
- List rows carry the latest visible note, the note count and the record-link count — one query each per page.
- "Done & skipped" rows (`search[state]=closed`) have no group headings. The row text includes Done or Skipped and the closed date in the company timezone (`dd-mm-yyyy`); ordered `closed_at desc, title, id`.
- The task page's "Other cycles" shows 📝 n per cycle from one `Notes.count_by_records/4` call.

## List and task page
The column is Notes' `max-w-xl` plus 15% (`max-w-[41.4rem]`), with an amber top bar and amber tab underline (`#f59e0b`) where Notes uses sky blue, and a due tile where a note has a person avatar. All | Mine are tabs; the list opens on **All** (`list_tasks/4` also defaults to `"all"`), because "Mine" leaves out unassigned tasks other people created, so a fresh list looked empty to everyone but the creator. The nav link goes to the plain list (All), matching its badge. Quick-add (`#task-compose`, creators only) is a title, an optional due date and Everyone or Private (`["admin"]`); a save error shows under its title (`#task-compose-error`, not a flash) and clears on typing. `#new_task` ("Full form") still opens `/tasks/new`. Search merges into the current scope and state, so a terms-only change does not drop Mine/All. Each search word must match (AND) the title, descriptions, assignee email, or a **linked record's name** — same rules as note search (`Linkable.matching_refs/4`: record names, document numbers and contact names, task/note titles only when the searcher may see them; see notes.md "Search"). Read at search time from `record_links`, nothing copied.

`:edit` opens on the post (`#task-post`): due tile, title, description, record chips, ✎ Edit. Edit, `:new` and `:copy` keep that same post and turn the lines into fields (`#task-form`, `TaskFormComponent`), with no due tile (the form is all fields, Due among them): assignee and Due date on the "assigned to" line, title and description as the big text, documents after "Task expects:", then "Repeat [every N] [unit] · Remind days before" (the every-N span is `hidden` while the unit is never, never also `inline-flex`), then the visibility chips. The list row and the post share their lines from `TaskComponents`: `people_line/1` above the title, `rhythm/1` ("Repeat every 2 months · reminder 14 days · Everyone") after the description and "Task expects:". The list row follows the post's order, each line truncated; people, title, description and rhythm are one link to the task page: people, title, description, rhythm (no Task expects), then the latest progress note as a sky quote (left border, italic) above the 📝 / 🔗 row. Save and Cancel belong to `TaskFormComponent` (zinc and gray pills on its 📝 / 🔗 row; the page adds Back on new/copy through its `:actions` slot). The post's own buttons are `action_row/1`: Copy, Back, Delete and ✎ Edit in one group; Done, Skip and Reopen in the other; `gap-7` between the groups, right-aligned on the 📝 / 🔗 row. They are one outline pill (`pill/1`: `rounded-full border px-3 py-0.5 text-sm`). Only the color differs: zinc Save, gray Cancel/Copy/Edit, amber Back/Reopen, red Delete. Done and Skip share one `w-20` box (`close_pill/1`) and are not that outline: Done is a filled green pill, Skip a filled gray pill. Both hide while `@editing`, and so do Copy, Back (`#back-task`) and Delete. The header ← stays. Save and Cancel remain. They do not use the `.button` class. `#delete-task` and `#done-task` are on the first render when the user may edit and close. An assignee who cannot edit sees the post, Done and Skip, and no Edit, form or Delete. Progress stays the notes panel (`#task-notes`), headed "📝 Progress", rendered `flush` (no card border or rounding: the page column already draws the lines).

## Nav badge
Root layout is not re-rendered on live navigation, so the badge is a sticky nested LiveView (`TaskLive.NavBadge`) subscribed to `Tasks.topic(company_id)`; every write broadcasts `{:tasks_changed, company_id}`. `live_render` from a conn ignores `:id` (the container gets a generated id); stickiness still holds because the root layout is not re-rendered. Tests assert the link id `full_circle_tasks` and use `live_isolated/3`.

## On a record page
`Tasks.for_record/4` is the only read of "tasks linked to this record": it
composes `visible_to/3` and joins `record_links` (`from_type "Task"`,
`to_type`/`to_id` the record). Open cycles first, then due date (undated
last). A hidden task is absent.

`TaskLive.TasksPanelComponent` (`id="tasks-panel"`) renders that list inside
`RecordAside` (see `.claude/skills/notes.md`), to the right of the notes
panel. Rows come from `Tasks.rows/4` (shared with `list_tasks/4`) and render
with `TaskComponents.task_row/1`, the Tasks list's row, with `new_tab`: each
opens the task in a new tab. The row is `data-post-open` and its text link
`data-post-link`, so a click on empty space opens the task
(`assets/js/post_open.js`, shared with note posts; see `.claude/skills/notes.md`).
Dialogs and the in-place edit form must stay *outside* the `<article>`, or mark
them `data-no-post-open`. Rows carry `can_close` / `can_edit`; the row's
`:actions` slot shows ✓ Done / Skip (`close_buttons/1` with `target`, shared
with the Tasks list) and ✎ Edit. The panel owns its own `close_dialog/1`
(`target={@myself}`): open_close → confirm_close → `Tasks.close_task/5`, then
reload. A fixed overlay inside the `@container` aside still covers the
viewport (checked in Chrome), so no portal; LiveViewTest cannot see inside a
`<.portal>` template anyway. ＋ Task opens the full
task form in place (`TaskFormComponent`, id `tasks-panel-new-task`); ✎ Edit
(`tasks-panel-edit-<id>`, open tasks the viewer may edit) swaps the row for it
(id `tasks-panel-edit`, inside `#tasks-panel-editing`). Both pass
`host: {type, id}`: create always adds the link to this record and the form
hides that record's chip (✕ would drop the task from this page). There is no
"Full form" link; `/tasks/new?link_type=&link_id=` still works and prefills
the chip. A task's progress stays on the task page (decided 2026-10-03): the
row shows the latest progress as a quote and the 📝 count only.

## Task write box: `TaskFormComponent`
`TaskLive.TaskFormComponent` is the only task form: the task page's
new/copy/edit (`id="task"`, so `#task-form`) and the panel. It owns the
changeset, links (queued on `:new`, saved at once on `:edit`), its picker
(`#{id}-picker`, notify `{TaskFormComponent, id}`), and saves through `Tasks`.
It tells the host `{:task_form, id, event}` (`notify: :liveview`) or
`send_update(module, id: cid, task_form: {id, event})`; events are
`{:saved, mode, task}`, `:cancelled`, `:links_changed`. Errors (stale,
closed, missing link) show inline in `#{id}-error`, under the record chips,
and clear on the next edit. Field errors sit under their own row via
`NoteComponents.field_errors/1`, only once that field is touched or saved
(`used_input?`): `#{id}-due-errors` (assignee, Due), `-title-errors`,
`-descriptions-errors`, `-documents-errors`, `-repeat-errors` (Repeat, every,
Remind) and `-visibility-errors`; a row of several inputs names the field
("Due: is needed to repeat"). Due's error also shows once Repeat is touched,
since picking a repeat causes it. The task page navigates
on `{:saved, :new, _}` after the message, so tests use `assert_redirect/1`
instead of matching `render_submit`'s result. Slots: `:footer` (📝 / 🔗
counts), `:actions` (the page's Back on new/copy). It resets when the host
passes another task or a newer `lock_version`.

**Live refresh.** Every host that renders `record_aside/1` declares
`on_mount {FullCircleWeb.RecordAside, :refresh_tasks_panel}`. That hook
subscribes the page to `Tasks.topic/1` and attaches a `:handle_info` hook that
turns `{:tasks_changed, _}` into `send_update(TasksPanelComponent, id:
"tasks-panel", refresh: true)` and halts, so a task made in another tab or by
another user appears without a reload, and the host needs no `handle_info`
clause. A component cannot subscribe for itself (it shares the host process)
and a global live_session hook would steal the message from pages that handle
it (`TaskLive.Index`). So it is opt-in per host. **A new host must add the
`on_mount` line.** With no panel rendered (`:new`), the `send_update` is a
logged no-op.

## Copy
`/tasks/:task_id/copy` (`TaskLive.Form`, `:copy`) is the `:new` path pre-filled by `copy_of/2` (title, descriptions, due date kept as-is, repeat, reminder, documents, assignee, visibility). Links, notes, cycles, series and status are NOT copied: a copy is its own series (`create_task/3`), made for per-item duties (road tax per lorry). The `#copy-task` button shows on the post (`:edit`, not while `@editing`) for anyone with `:create_task`, for open and closed cycles. An assignee who is no longer assignable is dropped on copy (the "keep demoted assignee" option rule is `:edit` only, since `assignee_options/2` keys on a loaded `task.assignee`).
