# Note Attachments: Tray, Multi-file and "Add from phone" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Files added in a note's write box wait in a tray until Save, several at a time, by pick, drag-drop, paste or a phone. The phone gets a QR-linked upload-only page that scans multi-page paper into one PDF.

**Architecture:** A `note_trays` row holds a write box's not-yet-saved files: `note_attachments` rows with `tray_id` set and `note_id` empty. The note's save transaction moves them onto the note. The phone page is a plain controller page, not LiveView, authenticated by a signed 10-minute `Phoenix.Token` that refreshes on every upload. Every upload broadcasts on `note_files:<company_id>`. An `on_mount` hook routes the broadcast to the components showing those files, so no host LiveView needs code. Scans upload page by page to a temporary folder, and a pure-Elixir writer builds the PDF.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / LiveView 1.2, Ecto + Postgres, `qr_code` (already a dependency), plain browser JS (canvas, `XMLHttpRequest`), esbuild.

**Spec:** `docs/superpowers/specs/2026-10-04-note-attach-from-phone-design.md`

**Spec amendment, made by this plan:** the spec said "no new table". This plan adds a small `note_trays` table (`id, company_id, user_id, note_id, closed_at`). Without it, a phone upload arriving *after* the desktop pressed Save or Cancel had nowhere sensible to go. With it:
- after **Save**, late phone uploads attach to the saved note;
- after **Cancel**, the phone is told "closed on the desktop";
- tray ownership is a column check rather than a scan of rows.

Task 1 updates the spec to match.

## Global Constraints

- Allowed upload types are unchanged: JPEG, PNG, WebP and PDF, sniffed from magic bytes. The limit is `Attachments.max_bytes()`, 10 MB.
- The phone link's idle expiry is **600 s**, refreshed on every successful upload.
- A scan holds at most **30 pages**, and the built PDF must still be ≤ 10 MB.
- Tray files and scan folders older than **24 h** are pruned daily.
- Cancel **hard-deletes** tray files. Removing a file from a *saved* note stays a soft remove (`removed_at`).
- Web pages stay desktop-first. The **only** phone page is `/up/:token`.
- Never run bare `mix format`; format only the files you touch (`mix format path/to/file.ex`).
- Commit on `master` directly. End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Flash kinds are `:info` and `:warn`. `:warning` renders nothing.
- All UI must read well in light **and** dark theme (pair every colour with a `dark:` variant).
- Default scan look is **Clean colour**; B&W and Original are the per-scan alternatives.

## Review Focus

1. **A phone upload after the desktop already saved** must land on the saved note, not vanish into a dead tray. Pinned in Task 2 (`attach_to_tray` follows a saved tray).
2. **Another user, even in the same company, guessing or reusing a tray id** must not be able to add to or read that tray. Pinned in Task 2.
3. **A stale or invalid Save** (someone else edited the note) must leave the tray files in the box, not claim them and not delete them. Pinned in Task 3.
4. **A user disabled in the company after the QR was shown** must be refused on the next phone request, even though the token is still fresh. Pinned in Task 7.
5. **A scan page that is not a JPEG**, such as a PNG or HEIC from an odd browser, must be refused on its own, without breaking the scan's other pages. Pinned in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `priv/repo/migrations/20261004120000_add_note_trays.exs` | `note_trays` table; `note_attachments.tray_id`; nullable `note_id`; xor check |
| `lib/full_circle/notes/note_tray.ex` | `NoteTray` schema |
| `lib/full_circle/notes/note_attachment.ex` (modify) | `tray_id`, xor constraint in changeset |
| `lib/full_circle/notes/trays.ex` | Tray lifecycle: open/get/list/discard_file/cancel/claim/prune |
| `lib/full_circle/notes/attachments.ex` (modify) | Writes into a note *or* a tray; `attach_to_tray/4`; broadcast + `topic/1` |
| `lib/full_circle/notes.ex` (modify) | `create_note` / `update_note` claim `attrs["tray_id"]` in their transaction |
| `lib/full_circle/notes/scan_pdf.ex` | JPEG pages → PDF 1.4 bytes; `jpeg_info/1` |
| `lib/full_circle/notes/scans.ex` | A scan's page folder: add/drop/count/finish/discard/prune |
| `lib/full_circle/notes/tray_pruner.ex` | Daily GenServer (copy of `PunchGate.PhotoPruner`) |
| `lib/full_circle/application.ex` (modify) | Supervise `TrayPruner` |
| `config/test.exs` (modify) | `note_tray_prune_enabled: false` |
| `lib/full_circle_web/phone_upload.ex` | Token sign/verify/resolve, QR URL, labels |
| `lib/full_circle_web/controllers/phone_upload_controller.ex` | `/up/:token` page + JSON endpoints |
| `lib/full_circle_web/controllers/phone_upload_html.ex` + `phone_upload_html/show.html.heex`, `expired.html.heex` | The phone page markup |
| `lib/full_circle_web/controllers/note_attachment_controller.ex` (modify) | `create_tray` for the desktop tray |
| `lib/full_circle_web/router.ex` (modify) | `:phone_upload` pipeline, `/up` routes, tray route, `NoteFiles` on_mount |
| `lib/full_circle_web/note_files.ex` | `on_mount` hook + `listen/3` registry |
| `lib/full_circle_web/live/note_live/phone_qr_component.ex` | "📱 From phone" button + QR popover |
| `lib/full_circle_web/components/note_components.ex` (modify) | `attach_button` takes `id`/`url`/`multiple`; `file_grid` takes `remove_event`/`confirm` |
| `lib/full_circle_web/live/note_live/composer_component.ex` (modify) | Tray state, tray UI, save/cancel wiring |
| `lib/full_circle_web/live/note_live/notes_panel_component.ex` (modify) | Phone QR on posts; reload on broadcast; drop edit-box 📎 |
| `lib/full_circle_web/live/note_live/form.ex` (modify) | Same, for the note page |
| `assets/js/note_attach.js` (modify) | Shared `uploadFiles`; `multiple`; `NoteDrop` hook (drop + paste) |
| `assets/js/app.js` (modify) | Register `NoteDrop` |
| `assets/js/phone_upload.js` | The phone page: scan / photo / files, enhance filters, resume |
| `config/config.exs` (modify) | esbuild entry `js/phone_upload.js` |
| `test/support/fixtures/notes_fixtures.ex` (modify) | `real_jpeg_file/1`, `tray_fixture/2` |
| `.claude/skills/notes.md` (modify) | Attachments section rewritten |

---

### Task 1: Tray table and attachment xor constraint

**Files:**
- Create: `priv/repo/migrations/20261004120000_add_note_trays.exs`
- Create: `lib/full_circle/notes/note_tray.ex`
- Modify: `lib/full_circle/notes/note_attachment.ex`
- Modify: `docs/superpowers/specs/2026-10-04-note-attach-from-phone-design.md` (the amendment)
- Test: `test/full_circle/notes_trays_test.exs`

**Interfaces:**
- Produces: `%FullCircle.Notes.NoteTray{id, company_id, user_id, note_id, closed_at, inserted_at}`; `NoteAttachment.changeset/2` accepting `tray_id` (and no longer requiring `note_id`), with error `{"must belong to a note or a tray", _}` on `:note_id`.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle/notes_trays_test.exs`:

```elixir
defmodule FullCircle.NotesTraysTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes.{NoteAttachment, NoteTray}

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company, note: note_fixture(company, admin)}
  end

  describe "note_xor_tray" do
    setup ctx do
      tray = Repo.insert!(%NoteTray{company_id: ctx.company.id, user_id: ctx.admin.id})

      base = %{
        file_name: "a.jpg",
        content_type: "image/jpeg",
        byte_size: 1,
        path: "x",
        company_id: ctx.company.id,
        uploaded_by_id: ctx.admin.id
      }

      %{tray: tray, base: base}
    end

    defp insert(attrs), do: %NoteAttachment{} |> NoteAttachment.changeset(attrs) |> Repo.insert()

    test "neither note nor tray is refused", ctx do
      assert {:error, cs} = insert(ctx.base)
      assert {"must belong to a note or a tray", _} = cs.errors[:note_id]
    end

    test "both note and tray is refused", ctx do
      assert {:error, _} = insert(Map.merge(ctx.base, %{note_id: ctx.note.id, tray_id: ctx.tray.id}))
    end

    test "a tray alone or a note alone is fine", ctx do
      assert {:ok, _} = insert(Map.put(ctx.base, :tray_id, ctx.tray.id))
      assert {:ok, _} = insert(Map.put(ctx.base, :note_id, ctx.note.id))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/notes_trays_test.exs`
Expected: compile error, `FullCircle.Notes.NoteTray.__struct__/0 is undefined`.

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20261004120000_add_note_trays.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.AddNoteTrays do
  use Ecto.Migration

  def change do
    # A write box's files before Save. note_id is set when Save claims the
    # tray, so a phone upload that arrives after Save can follow to the note.
    create table(:note_trays) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :note_id, references(:notes, on_delete: :delete_all)
      add :closed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:note_trays, [:inserted_at])

    execute "ALTER TABLE note_attachments ALTER COLUMN note_id DROP NOT NULL",
            "ALTER TABLE note_attachments ALTER COLUMN note_id SET NOT NULL"

    alter table(:note_attachments) do
      add :tray_id, references(:note_trays, on_delete: :nothing)
    end

    create index(:note_attachments, [:tray_id])

    create constraint(:note_attachments, :note_xor_tray,
             check: "(note_id IS NULL) <> (tray_id IS NULL)"
           )
  end
end
```

- [ ] **Step 4: Write the schema and changeset**

Create `lib/full_circle/notes/note_tray.ex`:

```elixir
defmodule FullCircle.Notes.NoteTray do
  @moduledoc """
  A write box's files before Save (see `FullCircle.Notes.Trays`). Open while
  `closed_at` is nil; Save sets `note_id` and `closed_at`, Cancel only
  `closed_at`.
  """
  use FullCircle.Schema

  schema "note_trays" do
    field :closed_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :user, FullCircle.UserAccounts.User
    belongs_to :note, FullCircle.Notes.Note

    timestamps(type: :utc_datetime)
  end
end
```

Replace the body of `lib/full_circle/notes/note_attachment.ex` with:

```elixir
defmodule FullCircle.Notes.NoteAttachment do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "note_attachments" do
    field :file_name, :string
    field :content_type, :string
    field :byte_size, :integer
    field :path, :string
    field :removed_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    # Exactly one of note / tray (the note_xor_tray check): a tray file is
    # waiting for its write box's Save.
    belongs_to :note, FullCircle.Notes.Note
    belongs_to :tray, FullCircle.Notes.NoteTray
    belongs_to :uploaded_by, FullCircle.UserAccounts.User
    belongs_to :removed_by, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(att, attrs) do
    att
    |> cast(
      attrs,
      ~w(file_name content_type byte_size path company_id note_id tray_id uploaded_by_id)a
    )
    |> validate_required(~w(file_name content_type byte_size path company_id uploaded_by_id)a)
    |> foreign_key_constraint(:note_id)
    |> foreign_key_constraint(:tray_id)
    |> check_constraint(:note_id,
      name: :note_xor_tray,
      message: "must belong to a note or a tray"
    )
  end
end
```

- [ ] **Step 5: Run the migration and the tests**

Run: `mix ecto.migrate && mix test test/full_circle/notes_trays_test.exs test/full_circle/notes_attachments_test.exs`
Expected: all PASS. The existing attachment tests still pass because they always set `note_id`.

- [ ] **Step 6: Record the spec amendment**

In `docs/superpowers/specs/2026-10-04-note-attach-from-phone-design.md`, under "### Data: the tray is attachments without a note", replace the paragraph that starts "Migration on `note_attachments`:" (and its three bullets) with:

```markdown
A small `note_trays` table (`id, company_id, user_id, note_id, closed_at`)
names each tray: its owner, and after Save the note it became. Amended during
planning: without it, a phone upload arriving after Save or Cancel had nowhere
to go. Late phone uploads now follow a saved tray to its note, and are refused
("closed on the desktop") after Cancel.

Migration on `note_attachments`:

- `note_id` becomes nullable;
- add `tray_id` referencing `note_trays`, nullable and indexed;
- add a check constraint: exactly one of `note_id` and `tray_id` is set.
```

and in the next paragraph's ownership sentence, replace "There is no tray table, so the rule is enforced on rows: an upload is refused if the tray already holds a row from another user or another company." with "The tray row records its owner; an upload into another user's tray id is refused."

- [ ] **Step 7: Commit**

```bash
mix format priv/repo/migrations/20261004120000_add_note_trays.exs lib/full_circle/notes/note_tray.ex lib/full_circle/notes/note_attachment.ex test/full_circle/notes_trays_test.exs
git add priv/repo/migrations/20261004120000_add_note_trays.exs lib/full_circle/notes/note_tray.ex lib/full_circle/notes/note_attachment.ex test/full_circle/notes_trays_test.exs docs/superpowers/specs/2026-10-04-note-attach-from-phone-design.md
git commit -m "feat(notes): note_trays table; an attachment belongs to a note or a tray

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Trays context, tray uploads, and the files broadcast

**Files:**
- Create: `lib/full_circle/notes/trays.ex`
- Modify: `lib/full_circle/notes/attachments.ex`
- Modify: `test/support/fixtures/notes_fixtures.ex`
- Test: `test/full_circle/notes_trays_test.exs` (append)

**Interfaces:**
- Consumes: `NoteTray`, `NoteAttachment.changeset/2` (Task 1).
- Produces:
  - `Trays.open(id, company, user) :: {:ok, NoteTray} | {:error, :not_found}`: creates the tray if missing. An id belonging to another user or company → `{:error, :not_found}`.
  - `Trays.get(id, company, user) :: {:ok, NoteTray} | {:error, :not_found}`
  - `Trays.list(tray_id, company, user) :: [NoteAttachment]`: the tray's files, oldest first.
  - `Trays.discard_file(att_id, tray_id, company, user) :: :ok`
  - `Trays.cancel(tray_id, company, user) :: :ok`
  - `Attachments.attach_to_tray(tray_id, upload, company, user) :: {:ok, NoteAttachment} | {:error, :not_found | :tray_closed | :too_large | :unsupported_type | ...} | :not_authorise`. It follows a *saved* tray to its note.
  - `Attachments.topic(company_id) :: String.t()`; every successful upload broadcasts `{:note_files_changed, {:tray, id} | {:note, id}}` on it.
  - Fixture `tray_fixture(company, user) :: NoteTray`.

- [ ] **Step 1: Add fixtures**

In `test/support/fixtures/notes_fixtures.ex`, add above `defp tmp_file`:

```elixir
  def tray_fixture(company, user) do
    {:ok, tray} = FullCircle.Notes.Trays.open(Ecto.UUID.generate(), company, user)
    tray
  end
