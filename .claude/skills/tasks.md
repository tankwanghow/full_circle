---
name: tasks
description: Use when working on FullCircle Tasks — recurring duties, job tracking, todos: the tasks table, Tasks.visible_to, Done/Skip/Reopen and next-cycle rules, the Tasks list/page, the sticky nav badge, or task progress notes.
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

## Progress notes
Notes with `subject_type "Task"`. `Notes.visible_to/3` lets anyone who can see the task read them. `list_versions/3` applies the task rule **per version**, using each version's own `subject_type`/`subject_id` (not the note's current subject), so re-pointing a restricted note at a task never exposes its old text. The notes panel defaults to Private on a task (= the task's people). Closing notes are Private.

## Close / reopen
- `close_task/5` locks the row (`FOR UPDATE`), adds the closing note, stamps, and inserts the next cycle with copied fields and record_links. Second close → `{:error, :already_closed}`. If an open, non-deleted cycle with the stepped due date already exists in the same series, it is reused instead of inserting a duplicate.
- `next_due_date/3` steps from the old due date; months clamp and **month-end stays month-end**; years keep the day (29 Feb → 28 Feb).
- `reopen_task/3` runs in one transaction with `FOR UPDATE` on the task and on the next cycle. It deletes the spawned next cycle only if untouched: open, `lock_version` 0, no notes, AND no record_links added after the cycle was created (copied links are stamped with the cycle's own `inserted_at`; `add_link` does not bump `lock_version`). Otherwise it keeps it (`next_kept: true`). Reopening an open task → `{:error, :open}`.
- Closed tasks cannot be edited (`{:error, :closed}`); `add_link/5` and `remove_link/4` also return `{:error, :closed}` on a closed task.
- `TaskLive.Index` and `TaskLive.Form` ignore a `confirm_close` event when no dialog is open (double submit).

## Lists and badge
- Groups: overdue (`< today`), due soon (`= today` or within `reminder_before_days`), upcoming, someday; `group_of/2` and the SQL CASE in `state/3` must stay twins.
- "Mine" = assigned to me, or unassigned and created by me. Badge = mine ∧ open ∧ (overdue ∨ due soon). "Today" = `Tasks.today(company)` (company timezone).
- List rows carry the latest visible note and note count — one query each per page.

## Nav badge
Root layout is not re-rendered on live navigation, so the badge is a sticky nested LiveView (`TaskLive.NavBadge`) subscribed to `Tasks.topic(company_id)`; every write broadcasts `{:tasks_changed, company_id}`. `live_render` from a conn ignores `:id` (the container gets a generated id); stickiness still holds because the root layout is not re-rendered. Tests assert the link id `full_circle_tasks` and use `live_isolated/3`.
