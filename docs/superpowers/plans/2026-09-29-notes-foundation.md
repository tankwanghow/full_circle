# Notes Foundation (Sub-project 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unused `FullCircle.Tugas` backend with a company-wide Notes system — notes about any FullCircle record (or none), per-note role visibility, full version history, attachments, links/backlinks, search — with a notes panel on every linkable record's edit page and a notes count on its index page.

**Architecture:** Two new contexts. `FullCircle.Linkable` is the registry of record types a note can be about or link to (Employee, Contact, Good, Note + 9 posted document types), stored as `(type, id)` pairs with no FKs. `FullCircle.Notes` owns notes, versions, attachments and `record_links`; every read goes through one composable `Notes.visible_to/3` query. Desktop LiveViews under `/companies/:company_id/notes`, one reusable `NotesPanelComponent` embedded in record forms and opened as a modal from index counts. Attachments upload/download over plain HTTP controllers.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / LiveView 1.2, Ecto + PostgreSQL (`pg_trgm` already installed), Tailwind 4 (no daisyUI), esbuild JS hook.

**Spec:** `docs/superpowers/specs/2026-09-29-notes-and-tasks-design.md` (sections 3–11). Read it before starting.

## Global Constraints

- Work on `master`, commit per task (solo workflow per `CLAUDE.md`). Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Never run bare `mix format`** — it rewrites ~14 unrelated files. Format only the files you touched: `mix format path/a.ex path/b.exs`.
- Schemas use `use FullCircle.Schema` (binary_id PKs), never `use Ecto.Schema`.
- All tables: `company_id` NOT NULL, `on_delete: :delete_all`.
- Unauthorized → return `:not_authorise`. LiveView flashes use kind `:warn` (`:warning` renders nothing).
- `Authorization.can?/3` has no catch-all; every new action needs a clause, grouped with the other `can?/3` clauses.
- Notes do **not** write `Sys.Log`; `note_versions` is their audit trail.
- Attachment allowlist `image/jpeg image/png image/webp application/pdf`, max `10_000_000` bytes, type **sniffed from magic bytes**, stored path relative to `:uploads_dir` as `<company_id>/notes/<note_id>/<uuid><ext>`.
- Visibility: `nil` = public; else non-empty list of roles from `Authorization.roles() -- ["disable"]`. Admin always reads; author always reads own note.
- Edit others' notes / delete others' notes: `admin`, `manager` only — and only notes they can read.
- UI: FullCircle plain Tailwind; every new colour gets a `dark:` variant (the app has a `.dark` theme).
- New UI strings wrapped in `gettext`; zh translations added in the final task.
- Title max 120 chars, optional. Body required, plain text rendered with `whitespace-pre-wrap`.

## Review Focus

1. **Restricted note leaking through a side channel** — a clerk must not see a manager-only note's existence via the index count, the panel, backlinks, search, versions, or the download URL. Pinned by visibility-matrix tests in Tasks 5, 6, 7, 9.
2. **Two people editing the same note** — second save must get "someone else changed this note", keep their text, and not write a version. Pinned in Task 5 (context) and Task 12 (LiveView).
3. **Linking to another company's record by pasting its UUID** (or a type not in the registry) — must be rejected as not found. Pinned in Tasks 4 and 5.
4. **Chinese text in notes** — `word_similarity` scores CJK poorly; a search for `焊工` must still find a note containing it (ILIKE is the filter, similarity only orders). Pinned in Task 7.
5. **Phone uploads arriving as `application/octet-stream` or a renamed `.exe`** — type decided by magic bytes only; a real JPEG with a wrong claim is accepted, a non-image with `.jpg` name is refused and nothing is written to disk. Pinned in Task 8.

---

## File Structure

Created:

| File | Responsibility |
|---|---|
| `priv/repo/migrations/20260929090000_drop_tugas.exs` | drop the four Tugas tables |
| `priv/repo/migrations/20260929091000_create_notes.exs` | notes, note_versions, note_attachments, record_links |
| `lib/full_circle/linkable.ex` | registry: types, resolve, resolve_many, search, url |
| `lib/full_circle/linkable/record_link.ex` | `record_links` schema |
| `lib/full_circle/notes.ex` | visibility, CRUD, versions, links, panel queries, counts, search |
| `lib/full_circle/notes/note.ex` | `notes` schema + changeset |
| `lib/full_circle/notes/note_version.ex` | `note_versions` schema + snapshot |
| `lib/full_circle/notes/note_attachment.ex` | `note_attachments` schema |
| `lib/full_circle/notes/attachments.ex` | attach / remove / list / readable lookup, sniffing |
| `lib/full_circle_web/controllers/note_attachment_controller.ex` | HTTP upload + download |
| `lib/full_circle_web/components/note_components.ex` | type labels, visibility badge, note card, attachment list, attach button, count badge |
| `lib/full_circle_web/live/note_live/record_picker_component.ex` | type select + search → pick a record |
| `lib/full_circle_web/live/note_live/index.ex` | `/notes` search list |
| `lib/full_circle_web/live/note_live/form.ex` | `/notes/new`, `/notes/:id/edit` |
| `lib/full_circle_web/live/note_live/show.ex` | `/notes/:id` detail, links, backlinks, history |
| `lib/full_circle_web/live/note_live/notes_panel_component.ex` | panel for a record (inline + modal) |
| `lib/full_circle_web/live/note_live/notes_index.ex` | helper for index pages: counts, open/close modal |
| `assets/js/note_attach.js` | plain-HTTP upload hook |
| `test/support/fixtures/notes_fixtures.ex` | `user_with_role/3`, `note_fixture/3`, file fixtures |
| `test/full_circle/linkable_test.exs`, `test/full_circle/notes_test.exs`, `test/full_circle/notes_attachments_test.exs` | context tests |
| `test/full_circle_web/controllers/note_attachment_controller_test.exs` | controller tests |
| `test/full_circle_web/live/note_live_test.exs`, `test/full_circle_web/live/notes_panel_live_test.exs` | LiveView tests |
| `.claude/skills/notes.md` | project skill for the Notes contract |

Deleted: `lib/full_circle/tugas.ex`, `lib/full_circle/tugas/` (4 files), `test/full_circle/tugas_test.exs`, `.claude/skills/tugas-duties.md`.

Modified: `lib/full_circle/authorization.ex`, `lib/full_circle/bill_pay.ex`, `test/full_circle/bill_pay_test.exs`, `lib/full_circle_web/router.ex`, `lib/full_circle_web/endpoint.ex`, `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, `lib/full_circle/command_palette/types.ex`, `assets/js/app.js`, the 12 form + 12 index LiveViews + 12 index components listed in Task 16, `priv/gettext/zh/LC_MESSAGES/default.po`, `CLAUDE.md`.

---

### Task 1: Remove the old Tugas backend

**Files:**
- Create: `priv/repo/migrations/20260929090000_drop_tugas.exs`
- Delete: `lib/full_circle/tugas.ex`, `lib/full_circle/tugas/duty.ex`, `lib/full_circle/tugas/duty_event.ex`, `lib/full_circle/tugas/duty_event_document.ex`, `lib/full_circle/tugas/duty_document.ex`, `test/full_circle/tugas_test.exs`, `.claude/skills/tugas-duties.md`
- Modify: `lib/full_circle/bill_pay.ex` (remove `opts`/`maybe_link_duty`), `test/full_circle/bill_pay_test.exs` (remove the `# --- TUGAS DUTY LINK ---` describe), `lib/full_circle/authorization.ex` (remove the `# --- Tugas (duties) ---` block, ~lines 144–190), `CLAUDE.md`

**Interfaces:**
- Produces: `BillPay.create_payment/3` and `create_payment_multi/4` exactly as before commit `17d2abed` (no `opts`).

- [ ] **Step 1: Reverse the BillPay wiring from commit 17d2abed**

```bash
git show 17d2abed -- lib/full_circle/bill_pay.ex test/full_circle/bill_pay_test.exs | git apply -R
```

If `git apply -R` reports a conflict, do it by hand: in `lib/full_circle/bill_pay.ex` change `def create_payment(attrs, com, user, opts \\ [])` → `def create_payment(attrs, com, user)`, `create_payment_multi(attrs, com, user, opts)` → `create_payment_multi(attrs, com, user)`, `def create_payment_multi(multi, attrs, com, user, opts \\ [])` → `def create_payment_multi(multi, attrs, com, user)`, delete the `|> maybe_link_duty(...)` pipe line, both `maybe_link_duty` clauses, their comment, and the `opts[:duty_id]` paragraph in the `@doc`. In `test/full_circle/bill_pay_test.exs` delete from `# --- TUGAS DUTY LINK ---` through the end of that `describe` block.

- [ ] **Step 2: Delete the Tugas files and authorization block**

```bash
git rm -q lib/full_circle/tugas.ex lib/full_circle/tugas/*.ex test/full_circle/tugas_test.exs .claude/skills/tugas-duties.md
```

In `lib/full_circle/authorization.ex` delete the block that starts with the comment `# --- Tugas (duties) ---` and ends after `def can?(user, :delete_others_duty_event, company), do: allow_roles(~w(admin manager supervisor), company, user)` (the next clause is `:create_fixed_asset` — keep it).

- [ ] **Step 3: Write the drop migration**

`priv/repo/migrations/20260929090000_drop_tugas.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.DropTugas do
  use Ecto.Migration

  # The backend-only Tugas tables were never used by any UI and hold no data
  # worth keeping; Notes & Tasks replace them (spec 2026-09-29).
  def up do
    drop_if_exists table(:duty_event_documents)
    drop_if_exists table(:duty_documents)
    drop_if_exists table(:duty_events)
    drop_if_exists table(:duties)
  end

  def down do
    raise Ecto.MigrationError, message: "irreversible: Tugas tables were dropped"
  end
end
```

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, replace the table row `` | `Tugas` | Duties: progress events, evidence files, multi-document links | `` with `` | `Notes` / `Linkable` | Company memory: notes about any record, role visibility, versions, attachments, links | ``, and in the project-skills list replace `` `tugas-duties.md` `` with `` `notes.md` `` (the file is written in Task 17).

- [ ] **Step 5: Verify nothing references Tugas and the suite is green**

Run: `grep -rn "Tugas\|duty_id\|tugas" lib test config | grep -v "_build"`
Expected: no output.

Run: `mix ecto.migrate && mix test`
Expected: all tests pass (count drops by the removed Tugas/BillPay-duty tests). If `mix ecto.migrate` fails because `20260916090000_create_tugas` never ran locally, that is fine — `drop_if_exists` covers it.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/bill_pay.ex lib/full_circle/authorization.ex test/full_circle/bill_pay_test.exs priv/repo/migrations/20260929090000_drop_tugas.exs
git add -A lib/full_circle/bill_pay.ex lib/full_circle/authorization.ex test/full_circle/bill_pay_test.exs priv/repo/migrations/20260929090000_drop_tugas.exs CLAUDE.md lib/full_circle/tugas.ex lib/full_circle/tugas test/full_circle/tugas_test.exs .claude/skills/tugas-duties.md
git commit -m "refactor(tugas): remove the unused backend-only Tugas; Notes & Tasks replace it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Notes authorization actions

**Files:**
- Modify: `lib/full_circle/authorization.ex` (insert where the Tugas block was, before `:create_fixed_asset`)
- Create: `test/full_circle/notes_test.exs`

**Interfaces:**
- Produces: `can?(user, :view_notes | :create_note | :edit_others_note | :delete_others_note, company) :: boolean`

- [ ] **Step 1: Write the failing test**

`test/full_circle/notes_test.exs`:

```elixir
defmodule FullCircle.NotesTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures

  setup do
    billing_setup()
  end

  describe "notes authorization" do
    test_authorise_to(:view_notes, ~w(admin manager supervisor cashier clerk auditor))
    test_authorise_to(:create_note, ~w(admin manager supervisor cashier clerk))
    test_authorise_to(:edit_others_note, ~w(admin manager))
    test_authorise_to(:delete_others_note, ~w(admin manager))
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/notes_test.exs`
Expected: FAIL with `FunctionClauseError` in `FullCircle.Authorization.can?/3`.

- [ ] **Step 3: Add the clauses**

In `lib/full_circle/authorization.ex`, immediately before `def can?(user, :create_fixed_asset, company),`:

```elixir
  # --- Notes ------------------------------------------------------------
  #
  # Per-note visibility (a role list on the note) decides *which* notes a user
  # reads; these decide whether they touch notes at all. auditor reads only.

  def can?(user, :view_notes, company),
    do: allow_roles(~w(admin manager supervisor cashier clerk auditor), company, user)

  def can?(user, :create_note, company),
    do: allow_roles(~w(admin manager supervisor cashier clerk), company, user)

  def can?(user, :edit_others_note, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :delete_others_note, company),
    do: allow_roles(~w(admin manager), company, user)
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/notes_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/authorization.ex test/full_circle/notes_test.exs
git add lib/full_circle/authorization.ex test/full_circle/notes_test.exs
git commit -m "feat(notes): authorization actions for notes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Tables and schemas

**Files:**
- Create: `priv/repo/migrations/20260929091000_create_notes.exs`, `lib/full_circle/notes/note.ex`, `lib/full_circle/notes/note_version.ex`, `lib/full_circle/notes/note_attachment.ex`, `lib/full_circle/linkable/record_link.ex`, `test/support/fixtures/notes_fixtures.ex`
- Test: `test/full_circle/notes_test.exs` (add describe)

**Interfaces:**
- Produces:
  - `FullCircle.Notes.Note` fields `title body subject_type subject_id visibility author_id updated_by_id lock_version deleted_at deleted_by_id company_id`, assocs `author`, `updated_by`, `attachments` (live only); `Note.changeset(note, attrs)`; `Note.visibility_roles() :: [String.t()]`; `Note.display_title(note) :: String.t()`
  - `FullCircle.Notes.NoteVersion` fields `note_id company_id version title body subject_type subject_id visibility written_by_id written_at edited_by_id inserted_at`; `NoteVersion.snapshot(note, version_no, editor) :: Ecto.Changeset.t()`
  - `FullCircle.Notes.NoteAttachment` fields `company_id note_id file_name content_type byte_size path uploaded_by_id removed_at removed_by_id`; `NoteAttachment.changeset(att, attrs)`
  - `FullCircle.Linkable.RecordLink` fields `company_id from_type from_id to_type to_id created_by_id inserted_at`; `RecordLink.changeset(link, attrs)`
  - Fixtures: `NotesFixtures.user_with_role(company, admin, role)`, `note_fixture(company, user, attrs \\ %{})` (defined in Task 5 once `create_note` exists — this task adds only `user_with_role`), `jpeg_file()`, `pdf_file()`, `text_file()`

- [ ] **Step 1: Write the failing schema tests**

Append to `test/full_circle/notes_test.exs` (inside the module):

```elixir
  alias FullCircle.Notes.Note

  describe "Note.changeset/2" do
    test "body is required and title is capped at 120" do
      cs = Note.changeset(%Note{}, %{"body" => "", "title" => String.duplicate("x", 121)})
      assert %{body: ["can't be blank"], title: [_]} = errors_on(cs)
    end

    test "subject type and id come as a pair" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "subject_type" => "Contact"})
      assert %{subject_id: ["must be set together with subject type"]} = errors_on(cs)
    end

    test "visibility accepts known roles only, never disable" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["manager", "disable"]})
      assert %{visibility: ["has an invalid entry"]} = errors_on(cs)

      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => ["manager", "clerk"]})
      assert cs.valid?
    end

    test "an empty visibility list is rejected — public is nil" do
      cs = Note.changeset(%Note{}, %{"body" => "b", "visibility" => []})
      assert %{visibility: ["use nil for public"]} = errors_on(cs)
    end

    test "display_title falls back to the first body line" do
      assert Note.display_title(%Note{title: nil, body: "first line\nsecond"}) == "first line"
      assert Note.display_title(%Note{title: "T", body: "x"}) == "T"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/notes_test.exs`
Expected: FAIL — `FullCircle.Notes.Note.__struct__/0 is undefined`.

- [ ] **Step 3: Write the migration**

`priv/repo/migrations/20260929091000_create_notes.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :title, :string, size: 120
      add :body, :text, null: false
      add :subject_type, :string
      add :subject_id, :binary_id
      add :visibility, {:array, :string}
      add :author_id, references(:users, on_delete: :nothing), null: false
      add :updated_by_id, references(:users, on_delete: :nothing), null: false
      add :lock_version, :integer, null: false, default: 0
      add :deleted_at, :utc_datetime
      add :deleted_by_id, references(:users, on_delete: :nothing)
      timestamps(type: :utc_datetime)
    end

    create constraint(:notes, :notes_subject_pair,
             check: "(subject_type IS NULL) = (subject_id IS NULL)"
           )

    # nil means public; an empty list would mean "nobody but admin and the
    # author", which is never what someone ticking no boxes intends.
    create constraint(:notes, :notes_visibility_not_empty,
             check: "visibility IS NULL OR cardinality(visibility) > 0"
           )

    create index(:notes, [:company_id, :subject_type, :subject_id])
    create index(:notes, [:company_id, :inserted_at])

    execute(
      "CREATE INDEX notes_title_trgm ON notes USING gin (title gin_trgm_ops)",
      "DROP INDEX notes_title_trgm"
    )

    execute(
      "CREATE INDEX notes_body_trgm ON notes USING gin (body gin_trgm_ops)",
      "DROP INDEX notes_body_trgm"
    )

    create table(:note_versions) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :title, :string, size: 120
      add :body, :text, null: false
      add :subject_type, :string
      add :subject_id, :binary_id
      add :visibility, {:array, :string}
      add :written_by_id, references(:users, on_delete: :nothing), null: false
      add :written_at, :utc_datetime, null: false
      add :edited_by_id, references(:users, on_delete: :nothing), null: false
      # usec: an edit and a delete can land inside the same second.
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:note_versions, [:note_id, :version])

    create table(:note_attachments) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :file_name, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :path, :string, null: false
      add :uploaded_by_id, references(:users, on_delete: :nothing), null: false
      add :removed_at, :utc_datetime
      add :removed_by_id, references(:users, on_delete: :nothing)
      timestamps(type: :utc_datetime)
    end

    create index(:note_attachments, [:note_id])

    create table(:record_links) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :from_type, :string, null: false
      add :from_id, :binary_id, null: false
      add :to_type, :string, null: false
      add :to_id, :binary_id, null: false
      add :created_by_id, references(:users, on_delete: :nothing), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:record_links, [:company_id, :from_type, :from_id, :to_type, :to_id])
    create index(:record_links, [:company_id, :to_type, :to_id])

    create constraint(:record_links, :record_links_not_self,
             check: "NOT (from_type = to_type AND from_id = to_id)"
           )
  end