```

- [ ] **Step 2: Write the failing tests**

Append inside `FullCircle.NotesTraysTest` (before the final `end`). Add `alias FullCircle.Notes.{Attachments, Trays}` and `alias FullCircle.Notes` beside the existing alias line at the top:

```elixir
  describe "trays" do
    test "open creates once and is idempotent for its owner", ctx do
      id = Ecto.UUID.generate()
      assert {:ok, %NoteTray{id: ^id}} = Trays.open(id, ctx.company, ctx.admin)
      assert {:ok, %NoteTray{id: ^id}} = Trays.open(id, ctx.company, ctx.admin)
      assert Repo.aggregate(NoteTray, :count) == 1
    end

    test "another user cannot open, read or fill someone's tray", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)
      clerk = user_with_role(ctx.company, ctx.admin, "clerk")

      assert {:error, :not_found} = Trays.open(tray.id, ctx.company, clerk)

      assert {:error, :not_found} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "a.jpg"},
                 ctx.company,
                 clerk
               )

      assert Trays.list(tray.id, ctx.company, clerk) == []
    end

    test "a tray upload is stored under notes/tray/<id>, listed, and broadcast", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Attachments.topic(ctx.company.id))

      assert {:ok, att} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "a.jpg"},
                 ctx.company,
                 ctx.admin
               )

      assert att.tray_id == tray.id and is_nil(att.note_id)
      assert String.starts_with?(att.path, "#{ctx.company.id}/notes/tray/#{tray.id}/")
      assert [%{id: id}] = Trays.list(tray.id, ctx.company, ctx.admin)
      assert id == att.id
      tray_id = tray.id
      assert_receive {:note_files_changed, {:tray, ^tray_id}}
    end

    test "a note upload broadcasts its note", ctx do
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Attachments.topic(ctx.company.id))

      {:ok, _} =
        Attachments.attach(
          ctx.note,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      note_id = ctx.note.id
      assert_receive {:note_files_changed, {:note, ^note_id}}
    end

    test "discard_file hard-deletes the row and the file", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)

      {:ok, att} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: jpeg_file(), file_name: "a.jpg"},
          ctx.company,
          ctx.admin
        )

      path = Attachments.abs_path(att)
      assert :ok = Trays.discard_file(att.id, tray.id, ctx.company, ctx.admin)
      refute File.exists?(path)
      assert Repo.get(NoteAttachment, att.id) == nil
    end

    test "cancel deletes every file and closes the tray; later uploads are refused", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)
      up = %{path: jpeg_file(), file_name: "a.jpg"}
      {:ok, a1} = Attachments.attach_to_tray(tray.id, up, ctx.company, ctx.admin)
      {:ok, a2} = Attachments.attach_to_tray(tray.id, %{up | path: jpeg_file()}, ctx.company, ctx.admin)

      assert :ok = Trays.cancel(tray.id, ctx.company, ctx.admin)
      refute File.exists?(Attachments.abs_path(a1))
      refute File.exists?(Attachments.abs_path(a2))
      assert Trays.list(tray.id, ctx.company, ctx.admin) == []
      assert %NoteTray{closed_at: %DateTime{}} = Repo.get(NoteTray, tray.id)

      assert {:error, :tray_closed} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "late.jpg"},
                 ctx.company,
                 ctx.admin
               )
    end

    test "an upload into a saved tray follows it to the note", ctx do
      tray = tray_fixture(ctx.company, ctx.admin)

      tray
      |> Ecto.Changeset.change(note_id: ctx.note.id, closed_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert {:ok, att} =
               Attachments.attach_to_tray(
                 tray.id,
                 %{path: jpeg_file(), file_name: "late.jpg"},
                 ctx.company,
                 ctx.admin
               )

      assert att.note_id == ctx.note.id and is_nil(att.tray_id)
      assert [%{file_name: "late.jpg"}] =
               Notes.get_note(ctx.note.id, ctx.company, ctx.admin).attachments
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/full_circle/notes_trays_test.exs`
Expected: compile error, `FullCircle.Notes.Trays.open/3 is undefined`.

- [ ] **Step 4: Write `Trays`**

Create `lib/full_circle/notes/trays.ex`:

```elixir
defmodule FullCircle.Notes.Trays do
  @moduledoc """
  A write box's files before Save. The box makes a random tray id when it
  opens; the first upload (desktop or phone) creates the `note_trays` row for
  that user. Save claims the tray inside the note's own transaction
  (`claim/5`), Cancel hard-deletes its files (they never belonged to a note,
  so there is no history to keep). A tray belongs to one user in one company:
  any other user's id is simply "not found". Contract: `.claude/skills/notes.md`.
  """
  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Notes.{Attachments, NoteAttachment, NoteTray}

  def open(id, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.insert(%NoteTray{id: id, company_id: company.id, user_id: user.id},
        on_conflict: :nothing,
        conflict_target: :id
      )

      get(id, company, user)
    else
      :error -> {:error, :not_found}
    end
  end

  def get(id, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %NoteTray{} = tray <-
           Repo.get_by(NoteTray, id: id, company_id: company.id, user_id: user.id) do
      {:ok, tray}
    else
      _ -> {:error, :not_found}
    end
  end

  def list(tray_id, company, user) do
    case get(tray_id, company, user) do
      {:ok, tray} ->
        from(a in NoteAttachment, where: a.tray_id == ^tray.id, order_by: [asc: a.inserted_at])
        |> Repo.all()

      _ ->
        []
    end
  end

  def discard_file(att_id, tray_id, company, user) do
    with {:ok, tray} <- get(tray_id, company, user),
         {:ok, att_id} <- Ecto.UUID.cast(att_id),
         %NoteAttachment{} = att <- Repo.get_by(NoteAttachment, id: att_id, tray_id: tray.id) do
      delete_files([att])
    end

    :ok
  end

  def cancel(tray_id, company, user) do
    with {:ok, tray} <- get(tray_id, company, user) do
      delete_files(Repo.all(from a in NoteAttachment, where: a.tray_id == ^tray.id))

      tray
      |> Ecto.Changeset.change(closed_at: DateTime.utc_now(:second))
      |> Repo.update!()
    end

    :ok
  end

  # Rows first, then files: a crash between leaves orphan files (pruned with
  # their folder), never rows pointing at nothing.
  defp delete_files([]), do: :ok

  defp delete_files(atts) do
    Repo.delete_all(from a in NoteAttachment, where: a.id in ^Enum.map(atts, & &1.id))
    Enum.each(atts, &File.rm(Attachments.abs_path(&1)))
  end
end
```

- [ ] **Step 5: Teach `Attachments` to write into a tray, and broadcast**

In `lib/full_circle/notes/attachments.ex`:

1. Change the alias line to `alias FullCircle.Notes.{Note, NoteAttachment, Trays}`.

2. Add below `def content_types`:

```elixir
  @doc "PubSub topic for \"a file landed\" in this company (see FullCircleWeb.NoteFiles)."
  def topic(company_id), do: "note_files:#{company_id}"
```

3. Replace `attach/4` with this version, and add `attach_to_tray/4` after it:

```elixir
  def attach(%Note{} = note, upload, company, user) do
    with %Note{} = note <- Notes.get_note(note.id, company, user) || {:error, :note_not_found},
         true <- Notes.may_edit?(note, user, Notes.rights(company, user)) || :not_authorise do
      store({:note, note}, upload, company, user)
    end
  end

  @doc """
  Adds a file to the caller's tray. A tray already saved follows to its note
  (a phone still sending after the desktop pressed Save); a cancelled one is
  `{:error, :tray_closed}`.
  """
  def attach_to_tray(tray_id, upload, company, user) do
    case Trays.get(tray_id, company, user) do
      {:ok, %{closed_at: nil} = tray} -> store({:tray, tray}, upload, company, user)
      {:ok, %{note_id: nil}} -> {:error, :tray_closed}
      {:ok, %{note_id: note_id}} -> attach(%Note{id: note_id}, upload, company, user)
      error -> error
    end
  end

  defp store(owner, upload, company, user) do
    src = upload[:path] || upload["path"]
    file_name = upload[:file_name] || upload["file_name"] || "file"

    with {:ok, size} <- assert_size(src),
         {:ok, content_type} <- sniff(src) do
      # file_name is display only; cap it under the varchar(255) column.
      name = file_name |> Path.basename() |> String.slice(0, 200)
      write(owner, src, name, size, content_type, company, user)
    end
  end
```

4. Replace `write/7` (the `defp write(note, ...)` function, including its `rescue`) with:

```elixir
  defp write(owner, src, file_name, size, content_type, company, user) do
    {dir, owner_attrs, target} =
      case owner do
        {:note, note} -> {[note.id], %{note_id: note.id}, {:note, note.id}}
        {:tray, tray} -> {["tray", tray.id], %{tray_id: tray.id}, {:tray, tray.id}}
      end

    rel = Path.join([company.id, "notes"] ++ dir ++ [Ecto.UUID.generate() <> ext(content_type)])
    abs = Path.join(uploads_dir(), rel)
    File.mkdir_p!(Path.dirname(abs))
    File.cp!(src, abs)

    %NoteAttachment{}
    |> NoteAttachment.changeset(
      Map.merge(owner_attrs, %{
        file_name: file_name,
        content_type: content_type,
        byte_size: size,
        path: rel,
        company_id: company.id,
        uploaded_by_id: user.id
      })
    )
    |> Repo.insert()
    |> case do
      {:ok, att} ->
        Phoenix.PubSub.broadcast(
          FullCircle.PubSub,
          topic(company.id),
          {:note_files_changed, target}
        )

        {:ok, att}

      {:error, cs} ->
        # Without its row the file is garbage nothing will ever find.
        File.rm(abs)
        {:error, cs}
    end
  rescue
    e in [File.Error, File.CopyError] ->
      Logger.error("note attachment copy failed: #{Exception.message(e)}")
      {:error, :copy_failed}
  end
```

5. Make `uploads_dir/0` public, because `Scans` (Task 5) needs it. Change `defp uploads_dir` to `def uploads_dir`.

- [ ] **Step 6: Run the tests**

Run: `mix test test/full_circle/notes_trays_test.exs test/full_circle/notes_attachments_test.exs test/full_circle_web/controllers/note_attachment_controller_test.exs`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
mix format lib/full_circle/notes/trays.ex lib/full_circle/notes/attachments.ex test/support/fixtures/notes_fixtures.ex test/full_circle/notes_trays_test.exs
git add lib/full_circle/notes/trays.ex lib/full_circle/notes/attachments.ex test/support/fixtures/notes_fixtures.ex test/full_circle/notes_trays_test.exs
git commit -m "feat(notes): tray uploads, cancel, and a note_files broadcast on every upload

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Save claims the tray

**Files:**
- Modify: `lib/full_circle/notes/trays.ex` (add `claim/5`)
- Modify: `lib/full_circle/notes.ex` (`create_note/3`, `update_note/4`)
- Test: `test/full_circle/notes_trays_test.exs` (append)

**Interfaces:**
- Consumes: `Trays.get/3`, `NoteTray`, `NoteAttachment` (Tasks 1–2).
- Produces:
  - `Trays.claim(repo, tray_id | nil, note, company, user) :: {:ok, count}`: moves an open tray's files onto `note` and closes the tray as saved. A nil, unknown or closed tray gives `{:ok, 0}`.
  - `Notes.create_note/3` and `Notes.update_note/4` read `attrs["tray_id"]` and claim it in the same transaction. A note with **only** new files and no field changes still claims.

- [ ] **Step 1: Write the failing tests**

Append inside `FullCircle.NotesTraysTest`:

```elixir
  describe "save claims the tray" do
    defp tray_with_file(ctx) do
      tray = tray_fixture(ctx.company, ctx.admin)

      {:ok, att} =
        Attachments.attach_to_tray(
          tray.id,
          %{path: jpeg_file(), file_name: "scan.jpg"},
          ctx.company,
          ctx.admin
        )

      {tray, att}
    end

    test "create_note attaches the tray's files and closes it as saved", ctx do
      {tray, att} = tray_with_file(ctx)

      assert {:ok, note} =
               Notes.create_note(%{"body" => "with file", "tray_id" => tray.id}, ctx.company, ctx.admin)

      assert [%{id: id}] = note.attachments
      assert id == att.id
      assert %{note_id: note_id, closed_at: %DateTime{}} = Repo.get(NoteTray, tray.id)
      assert note_id == note.id
    end

    test "a failed create (invalid) leaves the tray as it was", ctx do
      {tray, _att} = tray_with_file(ctx)

      assert {:error, %Ecto.Changeset{}} =
               Notes.create_note(
                 %{"body" => "x", "visibility" => ["nonsense"], "tray_id" => tray.id},
                 ctx.company,
                 ctx.admin
               )

      assert [_] = Trays.list(tray.id, ctx.company, ctx.admin)
      assert %{closed_at: nil} = Repo.get(NoteTray, tray.id)
    end

    test "update_note with only new files (no field change) still claims", ctx do
      {tray, _att} = tray_with_file(ctx)

      assert {:ok, note} =
               Notes.update_note(ctx.note, %{"tray_id" => tray.id}, ctx.company, ctx.admin)

      assert [%{file_name: "scan.jpg"}] = note.attachments
    end

    test "a stale update leaves the tray as it was", ctx do
      {tray, _att} = tray_with_file(ctx)
      {:ok, _} = Notes.update_note(ctx.note, %{"body" => "someone else"}, ctx.company, ctx.admin)

      assert {:error, :stale} =
               Notes.update_note(
                 ctx.note,
                 %{"body" => "mine", "tray_id" => tray.id},
                 ctx.company,
                 ctx.admin
               )

      assert [_] = Trays.list(tray.id, ctx.company, ctx.admin)
    end

    test "a tray id from another user is ignored, not claimed", ctx do
      {tray, _att} = tray_with_file(ctx)
      manager = user_with_role(ctx.company, ctx.admin, "manager")

      assert {:ok, note} =
               Notes.create_note(%{"body" => "x", "tray_id" => tray.id}, ctx.company, manager)

      assert note.attachments == []
      assert [_] = Trays.list(tray.id, ctx.company, ctx.admin)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/notes_trays_test.exs`
Expected: the five new tests FAIL. For example, `note.attachments == []` where one file was expected.

- [ ] **Step 3: Add `claim/5`**

In `lib/full_circle/notes/trays.ex`, add after `cancel/3`:

```elixir
  @doc """
  Moves an open tray's files onto `note` and closes the tray as saved. Runs
  inside the note's transaction (`repo` is the Multi's). The tray row is
  locked so a phone upload racing the save either lands in the tray before
  the claim or follows the saved tray to the note afterwards — never lost.
  """
  def claim(_repo, nil, _note, _company, _user), do: {:ok, 0}

  def claim(repo, tray_id, note, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(tray_id),
         %NoteTray{} = tray <-
           repo.one(
             from t in NoteTray,
               where:
                 t.id == ^id and t.company_id == ^company.id and t.user_id == ^user.id and
                   is_nil(t.closed_at),
               lock: "FOR UPDATE"
           ) do
      {n, _} =
        repo.update_all(from(a in NoteAttachment, where: a.tray_id == ^tray.id),
          set: [note_id: note.id, tray_id: nil]
        )

      tray
      |> Ecto.Changeset.change(note_id: note.id, closed_at: DateTime.utc_now(:second))
      |> repo.update!()

      {:ok, n}
    else
      _ -> {:ok, 0}
    end
  end
```

The `update_all` sets `note_id` and clears `tray_id` in one statement, so the xor check holds at every moment.

- [ ] **Step 4: Claim inside `create_note/3`**

In `lib/full_circle/notes.ex`, add `alias FullCircle.Notes.Trays` beside the module's other aliases. In `create_note/3`, insert this line directly after `|> insert_links(Map.get(attrs, "links") || [], company, user)`:

```elixir
          |> Multi.run(:tray, fn repo, %{note: note} ->
            Trays.claim(repo, Map.get(attrs, "tray_id"), note, company, user)
          end)
```

The `{:ok, %{note: note}}` branch already preloads `:attachments` after commit, so the claimed files come back on the note.

- [ ] **Step 5: Claim inside `update_note/4`**

In `update_note/4`:

1. Capture the tray before `attrs` is narrowed. Change the first line of the function body to:

```elixir
    tray_id = Map.get(attrs, "tray_id")
    attrs = attrs |> normalize_visibility() |> Map.drop(["links", "reply_to_id", "tray_id"])
```

2. Replace the no-change branch `{:ok, current}` with:

```elixir
      if changeset.changes == %{} do
        # Only new files (or nothing at all): no version, no lock bump.
        {:ok, _} = Repo.transaction(fn -> Trays.claim(Repo, tray_id, current, company, user) end)
        {:ok, Repo.preload(current, [:attachments], force: true)}
```

3. In the change branch's Multi, insert after the `|> Multi.run(:replies, ...)` line:

```elixir
        |> Multi.run(:tray, fn repo, %{note: n} -> Trays.claim(repo, tray_id, n, company, user) end)
```

The stale path raises `Ecto.StaleEntryError` inside `Multi.update(:note, ...)`, before `:tray` runs, and the transaction rolls back, so a stale save never claims.

- [ ] **Step 6: Run tests**

Run: `mix test test/full_circle/notes_trays_test.exs test/full_circle/notes_test.exs test/full_circle/notes_replies_test.exs`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
mix format lib/full_circle/notes/trays.ex lib/full_circle/notes.ex test/full_circle/notes_trays_test.exs
git add lib/full_circle/notes/trays.ex lib/full_circle/notes.ex test/full_circle/notes_trays_test.exs
git commit -m "feat(notes): saving a note claims its write box's tray in the same transaction

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: PDF from JPEG pages

**Files:**
- Create: `lib/full_circle/notes/scan_pdf.ex`
- Modify: `test/support/fixtures/notes_fixtures.ex` (`real_jpeg_file/1`)
- Test: `test/full_circle/notes_scan_pdf_test.exs`

**Interfaces:**
- Produces:
  - `ScanPdf.jpeg_info(binary) :: {:ok, %{width: pos_integer, height: pos_integer, components: 1 | 3}} | :error`
  - `ScanPdf.build([path], out_path) :: :ok | {:error, :no_pages | :bad_page | File.posix()}`
  - Fixture `real_jpeg_file(:rgb | :gray) :: path`. `:rgb` is 40×30 with 3 components; `:gray` is 30×40 with 1 component.

- [ ] **Step 1: Add the real JPEG fixtures**

These are real 40×30 RGB and 30×40 greyscale JPEGs (made with `convert`). The existing `jpeg_file/0` has only the magic bytes, so it can't be measured or rendered. In `test/support/fixtures/notes_fixtures.ex`, add above `defp tmp_file`:

```elixir
  # Real, decodable JPEGs (ImageMagick: 40x30 sRGB, 30x40 greyscale). ScanPdf
  # reads their size from the SOF marker and pdftoppm must render them.
  @rgb_jpeg "/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAeACgDASIAAhEBAxEB/8QAFwABAQEBAAAAAAAAAAAAAAAAAAcGBf/EACUQAAEEAQIFBQAAAAAAAAAAAAEAAgMEBQYRBxY1QVFUdJKy0v/EABgBAAMBAQAAAAAAAAAAAAAAAAIDBQQG/8QAHhEAAQUAAwEBAAAAAAAAAAAAAgABAwQRBRMxQXH/2gAMAwEAAhEDEQA/AN/mctXw1Rlm0yV7HSCMCMAncgnuR4XF58xXp7vwb+k4hdCg9y36vU6WOaYgLGXRcZxsFiDsk3df6qphtS0szbfWqxWGPbGZCZGtA2BA7E+V2lOuHnXZ/bO+zVRU+E3MddTeSrhXneOPzGRERNU9cXVWJsZnGx1qr4mPbMJCZCQNgHDsD5WU5DyvqKXzd+VRUSjhE311Qr8lPXDrjzPxZTSumruGyUlm1LXex0JjAjc4nclp7geFq0RGAMDYyzWLB2D7JPURERJC/9k="
  @gray_jpeg "/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//wAALCAAoAB4BAREA/8QAFwABAQEBAAAAAAAAAAAAAAAABgAHBf/EACYQAAEDAwMCBwAAAAAAAAAAAAEAAgMEBQYRISIHQRc2VHSTstL/2gAIAQEAAD8AcZHkFJjdvjra6OeSN8oiAhaCdSCe5G3Eo14q2H0ly+OP9rrY3mtsyS4SUVDBVxyRxGUmZjQNAQOzjvyCSoJ1f8q0vvWfSRY6nfSDzTVeyf8Adi2JGs7x+rySyw0VDJBHIyobKTM4gaBrh2B35BAvCq/ertvySfhJcEwq543epq2unpJI5Kd0QEL3E6lzT3aNuJT1SlKUpSl//9k="

  def real_jpeg_file(:rgb), do: tmp_file(".jpg", Base.decode64!(@rgb_jpeg))
  def real_jpeg_file(:gray), do: tmp_file(".jpg", Base.decode64!(@gray_jpeg))
```

- [ ] **Step 2: Write the failing tests**

Create `test/full_circle/notes_scan_pdf_test.exs`:

```elixir
defmodule FullCircle.NotesScanPdfTest do
  use ExUnit.Case, async: true

  import FullCircle.NotesFixtures

  alias FullCircle.Notes.ScanPdf

  defp out, do: Path.join(System.tmp_dir!(), "scan_#{System.unique_integer([:positive])}.pdf")

  test "jpeg_info reads size and components from the SOF marker" do
    assert {:ok, %{width: 40, height: 30, components: 3}} =
             ScanPdf.jpeg_info(File.read!(real_jpeg_file(:rgb)))

    assert {:ok, %{width: 30, height: 40, components: 1}} =
             ScanPdf.jpeg_info(File.read!(real_jpeg_file(:gray)))
  end

  test "jpeg_info refuses non-JPEG and truncated JPEG" do
    assert :error = ScanPdf.jpeg_info("%PDF-1.4 nope")
    assert :error = ScanPdf.jpeg_info(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 16>>)
    # magic bytes only (the old fixture): no SOF marker
    assert :error = ScanPdf.jpeg_info(File.read!(jpeg_file()))
  end

  test "build refuses no pages and a bad page" do
    assert {:error, :no_pages} = ScanPdf.build([], out())
    assert {:error, :bad_page} = ScanPdf.build([real_jpeg_file(:rgb), text_file()], out())
  end

  test "build writes a PDF whose xref offsets point at each object" do
    path = out()
    assert :ok = ScanPdf.build([real_jpeg_file(:rgb), real_jpeg_file(:gray)], path)
    pdf = File.read!(path)

    assert String.starts_with?(pdf, "%PDF-1.4")
    assert pdf =~ "/Count 2"
    assert pdf =~ "/ColorSpace /DeviceRGB"
    assert pdf =~ "/ColorSpace /DeviceGray"

    [_, xref_at] = Regex.run(~r/startxref\n(\d+)\n%%EOF\n$/, pdf)
    xref = binary_part(pdf, String.to_integer(xref_at), byte_size(pdf) - String.to_integer(xref_at))
    offsets = Regex.scan(~r/^(\d{10}) 00000 n $/m, xref) |> Enum.map(fn [_, o] -> String.to_integer(o) end)

    for {off, n} <- Enum.with_index(offsets, 1) do
      assert binary_part(pdf, off, byte_size("#{n} 0 obj")) == "#{n} 0 obj"
    end
  end

  @tag :pdftoppm
  test "poppler renders every page" do
    path = out()
    :ok = ScanPdf.build([real_jpeg_file(:rgb), real_jpeg_file(:gray)], path)
    base = path <> "-render"
    assert {_, 0} = System.cmd("pdftoppm", ["-jpeg", "-r", "20", path, base])
    assert File.exists?(base <> "-1.jpg") and File.exists?(base <> "-2.jpg")
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/full_circle/notes_scan_pdf_test.exs`
Expected: FAIL, `FullCircle.Notes.ScanPdf.jpeg_info/1 is undefined`.

- [ ] **Step 4: Write `ScanPdf`**

Create `lib/full_circle/notes/scan_pdf.ex`:

```elixir
defmodule FullCircle.Notes.ScanPdf do
  @moduledoc """
  Builds a PDF 1.4 file from JPEG pages, with no dependency: each JPEG is
  embedded as-is (`/DCTDecode`), so nothing is re-encoded. A page is sized
  from the image at 150 dpi and shrunk to fit A4 (portrait or landscape to
  match the image). Used for phone scans — see `FullCircle.Notes.Scans`.
  """

  @dpi 150
  @a4_short 595.28
  @a4_long 841.89

  @doc "Width, height and colour components from a JPEG's SOF marker."
  def jpeg_info(<<0xFF, 0xD8, rest::binary>>), do: scan(rest)
  def jpeg_info(_), do: :error

  # SOF0..SOF15 carry the frame size; C4 (DHT), C8 (JPG) and CC (DAC) share
  # the range but are not frames.
  defp scan(<<0xFF, m, _len::16, _precision, h::16, w::16, nc, _::binary>>)
       when m in 0xC0..0xCF and m not in [0xC4, 0xC8, 0xCC] do
    if nc in [1, 3] and w > 0 and h > 0,
      do: {:ok, %{width: w, height: h, components: nc}},
      else: :error
  end

  # Fill bytes before a marker.
  defp scan(<<0xFF, 0xFF, rest::binary>>), do: scan(<<0xFF, rest::binary>>)

  # Markers without a length.
  defp scan(<<0xFF, m, rest::binary>>) when m in 0xD0..0xD9 or m == 0x01, do: scan(rest)

  defp scan(<<0xFF, _m, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(skip), tail::binary>> -> scan(tail)
      _ -> :error
    end
  end

  defp scan(_), do: :error

  @doc "Writes the PDF of `jpeg_paths`, in order, to `out_path`."
  def build([], _out_path), do: {:error, :no_pages}

  def build(jpeg_paths, out_path) do
    with {:ok, pages} <- read_pages(jpeg_paths) do
      File.write(out_path, render(pages))
    end
  end

  defp read_pages(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, bin} <- File.read(path),
           {:ok, info} <- jpeg_info(bin) do
        {:cont, {:ok, [{bin, info} | acc]}}
      else
        _ -> {:halt, {:error, :bad_page}}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      error -> error
    end
  end

  # Objects: 1 catalog, 2 page tree, then per page i (0-based):
  # 3+3i page, 4+3i content stream, 5+3i image.
  defp render(pages) do
    n = length(pages)
    kids = Enum.map_join(0..(n - 1), " ", &"#{3 + 3 * &1} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{n} >>"
      ] ++
        Enum.flat_map(Enum.with_index(pages), fn {{bin, info}, i} ->
          {pw, ph} = page_size(info.width, info.height)
          content = "q #{fmt(pw)} 0 0 #{fmt(ph)} 0 0 cm /Im0 Do Q"
          space = if info.components == 1, do: "DeviceGray", else: "DeviceRGB"

          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{fmt(pw)} #{fmt(ph)}] " <>
              "/Resources << /XObject << /Im0 #{5 + 3 * i} 0 R >> >> /Contents #{4 + 3 * i} 0 R >>",
            ["<< /Length #{byte_size(content)} >>\nstream\n", content, "\nendstream"],
            [
              "<< /Type /XObject /Subtype /Image /Width #{info.width} /Height #{info.height} " <>
                "/ColorSpace /#{space} /BitsPerComponent 8 /Filter /DCTDecode " <>
                "/Length #{byte_size(bin)} >>\nstream\n",
              bin,
              "\nendstream"
            ]
          ]
        end)

    header = <<"%PDF-1.4\n%", 0xE2, 0xE3, 0xCF, 0xD3, "\n">>

    {body, offsets, _pos} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], byte_size(header)}, fn {obj, num}, {acc, offs, pos} ->
        chunk = ["#{num} 0 obj\n", obj, "\nendobj\n"]
        {[acc, chunk], [pos | offs], pos + IO.iodata_length(chunk)}
      end)

    xref_at = byte_size(header) + IO.iodata_length(body)
    size = length(objects) + 1

    xref = [
      "xref\n0 #{size}\n0000000000 65535 f \n",
      offsets
      |> Enum.reverse()
      |> Enum.map(&(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n"))
    ]

    trailer = "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
    [header, body, xref, trailer]
  end

  defp page_size(w, h) do
    {wpt, hpt} = {w * 72 / @dpi, h * 72 / @dpi}
    {maxw, maxh} = if w > h, do: {@a4_long, @a4_short}, else: {@a4_short, @a4_long}
    scale = Enum.min([1.0, maxw / wpt, maxh / hpt])
    {wpt * scale, hpt * scale}
  end

  defp fmt(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
end
```

Each xref entry is exactly 20 bytes: 10 digits, a space, `00000`, a space, `n`, a space and a newline. PDF readers depend on that.

- [ ] **Step 5: Run tests**

Run: `mix test test/full_circle/notes_scan_pdf_test.exs`
Expected: all PASS (5 tests). The `:pdftoppm` test runs because poppler is installed locally.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/notes/scan_pdf.ex test/full_circle/notes_scan_pdf_test.exs test/support/fixtures/notes_fixtures.ex
git add lib/full_circle/notes/scan_pdf.ex test/full_circle/notes_scan_pdf_test.exs test/support/fixtures/notes_fixtures.ex
git commit -m "feat(notes): ScanPdf builds a PDF from JPEG pages without dependencies

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: A scan's page folder

**Files:**
- Create: `lib/full_circle/notes/scans.ex`
- Test: `test/full_circle/notes_scans_test.exs`

**Interfaces:**
- Consumes: `ScanPdf.jpeg_info/1`, `ScanPdf.build/2` (Task 4); `Attachments.uploads_dir/0`, `Attachments.max_bytes/0` (Task 2).
- Produces:
  - `Scans.add_page(company_id, scan_id, src_path) :: {:ok, count} | {:error, :invalid_scan | :not_jpeg | :too_large | :too_many_pages}`
  - `Scans.drop_last(company_id, scan_id) :: {:ok, count}`
  - `Scans.count(company_id, scan_id) :: non_neg_integer`
  - `Scans.finish(company_id, scan_id) :: {:ok, pdf_path} | {:error, :no_pages | :too_large | :bad_page}`. The caller attaches the PDF, then calls `discard/2`.
  - `Scans.discard(company_id, scan_id) :: :ok`
  - `Scans.prune_before(DateTime) :: non_neg_integer` (folders removed)
  - `Scans.max_pages() :: 30`

- [ ] **Step 1: Write the failing tests**

Create `test/full_circle/notes_scans_test.exs`:

```elixir
defmodule FullCircle.NotesScansTest do
  use ExUnit.Case, async: true

  import FullCircle.NotesFixtures

  alias FullCircle.Notes.Scans

  setup do
    %{cid: Ecto.UUID.generate(), sid: Ecto.UUID.generate()}
  end

  test "pages are numbered in order, retake drops the last", %{cid: c, sid: s} do
    assert {:ok, 1} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    assert {:ok, 2} = Scans.add_page(c, s, real_jpeg_file(:gray))
    assert {:ok, 1} = Scans.drop_last(c, s)
    assert {:ok, 2} = Scans.add_page(c, s, real_jpeg_file(:gray))
    assert Scans.count(c, s) == 2
  end

  test "a non-JPEG page is refused alone; the scan keeps its pages", %{cid: c, sid: s} do
    {:ok, 1} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    assert {:error, :not_jpeg} = Scans.add_page(c, s, pdf_file())
    assert {:error, :not_jpeg} = Scans.add_page(c, s, jpeg_file())
    assert Scans.count(c, s) == 1
  end

  test "a scan id must be a UUID (it names a folder)", %{cid: c} do
    assert {:error, :invalid_scan} = Scans.add_page(c, "../../etc", real_jpeg_file(:rgb))
    assert Scans.count(c, "../../etc") == 0
  end

  test "more than max_pages is refused", %{cid: c, sid: s} do
    for _ <- 1..Scans.max_pages(), do: {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    assert {:error, :too_many_pages} = Scans.add_page(c, s, real_jpeg_file(:rgb))
  end

  test "finish builds one PDF; discard removes the folder", %{cid: c, sid: s} do
    {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:gray))
    assert {:ok, pdf} = Scans.finish(c, s)
    assert File.read!(pdf) =~ "/Count 2"
    assert :ok = Scans.discard(c, s)
    refute File.exists?(pdf)
    assert Scans.count(c, s) == 0
  end

  test "finish with no pages", %{cid: c, sid: s} do
    assert {:error, :no_pages} = Scans.finish(c, s)
  end

  test "prune_before removes only folders older than the cutoff", %{cid: c, sid: s} do
    old = Ecto.UUID.generate()
    {:ok, _} = Scans.add_page(c, s, real_jpeg_file(:rgb))
    {:ok, _} = Scans.add_page(c, old, real_jpeg_file(:rgb))
    two_days_ago = System.os_time(:second) - 2 * 86_400
    File.touch!(Scans.dir(c, old), two_days_ago)

    assert Scans.prune_before(DateTime.add(DateTime.utc_now(), -1, :day)) >= 1
    assert Scans.count(c, old) == 0
    assert Scans.count(c, s) == 1
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/notes_scans_test.exs`
Expected: FAIL, `FullCircle.Notes.Scans.add_page/3 is undefined`.

- [ ] **Step 3: Write `Scans`**

Create `lib/full_circle/notes/scans.ex`:

```elixir
defmodule FullCircle.Notes.Scans do
  @moduledoc """
  A phone scan in progress: one folder of JPEG pages per scan
  (`<uploads>/<company>/scans/<scan_id>/001.jpg …`), no database rows. Pages
  upload as they are taken, so a phone page reloaded mid-scan loses nothing;
  `finish/2` builds one PDF (`ScanPdf`). The folder's mtime is its age for
  `prune_before/1` — a page write touches it.
  """

  alias FullCircle.Notes.{Attachments, ScanPdf}

  @max_pages 30

  def max_pages, do: @max_pages

  def dir(company_id, scan_id),
    do: Path.join([Attachments.uploads_dir(), company_id, "scans", scan_id])

  def add_page(company_id, scan_id, src) do
    with {:ok, scan_id} <- cast(scan_id),
         {:ok, %{size: size}} when size <= 10_000_000 <- File.stat(src),
         {:ok, bin} <- File.read(src),
         {:ok, _info} <- ScanPdf.jpeg_info(bin),
         n when n < @max_pages <- count(company_id, scan_id) do
      dir = dir(company_id, scan_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, page_name(n + 1)), bin)
      File.touch!(dir)
      {:ok, n + 1}
    else
      {:error, :invalid_scan} -> {:error, :invalid_scan}
      {:ok, %File.Stat{}} -> {:error, :too_large}
      n when is_integer(n) -> {:error, :too_many_pages}
      _ -> {:error, :not_jpeg}
    end
  end

  def drop_last(company_id, scan_id) do
    case pages(company_id, scan_id) do
      [] ->
        {:ok, 0}

      pages ->
        File.rm(List.last(pages))
        {:ok, length(pages) - 1}
    end
  end

  def count(company_id, scan_id), do: length(pages(company_id, scan_id))

  def finish(company_id, scan_id) do
    pdf = Path.join(dir(company_id, scan_id), "scan.pdf")

    with [_ | _] = pages <- pages(company_id, scan_id),
         :ok <- ScanPdf.build(pages, pdf),
         {:ok, %{size: size}} <- File.stat(pdf) do
      if size <= Attachments.max_bytes(), do: {:ok, pdf}, else: {:error, :too_large}
    else
      [] -> {:error, :no_pages}
      {:error, reason} -> {:error, reason}
    end
  end

  def discard(company_id, scan_id) do
    with {:ok, scan_id} <- cast(scan_id), do: File.rm_rf(dir(company_id, scan_id))
    :ok
  end

  def prune_before(%DateTime{} = cutoff) do
    limit = DateTime.to_unix(cutoff)

    Path.join([Attachments.uploads_dir(), "*", "scans", "*"])
    |> Path.wildcard()
    |> Enum.filter(fn dir ->
      match?({:ok, %{mtime: m}} when m < limit, File.stat(dir, time: :posix))
    end)
    |> Enum.map(&File.rm_rf/1)
    |> length()
  end

  defp pages(company_id, scan_id) do
    case cast(scan_id) do
      {:ok, id} -> Path.wildcard(Path.join(dir(company_id, id), "[0-9][0-9][0-9].jpg")) |> Enum.sort()
      _ -> []
    end
  end

  defp page_name(n), do: String.pad_leading(Integer.to_string(n), 3, "0") <> ".jpg"

  defp cast(scan_id) do
    case Ecto.UUID.cast(scan_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_scan}
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/notes_scans_test.exs`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/notes/scans.ex test/full_circle/notes_scans_test.exs
git add lib/full_circle/notes/scans.ex test/full_circle/notes_scans_test.exs
git commit -m "feat(notes): scan page folders, uploaded page by page, finished into one PDF

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Daily pruning of trays and scans

**Files:**
- Modify: `lib/full_circle/notes/trays.ex` (add `prune_before/1`)
- Create: `lib/full_circle/notes/tray_pruner.ex`
- Modify: `lib/full_circle/application.ex`, `config/test.exs`
- Test: `test/full_circle/notes_trays_test.exs` (append)

**Interfaces:**
- Consumes: `Scans.prune_before/1` (Task 5), `NoteTray`/`NoteAttachment`.
- Produces: `Trays.prune_before(DateTime) :: {:ok, %{trays: n, files: n, scans: n}}`; supervised `FullCircle.Notes.TrayPruner` with `prune/0`.

- [ ] **Step 1: Write the failing test**

Append inside `FullCircle.NotesTraysTest`:

```elixir
  describe "prune_before" do
    test "removes old trays and their unsaved files, never a note's files", ctx do
      old = tray_fixture(ctx.company, ctx.admin)
      fresh = tray_fixture(ctx.company, ctx.admin)
      up = fn -> %{path: jpeg_file(), file_name: "a.jpg"} end
      {:ok, old_att} = Attachments.attach_to_tray(old.id, up.(), ctx.company, ctx.admin)
      {:ok, _} = Attachments.attach_to_tray(fresh.id, up.(), ctx.company, ctx.admin)
      {:ok, note_att} = Attachments.attach(ctx.note, up.(), ctx.company, ctx.admin)

      two_days_ago = DateTime.add(DateTime.utc_now(:second), -2, :day)

      Repo.update_all(from(t in NoteTray, where: t.id == ^old.id),
        set: [inserted_at: two_days_ago]
      )

      assert {:ok, %{trays: 1, files: 1}} =
               Trays.prune_before(DateTime.add(DateTime.utc_now(), -1, :day))

      refute File.exists?(Attachments.abs_path(old_att))
      assert Repo.get(NoteTray, old.id) == nil
      assert Repo.get(NoteTray, fresh.id)
      assert File.exists?(Attachments.abs_path(note_att))
    end
  end
```

`FullCircle.DataCase` already imports `Ecto.Query`, so `from` works here.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/notes_trays_test.exs`
Expected: FAIL, `Trays.prune_before/1 is undefined`.

- [ ] **Step 3: Add `prune_before/1` to `Trays`**

Add `alias FullCircle.Notes.Scans` to the aliases in `lib/full_circle/notes/trays.ex`, then add after `claim/5`:

```elixir
  @doc """
  Housekeeping (`TrayPruner`): deletes trays opened before `cutoff` with any
  files still in them (a browser closed without Save or Cancel), plus scan
  folders older than `cutoff`. A saved tray has no files left — they moved
  to the note — so only its row goes.
  """
  def prune_before(%DateTime{} = cutoff) do
    trays = Repo.all(from t in NoteTray, where: t.inserted_at < ^cutoff, select: t.id)
    files = Repo.all(from a in NoteAttachment, where: a.tray_id in ^trays)
    delete_files(files)
    {n, _} = Repo.delete_all(from t in NoteTray, where: t.id in ^trays)
    {:ok, %{trays: n, files: length(files), scans: Scans.prune_before(cutoff)}}
  end
```

- [ ] **Step 4: Write the pruner (a copy of `PunchGate.PhotoPruner`)**

Create `lib/full_circle/notes/tray_pruner.ex`:

```elixir
defmodule FullCircle.Notes.TrayPruner do
  @moduledoc """
  Deletes write-box trays and phone scan folders older than a day: files
  picked or scanned and never saved or cancelled. A plain supervised process
  that wakes daily, like `PunchGate.PhotoPruner` (there is no job runner).
  """
  use GenServer
  require Logger

  alias FullCircle.Notes.Trays

  @day_ms 24 * 60 * 60 * 1000
  @first_run_ms 5 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if enabled?(), do: Process.send_after(self(), :prune, @first_run_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    prune()
    Process.send_after(self(), :prune, @day_ms)
    {:noreply, state}
  end

  @doc "Runs one pass now. Safe to call by hand from a release console."
  def prune do
    {:ok, counts} = Trays.prune_before(DateTime.add(DateTime.utc_now(), -1, :day))

    if counts.trays + counts.scans > 0,
      do: Logger.info("note tray pruner: #{inspect(counts)}")

    :ok
  rescue
    e ->
      # Never take the supervision tree down over housekeeping; retry tomorrow.
      Logger.error("note tray pruner failed: #{Exception.message(e)}")
      :error
  end

  defp enabled?, do: Application.get_env(:full_circle, :note_tray_prune_enabled, true)
end
```

In `lib/full_circle/application.ex`, add `FullCircle.Notes.TrayPruner,` on the line after `FullCircle.PunchGate.IngestLogPruner,`.

In `config/test.exs`, add after the `punch_ingest_log_prune_enabled` line:

```elixir
config :full_circle, note_tray_prune_enabled: false
```

- [ ] **Step 5: Run tests**

Run: `mix test test/full_circle/notes_trays_test.exs`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/notes/trays.ex lib/full_circle/notes/tray_pruner.ex lib/full_circle/application.ex config/test.exs test/full_circle/notes_trays_test.exs
git add lib/full_circle/notes/trays.ex lib/full_circle/notes/tray_pruner.ex lib/full_circle/application.ex config/test.exs test/full_circle/notes_trays_test.exs
git commit -m "feat(notes): daily pruning of unsaved trays and scan folders

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The phone link token

**Files:**
- Create: `lib/full_circle_web/phone_upload.ex`
- Test: `test/full_circle_web/phone_upload_test.exs`

**Interfaces:**
- Produces:
  - `PhoneUpload.sign({:tray | :note, id}, label, company_id, user_id) :: token`
  - `PhoneUpload.url(target, label, company, user) :: absolute_url` (`Endpoint.url() <> "/up/" <> token`)
  - `PhoneUpload.resolve(token) :: {:ok, %{target, label, company, user, token}} | {:error, :expired | :invalid | :no_access}`. `token` is a **fresh** token for the same target.
  - `PhoneUpload.note_label(%Note{}) :: String.t()`: the title, else the first 40 characters of the body.
  - `PhoneUpload.max_age() :: 600`

- [ ] **Step 1: Write the failing tests**

Create `test/full_circle_web/phone_upload_test.exs`:

```elixir
defmodule FullCircleWeb.PhoneUploadTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircleWeb.PhoneUpload

  setup do
    billing_setup()
  end

  test "resolves a fresh token to its target, company and user", %{admin: a, company: c} do
    tray_id = Ecto.UUID.generate()
    token = PhoneUpload.sign({:tray, tray_id}, "a new note", c.id, a.id)

    assert {:ok, %{target: {:tray, ^tray_id}, label: "a new note", company: co, user: u, token: t2}} =
             PhoneUpload.resolve(token)

    assert co.id == c.id and u.id == a.id
    assert {:ok, _} = PhoneUpload.resolve(t2)
  end

  test "an expired token is refused", %{admin: a, company: c} do
    old =
      Phoenix.Token.sign(FullCircleWeb.Endpoint, "note phone upload", %{
        t: "note", i: Ecto.UUID.generate(), c: c.id, u: a.id, l: "x"
      }, signed_at: System.system_time(:second) - PhoneUpload.max_age() - 1)

    assert {:error, :expired} = PhoneUpload.resolve(old)
  end

  test "garbage and a forged target kind are invalid", %{admin: a, company: c} do
    assert {:error, :invalid} = PhoneUpload.resolve("nope")
    assert {:error, :invalid} = PhoneUpload.resolve(nil)

    forged =
      Phoenix.Token.sign(FullCircleWeb.Endpoint, "note phone upload", %{
        t: "company", i: c.id, c: c.id, u: a.id, l: "x"
      })

    assert {:error, :invalid} = PhoneUpload.resolve(forged)
  end

  test "a user disabled after the QR was shown is refused", %{admin: a, company: c} do
    clerk = user_with_role(c, a, "clerk")
    token = PhoneUpload.sign({:tray, Ecto.UUID.generate()}, "x", c.id, clerk.id)

    Repo.update_all(
      from(cu in FullCircle.Sys.CompanyUser,
        where: cu.company_id == ^c.id and cu.user_id == ^clerk.id
      ),
      set: [role: "disable"]
    )

    assert {:error, :no_access} = PhoneUpload.resolve(token)
  end

  test "url is absolute and note_label prefers the title" do
    assert PhoneUpload.url({:note, "n"}, "x", %{id: "c"}, %{id: "u"}) =~ ~r{^https?://.+/up/.+}
    assert PhoneUpload.note_label(%FullCircle.Notes.Note{title: "Bank letter", body: "b"}) == "Bank letter"

    assert PhoneUpload.note_label(%FullCircle.Notes.Note{title: nil, body: String.duplicate("x", 60)}) ==
             String.duplicate("x", 40) <> "…"
  end
end
```

`FullCircle.DataCase` already imports `Ecto.Query`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/phone_upload_test.exs`
Expected: FAIL, `FullCircleWeb.PhoneUpload.sign/4 is undefined`.

- [ ] **Step 3: Write `PhoneUpload`**

Create `lib/full_circle_web/phone_upload.ex`:

```elixir
defmodule FullCircleWeb.PhoneUpload do
  @moduledoc """
  The "📱 From phone" link: a signed token naming one write-box tray or one
  saved note, its company and the desktop user. It authorises uploads into
  that one target only — never reads. Idle expiry is #{600}s: every
  successful upload hands the phone a fresh token. Every request re-checks
  that the user is still active in the company (and, for a note, may still
  edit it — the upload functions do that).
  """
  alias FullCircle.{Repo, Sys}
  alias FullCircle.Notes.Note
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.UserAccounts.User

  @salt "note phone upload"
  @max_age 600

  def max_age, do: @max_age

  def sign({kind, id}, label, company_id, user_id) when kind in [:tray, :note] do
    Phoenix.Token.sign(FullCircleWeb.Endpoint, @salt, %{
      t: Atom.to_string(kind),
      i: id,
      c: company_id,
      u: user_id,
      l: label
    })
  end

  def url(target, label, company, user),
    do: FullCircleWeb.Endpoint.url() <> "/up/" <> sign(target, label, company.id, user.id)

  def resolve(token) when is_binary(token) do
    with {:ok, %{t: t, i: id, c: cid, u: uid, l: label}} <-
           Phoenix.Token.verify(FullCircleWeb.Endpoint, @salt, token, max_age: @max_age),
         {:ok, kind} <- kind(t),
         %Company{} = company <- Repo.get(Company, cid),
         %User{} = user <- Repo.get(User, uid),
         %CompanyUser{role: role} when role != "disable" <- Sys.get_company_user(cid, uid) do
      {:ok,
       %{
         target: {kind, id},
         label: label,
         company: company,
         user: user,
         token: sign({kind, id}, label, cid, uid)
       }}
    else
      {:error, :expired} -> {:error, :expired}
      %CompanyUser{} -> {:error, :no_access}
      _ -> {:error, :invalid}
    end
  end

  def resolve(_), do: {:error, :invalid}

  def note_label(%Note{title: title}) when is_binary(title) and title != "", do: title

  def note_label(%Note{body: body}) do
    body = String.trim(body || "")
    if String.length(body) > 40, do: String.slice(body, 0, 40) <> "…", else: body
  end

  defp kind("tray"), do: {:ok, :tray}
  defp kind("note"), do: {:ok, :note}
  defp kind(_), do: :error
end
```

If `Sys.get_company_user/2` returns `nil`, the user was removed from the company. That falls through to `_ -> {:error, :invalid}`, which the phone shows as an expired link. That's acceptable.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle_web/phone_upload_test.exs`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/phone_upload.ex test/full_circle_web/phone_upload_test.exs
git add lib/full_circle_web/phone_upload.ex test/full_circle_web/phone_upload_test.exs
git commit -m "feat(notes): signed 10-minute phone upload token, refreshed per upload

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Phone page, phone endpoints, and the desktop tray route

**Files:**
- Create: `lib/full_circle_web/controllers/phone_upload_controller.ex`
- Create: `lib/full_circle_web/controllers/phone_upload_html.ex`
- Create: `lib/full_circle_web/controllers/phone_upload_html/show.html.heex`
- Create: `lib/full_circle_web/controllers/phone_upload_html/expired.html.heex`
- Modify: `lib/full_circle_web/controllers/note_attachment_controller.ex` (add `create_tray/2`, extend `message/1`)
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/controllers/phone_upload_controller_test.exs`
- Test: `test/full_circle_web/controllers/note_attachment_controller_test.exs` (append)

**Interfaces:**
- Consumes: `PhoneUpload.resolve/1`, `note_label/1` (Task 7); `Attachments.attach/4`, `attach_to_tray/4` (Task 2); `Scans.*` (Task 5); `Trays.open/3` (Task 2).
- Produces the routes below. Every JSON success carries `"token"`, the fresh token. Every JSON error is `{"error": msg, "code": code}`, where `code` is one of `expired`, `closed`, `forbidden` or `invalid`.

| Route | Success JSON |
|---|---|
| `GET /up/:token` | HTML page (or the expired page with status 410) |
| `GET /up/:token/state?scan_id=` | `{label, pages, token}` |
| `POST /up/:token/files` (`file`) | `{id, token}` |
| `POST /up/:token/scans/:scan_id/pages` (`file`) | `{pages, token}` |
| `DELETE /up/:token/scans/:scan_id/pages/last` | `{pages, token}` |
| `POST /up/:token/scans/:scan_id/done` (`name`) | `{id, token}` |
| `POST /companies/:company_id/note_trays/:tray_id/files` (logged in, `file`) | `{ok, id}` |

- [ ] **Step 1: Write the failing controller tests**

Create `test/full_circle_web/controllers/phone_upload_controller_test.exs`:

```elixir
defmodule FullCircleWeb.PhoneUploadControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes
  alias FullCircle.Notes.{Scans, Trays}
  alias FullCircleWeb.PhoneUpload

  setup do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    note = note_fixture(comp, admin, %{"title" => "Bank letter"})
    tray = tray_fixture(comp, admin)
    %{admin: admin, comp: comp, note: note, tray: tray}
  end

  defp upload(path, name),
    do: %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}

  defp tok(ctx, target), do: PhoneUpload.sign(target, "label", ctx.comp.id, ctx.admin.id)

  test "the page renders for a good token and says expired otherwise", ctx do
    html = ctx.conn |> get(~p"/up/#{tok(ctx, {:note, ctx.note.id})}") |> html_response(200)
    assert html =~ "label"
    assert html =~ "phone_upload.js"
    assert ctx.conn |> get(~p"/up/garbage") |> html_response(410) =~ "expired"
  end

  test "a file goes into the tray and a fresh token comes back", ctx do
    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:tray, ctx.tray.id})}/files", %{
        "file" => upload(jpeg_file(), "wa.jpg")
      })

    assert %{"id" => _, "token" => fresh} = json_response(conn, 200)
    assert is_binary(fresh)
    assert [%{file_name: "wa.jpg"}] = Trays.list(ctx.tray.id, ctx.comp, ctx.admin)
  end

  test "a file goes straight onto a saved note", ctx do
    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:note, ctx.note.id})}/files", %{
        "file" => upload(pdf_file(), "letter.pdf")
      })

    assert %{"id" => _} = json_response(conn, 200)
    assert [%{file_name: "letter.pdf"}] = Notes.get_note(ctx.note.id, ctx.comp, ctx.admin).attachments
  end

  test "a cancelled tray answers closed", ctx do
    Trays.cancel(ctx.tray.id, ctx.comp, ctx.admin)

    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:tray, ctx.tray.id})}/files", %{
        "file" => upload(jpeg_file(), "late.jpg")
      })

    assert %{"code" => "closed"} = json_response(conn, 409)
  end

  test "a note the user may no longer edit answers forbidden", ctx do
    clerk = user_with_role(ctx.comp, ctx.admin, "clerk")
    token = PhoneUpload.sign({:note, ctx.note.id}, "x", ctx.comp.id, clerk.id)
    conn = post(ctx.conn, ~p"/up/#{token}/files", %{"file" => upload(jpeg_file(), "a.jpg")})
    assert %{"code" => "forbidden"} = json_response(conn, 403)
  end

  test "an expired token answers expired", ctx do
    conn = post(ctx.conn, ~p"/up/garbage/files", %{"file" => upload(jpeg_file(), "a.jpg")})
    assert %{"code" => "expired"} = json_response(conn, 401)
  end

  test "a wrong file type is a per-file error", ctx do
    conn =
      post(ctx.conn, ~p"/up/#{tok(ctx, {:tray, ctx.tray.id})}/files", %{
        "file" => upload(text_file(), "x.jpg")
      })

    assert %{"code" => "invalid", "error" => msg} = json_response(conn, 422)
    assert msg =~ "JPEG"
  end

  test "scan: pages, retake, state, done → one PDF in the tray", ctx do
    t = tok(ctx, {:tray, ctx.tray.id})
    sid = Ecto.UUID.generate()

    for _ <- 1..2 do
      conn = post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/pages", %{"file" => upload(real_jpeg_file(:rgb), "p.jpg")})
      assert %{"pages" => _} = json_response(conn, 200)
    end

    assert %{"pages" => 1} = ctx.conn |> delete(~p"/up/#{t}/scans/#{sid}/pages/last") |> json_response(200)
    assert %{"pages" => 1, "label" => "label"} = ctx.conn |> get(~p"/up/#{t}/state?scan_id=#{sid}") |> json_response(200)

    conn = post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/done", %{"name" => "Scan 2026-10-04 1432.pdf"})
    assert %{"id" => _} = json_response(conn, 200)
    assert [%{file_name: "Scan 2026-10-04 1432.pdf", content_type: "application/pdf"}] =
             Trays.list(ctx.tray.id, ctx.comp, ctx.admin)

    assert Scans.count(ctx.comp.id, sid) == 0
  end

  test "scan: a PNG page is refused, done with no pages is refused", ctx do
    t = tok(ctx, {:tray, ctx.tray.id})
    sid = Ecto.UUID.generate()
    conn = post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/pages", %{"file" => upload(pdf_file(), "p.pdf")})
    assert %{"code" => "invalid"} = json_response(conn, 422)
    conn = post(ctx.conn, ~p"/up/#{t}/scans/#{sid}/done", %{"name" => "x.pdf"})
    assert %{"code" => "invalid", "error" => msg} = json_response(conn, 422)
    assert msg =~ "page"
  end
