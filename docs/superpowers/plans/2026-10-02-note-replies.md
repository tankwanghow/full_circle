# Note Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a reply a real thread member: it belongs to its root via `reply_to_id`, is about what the root is about, can be read by exactly the root's readers, and the note page keeps the root and the conversation in view while writing.

**Architecture:** A new `notes.reply_to_id` column (root only, one level). `Notes.create_note/3` / `update_note/4` copy the root's subject and visibility inside the save's transaction (lock order: task → root note → reply) and a root's save syncs its live replies in the same transaction. Reads add `Notes.thread/3` and reply-aware `feed_details/3`. The composer gets a `reply_to` mode; `note_post/1` shows "↩ reply to …"; the note page renders root card → earlier replies → this note → later replies → reply box → "Linked from". Old note-on-note rows are converted by `FullCircle.Notes.ReplyBackfill`, called from the migration.

**Tech Stack:** Elixir 1.19.5, Phoenix 1.8, LiveView 1.2, Ecto/PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-10-02-note-replies-design.md` (incl. "Context while writing"). Read `.claude/skills/notes.md` (Visibility, Versions, lock order, Composer, Note page) and `.claude/skills/tasks.md` (task notes follow the task) first.

## Global Constraints

- A reply's `reply_to_id` is always a **root** (a note with `reply_to_id = nil`) in the same company that the writer can read; replying to a reply attaches to that reply's root.
- A reply's `subject_type`, `subject_id` and `visibility` always equal its root's. The writer never chooses them; client-sent values are ignored on create and update; `reply_to_id` never changes after create.
- **Lock order everywhere: task row → root note → reply note.** `Notes.update_note/4` / `create_note/3` take the task `FOR SHARE` (existing `:task_visibility` step) first, then the root `FOR SHARE`, then the note `FOR UPDATE` (`snapshot/4`). A root's save updates its replies after locking the root. `Tasks.update_task/4` (task → its notes) stays as is and syncs replies of task notes automatically (they are about the task too).
- `Notes.visible_to/3` stays the only read gate; no new visibility rule.
- Replies stay in the feed (user decision) with a "↩ reply to …" tag; links stay links (a note linking to a note is never a reply and never counts in 💬).
- One level: no reply-to-reply chains are ever stored.
- UI: light and dark theme (decluttered-index dark-mode trap; use `dark:hover:bg-gray-700/60` inside `bg-white` containers).
- Never run bare `mix format`; format only touched files. New zh msgids appended by hand after checking absence; never `mix gettext.extract --merge`.
- **Never revert, `git checkout`, stash or delete files you did not change.**
- Commit on `master`; messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Root narrowed after a reply was written** — a manager-only root's replies must become manager-only too; the reply's author still reads their own reply (author rule) but sees "Replying to a note you can't see", never the root's text. Tested in Task 2 and Task 5.
2. **Root deleted** — replies stay readable on their own page and on the record's panel, tagged "↩ reply to a deleted note"; nobody can reply to a deleted root. Tested in Task 1 and Task 5.
3. **Forged `reply_to_id`** — another company's note, an unreadable note, or a non-UUID must be refused with a changeset error, never a crash. Tested in Task 1.
4. **Reply-to-reply chains in old data** — the backfill must attach every old note-on-note to the true root, survive a cycle, and snapshot a version first. Tested in Task 1.
5. **Editing a reply keeps context** — in edit mode the "Replying to" card, its History ▸ and the earlier replies stay on screen and toggling the root's history does not lose typed text. Tested in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `priv/repo/migrations/20261002130000_add_reply_to_to_notes.exs` (new) | column, index, call backfill |
| `lib/full_circle/notes/reply_backfill.ex` (new) | convert old note-on-note rows |
| `lib/full_circle/notes/note.ex` | `reply_to_id` field |
| `lib/full_circle/notes.ex` | reply rules on create/update, root→reply sync, `thread/3`, reply-aware `feed_details/3`, `root_of/3` |
| `lib/full_circle_web/live/note_live/composer_component.ex` | `reply_to` mode |
| `lib/full_circle_web/components/note_components.ex` | "↩ reply to …" tag in `note_post/1` |
| `lib/full_circle_web/live/note_live/form.ex` | note page: root card, thread around the note, reply box, Linked from |
| `lib/full_circle_web/live/note_live/notes_panel_component.ex` | remove the now-unused `:thread` layout |
| tests: `test/full_circle/notes_replies_test.exs` (new), `test/full_circle_web/live/note_composer_test.exs`, `note_live_test.exs`, `notes_panel_live_test.exs` |
| docs: `.claude/skills/notes.md`, zh `.po`, spec status line |

---

### Task 1: `reply_to_id`, reply rules on save, root→reply sync, backfill

**Files:**
- Create: `priv/repo/migrations/20261002130000_add_reply_to_to_notes.exs`
- Create: `lib/full_circle/notes/reply_backfill.ex`
- Modify: `lib/full_circle/notes/note.ex`, `lib/full_circle/notes.ex`
- Create: `test/full_circle/notes_replies_test.exs`

**Interfaces:**
- Produces:
  - `Note.reply_to_id` (`:binary_id`, nullable; `belongs_to :reply_to, Note`), castable.
  - `Notes.create_note(%{"body" => …, "reply_to_id" => id}, company, user)` → `{:ok, reply}` with root's subject/visibility and `reply_to_id = root.id`; `{:error, %Ecto.Changeset{}}` with `reply_to_id: ["can't be replied to"]` for an unknown / unreadable / deleted / other-company / malformed id.
  - `Notes.update_note/4` on a reply ignores `subject_type`, `subject_id`, `visibility`, `reply_to_id`; on a root, a change of subject or visibility updates all live replies (`reply_to_id = root.id`, `deleted_at IS NULL`) in the same transaction.
  - `FullCircle.Notes.ReplyBackfill.run(repo) :: {:ok, converted_count}`.

- [ ] **Step 1: Write the failing tests**

Create `test/full_circle/notes_replies_test.exs`:

```elixir
defmodule FullCircle.NotesRepliesTest do
  use FullCircle.DataCase, async: false

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures

  alias FullCircle.{Notes, Repo}
  alias FullCircle.Notes.{Note, NoteVersion, ReplyBackfill}

  setup do
    billing_setup()
  end

  defp reply(company, user, root, attrs \\ %{}) do
    Notes.create_note(Map.merge(%{"body" => "a reply", "reply_to_id" => root.id}, attrs), company, user)
  end

  describe "creating a reply" do
    test "copies the root's subject and visibility, ignoring the client's", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      root =
        note_fixture(company, admin, %{
          "body" => "root",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      other = contact_fixture(company, admin)

      {:ok, r} =
        reply(company, admin, root, %{
          "subject_type" => "Contact",
          "subject_id" => other.id,
          "visibility" => [""]
        })

      assert r.reply_to_id == root.id
      assert {r.subject_type, r.subject_id} == {"Contact", c.id}
      assert r.visibility == ["manager"]
    end

    test "a reply to a reply joins the root's thread", %{company: company, admin: admin} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, r1} = reply(company, admin, root)
      {:ok, r2} = reply(company, admin, r1)
      assert r2.reply_to_id == root.id
    end

    test "a reply to a task note follows the task", %{company: company, admin: admin} do
      task = task_fixture(company, admin, %{"visibility" => ["manager"]})
      root = note_fixture(company, admin, %{"body" => "progress", "subject_type" => "Task", "subject_id" => task.id})
      {:ok, r} = reply(company, admin, root)
      assert {r.subject_type, r.subject_id, r.visibility} == {"Task", task.id, ["manager"]}
    end

    test "refuses unknown, unreadable, deleted, other-company and malformed targets", %{
      company: company,
      admin: admin
    } do
      clerk = user_with_role(company, admin, "clerk")
      hidden = note_fixture(company, admin, %{"body" => "m", "visibility" => ["manager"]})
      gone = note_fixture(company, admin, %{"body" => "gone"})
      {:ok, _} = Notes.delete_note(gone, company, admin)
      other_company = FullCircle.SysFixtures.company_fixture(admin, %{})
      foreign = note_fixture(other_company, admin, %{"body" => "foreign"})

      for {user, id} <- [
            {clerk, hidden.id},
            {admin, gone.id},
            {admin, foreign.id},
            {admin, Ecto.UUID.generate()},
            {admin, "x"}
          ] do
        assert {:error, cs} =
                 Notes.create_note(%{"body" => "r", "reply_to_id" => id}, company, user)

        assert %{reply_to_id: ["can't be replied to"]} = errors_on(cs)
      end
    end
  end

  describe "editing" do
    test "a reply's subject, visibility and reply_to cannot be changed", %{
      company: company,
      admin: admin
    } do
      root = note_fixture(company, admin, %{"body" => "root", "visibility" => ["manager"]})
      other = note_fixture(company, admin, %{"body" => "other"})
      {:ok, r} = reply(company, admin, root)

      {:ok, r2} =
        Notes.update_note(
          r,
          %{"body" => "edited", "visibility" => [""], "reply_to_id" => other.id, "subject_type" => "Note", "subject_id" => other.id},
          company,
          admin
        )

      assert r2.body == "edited"
      assert r2.visibility == ["manager"]
      assert r2.reply_to_id == root.id
      assert r2.subject_id == nil
    end

    test "a root's subject/visibility change updates its live replies only", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, r1} = reply(company, admin, root)
      {:ok, r2} = reply(company, admin, root)
      {:ok, _} = Notes.delete_note(r2, company, admin)
      unrelated = note_fixture(company, admin, %{"body" => "unrelated"})

      {:ok, _} =
        Notes.update_note(
          root,
          %{"visibility" => ["manager"], "subject_type" => "Contact", "subject_id" => c.id},
          company,
          admin
        )

      r1 = Repo.get!(Note, r1.id)
      assert {r1.subject_type, r1.subject_id, r1.visibility} == {"Contact", c.id, ["manager"]}
      assert Repo.get!(Note, r2.id).visibility == nil
      assert Repo.get!(Note, unrelated.id).visibility == nil
    end

    test "narrowing a root hides its replies from those who lost the root", %{
      company: company,
      admin: admin
    } do
      clerk = user_with_role(company, admin, "clerk")
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, r} = reply(company, admin, root)
      assert Notes.can_read?(r, company, clerk)
      {:ok, _} = Notes.update_note(root, %{"visibility" => ["manager"]}, company, admin)
      refute Notes.can_read?(Repo.get!(Note, r.id), company, clerk)
    end
  end

  describe "ReplyBackfill" do
    test "turns old note-on-note rows into replies of the true root with a version first", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      root =
        note_fixture(company, admin, %{
          "body" => "root",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      # Old-style rows: subject is the parent note, no reply_to_id.
      old1 = Repo.insert!(%Note{company_id: company.id, author_id: admin.id, updated_by_id: admin.id, body: "old1", subject_type: "Note", subject_id: root.id})
      old2 = Repo.insert!(%Note{company_id: company.id, author_id: admin.id, updated_by_id: admin.id, body: "old2", subject_type: "Note", subject_id: old1.id})

      assert {:ok, 2} = ReplyBackfill.run(Repo)

      for old <- [old1, old2] do
        n = Repo.get!(Note, old.id)
        assert n.reply_to_id == root.id
        assert {n.subject_type, n.subject_id, n.visibility} == {"Contact", c.id, ["manager"]}
        assert [%NoteVersion{subject_type: "Note"}] = Repo.all(from v in NoteVersion, where: v.note_id == ^old.id)
      end

      assert {:ok, 0} = ReplyBackfill.run(Repo)
    end

    test "a cycle does not loop forever", %{company: company, admin: admin} do
      a = Repo.insert!(%Note{company_id: company.id, author_id: admin.id, updated_by_id: admin.id, body: "a"})
      b = Repo.insert!(%Note{company_id: company.id, author_id: admin.id, updated_by_id: admin.id, body: "b", subject_type: "Note", subject_id: a.id})
      Repo.update!(Ecto.Changeset.change(a, subject_type: "Note", subject_id: b.id))
      assert {:ok, _} = ReplyBackfill.run(Repo)
    end
  end
end
```

(`import Ecto.Query` at the top if `from` is not already available through DataCase.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/notes_replies_test.exs`
Expected: FAIL — `reply_to_id` is not a field / `ReplyBackfill` undefined.

- [ ] **Step 3: Migration**

Create `priv/repo/migrations/20261002130000_add_reply_to_to_notes.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.AddReplyToToNotes do
  use Ecto.Migration

  def up do
    alter table(:notes) do
      add :reply_to_id, references(:notes, on_delete: :nilify_all)
    end

    create index(:notes, [:company_id, :reply_to_id])
    flush()
    {:ok, _} = FullCircle.Notes.ReplyBackfill.run(repo())
  end

  def down do
    drop index(:notes, [:company_id, :reply_to_id])

    alter table(:notes) do
      remove :reply_to_id
    end
  end
end
```

- [ ] **Step 4: Backfill module**

Create `lib/full_circle/notes/reply_backfill.ex`:

```elixir
defmodule FullCircle.Notes.ReplyBackfill do
  @moduledoc """
  One-off conversion of old note-on-note rows (a note whose subject is another
  note) into replies: `reply_to_id` = the true root (following parents while
  they are themselves about a note), subject and visibility = the root's. Each
  converted note gets a `note_versions` snapshot of its old state first.
  Idempotent: converted rows are no longer about a note. See the replies spec.
  """

  @roots_sql """
  WITH RECURSIVE chain AS (
    SELECT n.id AS note_id, n.subject_id AS parent_id, 1 AS depth, ARRAY[n.id] AS seen
    FROM notes n
    WHERE n.subject_type = 'Note' AND n.reply_to_id IS NULL
    UNION ALL
    SELECT c.note_id, p.subject_id, c.depth + 1, c.seen || p.id
    FROM chain c
    JOIN notes p ON p.id = c.parent_id
    WHERE p.subject_type = 'Note' AND NOT p.id = ANY(c.seen) AND c.depth < 50
  )
  SELECT DISTINCT ON (note_id) note_id, parent_id AS root_id
  FROM chain
  ORDER BY note_id, depth DESC
  """

  def run(repo) do
    %{rows: rows} = repo.query!(@roots_sql)
    pairs = for [note_id, root_id] <- rows, note_id != root_id, do: {note_id, root_id}

    repo.transaction(fn ->
      Enum.each(pairs, fn {note_id, root_id} ->
        repo.query!(
          """
          INSERT INTO note_versions
            (id, note_id, company_id, version, title, body, subject_type, subject_id,
             visibility, written_by_id, written_at, edited_by_id, inserted_at)
          SELECT gen_random_uuid(), n.id, n.company_id,
                 COALESCE((SELECT max(v.version) FROM note_versions v WHERE v.note_id = n.id), 0) + 1,
                 n.title, n.body, n.subject_type, n.subject_id, n.visibility,
                 n.updated_by_id, n.updated_at, n.updated_by_id, now()
          FROM notes n WHERE n.id = $1
          """,
          [note_id]
        )

        repo.query!(
          """
          UPDATE notes n
          SET reply_to_id = r.id, subject_type = r.subject_type,
              subject_id = r.subject_id, visibility = r.visibility
          FROM notes r
          WHERE n.id = $1 AND r.id = $2
          """,
          [note_id, root_id]
        )
      end)

      length(pairs)
    end)
  end
end
```

Ids from `repo.query!` come back as 16-byte binaries; pass them straight back as parameters (Postgrex accepts binary uuids). Check `note_versions` column names against `lib/full_circle/notes/note_version.ex` / the create_notes migration before running, and adjust if any differ. If a root in a cycle is itself about a note (pure cycle), the chain ends at a note still about a note: the guard `note_id != root_id` plus the `seen` array stops recursion; such rows stay unconverted (acceptable — test only asserts no hang).

- [ ] **Step 5: Schema**

In `lib/full_circle/notes/note.ex`: add `belongs_to :reply_to, __MODULE__` to the schema and `reply_to_id` to `@castable`.

- [ ] **Step 6: Reply rules in `Notes`**

In `lib/full_circle/notes.ex`:

1. `create_note/3` — after `attrs = normalize_visibility(attrs)`, resolve the target and fold the root's values in before building the changeset; inside the transaction, re-read the root `FOR SHARE` after the task lock:

```elixir
  def create_note(attrs, company, user) do
    attrs = normalize_visibility(attrs)

    if can?(user, :create_note, company) do
      case reply_target(attrs, company, user) do
        {:error, cs} ->
          {:error, cs}

        {:ok, root} ->
          attrs = reply_attrs(attrs, root)

          changeset =
            %Note{company_id: company.id, author_id: user.id, updated_by_id: user.id}
            |> Note.changeset(Map.delete(attrs, "links"))
            |> validate_subject(company, user)

          # Lock order: task row, then the root note, then (on update) the note.
          Multi.new()
          |> Multi.run(:task_visibility, fn repo, _ -> read_task_visibility(repo, changeset) end)
          |> Multi.run(:root, fn repo, _ -> lock_root(repo, root) end)
          |> Multi.insert(:note, fn m ->
            changeset |> follow_root(m.root) |> follow_task_visibility(m.task_visibility)
          end)
          |> insert_links(Map.get(attrs, "links") || [], company, user)
          |> Repo.transaction()
          |> case do
            {:ok, %{note: note}} ->
              {:ok, Repo.preload(note, [:author, :updated_by, :attachments])}

            {:error, :note, cs, _} ->
              {:error, cs}

            {:error, :root, :gone, _} ->
              {:error, reply_error()}

            {:error, _step, reason, _} ->
              {:error, reason}
          end
      end
    else
      :not_authorise
    end
  end
```

   Helpers (private, near `follow_task_visibility/2`):

```elixir
  # A reply always attaches to a root its writer can read; replying to a reply
  # joins that reply's root. {:ok, nil} when this is not a reply.
  defp reply_target(attrs, company, user) do
    case attrs["reply_to_id"] do
      blank when blank in [nil, ""] ->
        {:ok, nil}

      id ->
        with %Note{} = target <- get_note(id, company, user),
             %Note{} = root <- if(target.reply_to_id, do: get_note(target.reply_to_id, company, user), else: target) do
          {:ok, root}
        else
          _ -> {:error, reply_error()}
        end
    end
  end

  defp reply_error do
    %Note{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:reply_to_id, "can't be replied to")
  end

  # The root's subject and visibility; the writer's choices are dropped.
  defp reply_attrs(attrs, nil), do: Map.delete(attrs, "reply_to_id")

  defp reply_attrs(attrs, %Note{} = root) do
    Map.merge(attrs, %{
      "reply_to_id" => root.id,
      "subject_type" => root.subject_type,
      "subject_id" => root.subject_id,
      "visibility" => root.visibility
    })
  end

  defp lock_root(_repo, nil), do: {:ok, nil}

  defp lock_root(repo, %Note{id: id}) do
    case repo.one(
           from(n in Note,
             where: n.id == ^id and is_nil(n.deleted_at),
             lock: "FOR SHARE",
             select: %{subject_type: n.subject_type, subject_id: n.subject_id, visibility: n.visibility}
           )
         ) do
      nil -> {:error, :gone}
      root -> {:ok, root}
    end
  end

  defp follow_root(changeset, nil), do: changeset

  defp follow_root(changeset, root) do
    Ecto.Changeset.change(changeset,
      subject_type: root.subject_type,
      subject_id: root.subject_id,
      visibility: root.visibility
    )
  end
```

   Because `validate_subject/3` only checks a subject when it is set or changed, a reply copying a root's subject is validated like any new note (the writer can resolve it, or the root itself would not be readable).

2. `update_note/4`:
   - Always `Map.delete(attrs, "reply_to_id")`.
   - If `current.reply_to_id` is set (a reply): also delete `"subject_type"`, `"subject_id"`, `"visibility"` from attrs before building the changeset, and in the Multi add `|> Multi.run(:root, fn repo, _ -> lock_root(repo, %Note{id: current.reply_to_id}) end)` **between** `:task_visibility` and `snapshot/4`; the update applies `follow_root(m.root)` then `follow_task_visibility`. If `:root` returns `{:error, :gone}` (root deleted), skip following (keep the reply's stored values) — use a variant `lock_root_or_keep/2` returning `{:ok, nil}` for a deleted root so a reply of a deleted root can still be edited.
   - If `current.reply_to_id` is nil (a root): after the `Multi.update(:note, …)`, add

```elixir
        |> Multi.run(:replies, fn repo, %{note: n} ->
          if n.subject_type != current.subject_type or n.subject_id != current.subject_id or
               n.visibility != current.visibility do
            {count, _} =
              repo.update_all(
                from(r in Note, where: r.reply_to_id == ^n.id and is_nil(r.deleted_at)),
                set: [subject_type: n.subject_type, subject_id: n.subject_id, visibility: n.visibility]
              )

            {:ok, count}
          else
            {:ok, 0}
          end
        end)
```

   Keep the existing lock-order comment and extend it: "task row → root note → reply note". The no-op shortcut (`changeset.changes == %{}` → `{:ok, current}`) still applies.

- [ ] **Step 7: Run the tests**

Run: `mix ecto.migrate && mix test test/full_circle/notes_replies_test.exs test/full_circle/notes_test.exs test/full_circle/tasks_test.exs`
Expected: PASS. Then `mix test` once (full).

- [ ] **Step 8: Commit**

```bash
mix format priv/repo/migrations/20261002130000_add_reply_to_to_notes.exs lib/full_circle/notes/reply_backfill.ex lib/full_circle/notes/note.ex lib/full_circle/notes.ex test/full_circle/notes_replies_test.exs
git add priv/repo/migrations/20261002130000_add_reply_to_to_notes.exs lib/full_circle/notes/reply_backfill.ex lib/full_circle/notes/note.ex lib/full_circle/notes.ex test/full_circle/notes_replies_test.exs
git commit -m "feat(notes): replies belong to a root thread and follow its subject and visibility

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Reading threads — `thread/3`, `root_of/3`, reply-aware `feed_details/3`

**Files:**
- Modify: `lib/full_circle/notes.ex`
- Test: `test/full_circle/notes_replies_test.exs` (append)

**Interfaces:**
- Produces:
  - `Notes.thread(%Note{} = root, company, user) :: [%{id, note, d}]` — visible, live replies of `root` (`reply_to_id = root.id`), oldest first (`inserted_at`, then `id`), notes preloaded `:author, :attachments`, `d` from `feed_details/3`.
  - `Notes.root_of(%Note{} = note, company, user) :: {:root, Note} | {:deleted, nil} | {:hidden, nil} | :self` — `:self` for a root; for a reply, the root via `get_note/3` (preloaded), else `:deleted` when the root row has `deleted_at`, else `:hidden`.
  - `feed_details/3` entries gain `reply_to: nil | %{id: id, title: String.t() | nil, state: :ok | :deleted | :hidden}` and `replies` now counts **visible live replies** (`reply_to_id`), not notes linking to the note.

- [ ] **Step 1: Write the failing tests** (append inside the test module)

```elixir
  describe "reading threads" do
    test "thread lists visible live replies oldest first", %{company: company, admin: admin} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, a} = reply(company, admin, root, %{"body" => "first"})
      Repo.update_all(from(n in Note, where: n.id == ^a.id), set: [inserted_at: ~U[2020-01-01 00:00:00Z]])
      {:ok, b} = reply(company, admin, root, %{"body" => "second"})
      {:ok, c} = reply(company, admin, root, %{"body" => "gone"})
      {:ok, _} = Notes.delete_note(c, company, admin)

      assert Enum.map(Notes.thread(root, company, admin), & &1.id) == [a.id, b.id]
    end

    test "💬 counts replies, not notes that only link", %{company: company, admin: admin} do
      root = note_fixture(company, admin, %{"body" => "root"})
      {:ok, _} = reply(company, admin, root)
      note_fixture(company, admin, %{"body" => "quote", "links" => [%{"type" => "Note", "id" => root.id}]})
      assert %{replies: 1} = Notes.feed_details([root], company, admin)[root.id]
    end

    test "reply_to tag data: ok, deleted, hidden", %{company: company, admin: admin} do
      clerk = user_with_role(company, admin, "clerk")
      root = note_fixture(company, admin, %{"title" => "Genset", "body" => "root"})
      {:ok, r} = reply(company, clerk, root)

      assert %{reply_to: %{id: id, title: "Genset", state: :ok}} =
               Notes.feed_details([r], company, admin)[r.id]

      assert id == root.id

      {:ok, _} = Notes.update_note(root, %{"visibility" => ["manager"]}, company, admin)
      r = Repo.get!(Note, r.id)
      # The clerk wrote the reply, so still reads it (author rule) but not the root.
      assert %{reply_to: %{state: :hidden, title: nil}} =
               Notes.feed_details([r], company, clerk)[r.id]

      assert {:hidden, nil} = Notes.root_of(r, company, clerk)

      {:ok, _} = Notes.delete_note(Repo.get!(Note, root.id), company, admin)
      assert {:deleted, nil} = Notes.root_of(r, company, admin)
      assert %{reply_to: %{state: :deleted}} = Notes.feed_details([r], company, admin)[r.id]
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/notes_replies_test.exs`
Expected: FAIL — `Notes.thread/3` undefined.

- [ ] **Step 3: Implement**

In `lib/full_circle/notes.ex`:

```elixir
  @doc "Visible live replies of a root, oldest first, as feed items."
  def thread(%Note{id: root_id}, company, user) do
    notes =
      from(n in visible_to(company, user),
        where: n.reply_to_id == ^root_id,
        order_by: [asc: n.inserted_at, asc: n.id]
      )
      |> Repo.all()
      |> Repo.preload([:author, :attachments])

    details = feed_details(notes, company, user)
    Enum.map(notes, &%{id: &1.id, note: &1, d: Map.fetch!(details, &1.id)})
  end

  @doc "The root of a reply as this user may see it."
  def root_of(%Note{reply_to_id: nil}, _company, _user), do: :self

  def root_of(%Note{reply_to_id: root_id, company_id: company_id}, company, user) do
    case get_note(root_id, company, user) do
      %Note{} = root ->
        {:root, root}

      nil ->
        deleted? =
          Repo.exists?(
            from(n in Note,
              where: n.id == ^root_id and n.company_id == ^company_id and not is_nil(n.deleted_at)
            )
          )

        if deleted?, do: {:deleted, nil}, else: {:hidden, nil}
    end
  end
```

In `feed_details/3` replace `replies = count_by_records(company, user, "Note", ids)` with:

```elixir
    replies =
      from(n in visible_to(company, user),
        where: n.reply_to_id in ^ids,
        group_by: n.reply_to_id,
        select: {n.reply_to_id, count(n.id)}
      )
      |> Repo.all()
      |> Map.new()

    root_ids = notes |> Enum.map(& &1.reply_to_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    visible_roots =
      from(n in visible_to(company, user), where: n.id in ^root_ids, select: {n.id, n})
      |> Repo.all()
      |> Map.new()

    deleted_roots =
      from(n in Note,
        where: n.id in ^root_ids and n.company_id == ^company.id and not is_nil(n.deleted_at),
        select: n.id
      )
      |> Repo.all()
      |> MapSet.new()
```

and add to each entry:

```elixir
         reply_to:
           n.reply_to_id &&
             cond do
               root = visible_roots[n.reply_to_id] ->
                 %{id: n.reply_to_id, title: Note.display_title(root), state: :ok}

               MapSet.member?(deleted_roots, n.reply_to_id) ->
                 %{id: n.reply_to_id, title: nil, state: :deleted}

               true ->
                 %{id: n.reply_to_id, title: nil, state: :hidden}
             end,
```

Keep `count_by_records/4` (record panels still use it). Update the `feed_details/3` doc: "six queries per page".

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle/notes_replies_test.exs test/full_circle/notes_test.exs test/full_circle_web/live/note_live_test.exs`
Expected: PASS. If a feed test asserted that a linking note bumps 💬, update it to the new contract (replies only) and say so in the report.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/notes.ex test/full_circle/notes_replies_test.exs
git add lib/full_circle/notes.ex test/full_circle/notes_replies_test.exs test/full_circle_web/live/note_live_test.exs
git commit -m "feat(notes): thread, root_of and reply-aware feed details

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Composer reply mode

**Files:**
- Modify: `lib/full_circle_web/live/note_live/composer_component.ex`
- Test: `test/full_circle_web/live/note_composer_test.exs` (append)

**Interfaces:**
- Consumes: `Notes.create_note/3` with `"reply_to_id"` (Task 1).
- Produces: composer attr `reply_to: %Note{} | nil`. A box is **replying** when `reply_to` is set, or when `mode: :edit` and `note.reply_to_id` is set. A replying box: no about… chip / clear-subject / subject picker, no visibility chips or pill, shows `<p id="#{id}-reply-scope">Visible to the same people as the note it replies to.</p>`; picks (full edit mode) are always links; on create sends `"reply_to_id" => reply_to.id`; `subject_attrs` sends nothing for replies.

- [ ] **Step 1: Write the failing tests** (append inside `FullCircleWeb.NoteComposerTest`)

```elixir
  describe "reply mode" do
    test "posts a reply to the root with no subject or visibility choices", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      root = note_fixture(comp, admin, %{"body" => "root", "visibility" => ["manager"]})
      lv = host(conn, comp, admin, %{"reply_to" => root})

      refute has_element?(lv, "#c-open-picker")
      refute has_element?(lv, "#c-roles-toggle")
      refute has_element?(lv, "label.role-chip")
      assert has_element?(lv, "#c-reply-scope")

      lv |> form("#c-form", %{"note" => %{"body" => "agreed"}}) |> render_submit()
      reply = FullCircle.Repo.get_by!(Note, body: "agreed")
      assert reply.reply_to_id == root.id
      assert reply.visibility == ["manager"]
    end

    test "editing a reply hides subject and visibility; picks become links", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      root = note_fixture(comp, admin, %{"body" => "root"})
      {:ok, r} = FullCircle.Notes.create_note(%{"body" => "r", "reply_to_id" => root.id}, comp, admin)
      r = FullCircle.Notes.get_note(r.id, comp, admin)

      lv = host(conn, comp, admin, %{"mode" => :edit, "note" => r, "full" => true})
      refute has_element?(lv, "label.role-chip")
      assert has_element?(lv, "#c-reply-scope")

      lv |> element("#c-open-picker") |> render_click()
      lv |> form("#c-picker form", %{"type" => "Contact", "terms" => "Mei"}) |> render_change()
      lv |> element("#c-picker-pick-#{mei.id}") |> render_click()
      render(lv)

      assert [%{id: id}] = FullCircle.Notes.list_links(r, comp, admin)
      assert id == mei.id
      assert FullCircle.Repo.get!(Note, r.id).subject_id == nil
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_composer_test.exs`
Expected: FAIL — no `reply_to` attr / `#c-reply-scope` missing.

- [ ] **Step 3: Implement**

In `composer_component.ex`:
1. Add `reply_to: nil` to `@defaults`.
2. Add helpers:

```elixir
  # A reply takes its root's subject and visibility (Notes enforces it); the
  # box offers neither, and every pick is a link.
  defp replying?(%{reply_to: %Note{}}), do: true
  defp replying?(%{mode: :edit, note: %Note{reply_to_id: id}}) when not is_nil(id), do: true
  defp replying?(_), do: false
```

3. `subject_attrs/1`: first clause `defp subject_attrs(%{reply_to: %Note{}}), do: %{}` and a clause for an edited reply returning `%{}` (match `%{mode: :edit, note: %Note{reply_to_id: id}} when not is_nil(id)`), placed before the others.
4. `handle_event("save", …)` for create: when `socket.assigns.reply_to` is a `%Note{}`, `Map.put(params, "reply_to_id", socket.assigns.reply_to.id)`.
5. `pick/2`: when `replying?(socket.assigns)`, skip the subject branches — treat every pick as a link (`mode == :edit` → `add_saved_link/2`, else queue).
6. In `render/1`, assign `replying = replying?(assigns)` at the top (`assigns = assign(assigns, :replying, replying?(assigns))`) and:
   - wrap the visibility chips div, the hidden-visibility inputs div, the hint `<p>` and the roles-toggle pill with `and not @replying`;
   - the subject record_chip: `:if={@subject && !@fixed_subject && !@replying}`;
   - the open-picker button: `:if={!@fixed_subject and ((not @replying and (is_nil(@subject) or @full)) or (@replying and @full))}`, and its label `if @subject || @replying, do: gettext("link a record"), else: gettext("about…")`;
   - add after the error line:

```heex
          <p
            :if={@replying}
            id={"#{@id}-reply-scope"}
            class="pb-1 text-xs text-slate-500 dark:text-slate-400"
          >
            {gettext("Visible to the same people as the note it replies to.")}
          </p>
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/note_composer_test.exs test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/composer_component.ex test/full_circle_web/live/note_composer_test.exs
git add lib/full_circle_web/live/note_live/composer_component.ex test/full_circle_web/live/note_composer_test.exs
git commit -m "feat(notes): composer reply mode — no subject or visibility choices

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: "↩ reply to …" tag on posts

**Files:**
- Modify: `lib/full_circle_web/components/note_components.ex` (`note_post/1`)
- Test: `test/full_circle_web/live/note_live_test.exs`, `test/full_circle_web/live/notes_panel_live_test.exs`

**Interfaces:**
- Consumes: `d.reply_to` from `feed_details/3` (Task 2).
- Produces: in `note_post/1`, when `@d.reply_to` is set and `@host != {"Note", @d.reply_to.id}`, a tag in the header row with class `note-reply-to`: state `:ok` → `<a href="/companies/:cid/notes/:root_id">↩ reply to {title}</a>` (same-tab in the feed, `target="_blank"` when `new_tab`); `:deleted` → "↩ reply to a deleted note"; `:hidden` → "↩ reply to a note you can't see".

- [ ] **Step 1: Write the failing tests**

In `note_live_test.exs` describe "index" add:

```elixir
    test "a reply in the feed is tagged with its root", %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"title" => "Genset", "body" => "broke down"})
      {:ok, r} = FullCircle.Notes.create_note(%{"body" => "tech Monday", "reply_to_id" => root.id}, comp, admin)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")

      assert has_element?(
               lv,
               ~s(#notes-#{r.id} .note-reply-to a[href="/companies/#{comp.id}/notes/#{root.id}"]),
               "Genset"
             )

      refute has_element?(lv, "#notes-#{root.id} .note-reply-to")
    end
```

In `notes_panel_live_test.exs` add:

```elixir
  test "a reply about this contact shows in its panel, tagged", %{conn: conn, admin: admin, comp: comp, contact: c} do
    root = note_fixture(comp, admin, %{"body" => "credit terms", "subject_type" => "Contact", "subject_id" => c.id})
    {:ok, r} = FullCircle.Notes.create_note(%{"body" => "approved 60 days", "reply_to_id" => root.id}, comp, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    assert has_element?(lv, "#notes-panel-note-#{r.id} .note-reply-to")
    assert render(lv) =~ "approved 60 days"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs`
Expected: FAIL — no `.note-reply-to`.

- [ ] **Step 3: Implement**

In `note_post/1`, add to the assigns: `reply_to: if(d[:reply_to] && host != {"Note", d.reply_to.id}, do: d.reply_to)`, and in the header row (after the time span, before the `↩ linked` tag):

```heex
          <span
            :if={@reply_to}
            class="note-reply-to ml-1 rounded-full border border-slate-300 px-2 text-xs text-slate-600 dark:border-slate-600 dark:text-slate-300"
          >
            <%= case @reply_to.state do %>
              <% :ok -> %>
                <a
                  href={"/companies/#{@current_company.id}/notes/#{@reply_to.id}"}
                  target={@new_tab && "_blank"}
                  class="hover:underline"
                >
                  ↩ {gettext("reply to")} {@reply_to.title}
                </a>
              <% :deleted -> %>
                ↩ {gettext("reply to a deleted note")}
              <% :hidden -> %>
                ↩ {gettext("reply to a note you can't see")}
            <% end %>
          </span>
```

`d[:reply_to]` (access syntax) keeps items built elsewhere without the key working.

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/task_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/components/note_components.ex test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs
git add lib/full_circle_web/components/note_components.ex test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs
git commit -m "feat(notes): posts show which note they reply to

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Note page — root card, thread around the note, reply box, Linked from

**Files:**
- Modify: `lib/full_circle_web/live/note_live/form.ex`
- Modify: `lib/full_circle_web/live/note_live/notes_panel_component.ex` (remove `:thread`)
- Test: `test/full_circle_web/live/note_live_test.exs`, `test/full_circle_web/live/notes_panel_live_test.exs`

**Interfaces:**
- Consumes: `Notes.thread/3`, `Notes.root_of/3`, `Notes.list_backlinks/3` (existing: notes linking to a note), `Notes.list_versions/3`, `Notes.version_changes/2`, composer `reply_to`, `note_post/1` `host`.
- Produces DOM ids: `#replying-to` (root card section, reply pages only), `#replying-to-post`, `#toggle-root-history`, `#root-history`, `#replying-to-gone` (deleted/hidden root text), `#thread-before` (earlier replies, reply pages), `#thread-after` (later replies / all replies on a root page), items `#thread-<id>`, `#reply-box` wrapper with composer id `reply` (form `#reply-form`), `#linked-from` (backlinks). Existing ids (`#note-post`, `#edit-note`, `#note-form`, `#toggle-history`, `#note-history`, `#note-files`, `#delete-note`) unchanged.

Layout (top → bottom):
1. "← Note" bar (unchanged).
2. Reply pages only: `#replying-to` — "Replying to" label, the root as `note_post` (not detail; `host={{"Note", @note.id}}` hides its own chips pointing here) inside `#replying-to-post`, with a `#toggle-root-history` button (History ▸/▾) and, when open, `#root-history` (same markup as `#note-history`, fed by `Notes.version_changes(Notes.list_versions(root, …), root)`). Deleted/hidden root → `#replying-to-gone` with "Replying to a deleted note" / "Replying to a note you can't see" (no card).
3. Reply pages only: `#thread-before` — thread items with `inserted_at` before this note, as `note_post` with `host={{"Note", root.id}}`, ids `thread-<id>`.
4. This note: post view / edit mode exactly as today (main post, files, own History).
5. `#thread-after` — on a root page: all thread items; on a reply page: thread items after this note.
6. `#reply-box` — composer `id="reply"`, `reply_to={root}` (the note itself on a root page; the root on a reply page), `avatar`, placeholder "Post your reply…", submit "Reply"; hidden when the user lacks `:create_note` or the root is deleted/hidden.
7. `#linked-from` — `Notes.list_backlinks(note, …)` rendered as compact `note_post` items with `relation={:linked}`; omitted when empty.

- [ ] **Step 1: Update and add tests**

In `note_live_test.exs` describe "note page":
- "a note can be written about this note from its page" → rename "replying from a note's page adds to its thread": submit `#reply-form` (no `#notes-panel-new` click), assert `render(lv) =~ "confirmed with SSM search"`, `has_element?(lv, "#thread-after", "confirmed with SSM search")`, and the stored note has `reply_to_id == note.id` (replace the old `{"Note", note.id}` subject assertion).
- Any test that expected a note **linking** to this note inside the thread now finds it in `#linked-from` ("shows files, links, notes linking here and history": assert `has_element?(lv, "#linked-from", "points here")`).

Add:

```elixir
    test "a reply's page shows the root, earlier replies, the reply, later replies",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"title" => "Genset", "body" => "broke down"})
      {:ok, a} = FullCircle.Notes.create_note(%{"body" => "first", "reply_to_id" => root.id}, comp, admin)
      FullCircle.Repo.update_all(from(n in FullCircle.Notes.Note, where: n.id == ^a.id), set: [inserted_at: ~U[2020-01-01 00:00:00Z]])
      {:ok, b} = FullCircle.Notes.create_note(%{"body" => "second", "reply_to_id" => root.id}, comp, admin)
      {:ok, c} = FullCircle.Notes.create_note(%{"body" => "third", "reply_to_id" => root.id}, comp, admin)
      FullCircle.Repo.update_all(from(n in FullCircle.Notes.Note, where: n.id == ^c.id), set: [inserted_at: ~U[2099-01-01 00:00:00Z]])

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{b.id}")
      assert has_element?(lv, "#replying-to-post", "broke down")
      assert has_element?(lv, "#thread-before #thread-#{a.id}")
      assert has_element?(lv, "#note-post", "second")
      assert has_element?(lv, "#thread-after #thread-#{c.id}")
      refute has_element?(lv, "#thread-before #thread-#{b.id}")
      refute has_element?(lv, "#thread-after #thread-#{b.id}")
    end

    test "editing a reply keeps the root card and earlier replies; root history toggles without losing text",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, root} = FullCircle.Notes.update_note(root, %{"body" => "v2"}, comp, admin)
      {:ok, r} = FullCircle.Notes.create_note(%{"body" => "my reply", "reply_to_id" => root.id}, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{r.id}/edit")
      assert has_element?(lv, "#note-form")
      assert has_element?(lv, "#replying-to-post", "v2")

      lv |> form("#note-form", %{"note" => %{"body" => "half typed"}}) |> render_change()
      html = lv |> element("#toggle-root-history") |> render_click()
      assert html =~ "v1"
      assert has_element?(lv, "#note-form textarea", "half typed")
    end

    test "a reply whose root was deleted says so and offers no reply box",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "root"})
      {:ok, r} = FullCircle.Notes.create_note(%{"body" => "orphan", "reply_to_id" => root.id}, comp, admin)
      {:ok, _} = FullCircle.Notes.delete_note(root, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{r.id}")
      assert has_element?(lv, "#replying-to-gone", "deleted")
      assert has_element?(lv, "#note-post", "orphan")
      refute has_element?(lv, "#reply-form")
    end

    test "the reply's author who lost the root sees the reply, not the root",
         %{admin: admin, comp: comp} do
      clerk = user_with_role(comp, admin, "clerk")
      root = note_fixture(comp, admin, %{"body" => "secret root"})
      {:ok, r} = FullCircle.Notes.create_note(%{"body" => "clerk reply", "reply_to_id" => root.id}, comp, clerk)
      {:ok, _} = FullCircle.Notes.update_note(root, %{"visibility" => ["manager"]}, comp, admin)

      {:ok, lv, html} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes/#{r.id}")
      assert has_element?(lv, "#note-post", "clerk reply")
      assert has_element?(lv, "#replying-to-gone")
      refute html =~ "secret root"
    end
```

(Add `import Ecto.Query` to the test module if needed.)

In `notes_panel_live_test.exs`: delete the `ThreadHost` / "thread layout" test (the layout is removed); keep "card layout: Cancel closes the quick-add".

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — no `#replying-to`, `#reply-form`, `#thread-after`.

- [ ] **Step 3: Implement the note page**

In `lib/full_circle_web/live/note_live/form.ex`:
1. `mount/3`: add `show_root_history: false, root_history: []` to the initial assigns.
2. `assign_note/2`: also assign the thread context:

```elixir
    {root, root_state} =
      case Notes.root_of(note, com, user) do
        :self -> {note, :self}
        {:root, r} -> {Repo.preload(r, [:author, :updated_by, :attachments]), :ok}
        {state, nil} -> {nil, state}
      end

    thread = if root, do: Notes.thread(root, com, user), else: []

    {before, after_} =
      if root_state == :self,
        do: {[], thread},
        else: Enum.split_while(thread, &(&1.id != note.id)) |> then(fn {b, rest} -> {b, Enum.drop(rest, 1)} end)

    root_item =
      if root && root_state == :ok,
        do: %{id: root.id, note: root, d: Map.fetch!(Notes.feed_details([root], com, user), root.id)}

    backlinks =
      Notes.list_backlinks(note, com, user)
      |> Repo.preload([:author, :attachments])
      |> then(fn ns ->
        d = Notes.feed_details(ns, com, user)
        Enum.map(ns, &%{id: &1.id, note: &1, d: Map.fetch!(d, &1.id)})
      end)
```

   and `assign(…, root: root, root_state: root_state, root_item: root_item, thread_before: before, thread_after: after_, backlinks: backlinks, can_reply: FullCircle.Authorization.can?(user, :create_note, com) and root != nil)`. Add `alias FullCircle.Repo`. On `:new`, assign `root: nil, root_state: :self, root_item: nil, thread_before: [], thread_after: [], backlinks: [], can_reply: false`.
3. Events: `handle_event("toggle_root_history", _, socket)` flips `show_root_history` and loads `root_history: Notes.version_changes(Notes.list_versions(root, com, user), root)` when opening (no-op when `root_item` is nil; include it in the `/notes/new` no-op list).
4. `handle_info({:composer, "reply", {:saved, :new, _}}, socket)` → `{:noreply, reload(socket)}`. Remove the `{:notes_changed, "Note", _}` clause (the panel thread is gone).
5. `render/1`: replace the `NotesPanelComponent` thread block with the layout above. Extract the history list markup into a private function component `history_list(assigns)` (attrs `history`, `id`, `current_company`) used for both `#note-history` and `#root-history`. Thread items: `<div id="thread-before"> <.note_post :for={i <- @thread_before} id={"thread-#{i.id}"} item={i} current_company={@current_company} host={{"Note", @root.id}} /> </div>` (and the same for `#thread-after`). Reply box:

```heex
        <div :if={@can_reply} id="reply-box" class="border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <.live_component
            module={ComposerComponent}
            id="reply"
            reply_to={@root}
            avatar
            placeholder={gettext("Post your reply…")}
            submit_label={gettext("Reply")}
            current_company={@current_company}
            current_user={@current_user}
          />
        </div>
```

   Root card:

```heex
        <section
          :if={@root_state != :self}
          id="replying-to"
          class="border-b border-gray-200 bg-slate-50/70 dark:border-gray-700 dark:bg-gray-800/40"
        >
          <p class="px-4 pt-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
            {gettext("Replying to")}
          </p>
          <div :if={@root_item} id="replying-to-post">
            <.note_post id="replying-to-root" item={@root_item} current_company={@current_company} host={{"Note", @note.id}} />
            <div class="px-4 pb-2">
              <button
                type="button"
                id="toggle-root-history"
                phx-click="toggle_root_history"
                class="text-xs text-gray-500 hover:underline dark:text-gray-400"
              >
                {gettext("History")} {if @show_root_history, do: "▾", else: "▸"}
              </button>
            </div>
            <.history_list :if={@show_root_history} id="root-history" history={@root_history} current_company={@current_company} />
          </div>
          <p :if={is_nil(@root_item)} id="replying-to-gone" class="px-4 pb-2 text-sm text-slate-500 dark:text-slate-400">
            {if @root_state == :deleted,
              do: gettext("Replying to a deleted note"),
              else: gettext("Replying to a note you can't see")}
          </p>
        </section>
```

   Linked from:

```heex
        <section :if={@backlinks != []} id="linked-from" class="border-t border-gray-200 dark:border-gray-700">
          <p class="px-4 pt-2 text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
            {gettext("Linked from")}
          </p>
          <.note_post
            :for={i <- @backlinks}
            id={"linked-#{i.id}"}
            item={i}
            current_company={@current_company}
            host={{"Note", @note.id}}
            relation={:linked}
          />
        </section>
```

   Order in the template: bar → `#replying-to` → `#thread-before` → main post/edit (+ `#note-history`) → `#thread-after` → `#reply-box` → `#linked-from`.
6. Remove the `:thread` layout from `NotesPanelComponent` (the `layout` attr, its `:thread` branches, the `@can_create` thread gating stays for `:card`), and its moduledoc mention.

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_composer_test.exs test/full_circle_web/live/task_live_test.exs test/full_circle_web/live/tasks_panel_live_test.exs`
Expected: PASS. Then `mix test` (full) and `mix compile --force` (no warnings).

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/form.ex lib/full_circle_web/live/note_live/notes_panel_component.ex test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs
git add lib/full_circle_web/live/note_live/form.ex lib/full_circle_web/live/note_live/notes_panel_component.ex test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs
git commit -m "feat(notes): note page keeps the root and the conversation around the note

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Docs and translations

**Files:**
- Modify: `.claude/skills/notes.md`, `priv/gettext/zh/LC_MESSAGES/default.po`, `docs/superpowers/specs/2026-10-02-note-replies-design.md` (Status line)

- [ ] **Step 1: zh strings** — grep the new gettext strings in the files changed by Tasks 3–5 (`grep -rhoE 'gettext\("[^"]+"' lib/full_circle_web/live/note_live/form.ex lib/full_circle_web/live/note_live/composer_component.ex lib/full_circle_web/components/note_components.ex | sort -u`), check each with `grep -c '^msgid "…"$'`, append only missing ones, e.g.:

```po
msgid "Visible to the same people as the note it replies to."
msgstr "可见范围与所回复的备注相同。"

msgid "reply to"
msgstr "回复"

msgid "reply to a deleted note"
msgstr "回复已删除的备注"

msgid "reply to a note you can't see"
msgstr "回复你无法查看的备注"

msgid "Replying to"
msgstr "回复"

msgid "Replying to a deleted note"
msgstr "回复已删除的备注"

msgid "Replying to a note you can't see"
msgstr "回复你无法查看的备注"

msgid "Linked from"
msgstr "被以下备注关联"
```

`mix compile` must show no gettext errors.

- [ ] **Step 2: notes skill** — add a "## Replies" section: `reply_to_id` (root only, one level); a reply copies the root's subject + visibility on create and update (client values ignored); root save syncs live replies in the same transaction; **lock order: task row → root note → reply note**; `Notes.thread/3`, `root_of/3`, `feed_details` `replies` = replies only and `reply_to` tag data; composer `reply_to` / replying mode; note page layout and ids (`#replying-to`, `#toggle-root-history`, `#thread-before`, `#thread-after`, `#reply-box`/`#reply-form`, `#linked-from`); `ReplyBackfill` for old note-on-note rows. Remove/replace any sentence describing replies as "notes about a note" and the panel `:thread` layout.

- [ ] **Step 3: Spec status** — change the spec's `Status:` line to "implemented 2026-10-02 (plan docs/superpowers/plans/2026-10-02-note-replies.md)".

- [ ] **Step 4: Full suite and commit**

Run: `mix test` — 0 failures.

```bash
git add .claude/skills/notes.md priv/gettext/zh/LC_MESSAGES/default.po docs/superpowers/specs/2026-10-02-note-replies-design.md
git commit -m "docs(notes): replies contract; zh strings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Controller: browser pass (after Task 6)

Light and dark: a root note page with replies and a reply box; a reply's page (Replying to card, History ▸, earlier/later replies) in view and edit mode; a reply in the feed and in a contact's panel with its "↩ reply to" tag; a deleted-root reply. Run `mix ecto.migrate` on dev first (the backfill converts any old note-on-note rows there).