end
```

- [ ] **Step 4: Write the schemas**

`lib/full_circle/notes/note.ex`:

```elixir
defmodule FullCircle.Notes.Note do
  @moduledoc """
  A note in the company memory.

  `subject_type`/`subject_id` point at the record the note is *about* (a
  `FullCircle.Linkable` type) or are both nil for a free-standing note.
  `visibility` is nil for public, else the roles allowed to read it; admin and
  the author always read. Every edit leaves a `NoteVersion` of what it replaced.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.Notes.NoteAttachment
  alias FullCircle.UserAccounts.User

  schema "notes" do
    field :title, :string
    field :body, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :visibility, {:array, :string}
    field :lock_version, :integer, default: 0
    field :deleted_at, :utc_datetime

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :author, User
    belongs_to :updated_by, User
    belongs_to :deleted_by, User

    has_many :attachments, NoteAttachment, where: [removed_at: nil], preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @castable ~w(title body subject_type subject_id visibility)a

  def visibility_roles, do: FullCircle.Authorization.roles() -- ["disable"]

  def changeset(note, attrs) do
    note
    |> cast(attrs, @castable)
    |> update_change(:title, &blank_to_nil/1)
    |> validate_required([:body])
    |> validate_length(:title, max: 120)
    |> validate_subject_pair()
    |> validate_visibility()
    |> check_constraint(:subject_id, name: :notes_subject_pair)
    |> check_constraint(:visibility, name: :notes_visibility_not_empty)
  end

  def display_title(%__MODULE__{title: t}) when is_binary(t) and t != "", do: t

  def display_title(%__MODULE__{body: body}) do
    (body || "") |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 120)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp validate_subject_pair(cs) do
    type = get_field(cs, :subject_type)
    id = get_field(cs, :subject_id)

    if is_nil(type) == is_nil(id),
      do: cs,
      else: add_error(cs, :subject_id, "must be set together with subject type")
  end

  defp validate_visibility(cs) do
    case get_field(cs, :visibility) do
      nil -> cs
      [] -> add_error(cs, :visibility, "use nil for public")
      _roles -> validate_subset(cs, :visibility, visibility_roles(), message: "has an invalid entry")
    end
  end
end
```

`lib/full_circle/notes/note_version.ex`:

```elixir
defmodule FullCircle.Notes.NoteVersion do
  @moduledoc """
  What a note said *before* an edit or delete superseded it.

  `written_by`/`written_at` are who wrote that version and when; `edited_by`
  and `inserted_at` are who replaced it and when.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  alias FullCircle.UserAccounts.User

  schema "note_versions" do
    field :version, :integer
    field :title, :string
    field :body, :string
    field :subject_type, :string
    field :subject_id, :binary_id
    field :visibility, {:array, :string}
    field :written_at, :utc_datetime

    belongs_to :note, FullCircle.Notes.Note
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :written_by, User
    belongs_to :edited_by, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def snapshot(note, version_no, editor) do
    change(%__MODULE__{}, %{
      note_id: note.id,
      company_id: note.company_id,
      version: version_no,
      title: note.title,
      body: note.body,
      subject_type: note.subject_type,
      subject_id: note.subject_id,
      visibility: note.visibility,
      written_by_id: note.updated_by_id,
      written_at: note.updated_at,
      edited_by_id: editor.id
    })
    |> unique_constraint([:note_id, :version])
  end
end
```

`lib/full_circle/notes/note_attachment.ex`:

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
    belongs_to :note, FullCircle.Notes.Note
    belongs_to :uploaded_by, FullCircle.UserAccounts.User
    belongs_to :removed_by, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(att, attrs) do
    att
    |> cast(attrs, ~w(file_name content_type byte_size path company_id note_id uploaded_by_id)a)
    |> validate_required(~w(file_name content_type byte_size path company_id note_id uploaded_by_id)a)
    |> foreign_key_constraint(:note_id)
  end
end
```

`lib/full_circle/linkable/record_link.ex`:

```elixir
defmodule FullCircle.Linkable.RecordLink do
  @moduledoc """
  A link between two records, stored once and queried from either side.
  The ids carry no foreign keys; `FullCircle.Linkable` validates both ends.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  schema "record_links" do
    field :from_type, :string
    field :from_id, :binary_id
    field :to_type, :string
    field :to_id, :binary_id

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :created_by, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields ~w(company_id from_type from_id to_type to_id created_by_id)a

  def changeset(link, attrs) do
    link
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:to_id,
      name: :record_links_company_id_from_type_from_id_to_type_to_id_index,
      message: "already linked"
    )
    |> check_constraint(:to_id, name: :record_links_not_self, message: "cannot link to itself")
  end
end
```

- [ ] **Step 5: Write the fixtures module (role helper + files)**

`test/support/fixtures/notes_fixtures.ex`:

```elixir
defmodule FullCircle.NotesFixtures do
  @moduledoc false

  def user_with_role(company, admin, role) do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, user, role, admin)
    user
  end

  # Real magic bytes; the rest is padding. Written fresh per call so a test
  # that moves or deletes one never breaks another.
  def jpeg_file, do: tmp_file(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, 64))
  def pdf_file, do: tmp_file(".pdf", "%PDF-1.4\n" <> :binary.copy("x", 64))
  def text_file, do: tmp_file(".jpg", "this is not an image at all")

  def big_file(bytes), do: tmp_file(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, bytes))

  defp tmp_file(ext, content) do
    path = Path.join(System.tmp_dir!(), "notes_fixture_#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, content)
    path
  end
end
```

- [ ] **Step 6: Migrate and run the tests**

Run: `mix ecto.migrate && mix test test/full_circle/notes_test.exs`
Expected: all pass (4 authorization + 5 changeset).

- [ ] **Step 7: Commit**