end
```

Append to `test/full_circle_web/controllers/note_attachment_controller_test.exs`, before its final `end`:

```elixir
  test "a logged-in tray upload opens the tray on first use", %{conn: conn, admin: admin, comp: comp} do
    tray_id = Ecto.UUID.generate()

    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/note_trays/#{tray_id}/files", %{
        "file" => upload(jpeg_file(), "p.jpg")
      })

    assert %{"ok" => true, "id" => _} = json_response(conn, 200)
    assert [_] = FullCircle.Notes.Trays.list(tray_id, comp, admin)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/controllers/phone_upload_controller_test.exs test/full_circle_web/controllers/note_attachment_controller_test.exs`
Expected: FAIL, no route matches `/up/...`.

- [ ] **Step 3: Add the routes**

In `lib/full_circle_web/router.ex`, add after `pipeline :punch_api do … end`:

```elixir
  # The phone upload page (/up/:token): no session, no CSRF — the signed
  # token in the path is the credential (FullCircleWeb.PhoneUpload).
  pipeline :phone_upload do
    plug :accepts, ["html", "json"]
    plug :put_secure_browser_headers
  end

  scope "/up", FullCircleWeb do
    pipe_through :phone_upload
    get "/:token", PhoneUploadController, :show
    get "/:token/state", PhoneUploadController, :state
    post "/:token/files", PhoneUploadController, :file
    post "/:token/scans/:scan_id/pages", PhoneUploadController, :page
    delete "/:token/scans/:scan_id/pages/last", PhoneUploadController, :drop_page
    post "/:token/scans/:scan_id/done", PhoneUploadController, :done
  end
```

In the `scope "/companies/:company_id"` block that holds `post "/notes/:note_id/attachments"`, add below it:

```elixir
    post "/note_trays/:tray_id/files", NoteAttachmentController, :create_tray
```

- [ ] **Step 4: Add `create_tray` to the logged-in controller**

In `lib/full_circle_web/controllers/note_attachment_controller.ex`:

1. Change the alias to `alias FullCircle.Notes.{Attachments, Note, Trays}`.
2. Make `message/1` public, so the phone controller shares the wording. Change every `defp message(` to `def message(`, and add these clauses above `def message(_)`:

```elixir
  def message(:tray_closed), do: gettext("This note was closed on the desktop.")
  def message(:no_pages), do: gettext("Take at least one page.")
  def message(:too_many_pages), do: gettext("Up to 30 pages per PDF — finish this one first.")
  def message(:not_jpeg), do: gettext("That page is not a photo. Take it again.")
  def message(:bad_page), do: gettext("A page could not be read. Retake it.")
```

The existing `:too_large` message ("File is larger than 10 MB.") also covers a too-big PDF.

3. Add after the existing `create/2` clauses:

```elixir
  # The write box's 📎 / drop / paste: into its tray, created on first use.
  def create_tray(conn, %{"tray_id" => tray_id, "file" => %Plug.Upload{} = file}) do
    company = conn.assigns.current_company
    user = conn.assigns.current_user

    with {:ok, _tray} <- Trays.open(tray_id, company, user),
         {:ok, att} <-
           Attachments.attach_to_tray(
             tray_id,
             %{path: file.path, file_name: file.filename},
             company,
             user
           ) do
      json(conn, %{ok: true, id: att.id})
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: gettext("Not found.")})

      :not_authorise ->
        conn |> put_status(403) |> json(%{error: gettext("Not Authorise.")})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: message(reason)})
    end
  end

  def create_tray(conn, _params),
    do: conn |> put_status(422) |> json(%{error: gettext("No file received.")})