```bash
mix format priv/repo/migrations/20260929091000_create_notes.exs lib/full_circle/notes/*.ex lib/full_circle/linkable/record_link.ex test/support/fixtures/notes_fixtures.ex test/full_circle/notes_test.exs
git add priv/repo/migrations/20260929091000_create_notes.exs lib/full_circle/notes lib/full_circle/linkable test/support/fixtures/notes_fixtures.ex test/full_circle/notes_test.exs
git commit -m "feat(notes): notes, versions, attachments and record_links tables

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Linkable registry

**Files:**
- Create: `lib/full_circle/linkable.ex`, `test/full_circle/linkable_test.exs`

**Interfaces:**
- Consumes: `CommandPalette.Types.type_specs/0` (`{doc_type, update_action, label, route}`), `CommandPalette.Types.escape_like/1`, `Sys.user_company/2`, `Authorization.can?/3`.
- Produces:
  - `Linkable.types() :: [String.t()]` — `~w(Employee Contact Good Note Invoice PurInvoice Receipt Payment CreditNote DebitNote Journal Deposit ReturnCheque)`
  - `Linkable.type?(String.t()) :: boolean`
  - `Linkable.can_view_type?(type, company, user) :: boolean`
  - `Linkable.resolve(type, id, company, user) :: {:ok, target} | {:error, :not_found | :restricted}` where `target :: %{type: String.t(), id: String.t(), title: String.t(), subtitle: String.t() | nil, url: String.t()}`
  - `Linkable.resolve_many([{type, id}], company, user) :: %{{type, id} => {:ok, target} | {:error, :not_found | :restricted}}`
  - `Linkable.search(type, terms, company, user) :: [target]` (max 20)
  - `Linkable.url(type, id, company) :: String.t()`
  - The `"Note"` type is resolved through a function registered at runtime by `FullCircle.Notes` (Task 5 adds `Notes.resolve_notes/3`); until then `resolve("Note", …)` returns `{:error, :not_found}`.

- [ ] **Step 1: Write the failing tests**

`test/full_circle/linkable_test.exs`:

```elixir
defmodule FullCircle.LinkableTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Linkable

  setup do
    %{admin: admin, company: company} = billing_setup()
    contact = contact_fixture(company, admin, %{"name" => "Syarikat Ah Seng"})
    %{admin: admin, company: company, contact: contact}
  end

  test "types covers records, notes and the palette documents" do
    assert Linkable.types() ==
             ~w(Employee Contact Good Note Invoice PurInvoice Receipt Payment CreditNote DebitNote Journal Deposit ReturnCheque)

    assert Linkable.type?("Invoice")
    refute Linkable.type?("Transaction")
  end

  test "resolve a contact in the company", %{admin: admin, company: company, contact: c} do
    assert {:ok, %{type: "Contact", title: "Syarikat Ah Seng", url: url}} =
             Linkable.resolve("Contact", c.id, company, admin)

    assert url == "/companies/#{company.id}/contacts/#{c.id}/edit"
  end

  test "a contact from another company is not found", %{admin: admin, contact: c} do
    other = FullCircle.SysFixtures.company_fixture(admin, %{})
    assert {:error, :not_found} = Linkable.resolve("Contact", c.id, other, admin)
  end

  test "unknown type, malformed id and missing id are not found", %{admin: admin, company: company} do
    assert {:error, :not_found} = Linkable.resolve("Transaction", Ecto.UUID.generate(), company, admin)
    assert {:error, :not_found} = Linkable.resolve("Contact", "not-a-uuid", company, admin)
    assert {:error, :not_found} = Linkable.resolve("Contact", Ecto.UUID.generate(), company, admin)
  end

  test "resolve an invoice by its transactions", %{admin: admin, company: company} do
    inv = invoice_fixture(company, admin)

    assert {:ok, %{type: "Invoice", title: title, url: url}} =
             Linkable.resolve("Invoice", inv.id, company, admin)

    assert title == inv.invoice_no
    assert url == "/companies/#{company.id}/Invoice/#{inv.id}/edit"
  end

  test "a document the user may not view is restricted", %{admin: admin, company: company} do
    inv = invoice_fixture(company, admin)
    guest = user_with_role(company, admin, "guest")
    refute FullCircle.Authorization.can?(guest, :update_invoice, company)
    assert {:error, :restricted} = Linkable.resolve("Invoice", inv.id, company, guest)
  end

  test "resolve_many batches per type", %{admin: admin, company: company, contact: c} do
    missing = Ecto.UUID.generate()
    result = Linkable.resolve_many([{"Contact", c.id}, {"Contact", missing}], company, admin)
    assert {:ok, %{title: "Syarikat Ah Seng"}} = result[{"Contact", c.id}]
    assert {:error, :not_found} = result[{"Contact", missing}]
  end

  test "search contacts escapes LIKE metacharacters", %{admin: admin, company: company} do
    contact_fixture(company, admin, %{"name" => "100% Feed"})
    contact_fixture(company, admin, %{"name" => "1000 Feed"})
    assert [%{title: "100% Feed"}] = Linkable.search("Contact", "100%", company, admin)
  end

  test "search invoices by number", %{admin: admin, company: company} do
    inv = invoice_fixture(company, admin)
    assert Enum.any?(Linkable.search("Invoice", inv.invoice_no, company, admin), &(&1.id == inv.id))
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/linkable_test.exs`
Expected: FAIL — `FullCircle.Linkable` undefined.

- [ ] **Step 3: Implement**

`lib/full_circle/linkable.ex`:

```elixir
defmodule FullCircle.Linkable do
  @moduledoc """
  The registry of record types a note can be about or link to.

  References are `(type, id)` pairs with no foreign key; this module is the
  whitelist that keeps them honest. Every resolve is scoped to the company
  through `Sys.user_company/2`, so an id from another company is simply not
  found. Adding a type is one entry here plus its UI hooks (see the notes skill).
  """
  import Ecto.Query, warn: false

  alias FullCircle.{Repo, Sys}
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.Types, as: PaletteTypes

  @search_limit 20

  # kind :record — a table with company_id and a title column.
  @records [
    %{type: "Employee", schema: FullCircle.HR.Employee, title: :name, route: "employees"},
    %{type: "Contact", schema: FullCircle.Accounting.Contact, title: :name, route: "contacts"},
    %{type: "Good", schema: FullCircle.Product.Good, title: :name, route: "goods"}
  ]

  # kind :document — posted documents found through `transactions`, with the
  # palette's per-type update permission as the view gate.
  @documents Enum.map(PaletteTypes.type_specs(), fn {type, action, _label, route} ->
               %{type: type, action: action, route: route}
             end)

  def types do
    Enum.map(@records, & &1.type) ++ ["Note"] ++ Enum.map(@documents, & &1.type)
  end

  def type?(type), do: type in types()

  def url(type, id, company) do
    case spec(type) do
      {:record, %{route: route}} -> "/companies/#{company.id}/#{route}/#{id}/edit"
      {:document, %{route: route}} -> "/companies/#{company.id}/#{route}/#{id}/edit"
      :note -> "/companies/#{company.id}/notes/#{id}"
      nil -> "#"
    end
  end

  def can_view_type?(type, company, user) do
    case spec(type) do
      {:record, _} -> true
      :note -> FullCircle.Authorization.can?(user, :view_notes, company)
      {:document, %{action: action}} -> FullCircle.Authorization.can?(user, action, company)
      nil -> false
    end
  end

  def resolve(type, id, company, user) do
    resolve_many([{type, id}], company, user) |> Map.fetch!({type, id})
  end

  def resolve_many(refs, company, user) do
    refs
    |> Enum.uniq()
    |> Enum.group_by(fn {type, _} -> type end, fn {_, id} -> id end)
    |> Enum.flat_map(fn {type, ids} ->
      {valid, invalid} = Enum.split_with(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
      found = resolve_type(type, valid, company, user)

      Enum.map(invalid, &{{type, &1}, {:error, :not_found}}) ++
        Enum.map(valid, fn id -> {{type, id}, Map.get(found, id, {:error, :not_found})} end)
    end)
    |> Map.new()
  end

  def search(type, terms, company, user) do
    terms = String.trim(terms || "")

    cond do
      terms == "" -> []
      not can_view_type?(type, company, user) -> []
      true -> do_search(spec(type), type, terms, company, user)
    end
  end

  # --- internals ------------------------------------------------------------

  defp spec("Note"), do: :note

  defp spec(type) do
    case Enum.find(@records, &(&1.type == type)) do
      nil ->
        case Enum.find(@documents, &(&1.type == type)) do
          nil -> nil
          d -> {:document, d}
        end

      r ->
        {:record, r}
    end
  end

  defp resolve_type(type, ids, company, user) do
    cond do
      ids == [] -> %{}
      is_nil(spec(type)) -> %{}
      not can_view_type?(type, company, user) -> Map.new(ids, &{&1, {:error, :restricted}})
      true -> fetch(spec(type), type, ids, company, user)
    end
  end

  defp fetch({:record, %{schema: schema, title: title}}, type, ids, company, user) do
    from(r in schema,
      join: c in subquery(Sys.user_company(company, user)),
      on: c.id == r.company_id,
      where: r.id in ^ids,
      select: {r.id, field(r, ^title)}
    )
    |> Repo.all()
    |> Map.new(fn {id, t} -> {id, {:ok, target(type, id, t, nil, company)}} end)
  end

  defp fetch({:document, _}, type, ids, company, user) do
    doc_query(type, company, user)
    |> where([t], t.doc_id in ^ids)
    |> Repo.all()
    |> Map.new(fn row -> {row.doc_id, {:ok, doc_target(type, row, company)}} end)
  end

  defp fetch(:note, _type, ids, company, user) do
    FullCircle.Notes.resolve_notes(ids, company, user)
  end

  defp do_search({:record, %{schema: schema, title: title}}, type, terms, company, user) do
    pattern = "%#{PaletteTypes.escape_like(terms)}%"

    from(r in schema,
      join: c in subquery(Sys.user_company(company, user)),
      on: c.id == r.company_id,
      where: ilike(field(r, ^title), ^pattern),
      order_by: field(r, ^title),
      limit: @search_limit,
      select: {r.id, field(r, ^title)}
    )
    |> Repo.all()
    |> Enum.map(fn {id, t} -> target(type, id, t, nil, company) end)
  end

  defp do_search({:document, _}, type, terms, company, user) do
    pattern = "%#{PaletteTypes.escape_like(terms)}%"

    doc_query(type, company, user)
    |> where([t], ilike(t.doc_no, ^pattern))
    |> order_by([t], desc: max(t.doc_date))
    |> limit(@search_limit)
    |> Repo.all()
    |> Enum.map(&doc_target(type, &1, company))
  end

  defp do_search(:note, _type, terms, company, user) do
    FullCircle.Notes.search(company, user, terms, %{}, page: 1, per_page: @search_limit)
    |> Enum.map(fn n ->
      target("Note", n.id, FullCircle.Notes.Note.display_title(n), nil, company)
    end)
  end

  defp doc_query(type, company, user) do
    from(t in Transaction,
      join: c in subquery(Sys.user_company(company, user)),
      on: c.id == t.company_id,
      left_join: ct in Contact,
      on: ct.id == t.contact_id,
      where: t.doc_type == ^type and not is_nil(t.doc_id),
      group_by: [t.doc_id, t.doc_no],
      select: %{doc_id: t.doc_id, doc_no: t.doc_no, doc_date: max(t.doc_date), contact: max(ct.name)}
    )
  end

  defp doc_target(type, row, company) do
    subtitle = [row.contact, row.doc_date && Date.to_string(row.doc_date)] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
    target(type, row.doc_id, row.doc_no, subtitle, company)
  end

  defp target(type, id, title, subtitle, company) do
    %{type: type, id: id, title: title, subtitle: subtitle, url: url(type, id, company)}
  end
end
```

Temporary stub so this task compiles and passes on its own — add to the bottom of a **new** file `lib/full_circle/notes.ex` (Task 5 replaces its contents):

```elixir
defmodule FullCircle.Notes do
  @moduledoc false
  def resolve_notes(_ids, _company, _user), do: %{}
  def search(_company, _user, _terms, _filters, _opts), do: []
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/linkable_test.exs`
Expected: 9 tests, 0 failures. If "resolve an invoice" fails on `invoice_no`, check the field name on `FullCircle.Billing.Invoice` and that `transactions.doc_no` equals it for invoices (`grep -n "doc_no" lib/full_circle/billing.ex`).

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/linkable.ex lib/full_circle/notes.ex test/full_circle/linkable_test.exs
git add lib/full_circle/linkable.ex lib/full_circle/notes.ex test/full_circle/linkable_test.exs
git commit -m "feat(notes): Linkable registry of record types for subjects and links

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Notes core — visibility, create, read, edit with versions, delete

**Files:**
- Modify: `lib/full_circle/notes.ex` (replace the stub entirely), `test/support/fixtures/notes_fixtures.ex` (add `note_fixture/3`)
- Test: `test/full_circle/notes_test.exs`

**Interfaces:**
- Consumes: `Linkable.resolve/4`, `Note`, `NoteVersion`, `RecordLink`.
- Produces:
  - `Notes.visible_to(query \\ Note, company, user) :: Ecto.Query.t()` — company-scoped, not deleted, visibility applied; returns an empty query for users without `:view_notes`
  - `Notes.can_read?(note, company, user) :: boolean`
  - `Notes.can_edit?(note, company, user) :: boolean`, `Notes.can_delete?(note, company, user) :: boolean`
  - `Notes.get_note(id, company, user) :: Note.t() | nil` (preloads `author`, `updated_by`, `attachments`)
  - `Notes.change_note(note, attrs \\ %{}) :: Ecto.Changeset.t()` (normalizes visibility)
  - `Notes.create_note(attrs, company, user) :: {:ok, Note.t()} | {:error, Ecto.Changeset.t()} | {:error, {:link, :not_found}} | :not_authorise` — `attrs["links"]` optional list of `%{"type" => t, "id" => id}`
  - `Notes.update_note(note, attrs, company, user) :: {:ok, Note.t()} | {:error, :stale} | {:error, :not_found} | {:error, Ecto.Changeset.t()} | :not_authorise`
  - `Notes.delete_note(note, company, user) :: {:ok, Note.t()} | {:error, :not_found} | :not_authorise`
  - `Notes.list_versions(note, company, user) :: [NoteVersion.t()]` newest first, `edited_by` + `written_by` preloaded
  - `Notes.resolve_notes(ids, company, user) :: %{id => {:ok, target}}` (for Linkable)
  - Fixture: `NotesFixtures.note_fixture(company, user, attrs \\ %{}) :: Note.t()`

- [ ] **Step 1: Add the fixture**

Append inside `FullCircle.NotesFixtures`:

```elixir
  def note_fixture(company, user, attrs \\ %{}) do
    {:ok, note} =
      FullCircle.Notes.create_note(Map.merge(%{"body" => "a note"}, attrs), company, user)

    note
  end
```

- [ ] **Step 2: Write the failing tests**

Append to `test/full_circle/notes_test.exs` (add `import FullCircle.NotesFixtures` and `alias FullCircle.Notes` at the top of the module):

```elixir
  describe "visibility" do
    setup %{admin: admin, company: company} do
      %{
        manager: user_with_role(company, admin, "manager"),
        clerk: user_with_role(company, admin, "clerk"),
        clerk2: user_with_role(company, admin, "clerk"),
        auditor: user_with_role(company, admin, "auditor"),
        guest: user_with_role(company, admin, "guest")
      }
    end

    test "public note is read by every role with view_notes", ctx do
      note = note_fixture(ctx.company, ctx.clerk, %{"body" => "public"})

      for u <- [ctx.admin, ctx.manager, ctx.clerk2, ctx.auditor] do
        assert Notes.get_note(note.id, ctx.company, u)
      end

      refute Notes.get_note(note.id, ctx.company, ctx.guest)
    end

    test "restricted note: listed role, admin and author read; others do not", ctx do
      note = note_fixture(ctx.company, ctx.clerk, %{"body" => "secret", "visibility" => ["manager"]})

      assert Notes.get_note(note.id, ctx.company, ctx.manager)
      assert Notes.get_note(note.id, ctx.company, ctx.admin)
      assert Notes.get_note(note.id, ctx.company, ctx.clerk)
      refute Notes.get_note(note.id, ctx.company, ctx.clerk2)
      refute Notes.get_note(note.id, ctx.company, ctx.auditor)
    end

    test "another company never sees the note", ctx do
      note = note_fixture(ctx.company, ctx.admin)
      other = FullCircle.SysFixtures.company_fixture(ctx.admin, %{})
      refute Notes.get_note(note.id, other, ctx.admin)
    end

    test "a disabled user reads nothing, even their own note", ctx do
      note = note_fixture(ctx.company, ctx.clerk)
      {:ok, _} = FullCircle.Sys.change_user_role_in(ctx.company, ctx.clerk.id, "disable", ctx.admin)
      refute Notes.get_note(note.id, ctx.company, ctx.clerk)
    end
  end

  describe "create_note/3" do
    test "stores author, subject and normalizes visibility", %{admin: admin, company: company} do
      c = contact_fixture(company, admin)

      assert {:ok, note} =
               Notes.create_note(
                 %{
                   "body" => "pays late",
                   "subject_type" => "Contact",
                   "subject_id" => c.id,
                   "visibility" => ["", "manager", "manager"]
                 },
                 company,
                 admin
               )

      assert note.author_id == admin.id
      assert note.visibility == ["manager"]

      assert {:ok, public} =
               Notes.create_note(%{"body" => "x", "visibility" => [""]}, company, admin)

      assert public.visibility == nil
    end

    test "a subject from another company or an unknown type is rejected", %{admin: admin, company: company} do
      other = FullCircle.SysFixtures.company_fixture(admin, %{})
      foreign = contact_fixture(other, admin)

      assert {:error, cs} =
               Notes.create_note(
                 %{"body" => "x", "subject_type" => "Contact", "subject_id" => foreign.id},
                 company,
                 admin
               )

      assert %{subject_id: ["not found"]} = errors_on(cs)

      assert {:error, cs} =
               Notes.create_note(
                 %{"body" => "x", "subject_type" => "Nope", "subject_id" => Ecto.UUID.generate()},
                 company,
                 admin
               )

      assert %{subject_type: ["is invalid"]} = errors_on(cs)
    end

    test "creates links in the same transaction; a bad link rolls back", %{admin: admin, company: company} do
      c = contact_fixture(company, admin)

      assert {:ok, note} =
               Notes.create_note(
                 %{"body" => "x", "links" => [%{"type" => "Contact", "id" => c.id}]},
                 company,
                 admin
               )

      assert [%{type: "Contact", id: id}] = Notes.list_links(note, company, admin)
      assert id == c.id

      count = Repo.aggregate(FullCircle.Notes.Note, :count)

      assert {:error, {:link, :not_found}} =
               Notes.create_note(
                 %{"body" => "y", "links" => [%{"type" => "Contact", "id" => Ecto.UUID.generate()}]},
                 company,
                 admin
               )

      assert Repo.aggregate(FullCircle.Notes.Note, :count) == count
    end

    test "auditor and guest cannot create", %{admin: admin, company: company} do
      for role <- ~w(auditor guest) do
        u = user_with_role(company, admin, role)
        assert :not_authorise = Notes.create_note(%{"body" => "x"}, company, u)
      end
    end
  end

  describe "update_note/4" do
    test "an edit writes exactly one version of the old content", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "v1"})
      assert {:ok, note} = Notes.update_note(note, %{"body" => "v2"}, company, admin)
      assert note.body == "v2"
      assert [%{version: 1, body: "v1", edited_by_id: eid}] = Notes.list_versions(note, company, admin)
      assert eid == admin.id
    end

    test "a no-op edit writes no version", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "same"})
      assert {:ok, _} = Notes.update_note(note, %{"body" => "same"}, company, admin)
      assert [] = Notes.list_versions(note, company, admin)
    end

    test "a concurrent edit is stale and writes nothing", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "v1"})
      {:ok, _} = Notes.update_note(note, %{"body" => "theirs"}, company, admin)

      assert {:error, :stale} = Notes.update_note(note, %{"body" => "mine"}, company, admin)
      assert Notes.get_note(note.id, company, admin).body == "theirs"
      assert length(Notes.list_versions(note, company, admin)) == 1
    end

    test "author edits own; others need admin/manager AND read access", %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      clerk2 = user_with_role(company, admin, "clerk")
      manager = user_with_role(company, admin, "manager")

      mine = note_fixture(company, clerk, %{"body" => "a"})
      assert {:ok, mine} = Notes.update_note(mine, %{"body" => "b"}, company, clerk)
      assert :not_authorise = Notes.update_note(mine, %{"body" => "c"}, company, clerk2)
      assert {:ok, _} = Notes.update_note(mine, %{"body" => "d"}, company, manager)

      hidden = note_fixture(company, clerk, %{"body" => "a", "visibility" => ["supervisor"]})
      assert {:error, :not_found} = Notes.update_note(hidden, %{"body" => "z"}, company, manager)
    end
  end

  describe "delete_note/3" do
    test "soft-deletes, snapshots a version, hides everywhere", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "bye"})
      assert {:ok, _} = Notes.delete_note(note, company, admin)
      refute Notes.get_note(note.id, company, admin)
      assert %{deleted_at: %DateTime{}} = Repo.get!(FullCircle.Notes.Note, note.id)
      assert [%{body: "bye"}] = Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "clerk cannot delete another's note", %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      note = note_fixture(company, admin)
      assert :not_authorise = Notes.delete_note(note, company, clerk)
    end
  end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/full_circle/notes_test.exs`
Expected: FAIL — `Notes.create_note/3` undefined.

- [ ] **Step 4: Implement**

Replace `lib/full_circle/notes.ex` with:

```elixir
defmodule FullCircle.Notes do
  @moduledoc """
  Company memory: notes about any `FullCircle.Linkable` record, or none.

  Every read goes through `visible_to/3`. Edits snapshot the previous state into
  `note_versions`. See `.claude/skills/notes.md`.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{Linkable, Repo, Sys}
  alias FullCircle.Linkable.RecordLink
  alias FullCircle.Notes.{Note, NoteVersion}

  # --- visibility -----------------------------------------------------------

  def visible_to(query \\ Note, company, user) do
    if can?(user, :view_notes, company) do
      role = user_role_in_company(user.id, company.id)

      base =
        from(n in query,
          join: c in subquery(Sys.user_company(company, user)),
          on: c.id == n.company_id,
          where: is_nil(n.deleted_at)
        )

      if role == "admin" do
        base
      else
        from(n in base,
          where: is_nil(n.visibility) or ^role in n.visibility or n.author_id == ^user.id
        )
      end
    else
      from(n in query, where: false)
    end
  end

  def can_read?(%Note{id: id}, company, user) do
    Repo.exists?(from(n in visible_to(company, user), where: n.id == ^id))
  end

  def can_edit?(%Note{} = note, company, user) do
    can_read?(note, company, user) and
      ((note.author_id == user.id and can?(user, :create_note, company)) or
         can?(user, :edit_others_note, company))
  end

  def can_delete?(%Note{} = note, company, user) do
    can_read?(note, company, user) and
      ((note.author_id == user.id and can?(user, :create_note, company)) or
         can?(user, :delete_others_note, company))
  end

  # --- read -----------------------------------------------------------------

  def get_note(id, company, user) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        from(n in visible_to(company, user), where: n.id == ^id)
        |> Repo.one()
        |> Repo.preload([:author, :updated_by, :attachments])

      :error ->
        nil
    end
  end

  def resolve_notes(ids, company, user) do
    from(n in visible_to(company, user), where: n.id in ^ids)
    |> Repo.all()
    |> Map.new(fn n ->
      {n.id,
       {:ok,
        %{
          type: "Note",
          id: n.id,
          title: Note.display_title(n),
          subtitle: nil,
          url: Linkable.url("Note", n.id, company)
        }}}
    end)
  end

  def list_versions(%Note{} = note, company, user) do
    if can_read?(note, company, user) do
      from(v in NoteVersion, where: v.note_id == ^note.id, order_by: [desc: v.version])
      |> Repo.all()
      |> Repo.preload([:edited_by, :written_by])
    else
      []
    end
  end

  # --- write ----------------------------------------------------------------

  def change_note(%Note{} = note, attrs \\ %{}) do
    Note.changeset(note, normalize(attrs))
  end

  def create_note(attrs, company, user) do
    attrs = normalize(attrs)

    if can?(user, :create_note, company) do
      changeset =
        %Note{company_id: company.id, author_id: user.id, updated_by_id: user.id}
        |> Note.changeset(Map.delete(attrs, "links"))
        |> validate_subject(company, user)

      Multi.new()
      |> Multi.insert(:note, changeset)
      |> insert_links(Map.get(attrs, "links") || [], company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{note: note}} -> {:ok, Repo.preload(note, [:author, :updated_by, :attachments])}
        {:error, :note, cs, _} -> {:error, cs}
        {:error, _step, reason, _} -> {:error, reason}
      end
    else
      :not_authorise
    end
  end

  @doc """
  Edits a note. `note` must be the struct the editor loaded — its
  `lock_version` is what detects a concurrent save.
  """
  def update_note(%Note{} = note, attrs, company, user) do
    attrs = attrs |> normalize() |> Map.delete("links")

    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- can_edit?(current, company, user) || :not_authorise do
      changeset = note |> Note.changeset(attrs) |> validate_subject(company, user)

      if changeset.changes == %{} do
        {:ok, current}
      else
        changeset =
          changeset
          |> Ecto.Changeset.put_change(:updated_by_id, user.id)
          |> Ecto.Changeset.optimistic_lock(:lock_version)

        Multi.new()
        |> snapshot(current, user)
        |> Multi.update(:note, changeset)
        |> Repo.transaction()
        |> case do
          {:ok, %{note: n}} -> {:ok, Repo.preload(n, [:author, :updated_by, :attachments], force: true)}
          {:error, :note, cs, _} -> {:error, cs}
          {:error, _, reason, _} -> {:error, reason}
        end
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale}
  end

  def delete_note(%Note{} = note, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- can_delete?(current, company, user) || :not_authorise do
      Multi.new()
      |> snapshot(current, user)
      |> Multi.update(
        :note,
        Ecto.Changeset.change(current,
          deleted_at: DateTime.utc_now(:second),
          deleted_by_id: user.id
        )
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{note: n}} -> {:ok, n}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  defp snapshot(multi, current, user) do
    multi
    |> Multi.run(:version_no, fn repo, _ ->
      max = repo.one(from(v in NoteVersion, where: v.note_id == ^current.id, select: max(v.version)))
      {:ok, (max || 0) + 1}
    end)
    |> Multi.insert(:version, fn %{version_no: n} -> NoteVersion.snapshot(current, n, user) end)
  end

  defp insert_links(multi, links, company, user) do
    links
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {link, i}, m ->
      Multi.run(m, {:link, i}, fn repo, %{note: note} ->
        type = link["type"] || link[:type]
        id = link["id"] || link[:id]

        case Linkable.resolve(type, id, company, user) do
          {:ok, _} ->
            %RecordLink{}
            |> RecordLink.changeset(%{
              company_id: company.id,
              from_type: "Note",
              from_id: note.id,
              to_type: type,
              to_id: id,
              created_by_id: user.id
            })
            |> repo.insert()

          {:error, _} ->
            {:error, {:link, :not_found}}
        end
      end)
    end)
  end

  defp validate_subject(changeset, company, user) do
    type = Ecto.Changeset.get_field(changeset, :subject_type)
    id = Ecto.Changeset.get_field(changeset, :subject_id)

    cond do
      is_nil(type) or is_nil(id) ->
        changeset

      not Linkable.type?(type) ->
        Ecto.Changeset.add_error(changeset, :subject_type, "is invalid")

      match?({:ok, _}, Linkable.resolve(type, id, company, user)) ->
        changeset

      true ->
        Ecto.Changeset.add_error(changeset, :subject_id, "not found")
    end
  end

  # Form checkboxes send a hidden "" so an all-unticked group still submits;
  # "no roles ticked" means public, which is nil.
  defp normalize(attrs) do
    attrs = FullCircle.Helpers.key_to_string(attrs)

    case Map.fetch(attrs, "visibility") do
      {:ok, list} when is_list(list) ->
        roles = list |> Enum.reject(&(&1 in ["", nil])) |> Enum.uniq()
        Map.put(attrs, "visibility", if(roles == [], do: nil, else: roles))

      {:ok, v} when v in ["", nil] ->
        Map.put(attrs, "visibility", nil)

      _ ->
        attrs
    end
  end
end
```

`list_links/3` is used by a test here but belongs to Task 6; add this minimal version now at the end of the module so the create test passes (Task 6 keeps it):

```elixir
  def list_links(%Note{} = note, company, user) do
    rows =
      from(l in RecordLink,
        where: l.company_id == ^company.id and l.from_type == "Note" and l.from_id == ^note.id,
        order_by: [asc: l.inserted_at]
      )
      |> Repo.all()

    resolved = Linkable.resolve_many(Enum.map(rows, &{&1.to_type, &1.to_id}), company, user)

    Enum.map(rows, fn l ->
      %{link_id: l.id, type: l.to_type, id: l.to_id, target: resolved[{l.to_type, l.to_id}]}
    end)
  end
```

Note: `FullCircle.Helpers.key_to_string/1` must turn atom keys into strings without touching values. If it recurses into nested maps/lists and breaks the `links` list, replace the first line of `normalize/1` with `attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)`.

`user_role_in_company/2` is public in `FullCircle.Authorization` and comes in through `import FullCircle.Authorization`.

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/full_circle/notes_test.exs test/full_circle/linkable_test.exs`
Expected: all pass. If the disabled-user test errors on `change_user_role_in/4`'s return shape, check `lib/full_circle/sys.ex:725` and match what it returns.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/notes.ex test/full_circle/notes_test.exs test/support/fixtures/notes_fixtures.ex
git add lib/full_circle/notes.ex test/full_circle/notes_test.exs test/support/fixtures/notes_fixtures.ex
git commit -m "feat(notes): visibility, create with links, versioned edit, soft delete

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Links, backlinks, record panel query, index counts

**Files:**
- Modify: `lib/full_circle/notes.ex`
- Test: `test/full_circle/notes_test.exs`

**Interfaces:**
- Produces:
  - `Notes.add_link(note, type, id, company, user) :: {:ok, RecordLink.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()} | :not_authorise`
  - `Notes.remove_link(note, link_id, company, user) :: {:ok, RecordLink.t()} | {:error, :not_found} | :not_authorise`
  - `Notes.list_links/3` (from Task 5)
  - `Notes.list_backlinks(note, company, user) :: [Note.t()]`
  - `Notes.notes_for_record(type, id, company, user) :: [%{note: Note.t(), relation: :about | :linked}]` newest first, `author` + `attachments` preloaded
  - `Notes.count_by_records(company, user, type, ids) :: %{id => non_neg_integer}` (ids absent from the map have 0)

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/notes_test.exs`:

```elixir
  describe "links and record queries" do
    setup %{admin: admin, company: company} do
      c = contact_fixture(company, admin)
      clerk = user_with_role(company, admin, "clerk")
      %{contact: c, clerk: clerk}
    end

    test "add/remove link; duplicate and self links rejected", %{admin: admin, company: company, contact: c} do
      note = note_fixture(company, admin)
      assert {:ok, link} = Notes.add_link(note, "Contact", c.id, company, admin)
      assert {:error, cs} = Notes.add_link(note, "Contact", c.id, company, admin)
      assert %{to_id: ["already linked"]} = errors_on(cs)
      assert {:error, cs} = Notes.add_link(note, "Note", note.id, company, admin)
      assert %{to_id: ["cannot link to itself"]} = errors_on(cs)
      assert {:error, :not_found} = Notes.add_link(note, "Contact", Ecto.UUID.generate(), company, admin)
      assert {:ok, _} = Notes.remove_link(note, link.id, company, admin)
      assert [] = Notes.list_links(note, company, admin)
    end

    test "a linked record deleted later resolves to not_found, not a crash", %{admin: admin, company: company} do
      other = note_fixture(company, admin, %{"body" => "target"})
      note = note_fixture(company, admin)
      {:ok, _} = Notes.add_link(note, "Note", other.id, company, admin)
      {:ok, _} = Notes.delete_note(other, company, admin)
      assert [%{target: {:error, :not_found}}] = Notes.list_links(note, company, admin)
    end

    test "backlinks show only visible notes", %{admin: admin, company: company, clerk: clerk} do
      target = note_fixture(company, admin, %{"body" => "target"})
      open = note_fixture(company, admin, %{"body" => "open"})
      hidden = note_fixture(company, admin, %{"body" => "hidden", "visibility" => ["manager"]})
      {:ok, _} = Notes.add_link(open, "Note", target.id, company, admin)
      {:ok, _} = Notes.add_link(hidden, "Note", target.id, company, admin)

      assert [%{body: "open"}] = Notes.list_backlinks(target, company, clerk)
      assert length(Notes.list_backlinks(target, company, admin)) == 2
    end

    test "notes_for_record: about + linked, no duplicates, visibility applied",
         %{admin: admin, company: company, contact: c, clerk: clerk} do
      about = note_fixture(company, admin, %{"body" => "about", "subject_type" => "Contact", "subject_id" => c.id})
      {:ok, _} = Notes.add_link(about, "Contact", c.id, company, admin)
      linked = note_fixture(company, admin, %{"body" => "linked"})
      {:ok, _} = Notes.add_link(linked, "Contact", c.id, company, admin)

      _hidden =
        note_fixture(company, admin, %{
          "body" => "hidden",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "visibility" => ["manager"]
        })

      rows = Notes.notes_for_record("Contact", c.id, company, clerk)
      assert Enum.map(rows, &{&1.note.body, &1.relation}) |> Enum.sort() ==
               [{"about", :about}, {"linked", :linked}]
    end

    test "count_by_records respects visibility and counts each note once",
         %{admin: admin, company: company, contact: c, clerk: clerk} do
      c2 = contact_fixture(company, admin)
      a = note_fixture(company, admin, %{"subject_type" => "Contact", "subject_id" => c.id})
      {:ok, _} = Notes.add_link(a, "Contact", c.id, company, admin)
      b = note_fixture(company, admin)
      {:ok, _} = Notes.add_link(b, "Contact", c.id, company, admin)
      note_fixture(company, admin, %{"subject_type" => "Contact", "subject_id" => c.id, "visibility" => ["manager"]})

      assert Notes.count_by_records(company, clerk, "Contact", [c.id, c2.id]) == %{c.id => 2}
      assert Notes.count_by_records(company, admin, "Contact", [c.id, c2.id]) == %{c.id => 3}
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/notes_test.exs`
Expected: FAIL — `Notes.add_link/5` undefined.

- [ ] **Step 3: Implement**

Add to `lib/full_circle/notes.ex` (after `list_links/3`):

```elixir
  def add_link(%Note{} = note, type, id, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- can_edit?(current, company, user) || :not_authorise,
         {:ok, _} <- resolve_link_target(type, id, current, company, user) do
      %RecordLink{}
      |> RecordLink.changeset(%{
        company_id: company.id,
        from_type: "Note",
        from_id: current.id,
        to_type: type,
        to_id: id,
        created_by_id: user.id
      })
      |> Repo.insert()
    end
  end

  # A self-link is refused by a check constraint; let it reach the database so
  # the error lands on the changeset instead of masquerading as "not found".
  defp resolve_link_target("Note", id, %Note{id: id} = note, company, _user),
    do: {:ok, %{type: "Note", id: id, url: Linkable.url("Note", id, company), title: note.body}}

  defp resolve_link_target(type, id, _note, company, user) do
    case Linkable.resolve(type, id, company, user) do
      {:ok, t} -> {:ok, t}
      {:error, _} -> {:error, :not_found}
    end
  end

  def remove_link(%Note{} = note, link_id, company, user) do
    with %Note{} = current <- get_note(note.id, company, user) || {:error, :not_found},
         true <- can_edit?(current, company, user) || :not_authorise,
         %RecordLink{} = link <-
           Repo.one(
             from(l in RecordLink,
               where:
                 l.id == ^link_id and l.company_id == ^company.id and l.from_type == "Note" and
                   l.from_id == ^current.id
             )
           ) || {:error, :not_found} do
      Repo.delete(link)
    end
  end

  def list_backlinks(%Note{} = note, company, user) do
    from(n in visible_to(company, user),
      join: l in RecordLink,
      on: l.from_type == "Note" and l.from_id == n.id,
      where: l.company_id == ^company.id and l.to_type == "Note" and l.to_id == ^note.id,
      order_by: [desc: n.inserted_at]
    )
    |> Repo.all()
  end

  def notes_for_record(type, id, company, user) do
    about =
      from(n in visible_to(company, user),
        where: n.subject_type == ^type and n.subject_id == ^id
      )
      |> Repo.all()

    about_ids = MapSet.new(about, & &1.id)

    linked =
      from(n in visible_to(company, user),
        join: l in RecordLink,
        on: l.from_type == "Note" and l.from_id == n.id,
        where: l.company_id == ^company.id and l.to_type == ^type and l.to_id == ^id
      )
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(about_ids, &1.id))

    (Enum.map(about, &%{note: &1, relation: :about}) ++
       Enum.map(linked, &%{note: &1, relation: :linked}))
    |> Enum.sort_by(& &1.note.inserted_at, {:desc, DateTime})
    |> then(fn rows ->
      notes = Repo.preload(Enum.map(rows, & &1.note), [:author, :attachments])
      Enum.zip_with(rows, notes, fn row, n -> %{row | note: n} end)
    end)
  end

  @doc """
  Visible notes per record for an index page: notes about the record plus
  notes linking to it, each note counted once. Two queries per call, whatever
  the number of ids.
  """
  def count_by_records(_company, _user, _type, []), do: %{}

  def count_by_records(company, user, type, ids) do
    pairs =
      from(n in visible_to(company, user),
        where: n.subject_type == ^type and n.subject_id in ^ids,
        select: {n.subject_id, n.id}
      )
      |> Repo.all()

    linked =
      from(n in visible_to(company, user),
        join: l in RecordLink,
        on: l.from_type == "Note" and l.from_id == n.id,
        where: l.company_id == ^company.id and l.to_type == ^type and l.to_id in ^ids,
        select: {l.to_id, n.id}
      )
      |> Repo.all()

    (pairs ++ linked)
    |> Enum.uniq()
    |> Enum.frequencies_by(fn {record_id, _} -> record_id end)
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/notes_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/notes.ex test/full_circle/notes_test.exs
git add lib/full_circle/notes.ex test/full_circle/notes_test.exs
git commit -m "feat(notes): links, backlinks, notes for a record, per-record counts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Search and version diff

**Files:**
- Modify: `lib/full_circle/notes.ex`
- Test: `test/full_circle/notes_test.exs`

**Interfaces:**
- Produces:
  - `Notes.search(company, user, terms, filters, page: pos_integer, per_page: pos_integer) :: [Note.t()]` — `filters` map with optional string keys `"subject_type"`, `"subject_id"`, `"mine"` (`"true"`), `"from"`, `"to"` (ISO dates, inclusive, company timezone ignored — dates compare on `inserted_at::date` UTC). `author` preloaded.
  - `Notes.version_changes(versions, note) :: [%{version: NoteVersion.t(), changes: [{atom, old, new}]}]` — for each version (newest first), the fields that differ from the state that replaced it.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "search/5" do
    setup %{admin: admin, company: company} do
      clerk = user_with_role(company, admin, "clerk")
      note_fixture(company, admin, %{"title" => "Welding", "body" => "Ali can weld aluminium"})
      note_fixture(company, admin, %{"body" => "Ah Seng pays 100% late"})
      note_fixture(company, admin, %{"body" => "焊工 很好"})
      note_fixture(company, admin, %{"body" => "secret weld", "visibility" => ["manager"]})
      %{clerk: clerk}
    end

    defp bodies(list), do: list |> Enum.map(& &1.body) |> Enum.sort()

    test "every word must match title or body, visibility applied", %{company: company, clerk: clerk} do
      assert bodies(Notes.search(company, clerk, "weld", %{}, page: 1, per_page: 30)) ==
               ["Ali can weld aluminium"]
    end

    test "admin sees the restricted match too", %{company: company, admin: admin} do
      assert length(Notes.search(company, admin, "weld", %{}, page: 1, per_page: 30)) == 2
    end

    test "LIKE metacharacters are literal", %{company: company, clerk: clerk} do
      assert bodies(Notes.search(company, clerk, "100%", %{}, page: 1, per_page: 30)) ==
               ["Ah Seng pays 100% late"]
    end

    test "Chinese text is found", %{company: company, clerk: clerk} do
      assert bodies(Notes.search(company, clerk, "焊工", %{}, page: 1, per_page: 30)) == ["焊工 很好"]
    end

    test "empty terms list newest first and paginate", %{company: company, admin: admin} do
      assert length(Notes.search(company, admin, "", %{}, page: 1, per_page: 3)) == 3
      assert length(Notes.search(company, admin, "", %{}, page: 2, per_page: 3)) == 1
    end

    test "mine and subject filters", %{company: company, admin: admin, clerk: clerk} do
      c = contact_fixture(company, admin)
      note_fixture(company, clerk, %{"body" => "clerk's", "subject_type" => "Contact", "subject_id" => c.id})

      assert bodies(Notes.search(company, clerk, "", %{"mine" => "true"}, page: 1, per_page: 30)) == ["clerk's"]

      assert bodies(
               Notes.search(company, admin, "", %{"subject_type" => "Contact", "subject_id" => c.id},
                 page: 1,
                 per_page: 30
               )
             ) == ["clerk's"]
    end
  end

  describe "version_changes/2" do
    test "lists changed fields per version", %{admin: admin, company: company} do
      note = note_fixture(company, admin, %{"body" => "v1"})
      {:ok, note} = Notes.update_note(note, %{"body" => "v2"}, company, admin)
      {:ok, note} = Notes.update_note(note, %{"title" => "T"}, company, admin)
      versions = Notes.list_versions(note, company, admin)

      assert [
               %{version: %{version: 2}, changes: [{:title, nil, "T"}]},
               %{version: %{version: 1}, changes: [{:body, "v1", "v2"}]}
             ] = Notes.version_changes(versions, note)
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/notes_test.exs`
Expected: FAIL — `Notes.search/5` undefined.

- [ ] **Step 3: Implement**

Add to `lib/full_circle/notes.ex`:

```elixir
  alias FullCircle.CommandPalette.Types, as: PaletteTypes

  def search(company, user, terms, filters, page: page, per_page: per_page) do
    words = terms |> to_string() |> String.split(~r/\s+/, trim: true)

    visible_to(company, user)
    |> apply_words(words)
    |> apply_filters(filters || %{}, user)
    |> order_search(words, terms)
    |> offset(^((page - 1) * per_page))
    |> limit(^per_page)
    |> Repo.all()
    |> Repo.preload(:author)
  end

  # ILIKE decides what matches; word_similarity only orders. CJK text scores
  # near zero on trigrams, so similarity must never be the filter.
  defp apply_words(query, words) do
    Enum.reduce(words, query, fn w, q ->
      pattern = "%#{PaletteTypes.escape_like(w)}%"
      from(n in q, where: ilike(n.body, ^pattern) or ilike(coalesce(n.title, ""), ^pattern))
    end)
  end

  defp apply_filters(query, filters, user) do
    Enum.reduce(filters, query, fn
      {"subject_type", t}, q when t not in [nil, ""] -> from(n in q, where: n.subject_type == ^t)
      {"subject_id", id}, q when id not in [nil, ""] -> from(n in q, where: n.subject_id == ^id)
      {"mine", "true"}, q -> from(n in q, where: n.author_id == ^user.id)
      {"from", d}, q -> date_filter(q, d, :from)
      {"to", d}, q -> date_filter(q, d, :to)
      _, q -> q
    end)
  end

  # A hand-edited URL can carry anything; a bad date drops the filter.
  defp date_filter(q, d, dir) do
    case Date.from_iso8601(to_string(d)) do
      {:ok, date} when dir == :from -> from(n in q, where: fragment("?::date", n.inserted_at) >= ^date)
      {:ok, date} -> from(n in q, where: fragment("?::date", n.inserted_at) <= ^date)
      _ -> q
    end
  end

  defp order_search(query, [], _terms), do: from(n in query, order_by: [desc: n.inserted_at, desc: n.id])

  defp order_search(query, _words, terms) do
    from(n in query,
      order_by: [
        desc:
          fragment(
            "word_similarity(?, coalesce(?, '') || ' ' || ?)",
            ^terms,
            n.title,
            n.body
          ),
        desc: n.inserted_at
      ]
    )
  end

  @versioned ~w(title body subject_type subject_id visibility)a

  def version_changes(versions, %Note{} = note) do
    newer_states = [note | versions] |> Enum.take(length(versions))

    Enum.zip_with(versions, newer_states, fn v, newer ->
      changes =
        for f <- @versioned, Map.get(v, f) != Map.get(newer, f), do: {f, Map.get(v, f), Map.get(newer, f)}

      %{version: v, changes: changes}
    end)
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/notes_test.exs test/full_circle/linkable_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/notes.ex test/full_circle/notes_test.exs
git add lib/full_circle/notes.ex test/full_circle/notes_test.exs
git commit -m "feat(notes): search with filters, CJK-safe matching, version diffs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Attachments context

**Files:**
- Create: `lib/full_circle/notes/attachments.ex`, `test/full_circle/notes_attachments_test.exs`

**Interfaces:**
- Consumes: `Notes.get_note/3`, `Notes.can_edit?/3`.
- Produces:
  - `Attachments.content_types() :: [String.t()]`, `Attachments.max_bytes() :: 10_000_000`
  - `Attachments.attach(note, %{path: String.t(), file_name: String.t()}, company, user) :: {:ok, NoteAttachment.t()} | {:error, :too_large | :unsupported_type | :not_found | :copy_failed} | {:error, Ecto.Changeset.t()} | :not_authorise`
  - `Attachments.remove(attachment, company, user) :: {:ok, NoteAttachment.t()} | {:error, :not_found} | :not_authorise`
  - `Attachments.get_readable(id, company, user) :: NoteAttachment.t() | nil` (live or removed — history stays true; only note visibility gates it)
  - `Attachments.abs_path(attachment) :: String.t()`

- [ ] **Step 1: Write the failing tests**

`test/full_circle/notes_attachments_test.exs`:

```elixir
defmodule FullCircle.NotesAttachmentsTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes
  alias FullCircle.Notes.{Attachments, NoteAttachment}

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company, note: note_fixture(company, admin)}
  end

  test "stores a JPEG under the company/notes/note path with a sniffed type", ctx do
    assert {:ok, att} =
             Attachments.attach(ctx.note, %{path: jpeg_file(), file_name: "photo.png"}, ctx.company, ctx.admin)

    assert att.content_type == "image/jpeg"
    assert att.file_name == "photo.png"
    assert String.starts_with?(att.path, "#{ctx.company.id}/notes/#{ctx.note.id}/")
    assert String.ends_with?(att.path, ".jpg")
    assert File.exists?(Attachments.abs_path(att))
  end

  test "PDF is accepted", ctx do
    assert {:ok, %{content_type: "application/pdf"}} =
             Attachments.attach(ctx.note, %{path: pdf_file(), file_name: "cert.pdf"}, ctx.company, ctx.admin)
  end

  test "a non-image named .jpg is refused and nothing is written", ctx do
    dir = Path.join([Application.get_env(:full_circle, :uploads_dir), ctx.company.id, "notes", ctx.note.id])

    assert {:error, :unsupported_type} =
             Attachments.attach(ctx.note, %{path: text_file(), file_name: "x.jpg"}, ctx.company, ctx.admin)

    refute File.exists?(dir) and File.ls!(dir) != []
    assert Repo.aggregate(NoteAttachment, :count) == 0
  end

  test "oversize is refused before reading", ctx do
    assert {:error, :too_large} =
             Attachments.attach(
               ctx.note,
               %{path: big_file(Attachments.max_bytes()), file_name: "big.jpg"},
               ctx.company,
               ctx.admin
             )
  end

  test "only someone who can edit the note may attach", ctx do
    clerk = user_with_role(ctx.company, ctx.admin, "clerk")

    assert :not_authorise =
             Attachments.attach(ctx.note, %{path: jpeg_file(), file_name: "a.jpg"}, ctx.company, clerk)
  end

  test "remove hides it from the note but keeps the file and readable row", ctx do
    {:ok, att} = Attachments.attach(ctx.note, %{path: jpeg_file(), file_name: "a.jpg"}, ctx.company, ctx.admin)
    assert {:ok, removed} = Attachments.remove(att, ctx.company, ctx.admin)
    assert removed.removed_at
    assert [] = Notes.get_note(ctx.note.id, ctx.company, ctx.admin).attachments
    assert File.exists?(Attachments.abs_path(att))
    assert Attachments.get_readable(att.id, ctx.company, ctx.admin)
  end

  test "get_readable follows note visibility", ctx do
    hidden = note_fixture(ctx.company, ctx.admin, %{"visibility" => ["manager"]})
    {:ok, att} = Attachments.attach(hidden, %{path: jpeg_file(), file_name: "a.jpg"}, ctx.company, ctx.admin)
    clerk = user_with_role(ctx.company, ctx.admin, "clerk")
    refute Attachments.get_readable(att.id, ctx.company, clerk)
    refute Attachments.get_readable("not-a-uuid", ctx.company, ctx.admin)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/notes_attachments_test.exs`
Expected: FAIL — `FullCircle.Notes.Attachments` undefined.

- [ ] **Step 3: Implement**

`lib/full_circle/notes/attachments.ex`:

```elixir
defmodule FullCircle.Notes.Attachments do
  @moduledoc """
  Files on a note. Type is sniffed from magic bytes — the client's claim never
  reaches the column, because it decides how the file is served back. Size is
  checked with `File.stat/1` before any read. Removing hides a file from the
  note but keeps it on disk: older versions of the note may refer to it.
  """
  import Ecto.Query, warn: false
  require Logger

  alias FullCircle.{Notes, Repo}
  alias FullCircle.Notes.{Note, NoteAttachment}

  @max_bytes 10_000_000
  @content_types ~w(image/jpeg image/png image/webp application/pdf)

  def max_bytes, do: @max_bytes
  def content_types, do: @content_types

  def abs_path(%NoteAttachment{path: rel}), do: Path.join(uploads_dir(), rel)

  def attach(%Note{} = note, upload, company, user) do
    src = upload[:path] || upload["path"]
    file_name = upload[:file_name] || upload["file_name"] || "file"

    with %Note{} = note <- Notes.get_note(note.id, company, user) || {:error, :not_found},
         true <- Notes.can_edit?(note, company, user) || :not_authorise,
         {:ok, size} <- assert_size(src),
         {:ok, content_type} <- sniff(src) do
      write(note, src, Path.basename(file_name), size, content_type, company, user)
    end
  end

  def remove(%NoteAttachment{} = att, company, user) do
    with %Note{} = note <- Notes.get_note(att.note_id, company, user) || {:error, :not_found},
         true <- Notes.can_edit?(note, company, user) || :not_authorise do
      att
      |> Ecto.Changeset.change(removed_at: DateTime.utc_now(:second), removed_by_id: user.id)
      |> Repo.update()
    end
  end

  def get_readable(id, company, user) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      from(a in NoteAttachment,
        join: n in subquery(Notes.visible_to(company, user)),
        on: n.id == a.note_id,
        where: a.id == ^id
      )
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp assert_size(src) do
    case File.stat(src || "") do
      {:ok, %{size: size}} when size <= @max_bytes -> {:ok, size}
      {:ok, _} -> {:error, :too_large}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp sniff(src) do
    case File.open(src, [:read, :binary], &IO.binread(&1, 16)) do
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg"}
      {:ok, <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>>} -> {:ok, "image/png"}
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> {:ok, "image/webp"}
      {:ok, <<"%PDF-", _::binary>>} -> {:ok, "application/pdf"}
      {:ok, _} -> {:error, :unsupported_type}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp write(note, src, file_name, size, content_type, company, user) do
    rel = Path.join([company.id, "notes", note.id, Ecto.UUID.generate() <> ext(content_type)])
    abs = Path.join(uploads_dir(), rel)
    File.mkdir_p!(Path.dirname(abs))
    File.cp!(src, abs)

    %NoteAttachment{}
    |> NoteAttachment.changeset(%{
      file_name: file_name,
      content_type: content_type,
      byte_size: size,
      path: rel,
      company_id: company.id,
      note_id: note.id,
      uploaded_by_id: user.id
    })
    |> Repo.insert()
    |> case do
      {:ok, att} ->
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

  defp ext("image/jpeg"), do: ".jpg"
  defp ext("image/png"), do: ".png"
  defp ext("image/webp"), do: ".webp"
  defp ext("application/pdf"), do: ".pdf"

  defp uploads_dir, do: Application.get_env(:full_circle, :uploads_dir)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/notes_attachments_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/notes/attachments.ex test/full_circle/notes_attachments_test.exs
git add lib/full_circle/notes/attachments.ex test/full_circle/notes_attachments_test.exs
git commit -m "feat(notes): attachments with sniffed type, size gate, keep-on-remove

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Attachment HTTP controller

**Files:**
- Create: `lib/full_circle_web/controllers/note_attachment_controller.ex`, `test/full_circle_web/controllers/note_attachment_controller_test.exs`
- Modify: `lib/full_circle_web/router.ex` (the `scope "/companies/:company_id"` block that has `get "/TimeAttend/:id/photo"`), `lib/full_circle_web/endpoint.ex` (multipart length)

**Interfaces:**
- Consumes: `Attachments.attach/4`, `Attachments.get_readable/3`, `Attachments.abs_path/1`, `Notes.get_note/3`; `conn.assigns.current_company` / `current_user` (set by `set_active_company` from the URL's `company_id`, refusing non-members).
- Produces routes:
  - `POST /companies/:company_id/notes/:note_id/attachments` (multipart field `file`) → `200 {"ok": true, "id": id}` or `422 {"error": message}` / `403` / `404`
  - `GET /companies/:company_id/note_attachments/:id` → the file inline with its sniffed content type, or `404`

- [ ] **Step 1: Write the failing tests**

`test/full_circle_web/controllers/note_attachment_controller_test.exs`:

```elixir
defmodule FullCircleWeb.NoteAttachmentControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Notes.Attachments

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    note = note_fixture(comp, admin)
    %{conn: conn, admin: admin, comp: comp, note: note}
  end

  defp upload(path, name), do: %Plug.Upload{path: path, filename: name, content_type: "application/octet-stream"}

  test "uploads a file for a note the user can edit", %{conn: conn, admin: admin, comp: comp, note: note} do
    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{"file" => upload(jpeg_file(), "p.jpg")})

    assert %{"ok" => true, "id" => _} = json_response(conn, 200)
  end

  test "rejects an unsupported file with a message", %{conn: conn, admin: admin, comp: comp, note: note} do
    conn =
      conn
      |> log_in_user(admin)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{"file" => upload(text_file(), "x.jpg")})

    assert %{"error" => msg} = json_response(conn, 422)
    assert msg =~ "JPEG"
  end

  test "a clerk cannot upload to someone else's note", %{conn: conn, admin: admin, comp: comp, note: note} do
    clerk = user_with_role(comp, admin, "clerk")

    conn =
      conn
      |> log_in_user(clerk)
      |> post(~p"/companies/#{comp.id}/notes/#{note.id}/attachments", %{"file" => upload(jpeg_file(), "p.jpg")})

    assert json_response(conn, 403)
  end

  test "download serves the file with its sniffed type", %{conn: conn, admin: admin, comp: comp, note: note} do
    {:ok, att} = Attachments.attach(note, %{path: jpeg_file(), file_name: "p.jpg"}, comp, admin)
    conn = conn |> log_in_user(admin) |> get(~p"/companies/#{comp.id}/note_attachments/#{att.id}")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"
  end

  test "download of a restricted note's file is 404 for an outsider", %{conn: conn, admin: admin, comp: comp} do
    hidden = note_fixture(comp, admin, %{"visibility" => ["manager"]})
    {:ok, att} = Attachments.attach(hidden, %{path: jpeg_file(), file_name: "p.jpg"}, comp, admin)
    clerk = user_with_role(comp, admin, "clerk")
    conn = conn |> log_in_user(clerk) |> get(~p"/companies/#{comp.id}/note_attachments/#{att.id}")
    assert response(conn, 404)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle_web/controllers/note_attachment_controller_test.exs`
Expected: FAIL — no route / compile error on `~p`.

- [ ] **Step 3: Implement controller, routes, parser limit**

`lib/full_circle_web/controllers/note_attachment_controller.ex`:

```elixir
defmodule FullCircleWeb.NoteAttachmentController do
  @moduledoc """
  Plain-HTTP upload and download for note attachments. Uploads go over HTTP,
  not the LiveView socket, because a phone backgrounding the page during a
  camera pick kills the socket and loses a socket upload.
  """
  use FullCircleWeb, :controller

  alias FullCircle.Notes
  alias FullCircle.Notes.Attachments

  def create(conn, %{"note_id" => note_id, "file" => %Plug.Upload{} = file}) do
    company = conn.assigns.current_company
    user = conn.assigns.current_user

    case Notes.get_note(note_id, company, user) do
      nil ->
        conn |> put_status(404) |> json(%{error: gettext("Note not found.")})

      note ->
        case Attachments.attach(note, %{path: file.path, file_name: file.filename}, company, user) do
          {:ok, att} -> json(conn, %{ok: true, id: att.id})
          :not_authorise -> conn |> put_status(403) |> json(%{error: gettext("Not Authorise.")})
          {:error, reason} -> conn |> put_status(422) |> json(%{error: message(reason)})
        end
    end
  end

  def create(conn, _params),
    do: conn |> put_status(422) |> json(%{error: gettext("No file received.")})

  def show(conn, %{"id" => id}) do
    case Attachments.get_readable(id, conn.assigns.current_company, conn.assigns.current_user) do
      nil ->
        send_resp(conn, 404, "not found")

      att ->
        abs = Attachments.abs_path(att)

        if File.exists?(abs) do
          conn
          |> put_resp_content_type(att.content_type, nil)
          |> put_resp_header("content-disposition", ~s(inline; filename="#{safe_name(att.file_name)}"))
          |> send_file(200, abs)
        else
          send_resp(conn, 404, "not found")
        end
    end
  end

  defp message(:too_large), do: gettext("File is larger than 10 MB.")
  defp message(:unsupported_type), do: gettext("Only JPEG, PNG, WebP images and PDF files are allowed.")
  defp message(:not_found), do: gettext("File could not be read.")
  defp message(_), do: gettext("Upload failed.")

  defp safe_name(name), do: String.replace(name, ~r/["\r\n\\]/, "_")
end
```

Router — in `scope "/companies/:company_id", FullCircleWeb do` (the one with `get "/TimeAttend/:id/photo", ...`), after that line add:

```elixir
    post "/notes/:note_id/attachments", NoteAttachmentController, :create
    get "/note_attachments/:id", NoteAttachmentController, :show
```

Endpoint — in `lib/full_circle_web/endpoint.ex` change the parsers line to allow 10 MB files plus multipart overhead:

```elixir
  plug Plug.Parsers,
    parsers: [:urlencoded, {:multipart, length: 12_000_000}, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle_web/controllers/note_attachment_controller_test.exs`
Expected: 5 tests, 0 failures. If the POST test gets a 403 CSRF error, the test conn is fine (Phoenix.ConnTest skips CSRF); a real browser needs the `x-csrf-token` header, which the hook in Task 10 sends.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/controllers/note_attachment_controller.ex lib/full_circle_web/router.ex lib/full_circle_web/endpoint.ex test/full_circle_web/controllers/note_attachment_controller_test.exs
git add lib/full_circle_web/controllers/note_attachment_controller.ex lib/full_circle_web/router.ex lib/full_circle_web/endpoint.ex test/full_circle_web/controllers/note_attachment_controller_test.exs
git commit -m "feat(notes): plain-HTTP attachment upload and visibility-checked download

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Shared note UI — components, record picker, upload hook

**Files:**
- Create: `lib/full_circle_web/components/note_components.ex`, `lib/full_circle_web/live/note_live/record_picker_component.ex`, `assets/js/note_attach.js`
- Modify: `assets/js/app.js`
- Test: covered through LiveView tests in Tasks 11–15 (these are render helpers); compile check here.

**Interfaces:**
- Produces (import `FullCircleWeb.NoteComponents` where used):
  - `type_label(type :: String.t()) :: String.t()` (gettext'd)
  - `<.visibility_badge visibility={list | nil} />`
  - `<.note_card note={Note} relation={:about | :linked | nil} current_company={..} can_edit={bool} target={@myself | nil} />` — body, author, time, badge, attachments, attach button, "Open" link
  - `<.attachment_list attachments={[NoteAttachment]} current_company={..} can_edit={bool} target={..} />` — emits `"remove_attachment"` with `phx-value-id`
  - `<.attach_button note_id={id} current_company={..} />` — hook `NoteAttach`, on success pushes `"attachment_uploaded"` to its owner
  - `<.notes_count_badge count={int} id={record_id} />` — emits `"open_notes"` with `phx-value-id`
  - `<.record_link target={{:ok, map} | {:error, atom}} type={t} />` — link, "(deleted Invoice)", or "Restricted record"
  - `FullCircleWeb.NoteLive.RecordPickerComponent` — assigns `id`, `current_company`, `current_user`, `types` (default `Linkable.types()`), `label`; on pick sends `{:record_picked, picker_id, %{type:, id:, title:}}` to the parent LiveView process

- [ ] **Step 1: Write the components module**

`lib/full_circle_web/components/note_components.ex`:

```elixir
defmodule FullCircleWeb.NoteComponents do
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  import FullCircleWeb.CoreComponents, only: [icon: 1]

  alias FullCircle.Notes.Note

  def type_label("Employee"), do: gettext("Employee")
  def type_label("Contact"), do: gettext("Contact")
  def type_label("Good"), do: gettext("Good")
  def type_label("Note"), do: gettext("Note")
  def type_label("Invoice"), do: gettext("Invoice")
  def type_label("PurInvoice"), do: gettext("Purchase Invoice")
  def type_label("Receipt"), do: gettext("Receipt")
  def type_label("Payment"), do: gettext("Payment")
  def type_label("CreditNote"), do: gettext("Credit Note")
  def type_label("DebitNote"), do: gettext("Debit Note")
  def type_label("Journal"), do: gettext("Journal")
  def type_label("Deposit"), do: gettext("Deposit")
  def type_label("ReturnCheque"), do: gettext("Return Cheque")
  def type_label(other), do: other

  attr :visibility, :any, required: true

  def visibility_badge(%{visibility: nil} = assigns) do
    ~H"""
    <span class="rounded px-1 text-xs bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200">
      {gettext("Everyone")}
    </span>
    """
  end

  def visibility_badge(assigns) do
    ~H"""
    <span class="rounded px-1 text-xs bg-rose-100 text-rose-800 dark:bg-rose-900 dark:text-rose-200">
      🔒 {Enum.join(@visibility, ", ")}
    </span>
    """
  end

  attr :target, :any, required: true
  attr :type, :string, required: true

  def record_link(%{target: {:ok, t}} = assigns) do
    assigns = assign(assigns, :t, t)

    ~H"""
    <.link navigate={@t.url} class="text-blue-600 hover:font-bold dark:text-blue-400">
      {type_label(@type)}: {@t.title}
    </.link>
    """
  end

  def record_link(%{target: {:error, :restricted}} = assigns) do
    ~H"""
    <span class="italic text-gray-500">{gettext("Restricted record")}</span>
    """
  end

  def record_link(assigns) do
    ~H"""
    <span class="italic text-gray-500">({gettext("deleted")} {type_label(@type)})</span>
    """
  end

  attr :note, Note, required: true
  attr :relation, :atom, default: nil
  attr :current_company, :map, required: true
  attr :can_edit, :boolean, default: false
  attr :target, :any, default: nil

  def note_card(assigns) do
    ~H"""
    <div
      id={"note-card-#{@note.id}"}
      class="my-1 rounded border border-gray-300 bg-white p-2 text-left dark:border-gray-600 dark:bg-gray-800"
    >
      <div class="flex flex-wrap items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
        <.visibility_badge visibility={@note.visibility} />
        <span :if={@relation == :linked} class="rounded border px-1">↩ {gettext("linked")}</span>
        <span>{@note.author && @note.author.email}</span>
        <span>· {FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company)}</span>
        <.link
          navigate={"/companies/#{@current_company.id}/notes/#{@note.id}"}
          class="ml-auto text-blue-600 hover:font-bold dark:text-blue-400"
        >
          {gettext("Open")}
        </.link>
      </div>
      <div :if={@note.title} class="font-semibold">{@note.title}</div>
      <div class="whitespace-pre-wrap">{@note.body}</div>
      <.attachment_list
        attachments={@note.attachments}
        current_company={@current_company}
        can_edit={@can_edit}
        target={@target}
      />
      <.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />
    </div>
    """
  end

  attr :attachments, :list, required: true
  attr :current_company, :map, required: true
  attr :can_edit, :boolean, default: false
  attr :target, :any, default: nil

  def attachment_list(assigns) do
    ~H"""
    <div :if={@attachments != []} class="mt-1 flex flex-wrap gap-2 text-sm">
      <span :for={a <- @attachments} id={"att-#{a.id}"} class="flex items-center gap-1">
        <a
          href={"/companies/#{@current_company.id}/note_attachments/#{a.id}"}
          target="_blank"
          class="text-blue-600 hover:font-bold dark:text-blue-400"
        >
          📎 {a.file_name}
        </a>
        <button
          :if={@can_edit}
          type="button"
          phx-click="remove_attachment"
          phx-value-id={a.id}
          phx-target={@target}
          data-confirm={gettext("Remove this file from the note?")}
          class="text-rose-600 dark:text-rose-400"
          title={gettext("Remove")}
        >
          <.icon name="hero-x-mark" class="h-4 w-4" />
        </button>
      </span>
    </div>
    """
  end

  attr :note_id, :string, required: true
  attr :current_company, :map, required: true

  def attach_button(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 text-sm">
      <button
        type="button"
        id={"attach-#{@note_id}"}
        phx-hook="NoteAttach"
        data-url={"/companies/#{@current_company.id}/notes/#{@note_id}/attachments"}
        data-max-bytes={FullCircle.Notes.Attachments.max_bytes()}
        class="rounded border border-gray-400 px-2 hover:bg-gray-100 dark:border-gray-500 dark:hover:bg-gray-700"
      >
        📎 {gettext("Attach file")}
      </button>
      <span id={"attach-#{@note_id}-msg"} phx-update="ignore" class="text-rose-600 dark:text-rose-400"></span>
    </span>
    """
  end

  attr :count, :integer, required: true
  attr :id, :string, required: true

  def notes_count_badge(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_notes"
      phx-value-id={@id}
      class={[
        "rounded px-1 text-xs",
        @count > 0 && "bg-blue-600 text-white dark:bg-blue-500",
        @count == 0 && "text-gray-400 dark:text-gray-500"
      ]}
      title={gettext("Notes")}
    >
      📝 {if @count > 0, do: @count, else: "—"}
    </button>
    """
  end
end
```

- [ ] **Step 2: Write the record picker**

`lib/full_circle_web/live/note_live/record_picker_component.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.RecordPickerComponent do
  @moduledoc """
  Pick one record of any Linkable type: a type select plus a search box.
  Sends `{:record_picked, id, %{type:, id:, title:}}` to the parent LiveView.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents, only: [type_label: 1]

  alias FullCircle.Linkable

  @impl true
  def update(assigns, socket) do
    types = Map.get(assigns, :types) || Linkable.types()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(types: types)
     |> assign_new(:type, fn -> hd(types) end)
     |> assign_new(:terms, fn -> "" end)
     |> assign_new(:results, fn -> [] end)
     |> assign_new(:label, fn -> gettext("Find a record") end)}
  end

  @impl true
  def handle_event("search", %{"type" => type, "terms" => terms}, socket) do
    type = if type in socket.assigns.types, do: type, else: hd(socket.assigns.types)

    results =
      Linkable.search(type, terms, socket.assigns.current_company, socket.assigns.current_user)

    {:noreply, assign(socket, type: type, terms: terms, results: results)}
  end

  def handle_event("pick", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.results, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      r ->
        send(self(), {:record_picked, socket.assigns.id, %{type: r.type, id: r.id, title: r.title}})
        {:noreply, assign(socket, terms: "", results: [])}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="rounded border border-gray-300 p-2 dark:border-gray-600">
      <div class="text-sm font-semibold">{@label}</div>
      <form phx-change="search" phx-submit="search" phx-target={@myself} class="flex gap-1">
        <select name="type" class="rounded border-gray-300 text-sm">
          <option :for={t <- @types} value={t} selected={t == @type}>{type_label(t)}</option>
        </select>
        <input
          type="search"
          name="terms"
          value={@terms}
          phx-debounce="300"
          autocomplete="off"
          placeholder={gettext("Type a name or number...")}
          class="w-full rounded border-gray-300 text-sm"
        />
      </form>
      <div :if={@results != []} class="mt-1 max-h-48 overflow-y-auto">
        <button
          :for={r <- @results}
          type="button"
          id={"#{@id}-pick-#{r.id}"}
          phx-click="pick"
          phx-value-id={r.id}
          phx-target={@myself}
          class="block w-full rounded px-1 text-left text-sm hover:bg-amber-100 dark:hover:bg-amber-900"
        >
          {r.title} <span :if={r.subtitle} class="text-gray-500">— {r.subtitle}</span>
        </button>
      </div>
      <div :if={@results == [] and @terms != ""} class="text-sm text-gray-500">
        {gettext("No match.")}
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 3: Write the upload hook**

`assets/js/note_attach.js`:

```javascript
// Plain-HTTP attachment upload for notes. Why not LiveView uploads: on phones
// the camera/file picker backgrounds the page, the socket can time out, and a
// remount throws away an in-flight socket upload. A transient <input> in
// document.body survives a remount; an XHR survives the socket dying.
const IMAGE_EXT = new Set(["jpg", "jpeg", "png", "webp", "heic", "heif", "bmp", "avif"])

function ext(name) {
  const i = name.lastIndexOf(".")
  return i >= 0 ? name.slice(i + 1).toLowerCase() : ""
}

async function downscale(file, maxEdge = 1920, quality = 0.85) {
  const isImage = IMAGE_EXT.has(ext(file.name)) || (file.type || "").startsWith("image/")
  if (!isImage || file.size < 50000 || file.type === "image/gif") return file
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

export const NoteAttach = {
  mounted() {
    this.el.addEventListener("click", e => {
      e.preventDefault()
      const input = document.createElement("input")
      input.type = "file"
      input.accept = "image/*,application/pdf"
      input.style.display = "none"
      document.body.appendChild(input)
      input.addEventListener("change", () => {
        const file = input.files && input.files[0]
        input.remove()
        if (file) this.upload(file)
      })
      input.click()
    })
  },

  message(text) {
    const el = document.getElementById(`${this.el.id}-msg`)
    if (el) el.textContent = text || ""
  },

  async upload(original) {
    const file = await downscale(original)
    const max = parseInt(this.el.dataset.maxBytes, 10)
    if (file.size > max) {
      this.message(`File is larger than ${Math.floor(max / 1000000)} MB.`)
      return
    }
    this.message("Uploading…")
    const form = new FormData()
    form.append("file", file, file.name)
    const xhr = new XMLHttpRequest()
    xhr.open("POST", this.el.dataset.url)
    xhr.setRequestHeader("x-csrf-token", document.querySelector("meta[name='csrf-token']").content)
    xhr.onload = () => {
      let body = {}
      try { body = JSON.parse(xhr.responseText) } catch (_e) {}
      if (xhr.status === 200) {
        this.message("")
        if (this.liveSocket.isConnected()) {
          this.pushEventTo(this.el, "attachment_uploaded", { id: body.id })
        } else {
          window.location.reload()
        }
      } else {
        this.message(body.error || `Upload failed (${xhr.status}).`)
      }
    }
    xhr.onerror = () => this.message("Upload failed — check the connection and try again.")
    xhr.send(form)
  }
}
```

In `assets/js/app.js`, add near the other imports at the top:

```javascript
import { NoteAttach } from "./note_attach"
```

and after `let Hooks = {}`:

```javascript
Hooks.NoteAttach = NoteAttach
```

- [ ] **Step 4: Compile and build assets**

Run: `mix compile --warnings-as-errors && mix assets.build`
Expected: no warnings, esbuild succeeds.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/components/note_components.ex lib/full_circle_web/live/note_live/record_picker_component.ex
git add lib/full_circle_web/components/note_components.ex lib/full_circle_web/live/note_live/record_picker_component.ex assets/js/note_attach.js assets/js/app.js
git commit -m "feat(notes): shared note components, record picker, HTTP upload hook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Notes index page, routes, dashboard entry, palette action

**Files:**
- Create: `lib/full_circle_web/live/note_live/index.ex`, `test/full_circle_web/live/note_live_test.exs`
- Modify: `lib/full_circle_web/router.ex` (inside `live_session :require_authenticated_user_n_active_company`), `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, `lib/full_circle/command_palette/types.ex`

**Interfaces:**
- Consumes: `Notes.search/5`, `NoteComponents`.
- Produces routes (all in the authenticated live_session):
  - `live("/notes", NoteLive.Index, :index)`
  - `live("/notes/new", NoteLive.Form, :new)` (Task 12)
  - `live("/notes/:note_id/edit", NoteLive.Form, :edit)` (Task 12)
  - `live("/notes/:note_id", NoteLive.Show, :show)` (Task 13) — **must come after `/notes/new`**

- [ ] **Step 1: Write the failing test**

`test/full_circle_web/live/note_live_test.exs`:

```elixir
defmodule FullCircleWeb.NoteLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp}
  end

  describe "index" do
    test "lists visible notes and searches", %{conn: conn, admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"title" => "Welding", "body" => "Ali welds"})
      note_fixture(comp, admin, %{"body" => "Ah Seng pays late"})

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes")
      assert html =~ "Welding"
      assert html =~ "Ah Seng pays late"

      html = lv |> form("#search-form", %{"search" => %{"terms" => "weld"}}) |> render_submit()
      assert_patch(lv)
      html = render(lv)
      assert html =~ "Welding"
      refute html =~ "Ah Seng pays late"
    end

    test "restricted notes are not listed for a clerk", %{admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"body" => "manager only", "visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, _lv, html} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes")
      refute html =~ "manager only"
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Implement the index**