```

- [ ] **Step 5: Write the phone controller**

Create `lib/full_circle_web/controllers/phone_upload_controller.ex`:

```elixir
defmodule FullCircleWeb.PhoneUploadController do
  @moduledoc """
  The one phone page (`/up/:token`) and its JSON endpoints. Plain HTTP, not
  LiveView: the camera backgrounds the page and would kill a socket. Every
  answer carries a fresh token (the 10-minute window slides with use).
  """
  use FullCircleWeb, :controller

  alias FullCircle.Notes.{Attachments, Note, Scans}
  alias FullCircleWeb.{NoteAttachmentController, PhoneUpload}

  def show(conn, %{"token" => token}) do
    case PhoneUpload.resolve(token) do
      {:ok, ctx} ->
        conn
        |> put_layout(false)
        |> put_view(FullCircleWeb.PhoneUploadHTML)
        |> render(:show,
          token: ctx.token,
          label: ctx.label,
          target_key: target_key(ctx.target),
          max_bytes: Attachments.max_bytes()
        )

      _ ->
        conn
        |> put_status(410)
        |> put_layout(false)
        |> put_view(FullCircleWeb.PhoneUploadHTML)
        |> render(:expired)
    end
  end

  def state(conn, %{"token" => token} = params) do
    with_ctx(conn, token, fn ctx ->
      pages = Scans.count(ctx.company.id, params["scan_id"] || "")
      json(conn, %{label: ctx.label, pages: pages, token: ctx.token})
    end)
  end

  def file(conn, %{"token" => token, "file" => %Plug.Upload{} = file}) do
    with_ctx(conn, token, fn ctx ->
      upload = %{path: file.path, file_name: file.filename}
      reply(conn, ctx, store(ctx, upload), &%{id: &1.id})
    end)
  end

  def file(conn, _), do: error(conn, 422, "invalid", gettext("No file received."))

  def page(conn, %{"token" => token, "scan_id" => sid, "file" => %Plug.Upload{} = file}) do
    with_ctx(conn, token, fn ctx ->
      reply(conn, ctx, Scans.add_page(ctx.company.id, sid, file.path), &%{pages: &1})
    end)
  end

  def page(conn, _), do: error(conn, 422, "invalid", gettext("No file received."))

  def drop_page(conn, %{"token" => token, "scan_id" => sid}) do
    with_ctx(conn, token, fn ctx ->
      reply(conn, ctx, Scans.drop_last(ctx.company.id, sid), &%{pages: &1})
    end)
  end

  def done(conn, %{"token" => token, "scan_id" => sid} = params) do
    with_ctx(conn, token, fn ctx ->
      name = pdf_name(params["name"])

      result =
        with {:ok, pdf} <- Scans.finish(ctx.company.id, sid),
             {:ok, att} <- store(ctx, %{path: pdf, file_name: name}) do
          Scans.discard(ctx.company.id, sid)
          {:ok, att}
        end

      reply(conn, ctx, result, &%{id: &1.id})
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp with_ctx(conn, token, fun) do
    case PhoneUpload.resolve(token) do
      {:ok, ctx} -> fun.(ctx)
      _ -> error(conn, 401, "expired", gettext("This link has expired — show a new QR on the desktop."))
    end
  end

  defp store(%{target: {:tray, id}} = ctx, upload),
    do: Attachments.attach_to_tray(id, upload, ctx.company, ctx.user)

  defp store(%{target: {:note, id}} = ctx, upload),
    do: Attachments.attach(%Note{id: id}, upload, ctx.company, ctx.user)

  defp reply(conn, ctx, {:ok, value}, shape),
    do: json(conn, Map.put(shape.(value), :token, ctx.token))

  defp reply(conn, _ctx, {:error, :tray_closed}, _),
    do: error(conn, 409, "closed", NoteAttachmentController.message(:tray_closed))

  defp reply(conn, _ctx, err, _) when err in [:not_authorise, {:error, :note_not_found}, {:error, :not_found}],
    do: error(conn, 403, "forbidden", gettext("You can't add files to this note any more."))

  defp reply(conn, _ctx, {:error, reason}, _),
    do: error(conn, 422, "invalid", NoteAttachmentController.message(reason))

  defp error(conn, status, code, msg),
    do: conn |> put_status(status) |> json(%{error: msg, code: code})

  defp target_key({kind, id}), do: "#{kind}:#{id}"

  # The phone names the PDF from its own clock ("Scan 2026-10-04 1432.pdf");
  # only a sane basename ending in .pdf is kept.
  defp pdf_name(name) when is_binary(name) do
    base = name |> Path.basename() |> String.replace(~r/[^\w\s\-.]/u, "") |> String.slice(0, 120)
    if String.ends_with?(base, ".pdf") and base != ".pdf", do: base, else: "Scan.pdf"
  end

  defp pdf_name(_), do: "Scan.pdf"
end
```

`message/1` in `NoteAttachmentController` has no clause for `:invalid_scan`, so it falls back to "Upload failed.". That's fine, because only a broken or forged client sends a bad scan id.

- [ ] **Step 6: Write the phone page markup (the JS comes in Task 14)**

Create `lib/full_circle_web/controllers/phone_upload_html.ex`:

```elixir
defmodule FullCircleWeb.PhoneUploadHTML do
  use FullCircleWeb, :html

  embed_templates "phone_upload_html/*"
end
```

Create `lib/full_circle_web/controllers/phone_upload_html/show.html.heex`:

```heex
<!DOCTYPE html>
<html lang="en" class="h-full">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="robots" content="noindex" />
    <title>{gettext("Add to FullCircle")}</title>
    <link rel="stylesheet" href={~p"/assets/app.css"} />
    <script type="module" src={~p"/assets/phone_upload.js"}>
    </script>
  </head>
  <body class="min-h-full bg-gray-50 text-gray-900 dark:bg-gray-950 dark:text-gray-100">
    <main
      id="phone-upload"
      data-token={@token}
      data-target-key={@target_key}
      data-max-bytes={@max_bytes}
      class="mx-auto max-w-md p-4"
    >
      <p class="text-sm text-gray-500 dark:text-gray-400">{gettext("Adding to")}</p>
      <h1 class="text-xl font-bold">{@label}</h1>

      <div id="pu-banner" class="mt-3 hidden rounded-lg bg-rose-100 p-3 text-rose-800 dark:bg-rose-900/40 dark:text-rose-200">
      </div>

      <div class="mt-4 grid gap-3">
        <button id="pu-scan" type="button" class="rounded-xl bg-sky-600 p-4 text-lg font-bold text-white">
          📄 {gettext("Scan pages → PDF")}
        </button>
        <button id="pu-photo" type="button" class="rounded-xl bg-gray-200 p-4 text-lg font-bold dark:bg-gray-800">
          📷 {gettext("Photo")}
        </button>
        <button id="pu-files" type="button" class="rounded-xl bg-gray-200 p-4 text-lg font-bold dark:bg-gray-800">
          📎 {gettext("Files (WhatsApp, Downloads…)")}
        </button>
      </div>

      <section id="pu-scanning" class="mt-4 hidden rounded-xl border border-sky-300 p-3 dark:border-sky-700">
        <div class="flex items-center gap-2 text-sm">
          <span>{gettext("Look")}:</span>
          <select id="pu-look" class="rounded border-gray-300 bg-transparent text-sm dark:border-gray-600">
            <option value="clean" selected>{gettext("Clean colour")}</option>
            <option value="bw">{gettext("Black & white")}</option>
            <option value="original">{gettext("Original")}</option>
          </select>
          <span id="pu-pages" class="ml-auto font-semibold">0</span>
        </div>
        <div id="pu-thumbs" class="mt-2 flex gap-1 overflow-x-auto"></div>
        <div class="mt-3 grid grid-cols-3 gap-2">
          <button id="pu-next" type="button" class="rounded-lg bg-sky-600 p-3 font-bold text-white">
            ＋ {gettext("Page")}
          </button>
          <button id="pu-retake" type="button" class="rounded-lg bg-gray-200 p-3 dark:bg-gray-800">
            ↺ {gettext("Retake")}
          </button>
          <button id="pu-done" type="button" class="rounded-lg bg-emerald-600 p-3 font-bold text-white">
            ✓ {gettext("Done")}
          </button>
        </div>
      </section>

      <ul id="pu-sent" class="mt-4 space-y-1 text-sm"></ul>
    </main>
  </body>
</html>
```

Create `lib/full_circle_web/controllers/phone_upload_html/expired.html.heex`:

```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="robots" content="noindex" />
    <link rel="stylesheet" href={~p"/assets/app.css"} />
  </head>
  <body class="bg-gray-50 p-6 text-gray-900 dark:bg-gray-950 dark:text-gray-100">
    <p class="text-lg">
      {gettext("This link has expired — show a new QR on the desktop.")}
    </p>
    <p class="mt-2 text-sm text-gray-500">(link expired)</p>
  </body>
</html>
```

The test asserts `=~ "expired"`. The English gettext string contains it, and the fixed "(link expired)" line keeps that true in Chinese.

- [ ] **Step 7: Run tests**

Run: `mix test test/full_circle_web/controllers/phone_upload_controller_test.exs test/full_circle_web/controllers/note_attachment_controller_test.exs`
Expected: all PASS. If the `show` test fails on `phone_upload.js`, check that the template's `<script>` tag is present. The asset itself doesn't need to exist for the HTML assertion. `put_layout(false)` matters: `FullCircleWeb, :controller` sets `layouts: [html: FullCircleWeb.Layouts]`, which would otherwise wrap the phone page in the desktop app shell.

- [ ] **Step 8: Commit**

```bash
mix format lib/full_circle_web/controllers/phone_upload_controller.ex lib/full_circle_web/controllers/phone_upload_html.ex lib/full_circle_web/controllers/note_attachment_controller.ex lib/full_circle_web/router.ex test/full_circle_web/controllers/phone_upload_controller_test.exs test/full_circle_web/controllers/note_attachment_controller_test.exs
git add lib/full_circle_web/controllers/phone_upload_controller.ex lib/full_circle_web/controllers/phone_upload_html.ex lib/full_circle_web/controllers/phone_upload_html lib/full_circle_web/controllers/note_attachment_controller.ex lib/full_circle_web/router.ex test/full_circle_web/controllers/phone_upload_controller_test.exs test/full_circle_web/controllers/note_attachment_controller_test.exs
git commit -m "feat(notes): phone upload page and endpoints; desktop tray upload route

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Routing "a file landed" to the components that show it

**Files:**
- Create: `lib/full_circle_web/note_files.ex`
- Modify: `lib/full_circle_web/router.ex` (on_mount in `:require_authenticated_user_n_active_company`)
- Test: covered by the LiveView tests in Tasks 11 and 12. This task adds only the module and the wiring, and is verified by compiling and running the full notes LiveView suite.

**Interfaces:**
- Consumes: `Attachments.topic/1` (Task 2).
- Produces:
  - `FullCircleWeb.NoteFiles.listen(target, module, id) :: :ok`: called from a component's `update/2`. Later broadcasts for `target` arrive as `send_update(module, id: id, note_files: target)`.
  - `FullCircleWeb.NoteFiles.listen_self(target) :: :ok`: called from a LiveView. Later broadcasts arrive as `handle_info({:note_files, target}, socket)`.
  - `on_mount(:route, ...)`: subscribes the page and halts every `{:note_files_changed, _}`, so a host LiveView never sees the raw broadcast.

- [ ] **Step 1: Write the module**

Create `lib/full_circle_web/note_files.ex`:

```elixir
defmodule FullCircleWeb.NoteFiles do
  @moduledoc """
  Delivers "a file landed" (`{:note_files_changed, target}` on
  `Attachments.topic/1`) to whatever on the page shows that target's files —
  a write box's tray, a notes panel's posts, the note page — so no host
  LiveView needs a handle_info for it. Components register with `listen/3`
  from `update/2`; registrations live in the LiveView process's dictionary
  (components share their LiveView's process), keyed by target. A stale
  registration (component gone) is harmless: send_update to a missing
  component is ignored. Every broadcast is halted here.
  """
  alias FullCircle.Notes.Attachments

  @key {__MODULE__, :listeners}

  def on_mount(:route, _params, _session, socket) do
    company = socket.assigns[:current_company]

    if company && Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Attachments.topic(company.id))
      {:cont, Phoenix.LiveView.attach_hook(socket, :note_files, :handle_info, &route/2)}
    else
      {:cont, socket}
    end
  end

  def listen(target, module, id), do: put(target, {module, id})

  def listen_self(target), do: put(target, :self)

  defp put(target, who) do
    listeners = Process.get(@key, %{})
    Process.put(@key, Map.update(listeners, target, MapSet.new([who]), &MapSet.put(&1, who)))
    :ok
  end

  defp route({:note_files_changed, target}, socket) do
    for who <- Map.get(Process.get(@key, %{}), target, []) do
      case who do
        :self -> send(self(), {:note_files, target})
        {module, id} -> Phoenix.LiveView.send_update(module, id: id, note_files: target)
      end
    end

    {:halt, socket}
  end

  defp route(_msg, socket), do: {:cont, socket}
end
```

- [ ] **Step 2: Wire it into the company live session**

In `lib/full_circle_web/router.ex`, in `live_session :require_authenticated_user_n_active_company`, append `{FullCircleWeb.NoteFiles, :route}` to the `on_mount` list after `{FullCircleWeb.ActiveCompany, :assign_active_company}`. The hook needs `current_company`, which that hook assigns.

- [ ] **Step 3: Verify nothing regressed**

Run: `mix compile --warnings-as-errors && mix test test/full_circle_web/live/note_live_test.exs test/full_circle_web/live/notes_panel_live_test.exs`
Expected: compiles; all PASS. LiveViews whose `handle_info` has no catch-all clause (for example `ContactLive.Form`) don't crash, because the hook halts every broadcast.

- [ ] **Step 4: Commit**

```bash
mix format lib/full_circle_web/note_files.ex lib/full_circle_web/router.ex
git add lib/full_circle_web/note_files.ex lib/full_circle_web/router.ex
git commit -m "feat(notes): on_mount hook routing note file broadcasts to their components

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: "📱 From phone" button and QR

**Files:**
- Create: `lib/full_circle_web/live/note_live/phone_qr_component.ex`
- Test: `test/full_circle_web/live/note_live_test.exs` (append, in the note page describe block; mounted for real in Task 12)

**Interfaces:**
- Consumes: `PhoneUpload.url/4` (Task 7), `Trays.open/3` (Task 2).
- Produces: `<.live_component module={PhoneQrComponent} id=... target={{:tray, id} | {:note, id}} label="..." current_company=... current_user=... />`. It renders a `#{id}-open` button. Clicking it shows `#{id}-qr` (an SVG plus the link), and `#{id}-close` hides it. Opening it for a tray creates the tray row.

- [ ] **Step 1: Write the component**

Create `lib/full_circle_web/live/note_live/phone_qr_component.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.PhoneQrComponent do
  @moduledoc """
  "📱 From phone": a QR code for the phone upload page (`/up/:token`) of one
  write-box tray or one saved note. The token is made when the QR is opened
  (10-minute idle window, `FullCircleWeb.PhoneUpload`); opening it for a tray
  creates the tray row so the phone can fill it before any desktop upload.
  """
  use FullCircleWeb, :live_component

  alias FullCircle.Notes.Trays
  alias FullCircleWeb.PhoneUpload

  @impl true
  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> assign_new(:qr, fn -> nil end)}

  @impl true
  def handle_event("open", _, socket) do
    %{target: target, label: label, current_company: com, current_user: user} = socket.assigns

    if ready?(target, com, user) do
      url = PhoneUpload.url(target, label, com, user)
      svg = url |> QRCode.create(:medium) |> QRCode.render(:svg) |> elem(1)
      {:noreply, assign(socket, qr: svg, url: url)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close", _, socket), do: {:noreply, assign(socket, qr: nil)}

  defp ready?({:tray, id}, com, user), do: match?({:ok, _}, Trays.open(id, com, user))
  defp ready?({:note, _id}, _com, _user), do: true

  @impl true
  def render(assigns) do
    ~H"""
    <span id={@id} class="relative inline-flex">
      <button
        type="button"
        id={"#{@id}-open"}
        phx-click="open"
        phx-target={@myself}
        class="rounded border border-gray-400 px-2 text-sm hover:bg-gray-100 dark:border-gray-500 dark:hover:bg-gray-700"
      >
        📱 {gettext("From phone")}
      </button>
      <div
        :if={@qr}
        id={"#{@id}-qr"}
        class="absolute left-0 top-8 z-30 w-64 rounded-xl border border-gray-300 bg-white p-3 text-center shadow-lg dark:border-gray-600 dark:bg-gray-900"
      >
        <button
          type="button"
          id={"#{@id}-close"}
          phx-click="close"
          phx-target={@myself}
          class="absolute right-2 top-1 text-gray-500"
          title={gettext("Close")}
        >
          ✕
        </button>
        <div class="mx-auto w-48 rounded bg-white p-1 [&>svg]:h-auto [&>svg]:w-full">
          {Phoenix.HTML.raw(@qr)}
        </div>
        <p class="mt-2 text-xs text-gray-600 dark:text-gray-300">
          {gettext("Scan with your phone camera. Works for 10 minutes.")}
        </p>
        <a href={@url} target="_blank" class="mt-1 block truncate text-xs text-sky-600 dark:text-sky-400">
          {@url}
        </a>
      </div>
    </span>
    """
  end
end
```

The QR keeps a white background in dark mode, because phone cameras read dark-on-light codes most reliably.

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: compiles. Task 11 tests the component through the composer and Task 12 through the note page.

- [ ] **Step 3: Commit**

```bash
mix format lib/full_circle_web/live/note_live/phone_qr_component.ex
git add lib/full_circle_web/live/note_live/phone_qr_component.ex
git commit -m "feat(notes): From phone button with a QR to the phone upload page

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: The write box's tray

**Files:**
- Modify: `lib/full_circle_web/components/note_components.ex` (`attach_button/1`, `file_grid/1`)
- Modify: `lib/full_circle_web/live/note_live/composer_component.ex`
- Modify: `lib/full_circle_web/live/note_live/notes_panel_component.ex` (edit box: drop `attach_button` from `:actions`; drop the `:attachment_uploaded` clause)
- Modify: `lib/full_circle_web/live/note_live/form.ex` (edit box: drop `attach_button` from `:actions`; drop `handle_info({:composer, "note", :attachment_uploaded}, ...)`)
- Test: `test/full_circle_web/live/notes_panel_live_test.exs` (append), `test/full_circle_web/live/note_live_test.exs` (append)

**Interfaces:**
- Consumes: `Trays.list/3`, `discard_file/4`, `cancel/3` (Task 2); `Notes.create_note`/`update_note` claiming `"tray_id"` (Task 3); `NoteFiles.listen/3` (Task 9); `PhoneQrComponent` (Task 10); the tray route (Task 8).
- Produces:
  - Composer DOM: `#{id}-tray` with `data-tray-id`; tray files grid `#{id}-tray-files` (tiles `#att-<id>`, ✕ sends `discard_file`); `#{id}-files` 📎 button (multiple); `#{id}-phone` QR component.
  - `attach_button(id:, url:, multiple: true)`. The message span is `#{id}-msg`.
  - `file_grid(remove_event: "remove_attachment", confirm: <text> | nil)`.

- [ ] **Step 1: Write the failing LiveView tests**

Append to `test/full_circle_web/live/notes_panel_live_test.exs`, before the final `end`:

```elixir
  describe "write box tray" do
    defp tray_id(lv) do
      [_, id] = Regex.run(~r/id="notes-panel-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))
      id
    end

    defp drop_in(lv, comp, admin, name \\ "scan.jpg") do
      {:ok, _} =
        FullCircle.Notes.Attachments.attach_to_tray(
          tray_id(lv),
          %{path: jpeg_file(), file_name: name},
          comp,
          admin
        )

      # The broadcast reaches the LiveView, whose hook queues a send_update
      # behind this render; the second render sees it.
      _ = render(lv)
      render(lv)
    end

    test "a file uploaded into the box shows at once and attaches on Post",
         %{conn: conn, admin: admin, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      assert has_element?(lv, "#notes-panel-files")
      assert has_element?(lv, "#notes-panel-phone-open")

      assert drop_in(lv, comp, admin) =~ "scan.jpg"

      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "letter from bank"}})
      |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      note = FullCircle.Repo.preload(note, :attachments)
      assert [%{file_name: "scan.jpg"}] = note.attachments
    end

    test "Cancel throws the box's files away", %{conn: conn, admin: admin, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      id = tray_id(lv)
      drop_in(lv, comp, admin)

      lv |> element("#notes-panel-cancel") |> render_click()
      assert FullCircle.Notes.Trays.list(id, comp, admin) == []
    end

    test "✕ on a box file deletes it", %{conn: conn, admin: admin, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      id = tray_id(lv)
      drop_in(lv, comp, admin)
      [att] = FullCircle.Notes.Trays.list(id, comp, admin)

      lv |> element("#notes-panel-tray-files #att-#{att.id} button") |> render_click()
      refute render(lv) =~ "scan.jpg"
      assert FullCircle.Notes.Trays.list(id, comp, admin) == []
    end

    test "From phone shows a QR code", %{conn: conn, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      html = lv |> element("#notes-panel-phone-open") |> render_click()
      assert html =~ "<svg"
      assert html =~ "/up/"
    end
  end
```

Append to `test/full_circle_web/live/note_live_test.exs`, inside the describe block that tests the note page edit (the one containing `"shows files, links, notes linking here and history"`; reuse its setup variables `conn`, `admin`, `comp`), before that block's `end`:

```elixir
    test "editing: new files wait for Save; existing ✕ still removes at once",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "edit me"})

      {:ok, old} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "old.jpg"},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}/edit")
      [_, tray] = Regex.run(~r/id="note-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))

      {:ok, _} =
        FullCircle.Notes.Attachments.attach_to_tray(
          tray,
          %{path: jpeg_file(), file_name: "new.jpg"},
          comp,
          admin
        )

      _ = render(lv)
      assert render(lv) =~ "new.jpg"
      assert [%{file_name: "old.jpg"}] = FullCircle.Notes.get_note(note.id, comp, admin).attachments

      lv |> element("#note-files #att-#{old.id} button") |> render_click()
      assert FullCircle.Notes.get_note(note.id, comp, admin).attachments == []

      lv |> form("#note-form", %{"note" => %{"body" => "edited"}}) |> render_submit()
      assert [%{file_name: "new.jpg"}] = FullCircle.Notes.get_note(note.id, comp, admin).attachments
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs`
Expected: the new tests FAIL. For example, the `Regex.run` match fails because there is no `notes-panel-tray` yet.

- [ ] **Step 3: Generalise `attach_button` and `file_grid`**

In `lib/full_circle_web/components/note_components.ex`:

1. Replace `attach_button/1` (with its `attr` lines above it, if any) with:

```elixir
  attr :id, :string, required: true
  attr :url, :string, required: true, doc: "where the file is POSTed (a note's or a tray's route)"
  attr :multiple, :boolean, default: true
  attr :label, :string, default: nil

  def attach_button(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 text-sm">
      <button
        type="button"
        id={@id}
        phx-hook="NoteAttach"
        data-url={@url}
        data-multiple={to_string(@multiple)}
        data-max-bytes={FullCircle.Notes.Attachments.max_bytes()}
        class="rounded border border-gray-400 px-2 hover:bg-gray-100 dark:border-gray-500 dark:hover:bg-gray-700"
      >
        📎 {@label || gettext("Attach files")}
      </button>
      <span id={"#{@id}-msg"} phx-update="ignore" class="text-rose-600 dark:text-rose-400"></span>
    </span>
    """
  end
```

2. In `file_grid/1`, add two attrs after `attr :target ...`:

```elixir
  attr :remove_event, :string, default: "remove_attachment"
  attr :confirm, :any, default: :default, doc: "confirm text; nil for none"
```

and change the ✕ button's `phx-click` and `data-confirm` lines to:

```heex
          phx-click={@remove_event}
          phx-value-id={a.id}
          phx-target={@target}
          data-confirm={
            if @confirm == :default, do: gettext("Remove this file from the note?"), else: @confirm
          }
```

- [ ] **Step 4: Update the two saved-post callers of `attach_button`**

In `lib/full_circle_web/live/note_live/notes_panel_component.ex`, in the `.note_post` `:actions` slot, replace `<.attach_button note_id={item.id} current_company={@current_company} />` with:

```heex
            <.attach_button
              id={"attach-#{item.id}"}
              url={~p"/companies/#{@current_company.id}/notes/#{item.id}/attachments"}
            />
```

In `lib/full_circle_web/live/note_live/form.ex`, in the `.note_post` `:actions` slot, replace `<.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />` with:

```heex
              <.attach_button
                :if={@can_edit}
                id={"attach-#{@note.id}"}
                url={~p"/companies/#{@current_company.id}/notes/#{@note.id}/attachments"}
              />
```

- [ ] **Step 5: Remove the edit boxes' 📎 (the composer brings its own)**

In `notes_panel_component.ex`, in the edit `ComposerComponent`'s `<:actions>` slot, delete the `<.attach_button note_id={item.id} current_company={@current_company} />` line. The slot is then empty, so delete the whole `<:actions>…</:actions>` element. Also delete the clause `:attachment_uploaded -> {:ok, load(socket)}` from `update(%{composer: ...})`.

In `form.ex`, in the edit `ComposerComponent`'s `<:actions>` slot, delete the `<.attach_button note_id={@note.id} current_company={@current_company} />` line and keep the History button. Delete the function `def handle_info({:composer, "note", :attachment_uploaded}, socket), do: {:noreply, reload(socket)}` and the comment line above it.

- [ ] **Step 6: Give the composer a tray**

In `lib/full_circle_web/live/note_live/composer_component.ex`:

1. Aliases: change `alias FullCircle.Notes.Note` to `alias FullCircle.Notes.{Note, Trays}` and add `alias FullCircleWeb.NoteLive.PhoneQrComponent`.

2. Add an `update/2` clause directly after the `update(%{picked: ...})` clause:

```elixir
  # A file landed in this box's tray (FullCircleWeb.NoteFiles): desktop 📎,
  # drop, paste, or the phone.
  def update(%{note_files: {:tray, _}}, socket), do: {:ok, load_tray(socket)}
```

3. In `reset/1`, give every fresh box a new tray. Append to the end of the `reset/1` pipeline:

```elixir
    |> new_tray()
```

and add below `reset/1`:

```elixir
  # Each fresh box (open, after Save, after Cancel) gets a new tray id. The
  # row is created on first upload or when the phone QR opens.
  defp new_tray(socket) do
    tray_id = Ecto.UUID.generate()
    FullCircleWeb.NoteFiles.listen({:tray, tray_id}, __MODULE__, socket.assigns.id)
    assign(socket, tray_id: tray_id, tray_files: [])
  end

  defp load_tray(socket) do
    %{tray_id: id, current_company: com, current_user: user} = socket.assigns
    assign(socket, tray_files: Trays.list(id, com, user))
  end
```

4. Events. Replace the `handle_event("attachment_uploaded", ...)` clause (and its comment) with:

```elixir
  # The box's own 📎 / drop / paste finished an upload (the broadcast also
  # arrives; loading twice is harmless).
  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load_tray(socket)}

  def handle_event("discard_file", %{"id" => id}, socket) do
    %{tray_id: tray_id, current_company: com, current_user: user} = socket.assigns
    Trays.discard_file(id, tray_id, com, user)
    {:noreply, load_tray(socket)}
  end
```

Replace the `handle_event("cancel", ...)` clause with:

```elixir
  def handle_event("cancel", _, socket) do
    %{tray_id: tray_id, current_company: com, current_user: user} = socket.assigns
    Trays.cancel(tray_id, com, user)
    notify(socket, :cancelled)
    {:noreply, reset(socket)}
  end
```

In `handle_event("save", ...)`, change the line `params = Map.merge(params, subject_attrs(socket.assigns))` to:

```elixir
    params =
      params
      |> Map.merge(subject_attrs(socket.assigns))
      |> Map.put("tray_id", socket.assigns.tray_id)
```

Do **not** change the error branches: a failed or stale save keeps `tray_id` and `tray_files`, because `reset/1` runs only on `{:ok, _}`.

5. Render the tray. Add this function component near `messages/1`:

```elixir
  defp tray(assigns) do
    ~H"""
    <div
      id={"#{@id}-tray"}
      data-tray-id={@tray_id}
      phx-hook="NoteDrop"
      data-url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
      data-max-bytes={FullCircle.Notes.Attachments.max_bytes()}
      class="mt-1"
    >
      <.file_grid
        id={"#{@id}-tray-files"}
        attachments={@tray_files}
        removable
        remove_event="discard_file"
        confirm={nil}
        target={@myself}
      />
      <div class="mt-1 flex flex-wrap items-center gap-2">
        <.attach_button
          id={"#{@id}-files"}
          url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
        />
        <.live_component
          module={PhoneQrComponent}
          id={"#{@id}-phone"}
          target={{:tray, @tray_id}}
          label={tray_label(assigns)}
          current_company={@current_company}
          current_user={@current_user}
        />
        <span class="text-xs text-gray-500 dark:text-gray-400">
          {gettext("or drop / paste files here")}
        </span>
      </div>
    </div>
    """
  end

  defp tray_label(%{mode: :edit, note: %Note{} = note}), do: FullCircleWeb.PhoneUpload.note_label(note)
  defp tray_label(_), do: gettext("a new note")

  defp tray_assigns(a),
    do: Map.take(a, [:id, :myself, :tray_id, :tray_files, :current_company, :current_user, :mode, :note])
```

In **both** `render/1` clauses, insert `<.tray {tray_assigns(assigns)} />` directly after the `<textarea …>…</textarea>` element and before `<.messages …/>`.

- [ ] **Step 7: Run tests**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs test/full_circle_web/live`
Expected: all PASS. If an older test referenced the edit box's `#attach-<note_id>` inside the composer, or sent `attachment_uploaded` to the note page, update it to the new ids. The note page still ignores those events when `note: nil` (the guard in `form.ex` stays).

- [ ] **Step 8: Commit**

```bash
mix format lib/full_circle_web/components/note_components.ex lib/full_circle_web/live/note_live/composer_component.ex lib/full_circle_web/live/note_live/notes_panel_component.ex lib/full_circle_web/live/note_live/form.ex test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/components/note_components.ex lib/full_circle_web/live/note_live/composer_component.ex lib/full_circle_web/live/note_live/notes_panel_component.ex lib/full_circle_web/live/note_live/form.ex test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs
git commit -m "feat(notes): the write box holds files in a tray until Save; Cancel discards

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Saved posts: phone QR and live reload

**Files:**
- Modify: `lib/full_circle_web/live/note_live/notes_panel_component.ex`
- Modify: `lib/full_circle_web/live/note_live/form.ex`
- Test: `test/full_circle_web/live/notes_panel_live_test.exs`, `test/full_circle_web/live/note_live_test.exs` (append)

**Interfaces:**
- Consumes: `NoteFiles.listen/3`, `listen_self/1` (Task 9); `PhoneQrComponent` (Task 10); `PhoneUpload.note_label/1` (Task 7).
- Produces: panel post actions `#{panel_id}-phone-#{note_id}`; note page `#note-phone`. Either reloads when a file lands on its note from anywhere.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle_web/live/notes_panel_live_test.exs`, before the final `end`:

```elixir
  test "a file landing on a shown note (e.g. from the phone) appears without reload",
       %{conn: conn, admin: admin, comp: comp, contact: c} do
    note =
      note_fixture(comp, admin, %{"body" => "letter", "subject_type" => "Contact", "subject_id" => c.id})

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    assert has_element?(lv, "#notes-panel-phone-#{note.id}-open")

    {:ok, _} =
      FullCircle.Notes.Attachments.attach(note, %{path: jpeg_file(), file_name: "p.jpg"}, comp, admin)

    _ = render(lv)
    assert has_element?(lv, "#notes-panel-note-#{note.id} .note-thumb")
  end
```

Append to `test/full_circle_web/live/note_live_test.exs`, inside the same describe block used in Task 11:

```elixir
    test "the note page shows From phone and reloads when a file lands",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "phone me"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert has_element?(lv, "#note-phone-open")

      {:ok, _} =
        FullCircle.Notes.Attachments.attach(note, %{path: jpeg_file(), file_name: "p.jpg"}, comp, admin)

      _ = render(lv)
      assert render(lv) =~ "p.jpg"
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs`
Expected: the two new tests FAIL (no `-phone-` element).

- [ ] **Step 3: Panel: QR on posts, listen per shown note**

In `notes_panel_component.ex`:

1. Add `alias FullCircleWeb.NoteLive.PhoneQrComponent`.
2. Add an `update/2` clause directly before `def update(%{composer: …})`:

```elixir
  # A file landed on one of the shown notes (FullCircleWeb.NoteFiles).
  def update(%{note_files: {:note, _}}, socket), do: {:ok, load(socket)}
```

3. At the end of `load/1`, before `assign(socket, items: …)`, register for every shown note:

```elixir
    for item <- items, do: FullCircleWeb.NoteFiles.listen({:note, item.id}, __MODULE__, socket.assigns.id)
```

4. In the `.note_post` `:actions` slot, after the `<.attach_button … />` added in Task 11, add:

```heex
            <.live_component
              module={PhoneQrComponent}
              id={"#{@id}-phone-#{item.id}"}
              target={{:note, item.id}}
              label={FullCircleWeb.PhoneUpload.note_label(item.note)}
              current_company={@current_company}
              current_user={@current_user}
            />
```

- [ ] **Step 4: Note page: QR on the post, listen for its note**

In `form.ex`:

1. Add `alias FullCircleWeb.NoteLive.PhoneQrComponent`.
2. In `assign_note/2` (the function that assigns `@note`; find it with `grep -n "defp assign_note" lib/full_circle_web/live/note_live/form.ex`), add as its first line:

```elixir
    FullCircleWeb.NoteFiles.listen_self({:note, note.id})
```

where `note` is the function's note argument. Use whatever name the existing function gives it.

3. Add a `handle_info` clause **above** the catch-all `def handle_info(_msg, socket)`:

```elixir
  # A file landed on this note (phone, another tab): show it.
  def handle_info({:note_files, {:note, _}}, socket), do: {:noreply, reload(socket)}
```

4. In the `.note_post` `:actions` slot, after the `<.attach_button :if={@can_edit} … />`, add:

```heex
              <.live_component
                :if={@can_edit}
                module={PhoneQrComponent}
                id="note-phone"
                target={{:note, @note.id}}
                label={FullCircleWeb.PhoneUpload.note_label(@note)}
                current_company={@current_company}
                current_user={@current_user}
              />
```

- [ ] **Step 5: Run tests**

Run: `mix test test/full_circle_web/live`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle_web/live/note_live/notes_panel_component.ex lib/full_circle_web/live/note_live/form.ex test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/live/note_live/notes_panel_component.ex lib/full_circle_web/live/note_live/form.ex test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/note_live_test.exs
git commit -m "feat(notes): From phone on saved posts; panels and note page show landed files live

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Desktop JS: several files per pick, drag-and-drop and paste

**Files:**
- Modify: `assets/js/note_attach.js`
- Modify: `assets/js/app.js`

**Interfaces:**
- Consumes: the `NoteAttach` button (`data-url`, `data-multiple`, `data-max-bytes`, message span `#{id}-msg`) and the `NoteDrop` tray (`data-url`, `data-max-bytes`) from Task 11.
- Produces: `export async function uploadFiles(files, {url, maxBytes, onMessage})` returns `{ok, failed}`; hooks `NoteAttach` and `NoteDrop`.

There's no JS test runner in this project. This task is verified in the browser at Step 4.

- [ ] **Step 1: Rewrite `note_attach.js`**

Replace `assets/js/note_attach.js` with:

```js
// Plain-HTTP attachment upload for notes. Why not LiveView uploads: on phones
// the camera/file picker backgrounds the page, the socket can time out, and a
// remount throws away an in-flight socket upload. A transient <input> in
// document.body survives a remount; an XHR survives the socket dying.
// Only photo formats are re-encoded to JPEG. PNG/WebP/GIF can carry
// transparency (logos, screenshots) that JPEG would paint black.
const PHOTO_EXT = new Set(["jpg", "jpeg", "heic", "heif", "bmp", "avif"])
const PHOTO_TYPES = new Set(["image/jpeg", "image/heic", "image/heif", "image/bmp", "image/avif"])
const DONE_EVENT = "note-attach:done"

function ext(name) {
  const i = name.lastIndexOf(".")
  return i >= 0 ? name.slice(i + 1).toLowerCase() : ""
}

export async function downscale(file, maxEdge = 1920, quality = 0.85) {
  const isPhoto = PHOTO_EXT.has(ext(file.name)) || PHOTO_TYPES.has(file.type || "")
  if (!isPhoto || file.size < 50000) return file
  let bitmap
  try { bitmap = await createImageBitmap(file) } catch (_e) { return file }
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement("canvas")
  canvas.width = Math.round(bitmap.width * scale)
  canvas.height = Math.round(bitmap.height * scale)
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()
  const blob = await new Promise(r => canvas.toBlob(r, "image/jpeg", quality))
  if (!blob || blob.size >= file.size) return file
  const base = file.name.replace(/\.[^.]+$/, "") || "upload"
  return new File([blob], `${base}.jpg`, { type: "image/jpeg" })
}

function post(url, file) {
  return new Promise(resolve => {
    const form = new FormData()
    form.append("file", file, file.name)
    const xhr = new XMLHttpRequest()
    xhr.open("POST", url)
    xhr.setRequestHeader("x-csrf-token", document.querySelector("meta[name='csrf-token']").content)
    xhr.onload = () => {
      let body = {}
      try { body = JSON.parse(xhr.responseText) } catch (_e) {}
      resolve(xhr.status === 200 ? { ok: true, body } : { ok: false, error: body.error || `Upload failed (${xhr.status}).` })
    }
    xhr.onerror = () => resolve({ ok: false, error: "Upload failed — check the connection and try again." })
    xhr.send(form)
  })
}

// One file at a time, so a slow line shows steady progress and one bad file
// does not stop the rest.
export async function uploadFiles(files, { url, maxBytes, onMessage }) {
  const list = Array.from(files)
  let ok = 0
  const failed = []
  for (let i = 0; i < list.length; i++) {
    onMessage(list.length > 1 ? `Uploading ${i + 1} of ${list.length}…` : "Uploading…")
    const file = await downscale(list[i])
    if (file.size > maxBytes) {
      failed.push(`${list[i].name}: larger than ${Math.floor(maxBytes / 1000000)} MB`)
      continue
    }
    const res = await post(url, file)
    if (res.ok) ok++
    else failed.push(`${list[i].name}: ${res.error}`)
  }
  onMessage(failed.join(" · "))
  return { ok, failed }
}

// Announce to the element carrying this id *now*: the upload can outlive a
// re-render, and pushing from a detached element would reach the host
// LiveView instead of the component, which has no handler and would crash.
function announce(hook) {
  const current = document.getElementById(hook.el.id)
  if (current && hook.liveSocket.isConnected()) current.dispatchEvent(new CustomEvent(DONE_EVENT))
}

function listenDone(hook) {
  hook.el.addEventListener(DONE_EVENT, () => hook.pushEventTo(hook.el, "attachment_uploaded", {}))
}

export const NoteAttach = {
  mounted() {
    listenDone(this)
    this.el.addEventListener("click", e => {
      e.preventDefault()
      const input = document.createElement("input")
      input.type = "file"
      input.accept = "image/*,application/pdf"
      input.multiple = this.el.dataset.multiple === "true"
      input.style.display = "none"
      document.body.appendChild(input)
      input.addEventListener("change", async () => {
        const files = Array.from(input.files || [])
        input.remove()
        if (files.length === 0) return
        const msg = document.getElementById(`${this.el.id}-msg`)
        const { ok } = await uploadFiles(files, {
          url: this.el.dataset.url,
          maxBytes: parseInt(this.el.dataset.maxBytes, 10),
          onMessage: t => { if (msg) msg.textContent = t || "" }
        })
        if (ok > 0) announce(this)
      })
      input.click()
    })
  }
}

// The write box's tray: drop files onto the box, or paste a screenshot /
// copied file anywhere in it. Plain-text paste is left alone.
export const NoteDrop = {
  mounted() {
    listenDone(this)
    const box = this.el.closest("[id$='-box']") || this.el
    const send = async files => {
      const msgEl = this.el.querySelector("[id$='-files-msg']")
      const { ok } = await uploadFiles(files, {
        url: this.el.dataset.url,
        maxBytes: parseInt(this.el.dataset.maxBytes, 10),
        onMessage: t => { if (msgEl) msgEl.textContent = t || "" }
      })
      if (ok > 0) announce(this)
    }
    this.onDragOver = e => {
      if (!e.dataTransfer || !Array.from(e.dataTransfer.types).includes("Files")) return
      e.preventDefault()
      box.classList.add("ring-2", "ring-sky-400")
    }
    this.onDragLeave = () => box.classList.remove("ring-2", "ring-sky-400")
    this.onDrop = e => {
      if (!e.dataTransfer || e.dataTransfer.files.length === 0) return
      e.preventDefault()
      box.classList.remove("ring-2", "ring-sky-400")
      send(e.dataTransfer.files)
    }
    this.onPaste = e => {
      const files = e.clipboardData ? Array.from(e.clipboardData.files) : []
      if (files.length === 0) return
      e.preventDefault()
      send(files)
    }
    box.addEventListener("dragover", this.onDragOver)
    box.addEventListener("dragleave", this.onDragLeave)
    box.addEventListener("drop", this.onDrop)
    box.addEventListener("paste", this.onPaste)
    this.box = box
  },
  destroyed() {
    if (!this.box) return
    this.box.removeEventListener("dragover", this.onDragOver)
    this.box.removeEventListener("dragleave", this.onDragLeave)
    this.box.removeEventListener("drop", this.onDrop)
    this.box.removeEventListener("paste", this.onPaste)
  }
}
```

The tray's 📎 button has id `#{id}-files`, so its message span is `#{id}-files-msg`. `NoteDrop` writes its messages there, which is why it looks for `[id$='-files-msg']`.

- [ ] **Step 2: Register `NoteDrop`**

In `assets/js/app.js`, change `import { NoteAttach } from "./note_attach"` to `import { NoteAttach, NoteDrop } from "./note_attach"`, and add `Hooks.NoteDrop = NoteDrop` on the line after `Hooks.NoteAttach = NoteAttach`.

- [ ] **Step 3: Build**

Run: `mix assets.build`
Expected: no esbuild errors.

- [ ] **Step 4: Verify in the browser**

With `mix phx.server` running, open a contact's edit page in Chrome and press **＋ Note** in the notes panel:
1. **📎 Attach files**: pick 3 images at once. Expected: "Uploading 1 of 3…" and so on, then three tiles in the box.
2. Drag a PDF from the file manager onto the box. Expected: a blue ring while dragging, then a PDF tile.
3. Take a screenshot to the clipboard and press Ctrl+V in the textarea. Expected: a PNG tile. Pasting plain text still types text.
4. Press **Post**. Expected: the post shows all files.
5. Check both light and dark theme (the ring and the message colours).

- [ ] **Step 5: Commit**

```bash
git add assets/js/note_attach.js assets/js/app.js
git commit -m "feat(notes): several files per pick; drop and paste into the write box

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: The phone page script

**Files:**
- Create: `assets/js/phone_upload.js`
- Modify: `config/config.exs` (esbuild entry)

**Interfaces:**
- Consumes: the `show.html.heex` DOM ids (`#phone-upload` `data-token`/`data-target-key`/`data-max-bytes`, `#pu-*`) and the `/up/:token/*` endpoints (Task 8); `downscale` from `note_attach.js` (Task 13).

- [ ] **Step 1: Add the esbuild entry**

In `config/config.exs`, in the esbuild `args: ~w(js/app.js js/tri_autocomplete.js`, add `js/phone_upload.js` after `js/tri_autocomplete.js`.

- [ ] **Step 2: Write the script**

Create `assets/js/phone_upload.js`:

```js
// The phone upload page (/up/:token): scan pages into one PDF, take a photo,
// or pick files (WhatsApp media, Downloads, saved email attachments). Plain
// HTTP to the endpoints in PhoneUploadController. Every success returns a
// fresh token; it replaces the one in the URL so a reload keeps working
// within the 10-minute idle window. A scan in progress is remembered in
// localStorage and resumed from the server's page count after a reload.
import { downscale } from "./note_attach"

const root = document.getElementById("phone-upload")
if (root) start(root)

function start(root) {
  let token = root.dataset.token
  const maxBytes = parseInt(root.dataset.maxBytes, 10)
  const scanKey = `phoneUpload:scan:${root.dataset.targetKey}`
  const sentKey = `phoneUpload:sent:${root.dataset.targetKey}`
  const $ = id => document.getElementById(id)
  let scan = null // {id, pages}

  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem(k)) } catch (_e) { return null } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)) } catch (_e) {} },
    del(k) { try { localStorage.removeItem(k) } catch (_e) {} }
  }

  function banner(text) {
    $("pu-banner").textContent = text
    $("pu-banner").classList.remove("hidden")
    for (const id of ["pu-scan", "pu-photo", "pu-files", "pu-next", "pu-retake", "pu-done"]) $(id).disabled = true
  }

  function refresh(body) {
    if (body && body.token) {
      token = body.token
      history.replaceState(null, "", `/up/${token}`)
    }
  }

  async function call(method, path, form) {
    let res
    try {
      res = await fetch(`/up/${token}${path}`, { method, body: form })
    } catch (_e) {
      return { ok: false, retry: true, error: "No connection — tap ↻ to retry." }
    }
    let body = {}
    try { body = await res.json() } catch (_e) {}
    if (res.ok) { refresh(body); return { ok: true, body } }
    if (body.code === "expired" || body.code === "closed" || body.code === "forbidden") banner(body.error)
    return { ok: false, retry: false, error: body.error || `Failed (${res.status}).` }
  }

  // --- sent list -----------------------------------------------------------

  function addSent(name) {
    const li = document.createElement("li")
    li.className = "flex items-center gap-2 rounded bg-white p-2 dark:bg-gray-900"
    li.innerHTML = `<span class="pu-mark">⏳</span><span class="truncate"></span><span class="pu-err ml-auto text-rose-600 dark:text-rose-400"></span>`
    li.querySelector(".truncate").textContent = name
    $("pu-sent").prepend(li)
    return li
  }

  function markSent(li, res, retry) {
    li.querySelector(".pu-mark").textContent = res.ok ? "✓" : "✕"
    li.querySelector(".pu-err").textContent = res.ok ? "" : res.error
    if (res.ok) {
      const names = store.get(sentKey) || []
      store.set(sentKey, [li.querySelector(".truncate").textContent, ...names].slice(0, 30))
    } else if (res.retry && retry) {
      const b = document.createElement("button")
      b.type = "button"
      b.textContent = "↻"
      b.className = "ml-2 rounded bg-gray-200 px-2 dark:bg-gray-800"
      b.onclick = async () => { b.remove(); li.querySelector(".pu-mark").textContent = "⏳"; markSent(li, await retry(), retry) }
      li.appendChild(b)
    }
  }

  for (const name of (store.get(sentKey) || []).slice().reverse()) {
    const li = addSent(name)
    li.querySelector(".pu-mark").textContent = "✓"
  }

  // --- pickers -------------------------------------------------------------

  function pick({ capture, multiple, accept }, onFiles) {
    const input = document.createElement("input")
    input.type = "file"
    input.accept = accept
    if (capture) input.capture = "environment"
    input.multiple = !!multiple
    input.style.display = "none"
    document.body.appendChild(input)
    input.addEventListener("change", () => {
      const files = Array.from(input.files || [])
      input.remove()
      if (files.length) onFiles(files)
    })
    input.click()
  }

  async function sendFile(file) {
    const ready = await downscale(file)
    const li = addSent(file.name)
    const attempt = async () => {
      if (ready.size > maxBytes) return { ok: false, error: `Larger than ${Math.floor(maxBytes / 1000000)} MB.` }
      const form = new FormData()
      form.append("file", ready, ready.name)
      return call("POST", "/files", form)
    }
    markSent(li, await attempt(), attempt)
  }

  $("pu-photo").onclick = () => pick({ capture: true, accept: "image/*" }, files => sendFile(files[0]))
  $("pu-files").onclick = () =>
    pick({ multiple: true, accept: "image/*,application/pdf" }, async files => { for (const f of files) await sendFile(f) })

  // --- scanning ------------------------------------------------------------

  function showScan() {
    $("pu-scanning").classList.toggle("hidden", !scan)
    $("pu-pages").textContent = scan ? `${scan.pages} ${scan.pages === 1 ? "page" : "pages"}` : ""
  }

  function startScan() {
    scan = { id: crypto.randomUUID(), pages: 0 }
    store.set(scanKey, scan)
    $("pu-thumbs").innerHTML = ""
    showScan()
    takePage()
  }

  function takePage() {
    pick({ capture: true, accept: "image/*" }, async files => {
      const blob = await enhance(files[0], $("pu-look").value)
      const thumb = document.createElement("img")
      thumb.src = URL.createObjectURL(blob)
      thumb.className = "h-20 rounded border border-gray-300 opacity-50 dark:border-gray-600"
      $("pu-thumbs").appendChild(thumb)
      const form = new FormData()
      form.append("file", blob, "page.jpg")
      const res = await call("POST", `/scans/${scan.id}/pages`, form)
      if (res.ok) {
        thumb.classList.remove("opacity-50")
        scan.pages = res.body.pages
        store.set(scanKey, scan)
      } else {
        thumb.remove()
        alertLine(res.error)
      }
      showScan()
    })
  }

  function alertLine(text) {
    const li = addSent(text)
    li.querySelector(".pu-mark").textContent = "✕"
  }

  $("pu-scan").onclick = () => (scan ? takePage() : startScan())
  $("pu-next").onclick = () => takePage()

  $("pu-retake").onclick = async () => {
    if (!scan || scan.pages === 0) return
    const res = await call("DELETE", `/scans/${scan.id}/pages/last`)
    if (!res.ok) return alertLine(res.error)
    scan.pages = res.body.pages
    store.set(scanKey, scan)
    const last = $("pu-thumbs").lastElementChild
    if (last) last.remove()
    showScan()
    takePage()
  }

  $("pu-done").onclick = async () => {
    if (!scan) return
    const now = new Date()
    const p = n => String(n).padStart(2, "0")
    const name = `Scan ${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())} ${p(now.getHours())}${p(now.getMinutes())}.pdf`
    const li = addSent(`${name} (${scan.pages} pages)`)
    const form = new FormData()
    form.append("name", name)
    const res = await call("POST", `/scans/${scan.id}/done`, form)
    markSent(li, res, null)
    if (res.ok) {
      scan = null
      store.del(scanKey)
      $("pu-thumbs").innerHTML = ""
      showScan()
    }
  }

  // Resume a scan the page was reloaded in the middle of.
  const saved = store.get(scanKey)
  if (saved && saved.id) {
    call("GET", `/state?scan_id=${encodeURIComponent(saved.id)}`).then(res => {
      if (res.ok && res.body.pages > 0) {
        scan = { id: saved.id, pages: res.body.pages }
        showScan()
      } else {
        store.del(scanKey)
      }
    })
  }
}

// --- page look ---------------------------------------------------------------

async function enhance(file, look, maxEdge = 1920) {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
  const w = Math.round(bitmap.width * scale)
  const h = Math.round(bitmap.height * scale)
  const canvas = document.createElement("canvas")
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext("2d", { willReadFrequently: true })
  ctx.drawImage(bitmap, 0, 0, w, h)
  bitmap.close()
  if (look === "clean") cleanColour(ctx, w, h)
  if (look === "bw") blackWhite(ctx, w, h)
  const quality = look === "bw" ? 0.75 : look === "clean" ? 0.8 : 0.85
  return await new Promise(r => canvas.toBlob(r, "image/jpeg", quality))
}

const luma = (d, i) => (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8

// Levels stretch from the 2nd to the 98th luminance percentile: grey paper
// turns white, ink turns dark, colours (stamps, signatures) keep their hue.
function cleanColour(ctx, w, h) {
  const img = ctx.getImageData(0, 0, w, h)
  const d = img.data
  const hist = new Uint32Array(256)
  for (let i = 0; i < d.length; i += 4) hist[luma(d, i)]++
  const total = w * h
  const pct = p => {
    let acc = 0
    for (let v = 0; v < 256; v++) { acc += hist[v]; if (acc >= total * p) return v }
    return 255
  }
  const lo = pct(0.02)
  const hi = Math.max(pct(0.98), lo + 1)
  const lut = new Uint8ClampedArray(256)
  for (let v = 0; v < 256; v++) lut[v] = ((v - lo) * 255) / (hi - lo)
  for (let i = 0; i < d.length; i += 4) {
    d[i] = lut[d[i]]
    d[i + 1] = lut[d[i + 1]]
    d[i + 2] = lut[d[i + 2]]
  }
  ctx.putImageData(img, 0, 0)
}

// Local adaptive threshold (mean of a 31px window minus 10), via an integral
// image, so a shadow across the page does not swallow the text under it.
function blackWhite(ctx, w, h) {
  const img = ctx.getImageData(0, 0, w, h)
  const d = img.data
  const gray = new Uint8Array(w * h)
  for (let p = 0, i = 0; p < w * h; p++, i += 4) gray[p] = luma(d, i)
  const W = w + 1
  const integral = new Uint32Array(W * (h + 1))
  for (let y = 1; y <= h; y++) {
    let row = 0
    for (let x = 1; x <= w; x++) {
      row += gray[(y - 1) * w + (x - 1)]
      integral[y * W + x] = integral[(y - 1) * W + x] + row
    }
  }
  const r = 15
  const C = 10
  for (let y = 0; y < h; y++) {
    const y0 = Math.max(0, y - r)
    const y1 = Math.min(h, y + r + 1)
    for (let x = 0; x < w; x++) {
      const x0 = Math.max(0, x - r)
      const x1 = Math.min(w, x + r + 1)
      const sum = integral[y1 * W + x1] - integral[y0 * W + x1] - integral[y1 * W + x0] + integral[y0 * W + x0]
      const mean = sum / ((x1 - x0) * (y1 - y0))
      const v = gray[y * w + x] < mean - C ? 0 : 255
      const i = (y * w + x) * 4
      d[i] = d[i + 1] = d[i + 2] = v
    }
  }
  ctx.putImageData(img, 0, 0)
}
```

`import { downscale } from "./note_attach"` works because Task 13 exports `downscale`, and esbuild's code splitting puts it in a shared chunk.

- [ ] **Step 3: Build**

Run: `mix assets.build`
Expected: `priv/static/assets/phone_upload.js` exists with no esbuild errors.

- [ ] **Step 4: Verify in Chrome phone emulation**

With `mix phx.server` running:
1. On a note's page, press **📱 From phone** and open the link under the QR in a new tab. Turn on DevTools device emulation (Pixel 7).
2. **📎 Files**: pick 2 images. Expected: two ✓ rows, and the desktop tab shows them on the note without a reload.
3. **📄 Scan**: pick an image of a document (emulation has no camera, so the picker opens). Expected: a thumbnail, "1 page". Add a second page. Press **↺ Retake** and the last thumbnail goes. Press **✓ Done**. Expected: "Scan … (n pages)" ✓, and a PDF tile on the desktop whose preview shows the page.
4. Start a scan, add 1 page, then reload the phone tab. Expected: the scan section shows "1 page" again, and **Done** makes the PDF.
5. Change the look to **Black & white** and scan again. Expected: a crisp black-on-white page in the PDF.
6. Open a write box (＋ Note in a panel), use its **📱 From phone** link, upload a file, then press **Cancel** on the desktop and upload again from the phone. Expected: a red banner, "This note was closed on the desktop."
7. Check dark mode (DevTools → Rendering → `prefers-color-scheme: dark`).