`lib/full_circle_web/live/note_live/index.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.Index do
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Notes"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    terms = get_in(params, ["search", "terms"]) || ""
    filters = Map.take(params["filters"] || %{}, ~w(subject_type mine from to))

    {:noreply,
     socket
     |> assign(search: %{terms: terms}, filters: filters)
     |> load(1, true)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms}}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, terms, socket.assigns.filters))}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket, socket.assigns.search.terms, filters))}
  end

  def handle_event("next-page", _, socket) do
    {:noreply, load(socket, socket.assigns.page + 1, false)}
  end

  # Not `url/3`: Phoenix.VerifiedRoutes imports a url macro of that arity.
  defp index_path(socket, terms, filters) do
    q =
      %{"search[terms]" => terms}
      |> Map.merge(Map.new(filters, fn {k, v} -> {"filters[#{k}]", v} end))
      |> URI.encode_query()

    "/companies/#{socket.assigns.current_company.id}/notes?#{q}"
  end

  defp load(socket, page, reset) do
    notes =
      Notes.search(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.search.terms,
        socket.assigns.filters,
        page: page,
        per_page: @per_page
      )
      |> FullCircle.Repo.preload(:attachments)

    socket
    |> assign(page: page, end_of_timeline?: length(notes) < @per_page)
    |> stream(:notes, notes, reset: reset)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12 max-md:w-11/12">
      <p class="w-full text-center text-3xl font-medium">{@page_title}</p>
      <.search_form live search_val={@search.terms} placeholder={gettext("Words in the title or body...")} />
      <form id="filter-form" phx-change="filter" class="mb-2 flex flex-wrap items-end justify-center gap-2 text-sm">
        <label>
          {gettext("About")}
          <select name="filters[subject_type]" class="rounded border-gray-300 text-sm">
            <option value="">{gettext("Anything")}</option>
            <option :for={t <- Linkable.types()} value={t} selected={@filters["subject_type"] == t}>
              {type_label(t)}
            </option>
          </select>
        </label>
        <label>
          <input type="hidden" name="filters[mine]" value="false" />
          <input type="checkbox" name="filters[mine]" value="true" checked={@filters["mine"] == "true"} />
          {gettext("Written by me")}
        </label>
        <label>{gettext("From")} <input type="date" name="filters[from]" value={@filters["from"]} class="rounded border-gray-300 text-sm" /></label>
        <label>{gettext("To")} <input type="date" name="filters[to]" value={@filters["to"]} class="rounded border-gray-300 text-sm" /></label>
      </form>
      <div class="mb-2 text-center">
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :create_note, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/notes/new"}
          class="blue button"
        >
          {gettext("New Note")}
        </.link>
      </div>
      <div id="notes_list" phx-update="stream" phx-viewport-bottom={!@end_of_timeline? && "next-page"}>
        <div :for={{dom_id, note} <- @streams.notes} id={dom_id}>
          <.note_card note={note} current_company={@current_company} />
          <div :if={note.subject_type} class="-mt-1 mb-2 pl-2 text-xs text-gray-500">
            {gettext("About")} {type_label(note.subject_type)}
          </div>
        </div>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
```