- [ ] **Step 5: Commit**

```bash
git add assets/js/phone_upload.js config/config.exs
git commit -m "feat(notes): phone page script: multi-page scan to PDF, photo, files, resume

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Docs, full suite, real-phone check

**Files:**
- Modify: `.claude/skills/notes.md`

- [ ] **Step 1: Rewrite the skill's Attachments section**

In `.claude/skills/notes.md`, replace the paragraph that starts "Plain HTTP (`NoteAttachmentController`), never LiveView uploads" with the following. Keep the rest of the section (Templates…, PDF previews…) as it is:

```markdown
Plain HTTP (`NoteAttachmentController`, `PhoneUploadController`), never
LiveView uploads — phones lose socket uploads when the camera backgrounds the
page. Type sniffed from magic bytes. **Removal from a saved note hides the
file** (`get_readable/3` filters `removed_at`) but keeps it on disk — a
removed file is usually the wrong upload, so an old link must not keep
serving it.

**Tray (hold until Save).** Every write box (`ComposerComponent`) owns a
`tray_id`, fresh on each open/Save/Cancel (`reset/1` → `new_tray/1`). Files
picked, dropped, pasted or sent from the phone go into that tray
(`note_attachments.tray_id`, `note_id` empty — `note_xor_tray` check) and show
as `#{id}-tray-files`. Save passes `"tray_id"` to `Notes.create_note` /
`update_note`, which `Trays.claim/5` inside the note's transaction (a
files-only edit still claims; a stale/invalid save does not). Cancel
hard-deletes the tray's files (`Trays.cancel/3`). A saved tray follows: a
late phone upload attaches to its note; a cancelled one answers 409 closed.
`TrayPruner` deletes trays and scan folders older than 24 h. Files already
on a note keep the immediate soft remove (✕ on `#note-files`).