Router — inside `live_session :require_authenticated_user_n_active_company` right after the contacts routes:

```elixir
      live("/notes", NoteLive.Index, :index)
```

Dashboard — in `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, immediately before `<div class="font-medium text-xl">Accounting</div>`:

```heex
      <div
        :if={FullCircle.Authorization.can?(@current_user, :view_notes, @current_company)}
        class="mb-4 gap-1 flex flex-wrap justify-center"
      >
        <.link navigate={~p"/companies/#{@current_company.id}/notes"} class="button blue">
          📝 {gettext("Notes")}
        </.link>
      </div>
```

Palette — in `lib/full_circle/command_palette/types.ex` append to `@create_specs`:

```elixir
    {~w(newnote), "Note", :create_note, "New Note", "notes"}
```

(The action search builds `"/companies/#{id}/notes/new"` from the route segment.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle_web/live/note_live_test.exs test/full_circle/command_palette_test.exs`
Expected: all pass. If a palette test pins the exact list of create specs, add the `newnote` entry to its expectation.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/index.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex lib/full_circle/command_palette/types.ex test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/live/note_live/index.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex lib/full_circle/command_palette/types.ex test/full_circle_web/live/note_live_test.exs test/full_circle/command_palette_test.exs
git commit -m "feat(notes): notes index with search and filters, dashboard and palette entry

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Note form (new / edit)