**Phone (`/up/:token`).** `FullCircleWeb.PhoneUpload` signs `{:tray | :note,
id}` + company + user + label; 600 s idle — every success returns a fresh
token and the page swaps it into the URL. Every request re-checks the user
is active in the company; note uploads re-check `may_edit?`. Scans upload
page by page (`Notes.Scans`, `<uploads>/<company>/scans/<scan_id>/NNN.jpg`,
max 30) and `ScanPdf` builds the PDF on Done (JPEGs embedded as DCTDecode,
no re-encode). The 📱 button is `PhoneQrComponent` (QR made on open; a tray
target creates the tray row).

**Live arrival.** Every upload broadcasts `{:note_files_changed, {:tray |
:note, id}}` on `Attachments.topic(company_id)`. `FullCircleWeb.NoteFiles`
(on_mount in the company live_session) halts it and `send_update`s whoever
called `NoteFiles.listen/3` for that target (composer: its tray; notes
panel: each shown note), or sends `{:note_files, target}` to a LiveView that
called `listen_self/1` (the note page). Tests: a second `render(lv)` sees the
update (the send_update queues behind the first render call).
```

Also, in the panel section, replace the sentence "Files attach after the first save, through ✎ Edit." with "Files go into the box's tray and attach on Save." Search the skill for "Files attach after the first save" and update every occurrence the same way.

- [ ] **Step 2: Run the full suite**

Run: `mix test`
Expected: 0 failures. The suite was green at 2171 tests on 2026-10-04 and grows by this plan's tests. Known harmless noise: QueryRepo connection errors and punch-ingest log copy errors.

- [ ] **Step 3: Check the formatting of touched files**

Run: `git diff --name-only HEAD~14 -- '*.ex' '*.exs' | xargs mix format --check-formatted`
Expected: exit 0. Never run bare `mix format`.

- [ ] **Step 4: Commit the docs**

```bash
git add .claude/skills/notes.md
git commit -m "docs(notes): tray, phone upload and live-arrival contract

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Real-phone check (by the human, before deploy)**

The phone must reach the server, so either deploy to staging or production, or run dev on the LAN with `PHX_HOST` set to this machine's LAN IP. In dev, `Endpoint.url()` is `localhost`, which a phone can't open. On an **Android** phone and an **iPhone**:
1. Scan the desktop QR with the normal camera app, and the page opens.
2. **📄 Scan** a 3-page letter: the camera opens directly, every page uploads, **Done** gives one readable PDF, and the stamp colour is kept in Clean colour.
3. **📎 Files**: pick a WhatsApp image and a PDF from Downloads.
4. Lock the phone mid-scan, unlock it, and carry on. The pages are still there.
5. On iPhone, a HEIC photo arrives as JPEG (Safari converts it in the file input). If one arrives as HEIC, the server refuses it with the type message, and nothing breaks.