**Files:**
- Create: `lib/full_circle_web/live/note_live/form.ex`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/live/note_live_test.exs`

**Interfaces:**
- Consumes: `Notes.change_note/2`, `create_note/3`, `update_note/4`, `get_note/3`, `can_edit?/3`, `Linkable.resolve/4`, `RecordPickerComponent`, `Note.visibility_roles/0`.
- Produces: `/notes/new?subject_type=&subject_id=` pre-fills the subject; save redirects to `/notes/:id`; edit of a note the user cannot edit redirects to `/notes` with a `:warn` flash; a stale save keeps the text and flashes.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle_web/live/note_live_test.exs`:

```elixir
  describe "form" do
    test "creates a note about a contact with restricted visibility", %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      {:ok, lv, html} =
        live(conn, ~p"/companies/#{comp.id}/notes/new?subject_type=Contact&subject_id=#{c.id}")

      assert html =~ "Ah Seng"

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#note-form", %{"note" => %{"body" => "pays late", "visibility" => ["manager"]}})
        |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      assert to == "/companies/#{comp.id}/notes/#{note.id}"
      assert note.subject_id == c.id
      assert note.visibility == ["manager"]
    end

    test "blank body shows an error", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")
      html = lv |> form("#note-form", %{"note" => %{"body" => ""}}) |> render_change()
      assert html =~ "can&#39;t be blank"
    end

    test "edits and keeps a version", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}/edit")
      lv |> form("#note-form", %{"note" => %{"body" => "v2"}}) |> render_submit()
      assert [%{body: "v1"}] = FullCircle.Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "a stale save keeps the typed text and warns", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}/edit")
      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)

      html = lv |> form("#note-form", %{"note" => %{"body" => "my text"}}) |> render_submit()
      assert html =~ "someone else changed this note"
      assert html =~ "my text"
    end

    test "a clerk cannot open another user's note for edit", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin)
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes/#{note.id}/edit")

      assert to == "/companies/#{comp.id}/notes"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — no route `/notes/new`.

- [ ] **Step 3: Implement**

Router — below `live("/notes", NoteLive.Index, :index)`:

```elixir
      live("/notes/new", NoteLive.Form, :new)
      live("/notes/:note_id/edit", NoteLive.Form, :edit)
```

`lib/full_circle_web/live/note_live/form.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.Form do
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.Note
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    case socket.assigns.live_action do
      :new ->
        if FullCircle.Authorization.can?(user, :create_note, com) do
          {:ok, mount_new(socket, params)}
        else
          {:ok, deny(socket)}
        end

      :edit ->
        case Notes.get_note(params["note_id"], com, user) do
          %Note{} = note ->
            if Notes.can_edit?(note, com, user), do: {:ok, mount_edit(socket, note)}, else: {:ok, deny(socket)}

          nil ->
            {:ok, deny(socket)}
        end
    end
  end

  defp deny(socket) do
    socket
    |> put_flash(:warn, gettext("You cannot edit that note."))
    |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")
  end

  defp mount_new(socket, params) do
    subject =
      with t when is_binary(t) <- params["subject_type"],
           {:ok, target} <-
             Linkable.resolve(t, params["subject_id"], socket.assigns.current_company, socket.assigns.current_user) do
        %{type: t, id: target.id, title: target.title}
      else
        _ -> nil
      end

    socket
    |> assign(page_title: gettext("New Note"), note: %Note{}, subject: subject, links: [])
    |> assign(form: to_form(Notes.change_note(%Note{}, subject_attrs(subject))))
  end

  defp mount_edit(socket, note) do
    subject =
      if note.subject_type do
        case Linkable.resolve(note.subject_type, note.subject_id, socket.assigns.current_company, socket.assigns.current_user) do
          {:ok, t} -> %{type: note.subject_type, id: note.subject_id, title: t.title}
          _ -> %{type: note.subject_type, id: note.subject_id, title: gettext("(unavailable)")}
        end
      end

    socket
    |> assign(page_title: gettext("Edit Note"), note: note, subject: subject, links: [])
    |> assign(form: to_form(Notes.change_note(note)))
  end

  defp subject_attrs(nil), do: %{"subject_type" => nil, "subject_id" => nil}
  defp subject_attrs(s), do: %{"subject_type" => s.type, "subject_id" => s.id}

  @impl true
  def handle_event("validate", %{"note" => params}, socket) do
    cs =
      socket.assigns.note
      |> Notes.change_note(Map.merge(params, subject_attrs(socket.assigns.subject)))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("clear_subject", _, socket) do
    {:noreply, assign(socket, subject: nil)}
  end

  def handle_event("remove_new_link", %{"id" => id}, socket) do
    {:noreply, assign(socket, links: Enum.reject(socket.assigns.links, &(&1.id == id)))}
  end

  def handle_event("save", %{"note" => params}, socket) do
    params = Map.merge(params, subject_attrs(socket.assigns.subject))
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new ->
          Notes.create_note(
            Map.put(params, "links", Enum.map(socket.assigns.links, &%{"type" => &1.type, "id" => &1.id})),
            com,
            user
          )

        :edit ->
          Notes.update_note(socket.assigns.note, params, com, user)
      end

    case result do
      {:ok, note} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note saved."))
         |> push_navigate(to: ~p"/companies/#{com.id}/notes/#{note.id}")}

      {:error, :stale} ->
        {:noreply,
         socket
         |> assign(form: to_form(Notes.change_note(socket.assigns.note, params)))
         |> put_flash(:warn, gettext("someone else changed this note — reload to see their version"))}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      {:error, {:link, :not_found}} ->
        {:noreply, put_flash(socket, :warn, gettext("A linked record no longer exists."))}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  @impl true
  def handle_info({:record_picked, "subject-picker", picked}, socket) do
    {:noreply, assign(socket, subject: picked)}
  end

  def handle_info({:record_picked, "links-picker", picked}, socket) do
    links = Enum.uniq_by(socket.assigns.links ++ [picked], &{&1.type, &1.id})
    {:noreply, assign(socket, links: links)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12 max-md:w-11/12 rounded-lg border border-yellow-500 bg-yellow-100 p-4 dark:bg-yellow-950">
      <p class="w-full text-center text-3xl font-medium">{@page_title}</p>
      <.form for={@form} id="note-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <.input field={@form[:title]} label={gettext("Title (optional)")} />
        <.input field={@form[:body]} type="textarea" rows="8" label={gettext("Note")} />

        <div class="mt-2">
          <div class="text-sm font-semibold">{gettext("Who can read this note")}</div>
          <p class="text-xs text-gray-600 dark:text-gray-400">
            {gettext("Tick none for everyone. Admin and you can always read it.")}
          </p>
          <input type="hidden" name="note[visibility][]" value="" />
          <label :for={role <- Note.visibility_roles()} class="mr-3 inline-flex items-center gap-1 text-sm">
            <input
              type="checkbox"
              name="note[visibility][]"
              value={role}
              checked={role in (Ecto.Changeset.get_field(@form.source, :visibility) || [])}
            />
            {role}
          </label>
          <.error :for={msg <- Enum.map(@form[:visibility].errors, &translate_error/1)}>{msg}</.error>
        </div>

        <div class="mt-2 text-sm">
          <span class="font-semibold">{gettext("About")}:</span>
          <span :if={@subject}>
            {type_label(@subject.type)} — {@subject.title}
            <button type="button" phx-click="clear_subject" class="text-rose-600 dark:text-rose-400">✕</button>
          </span>
          <span :if={!@subject} class="text-gray-500">{gettext("nothing in particular")}</span>
          <.error :for={msg <- Enum.map(@form[:subject_id].errors ++ @form[:subject_type].errors, &translate_error/1)}>
            {msg}
          </.error>
        </div>

        <div :if={@live_action == :new and @links != []} class="mt-1 text-sm">
          <span class="font-semibold">{gettext("Links")}:</span>
          <span :for={l <- @links} class="mr-2">
            {type_label(l.type)} — {l.title}
            <button type="button" phx-click="remove_new_link" phx-value-id={l.id} class="text-rose-600">✕</button>
          </span>
        </div>

        <div class="mt-3 flex justify-center gap-2">
          <.button>{gettext("Save")}</.button>
          <.link navigate={~p"/companies/#{@current_company.id}/notes"} class="orange button">
            {gettext("Back")}
          </.link>
        </div>
      </.form>

      <div class="mt-3 grid gap-2">
        <.live_component
          module={RecordPickerComponent}
          id="subject-picker"
          label={gettext("Set what this note is about")}
          current_company={@current_company}
          current_user={@current_user}
        />
        <.live_component
          :if={@live_action == :new}
          module={RecordPickerComponent}
          id="links-picker"
          label={gettext("Link other records")}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>
    </div>
    """
  end
end
```

`translate_error/1` and `.error` come from `FullCircleWeb.CoreComponents` (lines ~458 and ~698).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: all pass. The create test asserts only the redirect target (`/notes/:id`), so it passes before Task 13 adds the show route.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/form.ex lib/full_circle_web/router.ex test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/live/note_live/form.ex lib/full_circle_web/router.ex test/full_circle_web/live/note_live_test.exs
git commit -m "feat(notes): note form with subject picker, visibility and stale handling

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Note show page — attachments, links, backlinks, history, delete

**Files:**
- Create: `lib/full_circle_web/live/note_live/show.ex`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/live/note_live_test.exs`

**Interfaces:**
- Consumes: `Notes.get_note/3`, `can_edit?/3`, `can_delete?/3`, `list_links/3`, `add_link/5`, `remove_link/4`, `list_backlinks/3`, `list_versions/3`, `version_changes/2`, `delete_note/3`, `Attachments.remove/3`, `Linkable.resolve/4`, `NoteComponents`, `RecordPickerComponent`.
- Produces: route `live("/notes/:note_id", NoteLive.Show, :show)` (after `/notes/new`).

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "show" do
    test "shows body, links, backlinks and history", %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})
      note = note_fixture(comp, admin, %{"body" => "v1", "links" => [%{"type" => "Contact", "id" => c.id}]})
      {:ok, note} = FullCircle.Notes.update_note(note, %{"body" => "v2"}, comp, admin)
      other = note_fixture(comp, admin, %{"body" => "points here"})
      {:ok, _} = FullCircle.Notes.add_link(other, "Note", note.id, comp, admin)

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert html =~ "v2"
      assert html =~ "Ah Seng"
      assert html =~ "points here"

      html = lv |> element("#toggle-history") |> render_click()
      assert html =~ "v1"
    end

    test "adds and removes a link", %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      note = note_fixture(comp, admin)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")

      lv |> form("#link-picker form", %{"type" => "Contact", "terms" => "Kedai"}) |> render_change()
      lv |> element("#link-picker-pick-#{c.id}") |> render_click()
      # The pick reaches Show via send/2, so read the page after it lands.
      assert render(lv) =~ "Kedai Mei"

      [link] = FullCircle.Notes.list_links(note, comp, admin)
      html = lv |> element("#remove-link-#{link.link_id}") |> render_click()
      refute html =~ "Kedai Mei"
    end

    test "delete returns to the index", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert {:error, {:live_redirect, %{to: to}}} = lv |> element("#delete-note") |> render_click()
      assert to == "/companies/#{comp.id}/notes"
    end

    test "a restricted note is not found for an outsider", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes/#{note.id}")

      assert to == "/companies/#{comp.id}/notes"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: FAIL — no route for show.

- [ ] **Step 3: Implement**

Router — below the two Form routes:

```elixir
      live("/notes/:note_id", NoteLive.Show, :show)
```

`lib/full_circle_web/live/note_live/show.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.Show do
  use FullCircleWeb, :live_view

  import FullCircleWeb.NoteComponents

  alias FullCircle.{Linkable, Notes}
  alias FullCircle.Notes.{Attachments, Note}
  alias FullCircleWeb.NoteLive.RecordPickerComponent

  @impl true
  def mount(%{"note_id" => id}, _session, socket) do
    case Notes.get_note(id, socket.assigns.current_company, socket.assigns.current_user) do
      %Note{} = note ->
        {:ok, socket |> assign(show_history: false) |> load(note)}

      nil ->
        {:ok,
         socket
         |> put_flash(:warn, gettext("Note not found."))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")}
    end
  end

  defp load(socket, note) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    subject =
      note.subject_type && Linkable.resolve(note.subject_type, note.subject_id, com, user)

    socket
    |> assign(
      page_title: Note.display_title(note),
      note: note,
      subject: subject,
      can_edit: Notes.can_edit?(note, com, user),
      can_delete: Notes.can_delete?(note, com, user),
      links: Notes.list_links(note, com, user),
      backlinks: Notes.list_backlinks(note, com, user)
    )
    |> assign_history()
  end

  defp assign_history(%{assigns: %{show_history: false}} = socket), do: assign(socket, history: [])

  defp assign_history(socket) do
    %{note: note, current_company: com, current_user: user} = socket.assigns
    assign(socket, history: Notes.version_changes(Notes.list_versions(note, com, user), note))
  end

  defp reload(socket) do
    case Notes.get_note(socket.assigns.note.id, socket.assigns.current_company, socket.assigns.current_user) do
      nil -> push_navigate(socket, to: ~p"/companies/#{socket.assigns.current_company.id}/notes")
      note -> load(socket, note)
    end
  end

  @impl true
  def handle_event("toggle_history", _, socket) do
    {:noreply, socket |> assign(show_history: !socket.assigns.show_history) |> assign_history()}
  end

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, reload(socket)}

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.note.attachments, &(&1.id == id)) do
      nil -> {:noreply, socket}
      att ->
        Attachments.remove(att, socket.assigns.current_company, socket.assigns.current_user)
        {:noreply, reload(socket)}
    end
  end

  def handle_event("remove_link", %{"id" => link_id}, socket) do
    Notes.remove_link(socket.assigns.note, link_id, socket.assigns.current_company, socket.assigns.current_user)
    {:noreply, reload(socket)}
  end

  def handle_event("delete", _, socket) do
    case Notes.delete_note(socket.assigns.note, socket.assigns.current_company, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Note deleted."))
         |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/notes")}

      _ ->
        {:noreply, put_flash(socket, :warn, gettext("Not Authorise."))}
    end
  end

  @impl true
  def handle_info({:record_picked, "link-picker", %{type: t, id: id}}, socket) do
    case Notes.add_link(socket.assigns.note, t, id, socket.assigns.current_company, socket.assigns.current_user) do
      {:ok, _} -> {:noreply, reload(socket)}
      {:error, %Ecto.Changeset{}} -> {:noreply, put_flash(socket, :warn, gettext("Already linked."))}
      _ -> {:noreply, put_flash(socket, :warn, gettext("Could not link that record."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-7/12 max-md:w-11/12">
      <div class="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
        <.visibility_badge visibility={@note.visibility} />
        <span>{@note.author.email}</span>
        <span>· {FullCircleWeb.Helpers.format_datetime(@note.inserted_at, @current_company)}</span>
        <span :if={@note.updated_at != @note.inserted_at}>
          · {gettext("edited by")} {@note.updated_by.email}
          {FullCircleWeb.Helpers.format_datetime(@note.updated_at, @current_company)}
        </span>
      </div>
      <h1 :if={@note.title} class="mt-1 text-2xl font-semibold">{@note.title}</h1>
      <div :if={@subject} class="mt-1 text-sm">
        {gettext("About")}: <.record_link target={@subject} type={@note.subject_type} />
      </div>
      <div class="mt-2 whitespace-pre-wrap rounded border border-gray-300 bg-white p-3 dark:border-gray-600 dark:bg-gray-800">{@note.body}</div>

      <div class="mt-2">
        <.attachment_list attachments={@note.attachments} current_company={@current_company} can_edit={@can_edit} />
        <.attach_button :if={@can_edit} note_id={@note.id} current_company={@current_company} />
      </div>

      <div class="mt-3 flex gap-2">
        <.link :if={@can_edit} navigate={~p"/companies/#{@current_company.id}/notes/#{@note.id}/edit"} class="blue button">
          {gettext("Edit")}
        </.link>
        <button
          :if={@can_delete}
          id="delete-note"
          phx-click="delete"
          data-confirm={gettext("Delete this note? Its history is kept.")}
          class="red button"
        >
          {gettext("Delete")}
        </button>
        <.link navigate={~p"/companies/#{@current_company.id}/notes"} class="orange button">{gettext("Back")}</.link>
      </div>

      <h2 class="mt-4 font-semibold">{gettext("Links")}</h2>
      <div :for={l <- @links} class="flex items-center gap-2 text-sm">
        <.record_link target={l.target} type={l.type} />
        <button
          :if={@can_edit}
          id={"remove-link-#{l.link_id}"}
          phx-click="remove_link"
          phx-value-id={l.link_id}
          class="text-rose-600 dark:text-rose-400"
        >
          ✕
        </button>
      </div>
      <p :if={@links == []} class="text-sm text-gray-500">{gettext("No links.")}</p>
      <div :if={@can_edit} class="mt-1">
        <.live_component
          module={RecordPickerComponent}
          id="link-picker"
          label={gettext("Link a record")}
          current_company={@current_company}
          current_user={@current_user}
        />
      </div>

      <h2 class="mt-4 font-semibold">{gettext("Notes linking here")}</h2>
      <div :for={b <- @backlinks} class="text-sm">
        <.link navigate={~p"/companies/#{@current_company.id}/notes/#{b.id}"} class="text-blue-600 hover:font-bold dark:text-blue-400">
          {Note.display_title(b)}
        </.link>
      </div>
      <p :if={@backlinks == []} class="text-sm text-gray-500">{gettext("None.")}</p>

      <button id="toggle-history" phx-click="toggle_history" class="mt-4 font-semibold text-blue-600 dark:text-blue-400">
        {if @show_history, do: "▾", else: "▸"} {gettext("History")}
      </button>
      <div :if={@show_history}>
        <div :for={h <- @history} class="my-1 rounded border border-gray-300 p-2 text-sm dark:border-gray-600">
          <div class="text-xs text-gray-500">
            {gettext("Version")} {h.version.version} · {gettext("replaced by")} {h.version.edited_by.email}
            {FullCircleWeb.Helpers.format_datetime(h.version.inserted_at, @current_company)}
          </div>
          <div :for={{field, old, new} <- h.changes}>
            <span class="font-semibold">{field}</span>:
            <span class="whitespace-pre-wrap bg-rose-100 line-through dark:bg-rose-900">{inspect_value(old)}</span>
            →
            <span class="whitespace-pre-wrap bg-green-100 dark:bg-green-900">{inspect_value(new)}</span>
          </div>
        </div>
        <p :if={@history == []} class="text-sm text-gray-500">{gettext("Never edited.")}</p>
      </div>
    </div>
    """
  end

  defp inspect_value(nil), do: "—"
  defp inspect_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp inspect_value(v), do: to_string(v)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle_web/live/note_live_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/note_live/show.ex lib/full_circle_web/router.ex test/full_circle_web/live/note_live_test.exs
git add lib/full_circle_web/live/note_live/show.ex lib/full_circle_web/router.ex test/full_circle_web/live/note_live_test.exs
git commit -m "feat(notes): note page with attachments, links, backlinks and history

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Notes panel on Contact and Employee edit pages

**Files:**
- Create: `lib/full_circle_web/live/note_live/notes_panel_component.ex`, `test/full_circle_web/live/notes_panel_live_test.exs`
- Modify: `lib/full_circle_web/live/contact_live/form.ex` (after `</.form>`, line ~276), `lib/full_circle_web/live/employee_live/form.ex` (after `</.form>`, line ~578)

**Interfaces:**
- Consumes: `Notes.notes_for_record/4`, `create_note/3`, `change_note/2`, `can_edit?/3`, `Attachments.remove/3`, `NoteComponents`.
- Produces: `FullCircleWeb.NoteLive.NotesPanelComponent` with assigns `id`, `record_type`, `record_id`, `current_company`, `current_user`, optional `notify_parent` (default `false`). When `notify_parent` is true, after a quick-add it sends `{:notes_changed, record_type, record_id}` to the parent LiveView.
- Embed snippet (used verbatim in Task 16 with `record_type` changed):

```heex
      <.live_component
        :if={@live_action == :edit and @id != "new"}
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="notes-panel"
        record_type="Contact"
        record_id={@id}
        current_company={@current_company}
        current_user={@current_user}
      />
```

- [ ] **Step 1: Write the failing tests**

`test/full_circle_web/live/notes_panel_live_test.exs`:

```elixir
defmodule FullCircleWeb.NotesPanelLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.HRFixtures
  import FullCircle.NotesFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    contact = contact_fixture(comp, admin, %{"name" => "Ah Seng"})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp, contact: contact}
  end

  test "contact edit page shows notes about and linking to it", %{conn: conn, admin: admin, comp: comp, contact: c} do
    note_fixture(comp, admin, %{"body" => "pays late", "subject_type" => "Contact", "subject_id" => c.id})
    note_fixture(comp, admin, %{"body" => "met at expo", "links" => [%{"type" => "Contact", "id" => c.id}]})

    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    assert html =~ "pays late"
    assert html =~ "met at expo"
    assert html =~ "linked"
  end

  test "quick-add creates a note about the record", %{conn: conn, comp: comp, contact: c} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#notes-panel-new") |> render_click()

    html =
      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "asks for 60 days"}})
      |> render_submit()

    assert html =~ "asks for 60 days"
    [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "panel hidden on the new-contact page", %{conn: conn, comp: comp} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/new")
    refute html =~ "notes-panel"
  end

  test "restricted notes are not shown to a clerk", %{admin: admin, comp: comp, contact: c} do
    note_fixture(comp, admin, %{"body" => "boss only", "subject_type" => "Contact", "subject_id" => c.id, "visibility" => ["manager"]})
    clerk = user_with_role(comp, admin, "clerk")
    {:ok, _lv, html} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    refute html =~ "boss only"
  end

  test "employee edit page has the panel", %{conn: conn, admin: admin, comp: comp} do
    emp = employee_fixture(%{}, comp, admin)
    note_fixture(comp, admin, %{"body" => "good welder", "subject_type" => "Employee", "subject_id" => emp.id})
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/employees/#{emp.id}/edit")
    assert html =~ "good welder"
  end
end
```

If `FullCircle.HRFixtures` is named differently, check `head -1 test/support/fixtures/hr_fixtures.ex` and adjust the import.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs`
Expected: FAIL — panel content missing.

- [ ] **Step 3: Implement the component**

`lib/full_circle_web/live/note_live/notes_panel_component.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.NotesPanelComponent do
  @moduledoc """
  Notes about, or linking to, one record. Rendered under a record's edit form
  and inside the index-page notes modal. Self-contained: all events target it.
  """
  use FullCircleWeb, :live_component

  import FullCircleWeb.NoteComponents

  alias FullCircle.Notes
  alias FullCircle.Notes.{Attachments, Note}

  # The host form re-renders on every keystroke (phx-change="validate"), which
  # calls update/2 each time. Only (re)load when the record changes, or the
  # panel would query per keystroke and wipe a half-typed quick-add.
  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:notify_parent, fn -> false end)
      |> assign_new(:adding, fn -> false end)

    key = {socket.assigns.record_type, socket.assigns.record_id}

    if socket.assigns[:loaded_for] == key do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(loaded_for: key, adding: false, form: to_form(Notes.change_note(%Note{})))
       |> load()}
    end
  end

  defp load(socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    rows = Notes.notes_for_record(t, id, com, user)

    assign(socket,
      rows: rows,
      editable: MapSet.new(for r <- rows, Notes.can_edit?(r.note, com, user), do: r.note.id),
      can_create: FullCircle.Authorization.can?(user, :create_note, com)
    )
  end

  @impl true
  def handle_event("new", _, socket), do: {:noreply, assign(socket, adding: true)}
  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, adding: false)}

  def handle_event("validate", %{"note" => params}, socket) do
    cs = %Note{} |> Notes.change_note(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs))}
  end

  def handle_event("save", %{"note" => params}, socket) do
    %{record_type: t, record_id: id, current_company: com, current_user: user} = socket.assigns
    attrs = Map.merge(params, %{"subject_type" => t, "subject_id" => id})

    case Notes.create_note(attrs, com, user) do
      {:ok, _note} ->
        if socket.assigns.notify_parent, do: send(self(), {:notes_changed, t, id})
        {:noreply, socket |> assign(adding: false, form: to_form(Notes.change_note(%Note{}))) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("attachment_uploaded", _, socket), do: {:noreply, load(socket)}

  def handle_event("remove_attachment", %{"id" => att_id}, socket) do
    att =
      socket.assigns.rows
      |> Enum.flat_map(& &1.note.attachments)
      |> Enum.find(&(&1.id == att_id))

    if att, do: Attachments.remove(att, socket.assigns.current_company, socket.assigns.current_user)
    {:noreply, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="mx-auto mt-3 rounded-lg border border-blue-300 bg-blue-50 p-3 dark:border-blue-700 dark:bg-blue-950"
    >
      <div class="flex items-center">
        <span class="font-semibold">📝 {gettext("Notes")} ({length(@rows)})</span>
        <span class="ml-auto flex gap-2">
          <button
            :if={@can_create and !@adding}
            id={"#{@id}-new"}
            type="button"
            phx-click="new"
            phx-target={@myself}
            class="blue button"
          >
            + {gettext("Note")}
          </button>
          <.link
            :if={@can_create}
            navigate={"/companies/#{@current_company.id}/notes/new?subject_type=#{@record_type}&subject_id=#{@record_id}"}
            class="text-sm text-blue-600 hover:font-bold dark:text-blue-400"
          >
            {gettext("Full form")}
          </.link>
        </span>
      </div>

      <.form
        :if={@adding}
        for={@form}
        id={"#{@id}-form"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="mt-2"
      >
        <.input field={@form[:body]} type="textarea" rows="3" placeholder={gettext("Write a note...")} />
        <div class="text-xs">
          {gettext("Readable by")} ({gettext("tick none for everyone")}):
          <input type="hidden" name="note[visibility][]" value="" />
          <label :for={role <- Note.visibility_roles()} class="mr-2 inline-flex items-center gap-1">
            <input type="checkbox" name="note[visibility][]" value={role} />{role}
          </label>
        </div>
        <div class="mt-1 flex gap-2">
          <.button>{gettext("Save")}</.button>
          <button type="button" phx-click="cancel" phx-target={@myself} class="orange button">
            {gettext("Cancel")}
          </button>
        </div>
        <p class="text-xs text-gray-500">{gettext("Attach files after saving.")}</p>
      </.form>

      <.note_card
        :for={r <- @rows}
        note={r.note}
        relation={r.relation}
        current_company={@current_company}
        can_edit={MapSet.member?(@editable, r.note.id)}
        target={@myself}
      />
      <p :if={@rows == []} class="text-sm text-gray-500">{gettext("No notes yet.")}</p>
    </div>
    """
  end
end
```

The `NoteAttach` hook calls `pushEventTo(this.el, …)`; the button lives inside this component, so the event reaches `handle_event("attachment_uploaded", …)` here.

- [ ] **Step 4: Embed in the two forms**

In `lib/full_circle_web/live/contact_live/form.ex`, immediately after the line `      </.form>` (~276) and before the closing `    </div>`, paste the embed snippet from **Interfaces** with `record_type="Contact"`.

In `lib/full_circle_web/live/employee_live/form.ex`, immediately after `      </.form>` (~578), paste the same snippet with `record_type="Employee"`. The employee form also has a `:copy` action — the `@live_action == :edit` guard excludes it.

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/contact_live_test.exs`
Expected: all pass (existing contact tests still green).

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle_web/live/note_live/notes_panel_component.ex lib/full_circle_web/live/contact_live/form.ex lib/full_circle_web/live/employee_live/form.ex test/full_circle_web/live/notes_panel_live_test.exs
git add lib/full_circle_web/live/note_live/notes_panel_component.ex lib/full_circle_web/live/contact_live/form.ex lib/full_circle_web/live/employee_live/form.ex test/full_circle_web/live/notes_panel_live_test.exs
git commit -m "feat(notes): notes panel with quick-add on contact and employee pages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Notes count + modal on Contact and Employee index pages

**Files:**
- Create: `lib/full_circle_web/live/note_live/notes_index.ex`
- Modify: `lib/full_circle_web/live/contact_live/index.ex`, `lib/full_circle_web/live/contact_live/index_component.ex`, `lib/full_circle_web/live/employee_live/index.ex`, `lib/full_circle_web/live/employee_live/index_component.ex`
- Test: `test/full_circle_web/live/notes_panel_live_test.exs`

**Interfaces:**
- Consumes: `Notes.count_by_records/4`, `NotesPanelComponent` (with `notify_parent`), `notes_count_badge/1`.
- Produces `FullCircleWeb.NoteLive.NotesIndex`:
  - `init(socket, record_type) :: socket` — assigns `notes_type`, `note_counts: %{}`, `notes_for: nil`
  - `count(socket, objects, reset?) :: socket` — merges visible counts for `Enum.map(objects, & &1.id)`
  - `open(socket, id) :: socket`, `close(socket) :: socket`
  - `changed(socket, id, row_module, stream_name \\ :objects) :: socket` — recounts one record and `send_update`s its row component (dom id `"#{stream_name}-#{id}"`)
  - `<NotesIndex.modal notes_for={@notes_for} notes_type={@notes_type} current_company={..} current_user={..} />`
- Each index LiveView adds three `handle_event`/`handle_info` clauses (shown below); each row component gets attr `note_count` and renders `<.notes_count_badge count={@note_count} id={@obj.id} />`.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle_web/live/notes_panel_live_test.exs`:

```elixir
  describe "index counts" do
    test "contact list shows visible counts and opens the modal", %{conn: conn, admin: admin, comp: comp, contact: c} do
      note_fixture(comp, admin, %{"body" => "pays late", "subject_type" => "Contact", "subject_id" => c.id})

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts")
      assert html =~ "📝 1"

      html = lv |> element("button[phx-click=open_notes][phx-value-id='#{c.id}']") |> render_click()
      assert html =~ "pays late"
    end

    test "count excludes notes a clerk cannot read", %{admin: admin, comp: comp, contact: c} do
      note_fixture(comp, admin, %{"subject_type" => "Contact", "subject_id" => c.id, "visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, _lv, html} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/contacts")
      refute html =~ "📝 1"
    end

    test "quick-add in the modal bumps the row count", %{conn: conn, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts")
      lv |> element("button[phx-click=open_notes][phx-value-id='#{c.id}']") |> render_click()
      lv |> element("#notes-modal-panel-new") |> render_click()
      lv |> form("#notes-modal-panel-form", %{"note" => %{"body" => "new one"}}) |> render_submit()
      assert render(lv) =~ "📝 1"
    end

    test "employee list shows counts", %{conn: conn, admin: admin, comp: comp} do
      emp = employee_fixture(%{}, comp, admin)
      note_fixture(comp, admin, %{"subject_type" => "Employee", "subject_id" => emp.id})
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/employees")
      assert html =~ "📝 1"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs`
Expected: FAIL — no badge.

- [ ] **Step 3: Implement the helper**

`lib/full_circle_web/live/note_live/notes_index.ex`:

```elixir
defmodule FullCircleWeb.NoteLive.NotesIndex do
  @moduledoc """
  Notes counts and the notes modal for a record index page. Counts are
  visibility-aware and fetched once per page load (see `Notes.count_by_records/4`).
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  import FullCircleWeb.CoreComponents, only: [modal: 1]

  alias FullCircle.Notes

  def init(socket, record_type) do
    assign(socket, notes_type: record_type, note_counts: %{}, notes_for: nil)
  end

  def count(socket, objects, reset?) do
    counts =
      Notes.count_by_records(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.notes_type,
        Enum.map(objects, & &1.id)
      )

    base = if reset?, do: %{}, else: socket.assigns.note_counts
    assign(socket, note_counts: Map.merge(base, counts))
  end

  def open(socket, id), do: assign(socket, notes_for: id)
  def close(socket), do: assign(socket, notes_for: nil)

  def changed(socket, id, row_module, stream_name \\ :objects) do
    socket = count(socket, [%{id: id}], false)
    n = Map.get(socket.assigns.note_counts, id, 0)
    Phoenix.LiveView.send_update(row_module, id: "#{stream_name}-#{id}", note_count: n)
    socket
  end

  attr :notes_for, :any, required: true
  attr :notes_type, :string, required: true
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  def modal(assigns) do
    ~H"""
    <.modal :if={@notes_for} id="notes-modal" show on_cancel={Phoenix.LiveView.JS.push("close_notes")}>
      <.live_component
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="notes-modal-panel"
        record_type={@notes_type}
        record_id={@notes_for}
        current_company={@current_company}
        current_user={@current_user}
        notify_parent={true}
      />
    </.modal>
    """
  end
end
```

- [ ] **Step 4: Wire the Contact index**

In `lib/full_circle_web/live/contact_live/index.ex`:

1. Add `alias FullCircleWeb.NoteLive.NotesIndex`.
2. In `mount/3`, pipe `|> NotesIndex.init("Contact")` after the `assign(page_title: …)`.
3. In `filter_objects/4`, before `|> stream(:objects, objects, reset: reset)`, add `|> NotesIndex.count(objects, reset)`.
4. In the `<.live_component … module={IndexComponent} …>` call inside `render/1`, add `note_count={Map.get(@note_counts, obj.id, 0)}`.
5. At the end of the `render/1` template (just before the final `</div>`), add:

```heex
      <NotesIndex.modal
        notes_for={@notes_for}
        notes_type={@notes_type}
        current_company={@current_company}
        current_user={@current_user}
      />
```

6. Add these clauses next to the other `handle_event/3` clauses:

```elixir
  @impl true
  def handle_event("open_notes", %{"id" => id}, socket), do: {:noreply, NotesIndex.open(socket, id)}
  def handle_event("close_notes", _, socket), do: {:noreply, NotesIndex.close(socket)}

  @impl true
  def handle_info({:notes_changed, _type, id}, socket),
    do: {:noreply, NotesIndex.changed(socket, id, IndexComponent)}
```

Keep all `handle_event/3` clauses contiguous and place `handle_info/2` after them. The index already marks `handle_event/3` with `@impl true`, so drop the `@impl true` line above the new `handle_event` clauses; keep the one above `handle_info/2` unless the module already defines `handle_info/2`.

In `lib/full_circle_web/live/contact_live/index_component.ex`:

1. Add `import FullCircleWeb.NoteComponents, only: [notes_count_badge: 1]`.
2. In `update/2` keep `assign(assigns)` (it merges, so `send_update` with only `note_count` keeps `obj`) and add `|> assign_new(:note_count, fn -> 0 end)`.
3. In `render/1`, right after the contact name link's closing `</.link>`, add `<.notes_count_badge count={@note_count} id={@obj.id} />`.

- [ ] **Step 5: Wire the Employee index**

Apply the same six index edits to `lib/full_circle_web/live/employee_live/index.ex` with `NotesIndex.init("Employee")`, and the three row edits to `lib/full_circle_web/live/employee_live/index_component.ex` (badge placed next to the employee name link). If the employee index's stream is not named `:objects` or its fetch function is not `filter_objects/4`, find the `stream(` call (`grep -n "stream(" lib/full_circle_web/live/employee_live/index.ex`) and put `NotesIndex.count(objects, reset)` right before it; pass the stream name as the 4th argument of `NotesIndex.changed/4`.

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs test/full_circle_web/live/contact_live_test.exs`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
mix format lib/full_circle_web/live/note_live/notes_index.ex lib/full_circle_web/live/contact_live/index.ex lib/full_circle_web/live/contact_live/index_component.ex lib/full_circle_web/live/employee_live/index.ex lib/full_circle_web/live/employee_live/index_component.ex test/full_circle_web/live/notes_panel_live_test.exs
git add lib/full_circle_web/live/note_live/notes_index.ex lib/full_circle_web/live/contact_live lib/full_circle_web/live/employee_live test/full_circle_web/live/notes_panel_live_test.exs
git commit -m "feat(notes): visibility-aware notes counts and modal on contact/employee lists

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Roll the panel and counts out to Good and the 9 document types

**Files (form / index / row component per type):**

| Type | Form (panel goes after `</.form>`) | Index LiveView | Row component |
|---|---|---|---|
| Good | `goods_live/form.ex` (~528) | `goods_live/index.ex` | `goods_live/index_component.ex` |
| Invoice | `invoice_live/form.ex` (~1161) | `invoice_live/index.ex` | `invoice_live/index_component.ex` |
| PurInvoice | `pur_invoice_live/form.ex` (~1327) | `pur_invoice_live/index.ex` | `pur_invoice_live/index_component.ex` |
| Receipt | `receipt_live/form.ex` (~1046) | `receipt_live/index.ex` | `receipt_live/index_component.ex` |
| Payment | `payment_live/form.ex` (~919) | `payment_live/index.ex` | `payment_live/index_component.ex` |
| CreditNote | `credit_note_live/form.ex` (~580) | `credit_note_live/index.ex` | `credit_note_live/index_component.ex` |
| DebitNote | `debit_note_live/form.ex` (~630) | `debit_note_live/index.ex` | `debit_note_live/index_component.ex` |
| Journal | `journal_live/form.ex` (~367) | `journal_live/index.ex` | `journal_live/index_component.ex` |
| Deposit | `cheque_live/deposit_form.ex` (~386) | `cheque_live/deposit_index.ex` | `cheque_live/deposit_index_component.ex` |
| ReturnCheque | `cheque_live/return_cheque_form.ex` (~335) | `cheque_live/return_cheque_index.ex` | `cheque_live/return_cheque_index_component.ex` |

(all paths under `lib/full_circle_web/live/`)

**Interfaces:**
- Consumes: `NotesPanelComponent`, `NotesIndex`, `notes_count_badge/1` exactly as in Tasks 14–15.

- [ ] **Step 1: Write the failing smoke test**

Append to `test/full_circle_web/live/notes_panel_live_test.exs`:

```elixir
  describe "rollout" do
    test "invoice edit page shows the panel and the invoice list shows counts", %{conn: conn, admin: admin, comp: comp} do
      inv = invoice_fixture(comp, admin)
      note_fixture(comp, admin, %{"body" => "customer disputes line 2", "subject_type" => "Invoice", "subject_id" => inv.id})

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/Invoice/#{inv.id}/edit")
      assert html =~ "customer disputes line 2"

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/Invoice")
      assert html =~ "📝 1"
    end

    test "every covered page renders with the panel or badge", %{conn: conn, comp: comp} do
      for path <- ~w(goods Invoice PurInvoice Receipt Payment CreditNote DebitNote Journal Deposit ReturnCheque) do
        {:ok, _lv, html} = live(conn, "/companies/#{comp.id}/#{path}")
        assert is_binary(html), "#{path} index failed to render"
      end
    end
  end
```

(The second test only proves the index pages still mount after the edits; the panel on each form is exercised by the manual check in Step 4.)

- [ ] **Step 2: Run to verify the invoice test fails**

Run: `mix test test/full_circle_web/live/notes_panel_live_test.exs`
Expected: the invoice test FAILS (no panel / no badge); the smoke test passes.

- [ ] **Step 3: Apply the edits for each row of the table**

For **each** type in the table:

a. **Form** — after the form's `      </.form>` line, paste (set `record_type` to the type from the table):

```heex
      <.live_component
        :if={@live_action == :edit and @id != "new"}
        module={FullCircleWeb.NoteLive.NotesPanelComponent}
        id="notes-panel"
        record_type="Invoice"
        record_id={@id}
        current_company={@current_company}
        current_user={@current_user}
      />
```

`:match`/`:unmatch` (e-invoice) and `:copy` actions are excluded by the `:edit` guard on purpose.

b. **Index LiveView** — the six edits from Task 15 Step 4 with `NotesIndex.init("<Type>")`: alias, init in mount, `NotesIndex.count(objects, reset)` before the `stream(` call, `note_count={Map.get(@note_counts, obj.id, 0)}` on the row `live_component`, the `<NotesIndex.modal …/>` at the end of the template, and the `open_notes`/`close_notes`/`:notes_changed` clauses. If the index names its stream differently or batches rows another way, put the `count` call right before its `stream(` call and pass the stream name to `NotesIndex.changed/4`. If an index already defines `handle_info/2`, add the `:notes_changed` clause next to it.

c. **Row component** — import `notes_count_badge`, add `assign_new(:note_count, fn -> 0 end)` in `update/2`, render `<.notes_count_badge count={@note_count} id={@obj.id} />` next to the document-number link.

If a page does not fit (e.g. its index rows are not keyed by the document id, or the form has no single `</.form>` at the page level), **do not skip silently** — list it under "Pages not covered" in the commit message and in `.claude/skills/notes.md` (Task 17).

- [ ] **Step 4: Run tests and click through**

Run: `mix test test/full_circle_web/live/`
Expected: all pass.

Then `mix phx.server`, log in, and for each of the 10 types open one existing record's edit page (panel visible under the form, quick-add works, attach a photo) and its index (badge visible, modal opens). Check once in dark theme.

- [ ] **Step 5: Commit**

```bash
mix format $(git diff --name-only -- lib/full_circle_web/live) test/full_circle_web/live/notes_panel_live_test.exs
git add lib/full_circle_web/live test/full_circle_web/live/notes_panel_live_test.exs
git commit -m "feat(notes): notes panel and counts on goods and posted documents

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: Translations, skill, final verification

**Files:**
- Modify: `priv/gettext/default.pot`, `priv/gettext/zh/LC_MESSAGES/default.po`, `CLAUDE.md`
- Create: `.claude/skills/notes.md`

- [ ] **Step 1: Extract and translate strings**

Run: `mix gettext.extract --merge`

Open `priv/gettext/zh/LC_MESSAGES/default.po` and fill every empty `msgstr` for the new strings. Core vocabulary: Notes 备注, Note 备注, New Note 新备注, Edit Note 编辑备注, Everyone 所有人, Who can read this note 谁可以查看此备注, Attach file 附加文件, Links 链接, Notes linking here 链接到此的备注, History 历史记录, Version 版本, replaced by 被替换者, Full form 完整表单, Written by me 我写的, About 关于, Restricted record 受限记录, deleted 已删除, No notes yet. 暂无备注。 Translate the rest in the same register as existing entries. Do not touch unrelated entries.

- [ ] **Step 2: Write the project skill**

`.claude/skills/notes.md`:

```markdown
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
a hidden `""` so unticked groups still submit — `Notes.normalize/1` turns
`["", ...]` into the list or nil.

## Versions
`update_note/4` snapshots the *current DB row* into `note_versions`, then
updates the *struct the editor loaded* with `optimistic_lock` — the loaded
`lock_version` is what detects a concurrent save (`{:error, :stale}`). No-op
edits return early and write no version. Delete is soft and also snapshots.

## Linkable
References are `(type, id)` with no FK. `Linkable` is the whitelist and scopes
every resolve to the company; foreign ids are `:not_found`, types the user may
not view are `:restricted`. Documents resolve through `transactions` using the
command palette's per-type `update_*` permission.

### Adding a linkable type
1. Entry in `@records` (table with `company_id` + title column) or add it to
   `CommandPalette.Types.type_specs` if it is a posted document.
2. `type_label/1` clause in `NoteComponents` (gettext).
3. Panel snippet after `</.form>` in its edit LiveView (`:edit` guard).
4. `NotesIndex` six edits in its index + badge in its row component.

## Attachments
Plain HTTP (`NoteAttachmentController`), never LiveView uploads — phones lose
socket uploads when the camera backgrounds the page. Type sniffed from magic
bytes; removal hides but keeps the file (history may refer to it).

## Counts
`Notes.count_by_records/4` = notes about ∪ notes linking, each note once,
visibility applied, two queries per page. Rows update via `send_update` with
only `note_count` — row components must `assign(assigns)` (merge), not replace.

## Pages not covered
(list any page Task 16 could not wire, or "none")
```

- [ ] **Step 3: Update CLAUDE.md**

Confirm Task 1's edits are present (`Notes` / `Linkable` row, `notes.md` in the skills list). Add under **Key Conventions**:

```markdown
- Notes (company memory) are read only through `Notes.visible_to/3`; see `.claude/skills/notes.md`
```

- [ ] **Step 4: Full verification**

Run: `mix compile --warnings-as-errors && mix test`
Expected: 0 failures. Record the new test count in the commit message.

Run: `git status --short`
Expected: only the files of this task.

- [ ] **Step 5: Commit**

```bash
git add priv/gettext .claude/skills/notes.md CLAUDE.md
git commit -m "docs(notes): zh translations, notes skill, CLAUDE.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Notes for the executor

- Task 4 introduces a stub `FullCircle.Notes`; Task 5 replaces the whole file. Do not keep both definitions.
- The spec's author filter is implemented as "Written by me"; a full author dropdown needs `:see_user_list`, which most roles lack. The date range filter is implemented.
- Adding `newnote` to the palette's `@create_specs` gives the palette a hit with `doc_type: "Note"`. Task 11's palette test run covers the search side; also open the palette in the browser once, type `newnote`, and confirm it navigates to `/notes/new`.
