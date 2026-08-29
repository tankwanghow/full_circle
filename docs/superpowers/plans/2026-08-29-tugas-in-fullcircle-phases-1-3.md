# Tugas-in-FullCircle (Phases 1–3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Tugas duty subsystem inside FullCircle — recurring duties with progress events and evidence uploads, and bidirectional duty↔Payment linking — ending at the first demo: complete a tax payment from a duty and see the bank-in slip on the Payment page.

**Architecture:** New `FullCircle.Tugas` context (4 tables: duties, duty_events, duty_event_documents, duty_documents) following FC's existing patterns: `FullCircle.Schema` UUID PKs, `Sys.user_company/2` scoping, `can?/3` allow-lists, `Ecto.Multi` mutations with `Sys.log_changeset/5` audit logs, `StdInterface` similarity search. LiveViews under `FullCircleWeb.TugasLive.*`; Payment linking rides the existing `mount_new`-clause + `create_payment_multi` extension points.

**Tech Stack:** Elixir 1.19.5, Phoenix 1.8.3, Phoenix LiveView 1.1.x, Ecto/PostgreSQL, Tailwind 3.4 (no daisyUI).

**Spec:** `docs/superpowers/specs/2026-08-28-tugas-in-fullcircle-design.md` — this plan covers spec phases 1–3. Phase 4 (todos, incl. the `todos` table) and phase 5 (mobile shell + `tasker` hardening) get their own plans later; the `tasker` role is NOT added to `Authorization.roles/0` in this plan.

## Global Constraints

- Work happens in the `full_circle/` nested git repo; commit directly on `master` (solo workflow, no branches).
- Every authorization clause added is an **allow-list** (`allow_roles`) — never `forbid_roles` (spec §6).
- `tasker` appears in NO role list in this plan (spec: not assignable until phase 5).
- All user-facing strings wrapped in `gettext(...)`.
- Schemas `use FullCircle.Schema` (binary_id PKs) with `timestamps(type: :utc_datetime)`; migrations use `timestamps(type: :timestamptz)`.
- Evidence file paths: `<uploads_dir>/<company_id>/tugas/<duty_id>/<event_id>/<uuid><ext>`; accepted types `.jpg .jpeg .png .webp .pdf`; max 10 MB (matches `UploadFileLive`'s `max_file_size: 10_000_000`). Files are NEVER served as public static paths.
- Every upload form MUST bind `phx-change` on the `<.form>` (skill `.claude/skills/liveview-upload-gotchas.md`) — LiveViewTest stays green even when this is missing, so tests must assert the binding exists in rendered HTML.
- Avoid the word "Recurring" in module/table names (`FullCircle.HR.Recurring` is unrelated payroll salary recurrence).
- Before each commit: `mix test <files touched>` green, then `mix credo` clean on changed files.
- Test DB config already sets `uploads_dir: System.tmp_dir!()` (config/test.exs:33) — file tests need no extra config.

---

### Task 1: Migration + Duty schema

**Files:**
- Create: `priv/repo/migrations/20260829090000_create_tugas_tables.exs`
- Create: `lib/full_circle/tugas/duty.ex`
- Test: `test/full_circle/tugas/duty_test.exs`

**Interfaces:**
- Consumes: `FullCircle.Schema`, `FullCircle.Sys.Company`
- Produces: tables `duties`, `duty_events`, `duty_event_documents`, `duty_documents` (all four created here; schema modules for the other three come in Task 2). `FullCircle.Tugas.Duty` with `changeset/2`; statuses `"active" | "done" | "skipped"`; recur units `"day" | "week" | "month" | "year"`; partial unique index named `:duties_one_live_cycle`.

- [ ] **Step 1: Write the migration**

```elixir
defmodule FullCircle.Repo.Migrations.CreateTugasTables do
  use Ecto.Migration

  def change do
    create table(:duties, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false
      add :title, :string, null: false
      add :descriptions, :text
      add :due_date, :date, null: false
      # "active" | "done" | "skipped"
      add :status, :string, null: false, default: "active"
      # same for every cycle of a recurring duty; each one-off gets its own
      add :series_id, :binary_id, null: false
      # set by end-series; stops spawning
      add :series_ended_at, :timestamptz
      # "day" | "week" | "month" | "year"; nil = one-off
      add :recur_unit, :string
      add :recur_every, :integer

      timestamps(type: :timestamptz)
    end

    create index(:duties, [:company_id, :status, :due_date])

    # Invariant: one live cycle per series — makes double-submit spawning impossible
    create unique_index(:duties, [:series_id],
             where: "status = 'active'",
             name: :duties_one_live_cycle
           )

    create table(:duty_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false
      add :duty_id, references(:duties, type: :binary_id, on_delete: :delete_all), null: false
      # "progress" | "done" | "skip" | "linked" | "unlinked" | "end_series"
      add :action, :string, null: false
      add :note, :text
      add :user_id, references(:users, type: :binary_id), null: false

      timestamps(type: :timestamptz)
    end

    create index(:duty_events, [:duty_id])

    create table(:duty_event_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false
      add :duty_event_id, references(:duty_events, type: :binary_id, on_delete: :delete_all),
        null: false
      add :orig_filename, :string, null: false
      add :file_path, :string, null: false
      add :content_type, :string, null: false
      add :size, :integer, null: false

      timestamps(type: :timestamptz)
    end

    create index(:duty_event_documents, [:duty_event_id])

    create table(:duty_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false
      add :duty_id, references(:duties, type: :binary_id, on_delete: :delete_all), null: false
      # FC's doc_type convention, e.g. "Payment"; doc_id has NO db-level FK
      add :doc_type, :string, null: false
      add :doc_id, :binary_id, null: false
      # denormalized for display, e.g. "PV-001234"
      add :doc_no, :string, null: false
      add :user_id, references(:users, type: :binary_id), null: false

      timestamps(type: :timestamptz)
    end

    create unique_index(:duty_documents, [:duty_id, :doc_type, :doc_id])
    create index(:duty_documents, [:company_id, :doc_type, :doc_id])
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: all four tables created without error.

- [ ] **Step 3: Write the failing schema tests**

```elixir
defmodule FullCircle.Tugas.DutyTest do
  use FullCircle.DataCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Tugas.Duty

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  defp valid_attrs(company, attrs \\ %{}) do
    Map.merge(
      %{
        "company_id" => company.id,
        "title" => "Pay monthly taxes",
        "due_date" => "2026-09-15"
      },
      attrs
    )
  end

  test "valid changeset autogenerates series_id and defaults status active", %{company: com} do
    cs = Duty.changeset(%Duty{}, valid_attrs(com))
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :series_id)
    assert Ecto.Changeset.get_field(cs, :status) == "active"
  end

  test "title, due_date, company_id are required", %{company: com} do
    cs = Duty.changeset(%Duty{}, %{})
    refute cs.valid?
    assert %{title: _, due_date: _, company_id: _} = errors_on(cs)
    assert cs |> Duty.changeset(valid_attrs(com)) |> Map.fetch!(:valid?)
  end

  test "recur_unit and recur_every must come together", %{company: com} do
    cs = Duty.changeset(%Duty{}, valid_attrs(com, %{"recur_unit" => "month"}))
    refute cs.valid?
    assert %{recur_every: _} = errors_on(cs)

    cs = Duty.changeset(%Duty{}, valid_attrs(com, %{"recur_every" => "2"}))
    refute cs.valid?
    assert %{recur_unit: _} = errors_on(cs)

    cs = Duty.changeset(%Duty{}, valid_attrs(com, %{"recur_unit" => "month", "recur_every" => "2"}))
    assert cs.valid?
  end

  test "recur_unit must be a known unit, recur_every positive", %{company: com} do
    cs = Duty.changeset(%Duty{}, valid_attrs(com, %{"recur_unit" => "quarter", "recur_every" => "1"}))
    refute cs.valid?

    cs = Duty.changeset(%Duty{}, valid_attrs(com, %{"recur_unit" => "month", "recur_every" => "0"}))
    refute cs.valid?
  end

  test "one live cycle per series (partial unique index)", %{company: com} do
    series = Ecto.UUID.generate()
    attrs = valid_attrs(com, %{"series_id" => series})

    assert {:ok, _} = %Duty{} |> Duty.changeset(attrs) |> Repo.insert()
    assert {:error, cs} = %Duty{} |> Duty.changeset(attrs) |> Repo.insert()
    assert %{series_id: _} = errors_on(cs)

    # a closed cycle in the same series is fine
    assert {:ok, _} =
             %Duty{} |> Duty.changeset(Map.put(attrs, "status", "done")) |> Repo.insert()
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas/duty_test.exs`
Expected: FAIL — `FullCircle.Tugas.Duty` is not available.

- [ ] **Step 5: Write the Duty schema**

```elixir
defmodule FullCircle.Tugas.Duty do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "duties" do
    field :title, :string
    field :descriptions, :string
    field :due_date, :date
    field :status, :string, default: "active"
    field :series_id, Ecto.UUID
    field :series_ended_at, :utc_datetime
    field :recur_unit, :string
    field :recur_every, :integer

    belongs_to :company, FullCircle.Sys.Company
    has_many :duty_events, FullCircle.Tugas.DutyEvent
    has_many :duty_documents, FullCircle.Tugas.DutyDocument

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(active done skipped)
  @recur_units ~w(day week month year)

  def statuses, do: @statuses
  def recur_units, do: @recur_units

  def changeset(duty, attrs) do
    duty
    |> cast(attrs, [
      :company_id,
      :title,
      :descriptions,
      :due_date,
      :status,
      :series_id,
      :series_ended_at,
      :recur_unit,
      :recur_every
    ])
    |> ensure_series_id()
    |> validate_required([:company_id, :title, :due_date, :status, :series_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:recur_unit, @recur_units)
    |> validate_number(:recur_every, greater_than: 0)
    |> validate_recurrence_pair()
    |> foreign_key_constraint(:company_id)
    |> unique_constraint(:series_id,
      name: :duties_one_live_cycle,
      message: "this series already has a live cycle"
    )
  end

  defp ensure_series_id(cs) do
    if get_field(cs, :series_id), do: cs, else: put_change(cs, :series_id, Ecto.UUID.generate())
  end

  # recurrence is stored as unit x every (e.g. every 2 months for SST) —
  # both set or both blank; blank = one-off duty
  defp validate_recurrence_pair(cs) do
    unit = get_field(cs, :recur_unit)
    every = get_field(cs, :recur_every)

    cond do
      is_nil(unit) and is_nil(every) -> cs
      is_nil(unit) -> add_error(cs, :recur_unit, "required when recur_every is set")
      is_nil(every) -> add_error(cs, :recur_every, "required when recur_unit is set")
      true -> cs
    end
  end
end
```

Note: the comment on `has_many :duty_events` / `:duty_documents` referencing Task 2 modules — the modules don't exist yet, but `has_many` only resolves the module at runtime use, so this compiles. If `mix compile --warnings-as-errors` complains, create empty stub modules in Task 1 and fill them in Task 2; otherwise leave to Task 2.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas/duty_test.exs`
Expected: PASS (all 5 tests). If the `has_many` targets break compilation, add minimal stubs (see Step 5 note) and re-run.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20260829090000_create_tugas_tables.exs \
        lib/full_circle/tugas/duty.ex test/full_circle/tugas/duty_test.exs
git commit -m "feat(tugas): duties data model with one-live-cycle-per-series invariant"
```

---

### Task 2: DutyEvent, DutyEventDocument, DutyDocument schemas

**Files:**
- Create: `lib/full_circle/tugas/duty_event.ex`
- Create: `lib/full_circle/tugas/duty_event_document.ex`
- Create: `lib/full_circle/tugas/duty_document.ex`
- Test: `test/full_circle/tugas/duty_event_test.exs`

**Interfaces:**
- Consumes: tables from Task 1; `FullCircle.Tugas.Duty`.
- Produces: `FullCircle.Tugas.DutyEvent` (`changeset/2`, actions `"progress" | "done" | "skip" | "linked" | "unlinked" | "end_series"`), `FullCircle.Tugas.DutyEventDocument` (`changeset/2`), `FullCircle.Tugas.DutyDocument` (`changeset/2`, unique constraint name `:duty_documents_duty_id_doc_type_doc_id_index`).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule FullCircle.Tugas.DutyEventTest do
  use FullCircle.DataCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Tugas.{Duty, DutyEvent, DutyEventDocument, DutyDocument}

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})

    {:ok, duty} =
      %Duty{}
      |> Duty.changeset(%{
        "company_id" => company.id,
        "title" => "Pay monthly taxes",
        "due_date" => "2026-09-15"
      })
      |> Repo.insert()

    %{admin: admin, company: company, duty: duty}
  end

  test "duty_event requires duty, action, user; action must be known", ctx do
    cs = DutyEvent.changeset(%DutyEvent{}, %{})
    refute cs.valid?
    assert %{duty_id: _, action: _, user_id: _, company_id: _} = errors_on(cs)

    cs =
      DutyEvent.changeset(%DutyEvent{}, %{
        "company_id" => ctx.company.id,
        "duty_id" => ctx.duty.id,
        "action" => "sideways",
        "user_id" => ctx.admin.id
      })

    refute cs.valid?

    cs =
      DutyEvent.changeset(%DutyEvent{}, %{
        "company_id" => ctx.company.id,
        "duty_id" => ctx.duty.id,
        "action" => "progress",
        "note" => "printed the payment slip",
        "user_id" => ctx.admin.id
      })

    assert cs.valid?
    assert {:ok, _} = Repo.insert(cs)
  end

  test "duty_event_document requires its event and file columns", ctx do
    {:ok, event} =
      %DutyEvent{}
      |> DutyEvent.changeset(%{
        "company_id" => ctx.company.id,
        "duty_id" => ctx.duty.id,
        "action" => "done",
        "user_id" => ctx.admin.id
      })
      |> Repo.insert()

    cs = DutyEventDocument.changeset(%DutyEventDocument{}, %{})
    refute cs.valid?

    cs =
      DutyEventDocument.changeset(%DutyEventDocument{}, %{
        "company_id" => ctx.company.id,
        "duty_event_id" => event.id,
        "orig_filename" => "bank-in-slip.jpg",
        "file_path" => "/tmp/whatever/abc.jpg",
        "content_type" => "image/jpeg",
        "size" => 123_456
      })

    assert cs.valid?
    assert {:ok, _} = Repo.insert(cs)
  end

  test "duty_document unique on (duty_id, doc_type, doc_id)", ctx do
    attrs = %{
      "company_id" => ctx.company.id,
      "duty_id" => ctx.duty.id,
      "doc_type" => "Payment",
      "doc_id" => Ecto.UUID.generate(),
      "doc_no" => "PV-000001",
      "user_id" => ctx.admin.id
    }

    assert {:ok, _} = %DutyDocument{} |> DutyDocument.changeset(attrs) |> Repo.insert()
    assert {:error, cs} = %DutyDocument{} |> DutyDocument.changeset(attrs) |> Repo.insert()
    assert %{doc_id: _} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas/duty_event_test.exs`
Expected: FAIL — modules not available.

- [ ] **Step 3: Write the three schemas**

```elixir
defmodule FullCircle.Tugas.DutyEvent do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "duty_events" do
    field :action, :string
    field :note, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :duty, FullCircle.Tugas.Duty
    belongs_to :user, FullCircle.UserAccounts.User
    has_many :duty_event_documents, FullCircle.Tugas.DutyEventDocument

    timestamps(type: :utc_datetime)
  end

  @actions ~w(progress done skip linked unlinked end_series)

  def actions, do: @actions

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:company_id, :duty_id, :action, :note, :user_id])
    |> validate_required([:company_id, :duty_id, :action, :user_id])
    |> validate_inclusion(:action, @actions)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:duty_id)
    |> foreign_key_constraint(:user_id)
  end
end
```

```elixir
defmodule FullCircle.Tugas.DutyEventDocument do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "duty_event_documents" do
    field :orig_filename, :string
    field :file_path, :string
    field :content_type, :string
    field :size, :integer

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :duty_event, FullCircle.Tugas.DutyEvent

    timestamps(type: :utc_datetime)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [:company_id, :duty_event_id, :orig_filename, :file_path, :content_type, :size])
    |> validate_required([
      :company_id,
      :duty_event_id,
      :orig_filename,
      :file_path,
      :content_type,
      :size
    ])
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:duty_event_id)
  end
end
```

```elixir
defmodule FullCircle.Tugas.DutyDocument do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "duty_documents" do
    field :doc_type, :string
    # no DB-level FK — the whitelist's delete-path rule (spec §4) covers dangling links
    field :doc_id, Ecto.UUID
    field :doc_no, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :duty, FullCircle.Tugas.Duty
    belongs_to :user, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:company_id, :duty_id, :doc_type, :doc_id, :doc_no, :user_id])
    |> validate_required([:company_id, :duty_id, :doc_type, :doc_id, :doc_no, :user_id])
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:duty_id)
    |> unique_constraint(:doc_id, name: :duty_documents_duty_id_doc_type_doc_id_index)
  end
end
```

Check the actual User module name with `grep -rn "defmodule FullCircle.UserAccounts.User" lib/` — if it differs (e.g. `FullCircle.UserAccounts.User` vs another namespace), use the real one everywhere this plan says `FullCircle.UserAccounts.User`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas/`
Expected: PASS (Tasks 1+2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tugas/ test/full_circle/tugas/duty_event_test.exs
git commit -m "feat(tugas): duty_events, evidence documents and duty_documents schemas"
```

---

### Task 3: Authorization clauses

**Files:**
- Modify: `lib/full_circle/authorization.ex` (add clauses BEFORE the catch-all/fallback clauses at the bottom of `can?/3`; keep them in one commented block)
- Test: `test/full_circle/tugas_test.exs` (new file — grows through Tasks 4–6, 11)

**Interfaces:**
- Produces `can?/3` for: `:view_tugas`, `:create_duty`, `:update_duty`, `:add_duty_event`, `:complete_duty`, `:skip_duty`, `:upload_duty_evidence`, `:link_duty_document`, `:end_duty_series`, `:correct_others_event`, `:delete_others_evidence`, `:unlink_duty_document`.
- Note: `:link_duty_document` gates the **link-existing pickers** (Task 13). Linking at document-create time is governed by the document's own permission (e.g. `:create_payment`) and performs no separate check (spec §6).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule FullCircle.TugasTest do
  use FullCircle.DataCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  describe "tugas authorization" do
    test_authorise_to(:view_tugas, ["admin", "manager", "supervisor", "clerk", "cashier", "auditor"])
    test_authorise_to(:create_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:update_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:add_duty_event, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:complete_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:skip_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:upload_duty_evidence, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:link_duty_document, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:end_duty_series, ["admin", "manager", "supervisor"])
    test_authorise_to(:correct_others_event, ["admin", "manager", "supervisor"])
    test_authorise_to(:delete_others_evidence, ["admin", "manager", "supervisor"])
    test_authorise_to(:unlink_duty_document, ["admin", "manager", "supervisor"])
  end
end
```

(The `test_authorise_to/2` macro from `FullCircle.DataCase` asserts listed roles pass AND every other role in `Authorization.roles/0` is denied — this is what keeps these clauses honest as allow-lists.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: FAIL — every unlisted action falls through to `can?`'s default (denied for the allowed roles).

- [ ] **Step 3: Add the clauses to Authorization**

Insert near the other feature blocks (style: one clause per action, matching the file's existing formatting):

```elixir
  # --- Tugas (spec: docs/superpowers/specs/2026-08-28-tugas-in-fullcircle-design.md §6)
  # All allow-lists. tasker joins these lists in phase 5 only.

  def can?(user, :view_tugas, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier auditor), company, user)

  def can?(user, :create_duty, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :update_duty, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :add_duty_event, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :complete_duty, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :skip_duty, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :upload_duty_evidence, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :link_duty_document, company),
    do: allow_roles(~w(admin manager supervisor clerk cashier), company, user)

  def can?(user, :end_duty_series, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :correct_others_event, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :delete_others_evidence, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :unlink_duty_document, company),
    do: allow_roles(~w(admin manager supervisor), company, user)
```

Placement: `can?/3` is pattern-matched top-to-bottom — put this block anywhere before a generic fallback clause (check the end of the `can?` clauses for a catch-all; if none exists, placement among the other blocks is free).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/authorization.ex test/full_circle/tugas_test.exs
git commit -m "feat(tugas): authorization allow-lists for duty actions"
```

---

### Task 4: Tugas context — duty CRUD and listing

**Files:**
- Create: `lib/full_circle/tugas.ex`
- Test: `test/full_circle/tugas_test.exs` (extend)

**Interfaces:**
- Consumes: `StdInterface.create/6`, `StdInterface.update/7`, `StdInterface.filter/5` (the query-taking variant), `Sys.user_company/2`, Task 3 clauses.
- Produces:
  - `create_duty(attrs, com, user)` → `{:ok, %Duty{}}` | `{:error, op, changeset, _}` | `:not_authorise`
  - `update_duty(%Duty{}, attrs, com, user)` → same, plus `{:error, :not_live}` when `duty.status != "active"`
  - `get_duty!(id, com, user)` → `%Duty{}` preloaded: `duty_events` (newest first, each with `:user` and `:duty_event_documents`) and `duty_documents`
  - `filter_duties(terms, status, com, user, page: p, per_page: n)` → `[%Duty{}]`; `status` in `"active" | "done" | "skipped" | "all"`; default order: live cycles first by due_date asc (overdue on top), then closed by updated_at desc

- [ ] **Step 1: Write the failing tests (append to `test/full_circle/tugas_test.exs`)**

```elixir
  alias FullCircle.Tugas
  alias FullCircle.Tugas.Duty

  defp duty_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "title" => "Pay monthly taxes",
        "descriptions" => "IRB counter before 15th",
        "due_date" => "2026-09-15",
        "recur_unit" => "month",
        "recur_every" => "1"
      },
      attrs
    )
  end

  describe "duty CRUD" do
    test "create_duty inserts with audit log", %{admin: admin, company: com} do
      assert {:ok, %Duty{} = duty} = Tugas.create_duty(duty_attrs(), com, admin)
      assert duty.status == "active"
      assert duty.series_id

      assert [log] = FullCircle.Sys.log_entry_for("duties", duty.id, com.id)
      assert log.action == "create_duty"
    end

    test "create_duty denies unauthorised roles", %{admin: admin, company: com} do
      auditor = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, auditor, "auditor", admin)
      assert :not_authorise = Tugas.create_duty(duty_attrs(), com, auditor)
    end

    test "update_duty edits a live cycle, refuses a closed one", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)

      assert {:ok, %Duty{title: "Pay SST"}} =
               Tugas.update_duty(duty, %{"title" => "Pay SST"}, com, admin)

      closed = duty |> Ecto.Changeset.change(status: "done") |> Repo.update!()
      assert {:error, :not_live} = Tugas.update_duty(closed, %{"title" => "X"}, com, admin)
    end

    test "get_duty! scopes to the company", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      assert %Duty{} = Tugas.get_duty!(duty.id, com, admin)

      other_admin = user_fixture()
      other_com = company_fixture(other_admin, %{})

      assert_raise Ecto.NoResultsError, fn ->
        Tugas.get_duty!(duty.id, other_com, other_admin)
      end
    end
  end

  describe "filter_duties/5" do
    test "live cycles first by due_date, closed after; status filter works", %{
      admin: admin,
      company: com
    } do
      {:ok, late} = Tugas.create_duty(duty_attrs(%{"title" => "Late", "due_date" => "2026-01-01"}), com, admin)
      {:ok, soon} = Tugas.create_duty(duty_attrs(%{"title" => "Soon", "due_date" => "2026-12-01"}), com, admin)
      {:ok, closed} = Tugas.create_duty(duty_attrs(%{"title" => "Closed"}), com, admin)
      closed |> Ecto.Changeset.change(status: "done") |> Repo.update!()

      titles =
        Tugas.filter_duties("", "all", com, admin, page: 1, per_page: 10)
        |> Enum.map(& &1.title)

      assert titles == ["Late", "Soon", "Closed"]

      assert ["Closed"] =
               Tugas.filter_duties("", "done", com, admin, page: 1, per_page: 10)
               |> Enum.map(& &1.title)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: FAIL — `FullCircle.Tugas` not available.

- [ ] **Step 3: Write the context**

```elixir
defmodule FullCircle.Tugas do
  @moduledoc """
  Duties with progress events, evidence uploads and duty<->document links.
  Spec: docs/superpowers/specs/2026-08-28-tugas-in-fullcircle-design.md
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{Repo, StdInterface, Sys}
  alias FullCircle.Tugas.{Duty, DutyEvent, DutyEventDocument, DutyDocument}

  # --- duties -------------------------------------------------------------

  def create_duty(attrs, com, user) do
    StdInterface.create(Duty, "duty", attrs, com, user)
  end

  def update_duty(%Duty{status: "active"} = duty, attrs, com, user) do
    StdInterface.update(Duty, "duty", duty, attrs, com, user)
  end

  def update_duty(%Duty{}, _attrs, _com, _user), do: {:error, :not_live}

  def get_duty!(id, com, user) do
    events_query = from(e in DutyEvent, order_by: [desc: e.inserted_at])

    from(d in duty_query(com, user), where: d.id == ^id)
    |> Repo.one!()
    |> Repo.preload([
      [duty_events: {events_query, [:user, :duty_event_documents]}],
      :duty_documents
    ])
  end

  def filter_duties(terms, status, com, user, page: page, per_page: per_page) do
    duty_query(com, user)
    |> filter_status(status)
    |> order_by([d],
      asc: fragment("CASE WHEN ? = 'active' THEN 0 ELSE 1 END", d.status),
      asc: d.due_date,
      desc: d.updated_at
    )
    |> StdInterface.filter([:title, :descriptions], terms, page: page, per_page: per_page)
  end

  defp duty_query(com, user) do
    from(d in Duty,
      join: c in subquery(Sys.user_company(com, user)),
      on: c.id == d.company_id
    )
  end

  defp filter_status(query, status) when status in ~w(active done skipped),
    do: from(d in query, where: d.status == ^status)

  defp filter_status(query, _all), do: query
end
```

Note on `StdInterface.create` returns: it returns `{:ok, obj}` on success (see std_interface.ex:91-92), so the test asserts `{:ok, %Duty{}}` directly.

Note on ordering: `StdInterface.filter/4` wraps the query in a subquery and puts offset/limit outside — Postgres usually honors the inner `order_by`, and the Task-4 ordering test pins it. If that test fails on ordering, drop the `order_by` from the context query and apply it in a thin local copy of the filter (outer query) instead.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: PASS. If the preload syntax `{events_query, [...]}` misbehaves, use the equivalent `Repo.preload(duty, duty_events: {events_query, [:user, :duty_event_documents]}, duty_documents: [])`.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tugas.ex test/full_circle/tugas_test.exs
git commit -m "feat(tugas): context CRUD and duty listing"
```

---

### Task 5: Duty workflow — events, complete/skip, spawn-next, end-series

**Files:**
- Modify: `lib/full_circle/tugas.ex`
- Test: `test/full_circle/tugas_test.exs` (extend)

**Interfaces:**
- Consumes: Task 4 context; `Sys.log_changeset/5`.
- Produces:
  - `next_due_date(%Date{}, unit, every)` → `%Date{}` (unit in `"day" | "week" | "month" | "year"`)
  - `add_progress_event(duty, note, files, com, user)` → `{:ok, %{event: %DutyEvent{}, evidence: [%DutyEventDocument{}]}}` | `{:error, ...}` | `:not_authorise`
  - `close_duty(duty, action, note, files, com, user)` with action `"done" | "skip"` → `{:ok, %{duty: %Duty{}, event: %DutyEvent{}, next_cycle: %Duty{} | nil, evidence: [...]}}` | `{:error, :not_live}` | `:not_authorise`
  - `end_series(duty, note, com, user)` → `{:ok, %{duty: %Duty{}, event: %DutyEvent{}}}` | `{:error, :not_live}` | `:not_authorise`
  - `files` is a list of `%{tmp_path: path, orig_filename: name, content_type: type, size: bytes}` (may be `[]`); file handling itself is Task 6 — in this task `add_progress_event`/`close_duty` accept the argument and pass it to a stub `attach_files_multi/4` that no-ops on `[]`.

- [ ] **Step 1: Write the failing tests (append)**

```elixir
  describe "next_due_date/3" do
    test "advances by unit x every" do
      assert Tugas.next_due_date(~D[2026-09-15], "day", 10) == ~D[2026-09-25]
      assert Tugas.next_due_date(~D[2026-09-15], "week", 2) == ~D[2026-09-29]
      assert Tugas.next_due_date(~D[2026-09-15], "month", 2) == ~D[2026-11-15]
      assert Tugas.next_due_date(~D[2026-01-31], "month", 1) == ~D[2026-02-28]
      assert Tugas.next_due_date(~D[2026-09-15], "year", 1) == ~D[2027-09-15]
    end
  end

  describe "add_progress_event/5" do
    test "writes event with log", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)

      assert {:ok, %{event: event}} =
               Tugas.add_progress_event(duty, "printed slip", [], com, admin)

      assert event.action == "progress"
      assert event.note == "printed slip"
      assert event.user_id == admin.id
      assert [log] = FullCircle.Sys.log_entry_for("duty_events", event.id, com.id)
      assert log.action == "add_duty_event"
    end
  end

  describe "close_duty/6" do
    test "done closes the cycle and spawns the next one", %{admin: admin, company: com} do
      {:ok, duty} =
        Tugas.create_duty(duty_attrs(%{"recur_unit" => "month", "recur_every" => "2"}), com, admin)

      assert {:ok, %{duty: closed, event: event, next_cycle: next}} =
               Tugas.close_duty(duty, "done", "paid at IRB", [], com, admin)

      assert closed.status == "done"
      assert event.action == "done"
      assert next.status == "active"
      assert next.series_id == duty.series_id
      assert next.title == duty.title
      assert next.due_date == Tugas.next_due_date(duty.due_date, "month", 2)
    end

    test "skip closes with skipped status and still spawns", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)

      assert {:ok, %{duty: closed, next_cycle: next}} =
               Tugas.close_duty(duty, "skip", nil, [], com, admin)

      assert closed.status == "skipped"
      assert next
    end

    test "a one-off duty spawns nothing", %{admin: admin, company: com} do
      {:ok, duty} =
        Tugas.create_duty(
          duty_attrs(%{"recur_unit" => "", "recur_every" => ""}),
          com,
          admin
        )

      assert {:ok, %{next_cycle: nil}} = Tugas.close_duty(duty, "done", nil, [], com, admin)
    end

    test "closing an already-closed duty is refused", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      {:ok, _} = Tugas.close_duty(duty, "done", nil, [], com, admin)
      assert {:error, :not_live} = Tugas.close_duty(Repo.get!(Duty, duty.id), "done", nil, [], com, admin)
    end
  end

  describe "end_series/4" do
    test "closes without spawning and stamps series_ended_at", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)

      assert {:ok, %{duty: closed, event: event}} =
               Tugas.end_series(duty, "no longer needed", com, admin)

      assert closed.status == "done"
      assert closed.series_ended_at
      assert event.action == "end_series"
      assert [] = Repo.all(from d in Duty, where: d.series_id == ^duty.series_id and d.status == "active")
    end

    test "end_series is supervisory only", %{admin: admin, company: com} do
      clerk = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      assert :not_authorise = Tugas.end_series(duty, nil, com, clerk)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement (append to `lib/full_circle/tugas.ex`)**

```elixir
  # --- duty workflow ------------------------------------------------------

  def next_due_date(%Date{} = due, unit, every) when unit in ~w(day week month year) do
    Date.shift(due, [{String.to_existing_atom(unit), every}])
  end

  def add_progress_event(%Duty{} = duty, note, files, com, user) do
    with true <- can?(user, :add_duty_event, com) || :not_authorise,
         true <- files == [] or can?(user, :upload_duty_evidence, com) || :not_authorise do
      Multi.new()
      |> insert_event_multi(:event, duty, "progress", note, com, user)
      |> attach_files_multi(:event, files, com)
      |> Repo.transaction()
      |> normalize_result()
    end
  end

  def close_duty(%Duty{status: "active"} = duty, action, note, files, com, user)
      when action in ~w(done skip) do
    permission = if action == "done", do: :complete_duty, else: :skip_duty

    with true <- can?(user, permission, com) || :not_authorise,
         true <- files == [] or can?(user, :upload_duty_evidence, com) || :not_authorise do
      new_status = if action == "done", do: "done", else: "skipped"

      Multi.new()
      |> Multi.update(:duty, Duty.changeset(duty, %{"status" => new_status}))
      |> insert_event_multi(:event, duty, action, note, com, user)
      |> attach_files_multi(:event, files, com)
      |> spawn_next_multi(duty, com)
      |> Repo.transaction()
      |> normalize_result()
    end
  end

  def close_duty(%Duty{}, _action, _note, _files, _com, _user), do: {:error, :not_live}

  def end_series(%Duty{status: "active"} = duty, note, com, user) do
    case can?(user, :end_duty_series, com) do
      true ->
        Multi.new()
        |> Multi.update(
          :duty,
          Duty.changeset(duty, %{
            "status" => "done",
            "series_ended_at" => DateTime.utc_now() |> DateTime.truncate(:second)
          })
        )
        |> insert_event_multi(:event, duty, "end_series", note, com, user)
        |> Repo.transaction()
        |> normalize_result()

      false ->
        :not_authorise
    end
  end

  def end_series(%Duty{}, _note, _com, _user), do: {:error, :not_live}

  defp insert_event_multi(multi, name, duty, action, note, com, user) do
    multi
    |> Multi.insert(
      name,
      DutyEvent.changeset(%DutyEvent{}, %{
        "company_id" => com.id,
        "duty_id" => duty.id,
        "action" => action,
        "note" => note,
        "user_id" => user.id
      })
    )
    |> Multi.insert("#{name}_log", fn %{^name => event} ->
      Sys.log_changeset(
        :add_duty_event,
        event,
        %{"action" => action, "note" => note || ""},
        com,
        user
      )
    end)
  end

  # Task 6 implements file storage; [] is a no-op so Task 5 ships without it.
  defp attach_files_multi(multi, _event_name, [], _com), do: multi

  defp spawn_next_multi(multi, %Duty{recur_unit: nil}, _com), do: Multi.put(multi, :next_cycle, nil)

  defp spawn_next_multi(multi, %Duty{series_ended_at: %DateTime{}}, _com),
    do: Multi.put(multi, :next_cycle, nil)

  defp spawn_next_multi(multi, %Duty{} = duty, com) do
    Multi.insert(
      multi,
      :next_cycle,
      Duty.changeset(%Duty{}, %{
        "company_id" => com.id,
        "title" => duty.title,
        "descriptions" => duty.descriptions,
        "due_date" => next_due_date(duty.due_date, duty.recur_unit, duty.recur_every),
        "status" => "active",
        "series_id" => duty.series_id,
        "recur_unit" => duty.recur_unit,
        "recur_every" => duty.recur_every
      })
    )
  end

  defp normalize_result({:ok, changes}), do: {:ok, changes}
  defp normalize_result({:error, op, value, changes}), do: {:error, op, value, changes}
```

Two shapes to be careful with:

1. The `with ... || :not_authorise` pattern: `can?` returns a boolean; `false || :not_authorise` → `:not_authorise`, which fails the `with` and is returned as-is. Check it reads clean under credo; if not, use explicit `case` nesting like `end_series` does.
2. The one-live-cycle index means `spawn_next_multi`'s insert would fail if a live cycle already existed — that's the invariant doing its job (a double-submitted close hits `{:error, :next_cycle, changeset, _}` instead of duplicating). `close_duty` on a stale struct with `status: "active"` in memory but already closed in DB: the `Multi.update` uses the struct; add a `where`-guarded update if this proves racy — v1 accepts the changeset path since the second submit's spawn collides on the index and rolls back the whole Multi.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tugas.ex test/full_circle/tugas_test.exs
git commit -m "feat(tugas): duty workflow - events, close, spawn-next, end-series"
```

---

### Task 6: Evidence files — storage, 48 h own-author rules

**Files:**
- Modify: `lib/full_circle/tugas.ex` (real `attach_files_multi/4` + correction/delete functions + `get_evidence!/3`)
- Test: `test/full_circle/tugas_test.exs` (extend)

**Interfaces:**
- Consumes: `Application.get_env(:full_circle, :uploads_dir)` (test config → `System.tmp_dir!()`).
- Produces:
  - `attach_files_multi/4` (private) — inserts `DutyEventDocument` rows and copies files to `<uploads_dir>/<company_id>/tugas/<duty_id>/<event_id>/<uuid><ext>` inside the Multi
  - `get_evidence!(id, com, user)` → `%DutyEventDocument{}` (company-scoped via duty join) — used by the file controller (Task 7)
  - `correct_event_note(%DutyEvent{}, note, com, user)` → `{:ok, %DutyEvent{}}` | `:not_authorise` — own event within 48 h needs only `:add_duty_event`; otherwise `:correct_others_event`
  - `delete_evidence(%DutyEventDocument{}, com, user)` → `{:ok, %DutyEventDocument{}}` | `:not_authorise` — uploader within 48 h needs only `:upload_duty_evidence`; otherwise `:delete_others_evidence`; removes DB row then the file
  - module attribute `@correction_window_hours 48`

- [ ] **Step 1: Write the failing tests (append)**

```elixir
  defp tmp_evidence_file(name \\ "slip.jpg") do
    path = Path.join(System.tmp_dir!(), "tugas-test-#{Ecto.UUID.generate()}.jpg")
    File.write!(path, "fake-jpeg-bytes")
    %{tmp_path: path, orig_filename: name, content_type: "image/jpeg", size: 15}
  end

  describe "evidence files" do
    test "attach on progress event stores file at the spec path", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      file = tmp_evidence_file("bank-in-slip.jpg")

      assert {:ok, %{event: event, evidence: [doc]}} =
               Tugas.add_progress_event(duty, "deposited", [file], com, admin)

      assert doc.orig_filename == "bank-in-slip.jpg"
      assert doc.duty_event_id == event.id
      assert doc.file_path =~ "/#{com.id}/tugas/#{duty.id}/#{event.id}/"
      assert String.ends_with?(doc.file_path, ".jpg")
      assert File.exists?(doc.file_path)
    end

    test "attach on the completing event works too", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)

      assert {:ok, %{evidence: [doc]}} =
               Tugas.close_duty(duty, "done", "paid", [tmp_evidence_file()], com, admin)

      assert File.exists?(doc.file_path)
    end

    test "get_evidence! is company-scoped", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      {:ok, %{evidence: [doc]}} = Tugas.add_progress_event(duty, nil, [tmp_evidence_file()], com, admin)

      assert Tugas.get_evidence!(doc.id, com, admin).id == doc.id

      other_admin = user_fixture()
      other_com = company_fixture(other_admin, %{})
      assert_raise Ecto.NoResultsError, fn -> Tugas.get_evidence!(doc.id, other_com, other_admin) end
    end

    test "own delete within 48h allowed for everyday roles; others' needs supervisory", %{
      admin: admin,
      company: com
    } do
      clerk = user_fixture()
      cashier = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
      FullCircle.Sys.allow_user_to_access(com, cashier, "cashier", admin)

      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, clerk)
      {:ok, %{evidence: [doc]}} = Tugas.add_progress_event(duty, nil, [tmp_evidence_file()], com, clerk)

      # another everyday user cannot delete it
      assert :not_authorise = Tugas.delete_evidence(doc, com, cashier)
      # a supervisor-tier user can
      assert {:ok, _} = Tugas.delete_evidence(doc, com, admin)
      refute File.exists?(doc.file_path)
    end

    test "own delete outside 48h needs supervisory rights", %{admin: admin, company: com} do
      clerk = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, clerk)
      {:ok, %{evidence: [doc]}} = Tugas.add_progress_event(duty, nil, [tmp_evidence_file()], com, clerk)

      old = DateTime.utc_now() |> DateTime.add(-49, :hour) |> DateTime.truncate(:second)
      doc = doc |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

      assert :not_authorise = Tugas.delete_evidence(doc, com, clerk)
    end

    test "correct_event_note: own within 48h, else supervisory", %{admin: admin, company: com} do
      clerk = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, clerk)
      {:ok, %{event: event}} = Tugas.add_progress_event(duty, "typo note", [], com, clerk)

      assert {:ok, fixed} = Tugas.correct_event_note(event, "fixed note", com, clerk)
      assert fixed.note == "fixed note"

      old = DateTime.utc_now() |> DateTime.add(-49, :hour) |> DateTime.truncate(:second)
      event = event |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

      assert :not_authorise = Tugas.correct_event_note(event, "too late", com, clerk)
      assert {:ok, _} = Tugas.correct_event_note(event, "supervisor fix", com, admin)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: FAIL — `evidence` key missing from results, functions undefined.

- [ ] **Step 3: Implement (replace the `attach_files_multi` stub; append the rest)**

```elixir
  @correction_window_hours 48

  defp attach_files_multi(multi, _event_name, [], _com), do: Multi.put(multi, :evidence, [])

  defp attach_files_multi(multi, event_name, files, com) do
    Multi.run(multi, :evidence, fn repo, %{^event_name => event} ->
      dest_dir =
        Path.join([
          Application.get_env(:full_circle, :uploads_dir),
          "#{com.id}",
          "tugas",
          "#{event.duty_id}",
          "#{event.id}"
        ])

      File.mkdir_p!(dest_dir)

      docs =
        Enum.map(files, fn f ->
          dest = Path.join(dest_dir, Ecto.UUID.generate() <> Path.extname(f.orig_filename))
          File.cp!(f.tmp_path, dest)

          repo.insert!(
            DutyEventDocument.changeset(%DutyEventDocument{}, %{
              "company_id" => com.id,
              "duty_event_id" => event.id,
              "orig_filename" => f.orig_filename,
              "file_path" => dest,
              "content_type" => f.content_type,
              "size" => f.size
            })
          )
        end)

      {:ok, docs}
    end)
  end

  def get_evidence!(id, com, user) do
    from(doc in DutyEventDocument,
      join: e in DutyEvent,
      on: e.id == doc.duty_event_id,
      join: d in Duty,
      on: d.id == e.duty_id,
      join: c in subquery(Sys.user_company(com, user)),
      on: c.id == d.company_id,
      where: doc.id == ^id,
      select: doc
    )
    |> Repo.one!()
  end

  def correct_event_note(%DutyEvent{} = event, note, com, user) do
    if own_within_window?(event.user_id, event.inserted_at, user) do
      authorized_correct(event, note, com, user, :add_duty_event)
    else
      authorized_correct(event, note, com, user, :correct_others_event)
    end
  end

  defp authorized_correct(event, note, com, user, permission) do
    case can?(user, permission, com) do
      true ->
        Multi.new()
        |> Multi.update(:event, DutyEvent.changeset(event, %{"note" => note}))
        |> Multi.insert("correct_log", fn %{event: e} ->
          Sys.log_changeset(:correct_event_note, e, %{"note" => note}, com, user)
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{event: e}} -> {:ok, e}
          {:error, _, cs, _} -> {:error, cs}
        end

      false ->
        :not_authorise
    end
  end

  def delete_evidence(%DutyEventDocument{} = doc, com, user) do
    permission =
      if own_within_window?(uploader_id(doc, com, user), doc.inserted_at, user),
        do: :upload_duty_evidence,
        else: :delete_others_evidence

    case can?(user, permission, com) do
      true ->
        Multi.new()
        |> Multi.delete(:evidence, doc)
        |> Multi.insert("delete_evidence_log", fn %{evidence: d} ->
          Sys.log_changeset(:delete_evidence, d, %{"deleted_file" => d.orig_filename}, com, user)
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{evidence: d}} ->
            File.rm(d.file_path)
            {:ok, d}

          {:error, _, cs, _} ->
            {:error, cs}
        end

      false ->
        :not_authorise
    end
  end

  # evidence rows carry no user_id — ownership is the event's author
  defp uploader_id(%DutyEventDocument{} = doc, _com, _user) do
    Repo.one!(from e in DutyEvent, where: e.id == ^doc.duty_event_id, select: e.user_id)
  end

  defp own_within_window?(author_id, inserted_at, user) do
    author_id == user.id and
      DateTime.diff(DateTime.utc_now(), inserted_at, :hour) < @correction_window_hours
  end
```

Note: `Sys.log_changeset` on a deleted row still works — it only reads `__meta__.source` and `id` from the struct.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tugas.ex test/full_circle/tugas_test.exs
git commit -m "feat(tugas): evidence file storage and 48h own-author rules"
```

---

### Task 7: Authenticated evidence file serving

**Files:**
- Create: `lib/full_circle_web/controllers/tugas_file_controller.ex`
- Modify: `lib/full_circle_web/router.ex` (one `get` line in the `/companies/:company_id` scope, next to `get "/download/:filename"` at router.ex:111)
- Test: `test/full_circle_web/controllers/tugas_file_controller_test.exs`

**Interfaces:**
- Consumes: `Tugas.get_evidence!/3`, `can?(user, :view_tugas, company)`; conn assigns `current_user` / `current_company` (provided by the `:browser` pipeline's `set_active_company` plug).
- Produces: route `GET /companies/:company_id/tugas_files/:id` returning the file with its stored content type. This is the ONLY way evidence files are served (never static).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.TugasFileControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Tugas

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})

    {:ok, duty} =
      Tugas.create_duty(
        %{"title" => "Pay monthly taxes", "due_date" => "2026-09-15"},
        comp,
        user
      )

    path = Path.join(System.tmp_dir!(), "tugas-ctrl-#{Ecto.UUID.generate()}.jpg")
    File.write!(path, "fake-jpeg-bytes")

    {:ok, %{evidence: [doc]}} =
      Tugas.add_progress_event(
        duty,
        nil,
        [%{tmp_path: path, orig_filename: "slip.jpg", content_type: "image/jpeg", size: 15}],
        comp,
        user
      )

    %{conn: log_in_user(conn, user), user: user, comp: comp, doc: doc}
  end

  test "serves evidence to an authorised company member", %{conn: conn, comp: comp, doc: doc} do
    conn = get(conn, ~p"/companies/#{comp.id}/tugas_files/#{doc.id}")
    assert response(conn, 200) == "fake-jpeg-bytes"
    assert response_content_type(conn, :jpeg) =~ "image/jpeg"
  end

  test "404s for a member of a different company", %{doc: doc} do
    other = user_fixture()
    other_comp = company_fixture(other, %{})
    conn = build_conn() |> log_in_user(other)

    assert_raise Ecto.NoResultsError, fn ->
      get(conn, ~p"/companies/#{other_comp.id}/tugas_files/#{doc.id}")
    end
  end
end
```

(`response_content_type(conn, :jpeg)` needs the `:jpeg` MIME alias; if it errors, assert on `get_resp_header(conn, "content-type")` instead.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/controllers/tugas_file_controller_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Add controller and route**

```elixir
defmodule FullCircleWeb.TugasFileController do
  use FullCircleWeb, :controller

  alias FullCircle.{Authorization, Tugas}

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    company = conn.assigns.current_company

    if Authorization.can?(user, :view_tugas, company) do
      doc = Tugas.get_evidence!(id, company, user)

      conn
      |> put_resp_content_type(doc.content_type)
      |> send_file(200, doc.file_path)
    else
      conn
      |> put_status(:forbidden)
      |> text("forbidden")
    end
  end
end
```

Router — inside the `scope "/companies/:company_id"` block, beside the other controller `get`s (router.ex:109-111):

```elixir
    get "/tugas_files/:id", TugasFileController, :show
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle_web/controllers/tugas_file_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/controllers/tugas_file_controller.ex lib/full_circle_web/router.ex \
        test/full_circle_web/controllers/tugas_file_controller_test.exs
git commit -m "feat(tugas): authenticated evidence file serving"
```

---

### Task 8: Routes, dashboard entry, duty dashboard (index LiveView)

**Files:**
- Modify: `lib/full_circle_web/router.ex` (live routes in the existing `live_session :require_authenticated_user_n_active_company`, router.ex:113)
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` (Tugas section)
- Create: `lib/full_circle_web/live/tugas_live/index.ex`
- Test: `test/full_circle_web/live/tugas_live_test.exs`

**Interfaces:**
- Consumes: `Tugas.filter_duties/5`, `can?(:view_tugas)`, FC components `<.search_form>`, `<.infinite_scroll_footer>` (see `AccountLive.Index` for both).
- Produces routes:
  - `live("/tugas", TugasLive.Index, :index)`
  - `live("/tugas/duties/new", TugasLive.Form, :new)` (Form built in Task 9 — add all four routes now; the Form/Show modules get stubs only if the router refuses to compile, which it doesn't for missing modules until the route is hit)
  - `live("/tugas/duties/:duty_id/edit", TugasLive.Form, :edit)`
  - `live("/tugas/duties/:duty_id", TugasLive.Show, :show)`

  Route order matters: `new` and `:duty_id/edit` before the bare `:duty_id` catch — Phoenix matches in definition order.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule FullCircleWeb.TugasLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Tugas

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, comp: comp}
  end

  defp create_duty(comp, user, attrs \\ %{}) do
    {:ok, duty} =
      Tugas.create_duty(
        Map.merge(
          %{
            "title" => "Pay monthly taxes",
            "due_date" => "2026-09-15",
            "recur_unit" => "month",
            "recur_every" => "1"
          },
          attrs
        ),
        comp,
        user
      )

    duty
  end

  describe "duty dashboard" do
    test "lists duties with status and due date", %{conn: conn, comp: comp, user: user} do
      create_duty(comp, user)
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/tugas")
      assert html =~ "Pay monthly taxes"
      assert html =~ "2026-09-15"
    end

    test "search filters by title", %{conn: conn, comp: comp, user: user} do
      create_duty(comp, user, %{"title" => "Renew fire cert"})
      create_duty(comp, user, %{"title" => "Pay SST"})

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas")
      lv |> element("form#search-form") |> render_change(%{"search" => %{"terms" => "fire", "status" => "all"}})
      html = render(lv)
      assert html =~ "Renew fire cert"
    end

    test "denied for a user without view_tugas", %{comp: _comp} do
      # punch_camera has no :view_tugas
      admin = user_fixture()
      comp = company_fixture(admin, %{})
      pc = user_fixture()
      FullCircle.Sys.allow_user_to_access(comp, pc, "punch_camera", admin)
      conn = build_conn() |> log_in_user(pc)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/companies/#{comp.id}/tugas")

      assert to =~ "/dashboard"
    end
  end

  describe "dashboard entry" do
    test "Tugas button shows for authorised roles", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ ~p"/companies/#{comp.id}/tugas"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: FAIL — no route / module.

- [ ] **Step 3: Add routes, dashboard button, and the Index LiveView**

Router (inside the live_session, near the other feature groups):

```elixir
      live("/tugas", TugasLive.Index, :index)
      live("/tugas/duties/new", TugasLive.Form, :new)
      live("/tugas/duties/:duty_id/edit", TugasLive.Form, :edit)
      live("/tugas/duties/:duty_id", TugasLive.Show, :show)
```

Dashboard (`dashboard_live.ex`) — add a section following the existing section pattern (a heading div + button-row div), gated like the bank-reconciliation button:

```elixir
      <div
        :if={FullCircle.Authorization.can?(@current_user, :view_tugas, @current_company)}
        class="font-medium text-xl"
      >
        Tugas
      </div>
      <div
        :if={FullCircle.Authorization.can?(@current_user, :view_tugas, @current_company)}
        class="mb-4 gap-1 flex flex-wrap justify-center"
      >
        <.link navigate={~p"/companies/#{@current_company.id}/tugas"} class="button blue">
          {gettext("Duties")}
        </.link>
      </div>
```

Index LiveView (modeled on `AccountLive.Index`, rows inline instead of a stream component):

```elixir
defmodule FullCircleWeb.TugasLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.{Authorization, Tugas}

  @per_page 30

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_tugas, company) do
      {:ok, assign(socket, page_title: gettext("Duties"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = params["search"] || %{}
    terms = search["terms"] || ""
    status = search["status"] || "active"

    {:noreply,
     socket
     |> assign(search: %{terms: terms, status: status})
     |> filter_objects(terms, status, true, 1)}
  end

  @impl true
  def handle_event("next-page", _, socket) do
    %{terms: terms, status: status} = socket.assigns.search
    {:noreply, filter_objects(socket, terms, status, false, socket.assigns.page + 1)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"terms" => terms, "status" => status}}, socket) do
    qry = %{"search[terms]" => terms, "search[status]" => status}
    url = "/companies/#{socket.assigns.current_company.id}/tugas?#{URI.encode_query(qry)}"
    {:noreply, push_patch(socket, to: url)}
  end

  defp filter_objects(socket, terms, status, reset, page) do
    objects =
      Tugas.filter_duties(
        terms,
        status,
        socket.assigns.current_company,
        socket.assigns.current_user,
        page: page,
        per_page: @per_page
      )

    socket
    |> assign(page: page, per_page: @per_page)
    |> stream(:objects, objects, reset: reset)
    |> assign(end_of_timeline?: Enum.count(objects) < @per_page)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={%{}}
        id="search-form"
        phx-change="search"
        phx-submit="search"
        autocomplete="off"
        class="flex gap-2 justify-center my-2"
      >
        <input
          type="search"
          name="search[terms]"
          value={@search.terms}
          placeholder={gettext("Title or descriptions...")}
          class="rounded border px-2 py-1 w-5/12"
        />
        <select name="search[status]" class="rounded border px-2 py-1">
          <option value="active" selected={@search.status == "active"}>{gettext("Active")}</option>
          <option value="done" selected={@search.status == "done"}>{gettext("Done")}</option>
          <option value="skipped" selected={@search.status == "skipped"}>{gettext("Skipped")}</option>
          <option value="all" selected={@search.status == "all"}>{gettext("All")}</option>
        </select>
      </.form>
      <div class="text-center mb-2">
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :create_duty, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/tugas/duties/new"}
          class="blue button"
          id="new_duty"
        >
          {gettext("New Duty")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/dashboard"} class="gray button">
          {gettext("Dashboard")}
        </.link>
      </div>
      <div class="bg-amber-200 border-y-2 border-amber-500 font-bold p-2 flex gap-1 text-sm">
        <div class="w-5/12">{gettext("Title")}</div>
        <div class="w-2/12">{gettext("Due Date")}</div>
        <div class="w-2/12">{gettext("Recurs")}</div>
        <div class="w-2/12 text-center">{gettext("Status")}</div>
      </div>
      <div id="objects_list" phx-update="stream" phx-viewport-bottom={!@end_of_timeline? && "next-page"}>
        <div
          :for={{obj_id, duty} <- @streams.objects}
          id={obj_id}
          class="flex gap-1 border-b p-2 text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
        >
          <.link
            navigate={~p"/companies/#{@current_company.id}/tugas/duties/#{duty.id}"}
            class="w-5/12 text-blue-600"
          >
            {duty.title}
          </.link>
          <div class={[
            "w-2/12",
            duty.status == "active" and Date.compare(duty.due_date, Date.utc_today()) == :lt &&
              "text-rose-600 font-bold"
          ]}>
            {duty.due_date}
          </div>
          <div class="w-2/12">
            {if duty.recur_unit,
              do: gettext("every %{n} %{unit}", n: duty.recur_every, unit: duty.recur_unit),
              else: gettext("one-off")}
          </div>
          <div class="w-2/12 text-center">{duty.status}</div>
        </div>
      </div>
      <.infinite_scroll_footer ended={@end_of_timeline?} />
    </div>
    """
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: PASS. (The Form/Show routes point at not-yet-written modules; that only breaks when navigated to, which these tests don't do.)

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex \
        lib/full_circle_web/live/tugas_live/index.ex test/full_circle_web/live/tugas_live_test.exs
git commit -m "feat(tugas): duty dashboard, routes and dashboard entry"
```

---

### Task 9: Duty form LiveView (new/edit)

**Files:**
- Create: `lib/full_circle_web/live/tugas_live/form.ex`
- Test: `test/full_circle_web/live/tugas_live_test.exs` (extend)

**Interfaces:**
- Consumes: `Tugas.create_duty/3`, `Tugas.update_duty/4`, `Duty.changeset/2`, `Duty.recur_units/0`; modeled on `TradingLocationLive.Form`.
- Produces: LiveView at `/tugas/duties/new` and `/tugas/duties/:duty_id/edit`; form name `duty`; fields `title`, `descriptions`, `due_date`, `recur_every`, `recur_unit` (blank option = one-off).

- [ ] **Step 1: Write the failing tests (append to the LiveView test file)**

```elixir
  describe "duty form" do
    test "creates a duty", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/new")

      lv
      |> form("#duty-form",
        duty: %{
          "title" => "Pay SST",
          "due_date" => "2026-10-31",
          "recur_every" => "2",
          "recur_unit" => "month"
        }
      )
      |> render_submit()

      assert_redirect(lv, ~p"/companies/#{comp.id}/tugas")

      assert [duty] =
               FullCircle.Repo.all(
                 Ecto.Query.from(d in FullCircle.Tugas.Duty, where: d.title == "Pay SST")
               )

      assert duty.recur_every == 2
    end

    test "validates required fields inline", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/new")

      html =
        lv
        |> form("#duty-form", duty: %{"title" => ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "edits a live duty", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}/edit")
      assert html =~ "Pay monthly taxes"

      lv
      |> form("#duty-form", duty: %{"title" => "Pay monthly taxes (IRB)"})
      |> render_submit()

      assert FullCircle.Repo.get!(FullCircle.Tugas.Duty, duty.id).title == "Pay monthly taxes (IRB)"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: FAIL — `TugasLive.Form` undefined.

- [ ] **Step 3: Write the Form LiveView**

```elixir
defmodule FullCircleWeb.TugasLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.{Authorization, Tugas}
  alias FullCircle.Tugas.Duty

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    permission = if socket.assigns.live_action == :new, do: :create_duty, else: :update_duty

    cond do
      not Authorization.can?(user, permission, company) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))
         |> push_navigate(to: ~p"/companies/#{company.id}/tugas")}

      socket.assigns.live_action == :new ->
        cs = Duty.changeset(%Duty{}, %{"company_id" => company.id})

        {:ok,
         socket
         |> assign(page_title: gettext("New Duty"))
         |> assign(form: to_form(cs))}

      true ->
        duty = Tugas.get_duty!(params["duty_id"], company, user)

        {:ok,
         socket
         |> assign(page_title: gettext("Edit Duty"))
         |> assign(duty: duty)
         |> assign(form: to_form(Duty.changeset(duty, %{})))}
    end
  end

  @impl true
  def handle_event("validate", %{"duty" => params}, socket) do
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> Duty.changeset(%Duty{}, params)
        :edit -> Duty.changeset(socket.assigns.duty, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  @impl true
  def handle_event("save", %{"duty" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new -> Tugas.create_duty(params, company, user)
        :edit -> Tugas.update_duty(socket.assigns.duty, params, company, user)
      end

    case result do
      {:ok, _duty} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Duty saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/tugas")}

      {:error, :not_live} ->
        {:noreply, put_flash(socket, :error, gettext("Only a live duty can be edited."))}

      {:error, _op, %Ecto.Changeset{} = cs, _} ->
        {:noreply, assign(socket, form: to_form(cs))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-5/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="duty-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <.input field={@form[:title]} label={gettext("Title")} />
        <.input field={@form[:descriptions]} type="textarea" label={gettext("Descriptions")} />
        <.input field={@form[:due_date]} type="date" label={gettext("Due Date")} />
        <div class="flex gap-2">
          <.input field={@form[:recur_every]} type="number" label={gettext("Repeat every")} />
          <.input
            field={@form[:recur_unit]}
            type="select"
            label={gettext("Unit")}
            options={[{gettext("one-off"), ""} | Enum.map(Duty.recur_units(), &{&1, &1})]}
          />
        </div>
        <div class="text-center mt-3">
          <button class="blue button" phx-disable-with={gettext("Saving...")}>
            {gettext("Save")}
          </button>
          <.link navigate={~p"/companies/#{@current_company.id}/tugas"} class="gray button">
            {gettext("Cancel")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end
```

Check `<.input>`'s actual API in `lib/full_circle_web/components/core_components.ex` (label/type/options prop names) and adjust to the real component names FC uses — the form MUST end up with inputs named `duty[title]`, `duty[due_date]`, `duty[recur_every]`, `duty[recur_unit]`, `duty[descriptions]` for the tests to pass.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/tugas_live/form.ex test/full_circle_web/live/tugas_live_test.exs
git commit -m "feat(tugas): duty form"
```

---

### Task 10: Duty show LiveView — timeline, progress, complete/skip, end-series, uploads

**Files:**
- Create: `lib/full_circle_web/live/tugas_live/show.ex`
- Test: `test/full_circle_web/live/tugas_live_test.exs` (extend)

**Interfaces:**
- Consumes: `Tugas.get_duty!/3`, `add_progress_event/5`, `close_duty/6`, `end_series/4`; upload staging pattern below.
- Produces: LiveView at `/tugas/duties/:duty_id`. Elements with stable ids used by later tasks/tests: `#event-form` (the note+upload form — MUST bind `phx-change="validate"`), buttons `#btn-progress`, `#btn-complete`, `#btn-skip`, `#btn-end-series`, `#create-payment` link (Task 12 asserts its href), event rows `#event-<id>`, evidence links `#evidence-<id>` pointing at `/companies/<com>/tugas_files/<id>`.

- [ ] **Step 1: Write the failing tests (append)**

```elixir
  describe "duty show" do
    test "renders header and event timeline", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, _, _} = Tugas.add_progress_event(duty, "printed slip", [], comp, user)

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")
      assert html =~ "Pay monthly taxes"
      assert html =~ "printed slip"
      # the upload-form contract from liveview-upload-gotchas: phx-change must be bound
      assert html =~ ~s(id="event-form")
      assert html =~ ~s(phx-change="validate")
    end

    test "add progress note", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")

      lv
      |> form("#event-form", event: %{"note" => "cheque signed by boss"})
      |> render_submit(%{"action" => "progress"})

      assert render(lv) =~ "cheque signed by boss"
    end

    test "complete spawns next cycle and shows it", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")

      lv
      |> form("#event-form", event: %{"note" => "deposited to IRB"})
      |> render_submit(%{"action" => "done"})

      assert FullCircle.Repo.get!(FullCircle.Tugas.Duty, duty.id).status == "done"

      assert FullCircle.Repo.one(
               Ecto.Query.from(d in FullCircle.Tugas.Duty,
                 where: d.series_id == ^duty.series_id and d.status == "active"
               )
             )
    end

    test "upload evidence on a progress event", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")

      lv
      |> file_input("#event-form", :evidence, [
        %{
          name: "bank-in-slip.jpg",
          content: "fake-jpeg-bytes",
          type: "image/jpeg"
        }
      ])
      |> render_upload("bank-in-slip.jpg")

      lv
      |> form("#event-form", event: %{"note" => "slip scanned"})
      |> render_submit(%{"action" => "progress"})

      html = render(lv)
      assert html =~ "bank-in-slip.jpg"
      assert html =~ "/tugas_files/"
    end

    test "end series button closes without spawning", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")

      lv |> element("#btn-end-series") |> render_click()

      assert FullCircle.Repo.get!(FullCircle.Tugas.Duty, duty.id).status == "done"

      refute FullCircle.Repo.one(
               Ecto.Query.from(d in FullCircle.Tugas.Duty,
                 where: d.series_id == ^duty.series_id and d.status == "active"
               )
             )
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: FAIL — `TugasLive.Show` undefined.

- [ ] **Step 3: Write the Show LiveView**

```elixir
defmodule FullCircleWeb.TugasLive.Show do
  use FullCircleWeb, :live_view

  alias FullCircle.{Authorization, Tugas}

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_tugas, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Duty"))
       |> assign(note: "")
       |> load_duty(params["duty_id"])
       |> allow_upload(:evidence,
         accept: ~w(.jpg .jpeg .png .webp .pdf),
         max_file_size: 10_000_000,
         max_entries: 5
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  defp load_duty(socket, duty_id) do
    duty =
      Tugas.get_duty!(duty_id, socket.assigns.current_company, socket.assigns.current_user)

    assign(socket, duty: duty)
  end

  @impl true
  def handle_event("validate", %{"event" => params}, socket) do
    {:noreply, assign(socket, note: params["note"] || "")}
  end

  # the file input's own change events arrive without the "event" key
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :evidence, ref)}
  end

  @impl true
  def handle_event("save-event", %{"action" => action} = params, socket) do
    note = get_in(params, ["event", "note"]) || socket.assigns.note
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    duty = socket.assigns.duty

    files =
      consume_uploaded_entries(socket, :evidence, fn %{path: path}, entry ->
        staged =
          Path.join(
            System.tmp_dir!(),
            "tugas-staged-#{Ecto.UUID.generate()}#{Path.extname(entry.client_name)}"
          )

        File.cp!(path, staged)

        {:ok,
         %{
           tmp_path: staged,
           orig_filename: entry.client_name,
           content_type: entry.client_type,
           size: entry.client_size
         }}
      end)

    result =
      case action do
        "progress" -> Tugas.add_progress_event(duty, note, files, company, user)
        a when a in ["done", "skip"] -> Tugas.close_duty(duty, a, note, files, company, user)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(note: "")
         |> put_flash(:info, gettext("Saved."))
         |> load_duty(duty.id)}

      {:error, :not_live} ->
        {:noreply, put_flash(socket, :error, gettext("This duty is already closed."))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      {:error, _op, _value, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the event."))}
    end
  end

  @impl true
  def handle_event("end-series", _, socket) do
    case Tugas.end_series(
           socket.assigns.duty,
           nil,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Series ended."))
         |> load_duty(socket.assigns.duty.id)}

      {:error, :not_live} ->
        {:noreply, put_flash(socket, :error, gettext("This duty is already closed."))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@duty.title}</p>
      <p class="text-center text-sm">
        {gettext("Due")} {@duty.due_date} · {@duty.status} ·
        {if @duty.recur_unit,
          do: gettext("every %{n} %{unit}", n: @duty.recur_every, unit: @duty.recur_unit),
          else: gettext("one-off")}
      </p>
      <p :if={@duty.descriptions} class="text-center text-sm text-gray-600">{@duty.descriptions}</p>

      <div class="text-center my-2">
        <.link
          id="create-payment"
          navigate={~p"/companies/#{@current_company.id}/Payment/new?duty_id=#{@duty.id}"}
          class="blue button"
        >
          {gettext("Make Payment")}
        </.link>
        <.link
          :if={@duty.status == "active"}
          navigate={~p"/companies/#{@current_company.id}/tugas/duties/#{@duty.id}/edit"}
          class="gray button"
        >
          {gettext("Edit")}
        </.link>
        <button
          :if={
            @duty.status == "active" && @duty.recur_unit &&
              FullCircle.Authorization.can?(@current_user, :end_duty_series, @current_company)
          }
          id="btn-end-series"
          phx-click="end-series"
          data-confirm={gettext("End this series? No further cycles will be created.")}
          class="red button"
        >
          {gettext("End Series")}
        </button>
        <.link navigate={~p"/companies/#{@current_company.id}/tugas"} class="gray button">
          {gettext("Duties")}
        </.link>
      </div>

      <.form
        :if={
          @duty.status == "active" and
            FullCircle.Authorization.can?(@current_user, :add_duty_event, @current_company)
        }
        for={%{}}
        id="event-form"
        phx-change="validate"
        phx-submit="save-event"
        class="border rounded p-3 my-3"
      >
        <textarea
          name="event[note]"
          placeholder={gettext("Progress note...")}
          class="w-full rounded border p-2"
        >{@note}</textarea>
        <div class="my-2">
          <.live_file_input upload={@uploads.evidence} />
          <div :for={entry <- @uploads.evidence.entries} class="text-sm">
            {entry.client_name}
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              aria-label="cancel"
            >
              &times;
            </button>
            <span :for={err <- upload_errors(@uploads.evidence, entry)} class="text-rose-600">
              {inspect(err)}
            </span>
          </div>
        </div>
        <div class="flex gap-2">
          <button id="btn-progress" name="action" value="progress" class="blue button">
            {gettext("Add Progress")}
          </button>
          <button id="btn-complete" name="action" value="done" class="green button">
            {gettext("Complete")}
          </button>
          <button id="btn-skip" name="action" value="skip" class="gray button">
            {gettext("Skip")}
          </button>
        </div>
      </.form>

      <div class="font-medium text-xl mt-4">{gettext("Timeline")}</div>
      <div :for={event <- @duty.duty_events} id={"event-#{event.id}"} class="border-b py-2 text-sm">
        <span class="font-bold">{event.action}</span>
        · {event.user.email} · {event.inserted_at}
        <div :if={event.note}>{event.note}</div>
        <div :for={doc <- event.duty_event_documents} class="ml-4">
          <.link
            id={"evidence-#{doc.id}"}
            href={~p"/companies/#{@current_company.id}/tugas_files/#{doc.id}"}
            target="_blank"
            class="text-blue-600 underline"
          >
            {doc.orig_filename}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
```

Notes for the implementer:
- `event.user.email` — check the User schema's display field (`email` vs `name`) and use what FC shows elsewhere.
- Submit buttons carrying `name="action" value="..."` deliver `%{"action" => ...}` in the submit params — that's what `render_submit(%{"action" => "progress"})` simulates.
- Image evidence renders as a link in this task; thumbnails/lightbox arrive with the DocPanel (Task 13) — reuse its thumbnail markup back here afterwards if desired (not required for this plan).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite + credo, commit**

```bash
mix test && mix credo
git add lib/full_circle_web/live/tugas_live/show.ex test/full_circle_web/live/tugas_live_test.exs
git commit -m "feat(tugas): duty show with timeline, workflow actions and evidence upload"
```

---

### Task 11: Linking context — link/unlink, panel queries, picker searches

**Files:**
- Modify: `lib/full_circle/tugas.ex`
- Test: `test/full_circle/tugas_test.exs` (extend)

**Interfaces:**
- Consumes: `FullCircle.BillPay.Payment` (fields `id`, `payment_no`, `payment_date`, `company_id`), Task 2 `DutyDocument`, Task 5 `insert_event_multi`.
- Produces:
  - `link_document_multi(multi, doc_key, doc_type, duty_id, com, user)` — appends to an existing Multi: `:duty_for_link` (company-checked fetch), `:create_duty_document`, `:duty_linked_event`, `"link_duty_document_log"`. `doc_key` is the Multi key holding the created document (e.g. `:create_payment`); doc_no extracted per type (`"Payment"` → `payment_no`). Used by Task 12 inside payment creation — performs NO `can?` check itself (governed by the document's create permission, spec §6).
  - `link_document(duty, doc_type, doc_id, com, user)` → `{:ok, %DutyDocument{}}` | `{:error, :not_found}` | `{:error, %Ecto.Changeset{}}` | `:not_authorise` — the standalone picker path; checks `:link_duty_document`.
  - `unlink_document(%DutyDocument{}, com, user)` → `{:ok, %DutyDocument{}}` | `:not_authorise` — checks `:unlink_duty_document`; deletes row + `unlinked` event + log.
  - `linked_duties_for_doc(doc_type, doc_id, com, user)` → `[%DutyDocument{}]` each preloaded `duty` → `duty_events` (desc, with `:user`, `:duty_event_documents`) — the DocPanel's data source; returns `[]` without `:view_tugas`.
  - `search_linkable_docs("Payment", terms, com, user)` → up to 10 `%{id, doc_no, date}` maps by `payment_no` match.
  - `search_duties_for_link(terms, com, user)` → up to 10 active `%Duty{}` by title match.

- [ ] **Step 1: Write the failing tests (append to `test/full_circle/tugas_test.exs`)**

The payment fixture setup mirrors `test/full_circle/bill_pay_test.exs` — but a full payment needs the billing fixtures. Keep it light: linking only reads `id`/`payment_no`/`company_id`, so insert a minimal Payment row directly.

```elixir
  defp bare_payment(com) do
    Repo.insert!(
      %FullCircle.BillPay.Payment{
        payment_no: "PV-TEST01",
        payment_date: ~D[2026-09-10],
        company_id: com.id
      },
      # bypass changeset — linking only needs id/payment_no/company_id
      on_conflict: :nothing
    )
  end

  describe "document linking" do
    test "link_document writes link + linked event + log", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      payment = bare_payment(com)

      assert {:ok, link} = Tugas.link_document(duty, "Payment", payment.id, com, admin)
      assert link.doc_no == "PV-TEST01"

      duty = Tugas.get_duty!(duty.id, com, admin)
      assert Enum.any?(duty.duty_events, &(&1.action == "linked" and &1.note =~ "PV-TEST01"))
      assert [log] = FullCircle.Sys.log_entry_for("duty_documents", link.id, com.id)
      assert log.action == "link_duty_document"
    end

    test "duplicate link is rejected", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      payment = bare_payment(com)
      {:ok, _} = Tugas.link_document(duty, "Payment", payment.id, com, admin)
      assert {:error, %Ecto.Changeset{}} = Tugas.link_document(duty, "Payment", payment.id, com, admin)
    end

    test "linking a doc from another company fails", %{admin: admin, company: com} do
      other_admin = user_fixture()
      other_com = company_fixture(other_admin, %{})
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      foreign_payment = bare_payment(other_com)

      assert {:error, :not_found} =
               Tugas.link_document(duty, "Payment", foreign_payment.id, com, admin)
    end

    test "unlink is supervisory and writes unlinked event", %{admin: admin, company: com} do
      clerk = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      payment = bare_payment(com)
      {:ok, link} = Tugas.link_document(duty, "Payment", payment.id, com, admin)

      assert :not_authorise = Tugas.unlink_document(link, com, clerk)
      assert {:ok, _} = Tugas.unlink_document(link, com, admin)

      duty = Tugas.get_duty!(duty.id, com, admin)
      assert Enum.any?(duty.duty_events, &(&1.action == "unlinked"))
      assert [] = Repo.all(Ecto.Query.from(dd in FullCircle.Tugas.DutyDocument, where: dd.duty_id == ^duty.id))
    end

    test "linked_duties_for_doc returns duty with trail and evidence", %{admin: admin, company: com} do
      {:ok, duty} = Tugas.create_duty(duty_attrs(), com, admin)
      {:ok, _} = Tugas.add_progress_event(duty, "deposited", [tmp_evidence_file()], com, admin)
      payment = bare_payment(com)
      {:ok, _} = Tugas.link_document(duty, "Payment", payment.id, com, admin)

      assert [dd] = Tugas.linked_duties_for_doc("Payment", payment.id, com, admin)
      assert dd.duty.title == "Pay monthly taxes"
      assert Enum.any?(dd.duty.duty_events, &(&1.duty_event_documents != []))

      # without view_tugas -> empty
      pc = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, pc, "punch_camera", admin)
      assert [] = Tugas.linked_duties_for_doc("Payment", payment.id, com, pc)
    end

    test "search helpers find candidates", %{admin: admin, company: com} do
      {:ok, _duty} = Tugas.create_duty(duty_attrs(%{"title" => "Renew fire cert"}), com, admin)
      payment = bare_payment(com)

      assert [%{doc_no: "PV-TEST01"}] = Tugas.search_linkable_docs("Payment", "TEST", com, admin)
      assert [_] = Tugas.search_duties_for_link("fire", com, admin)
      assert [] = Tugas.search_duties_for_link("zzz-no-match", com, admin)
      assert payment.id
    end
  end
```

(If inserting a bare `%Payment{}` trips NOT NULL columns, add the minimum required fields — check `\d payments` via `psql` or the Payment schema's `validate_required` — keeping the fixture as small as the DB allows.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement (append to `lib/full_circle/tugas.ex`)**

```elixir
  # --- duty <-> document links -------------------------------------------

  @linkable_doc_types ~w(Payment)

  def linkable_doc_types, do: @linkable_doc_types

  @doc """
  Appends the duty-link steps to a document-creating Multi. `doc_key` is the
  Multi key whose result is the created document. No can? check here: linking
  at create time is governed by the document's own create permission (spec §6).
  """
  def link_document_multi(multi, doc_key, doc_type, duty_id, com, user)
      when doc_type in @linkable_doc_types do
    multi
    |> Multi.run(:duty_for_link, fn repo, _ ->
      case repo.one(from d in Duty, where: d.id == ^duty_id and d.company_id == ^com.id) do
        nil -> {:error, :duty_not_found}
        duty -> {:ok, duty}
      end
    end)
    |> Multi.insert(:create_duty_document, fn %{^doc_key => doc, duty_for_link: duty} ->
      DutyDocument.changeset(%DutyDocument{}, %{
        "company_id" => com.id,
        "duty_id" => duty.id,
        "doc_type" => doc_type,
        "doc_id" => doc.id,
        "doc_no" => doc_no_of(doc_type, doc),
        "user_id" => user.id
      })
    end)
    |> Multi.insert(:duty_linked_event, fn %{create_duty_document: dd} ->
      DutyEvent.changeset(%DutyEvent{}, %{
        "company_id" => com.id,
        "duty_id" => dd.duty_id,
        "action" => "linked",
        "note" => "#{dd.doc_type} #{dd.doc_no} linked",
        "user_id" => user.id
      })
    end)
    |> Multi.insert("link_duty_document_log", fn %{create_duty_document: dd} ->
      Sys.log_changeset(
        :link_duty_document,
        dd,
        %{"doc_type" => dd.doc_type, "doc_no" => dd.doc_no},
        com,
        user
      )
    end)
  end

  defp doc_no_of("Payment", doc), do: doc.payment_no

  def link_document(%Duty{} = duty, doc_type, doc_id, com, user)
      when doc_type in @linkable_doc_types do
    with true <- can?(user, :link_duty_document, com) || :not_authorise,
         {:ok, _doc} <- fetch_linkable(doc_type, doc_id, com) do
      Multi.new()
      |> Multi.put(:doc, elem(fetch_linkable(doc_type, doc_id, com), 1))
      |> link_document_multi(:doc, doc_type, duty.id, com, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{create_duty_document: dd}} -> {:ok, dd}
        {:error, :create_duty_document, cs, _} -> {:error, cs}
        {:error, :duty_for_link, reason, _} -> {:error, reason}
      end
    end
  end

  defp fetch_linkable("Payment", doc_id, com) do
    case Repo.one(
           from p in FullCircle.BillPay.Payment,
             where: p.id == ^doc_id and p.company_id == ^com.id
         ) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  def unlink_document(%DutyDocument{} = dd, com, user) do
    case can?(user, :unlink_duty_document, com) do
      true ->
        Multi.new()
        |> Multi.delete(:delete_duty_document, dd)
        |> Multi.insert(:duty_unlinked_event, fn _ ->
          DutyEvent.changeset(%DutyEvent{}, %{
            "company_id" => com.id,
            "duty_id" => dd.duty_id,
            "action" => "unlinked",
            "note" => "#{dd.doc_type} #{dd.doc_no} unlinked",
            "user_id" => user.id
          })
        end)
        |> Multi.insert("unlink_duty_document_log", fn %{delete_duty_document: deleted} ->
          Sys.log_changeset(
            :unlink_duty_document,
            deleted,
            %{"doc_type" => deleted.doc_type, "doc_no" => deleted.doc_no},
            com,
            user
          )
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{delete_duty_document: deleted}} -> {:ok, deleted}
          {:error, _, value, _} -> {:error, value}
        end

      false ->
        :not_authorise
    end
  end

  def linked_duties_for_doc(doc_type, doc_id, com, user) do
    if can?(user, :view_tugas, com) do
      events_query =
        from(e in DutyEvent,
          order_by: [desc: e.inserted_at],
          preload: [:user, :duty_event_documents]
        )

      from(dd in DutyDocument,
        where:
          dd.doc_type == ^doc_type and dd.doc_id == ^doc_id and dd.company_id == ^com.id,
        preload: [duty: [duty_events: ^events_query]]
      )
      |> Repo.all()
    else
      []
    end
  end

  def duty_links(%Duty{} = duty), do: Repo.all(from dd in DutyDocument, where: dd.duty_id == ^duty.id)

  def search_linkable_docs("Payment", terms, com, user) do
    if can?(user, :view_tugas, com) do
      from(p in FullCircle.BillPay.Payment,
        where: p.company_id == ^com.id,
        where: ilike(p.payment_no, ^"%#{terms}%"),
        order_by: [desc: p.payment_date],
        limit: 10,
        select: %{id: p.id, doc_no: p.payment_no, date: p.payment_date}
      )
      |> Repo.all()
    else
      []
    end
  end

  def search_duties_for_link(terms, com, user) do
    if can?(user, :view_tugas, com) do
      from(d in Duty,
        where: d.company_id == ^com.id and d.status == "active",
        where: ilike(d.title, ^"%#{terms}%"),
        order_by: [asc: d.due_date],
        limit: 10
      )
      |> Repo.all()
    else
      []
    end
  end
```

Cleanup during implementation: `link_document/5` calls `fetch_linkable` twice in the sketch above — restructure to call once (`with {:ok, doc} <- fetch_linkable(...)` then `Multi.put(:doc, doc)`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/tugas_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tugas.ex test/full_circle/tugas_test.exs
git commit -m "feat(tugas): duty-document linking, panel queries and picker searches"
```

---

### Task 12: `?duty_id=` payment flow — BillPay opts + Payment form clause

**Files:**
- Modify: `lib/full_circle/bill_pay.ex` (`create_payment/3` → `/4` with `opts \\ []`; `create_payment_multi/4` → `/5` with `opts \\ []`)
- Modify: `lib/full_circle_web/live/payment_live/form.ex` (new `mount_new` clause at form.ex:37 area; `save/3` `:new` branch)
- Test: `test/full_circle/bill_pay_test.exs` (extend) and `test/full_circle_web/live/tugas_live_test.exs` (extend)

**Interfaces:**
- Consumes: `Tugas.link_document_multi/6` (Task 11), `Tugas.get_duty!/3`.
- Produces:
  - `BillPay.create_payment(attrs, com, user, opts \\ [])` — `opts[:duty_id]` triggers the link steps inside the same transaction. Existing arity-3 callers unaffected (default arg). The arity-4 caller in `bank_reconciliation.ex:892` (`create_payment_multi(Multi.new(), attrs, com, user)`) is also unaffected.
  - `PaymentLive.Form` handles `/Payment/new?duty_id=<id>`: assigns `:duty`, prefills `descriptions` with the duty title; successful save redirects to the duty show page with flash `"<payment_no> created and linked to duty."`.

- [ ] **Step 1: Write the failing context test (append to `test/full_circle/bill_pay_test.exs`)**

```elixir
  describe "create_payment/4 with duty_id" do
    test "links the payment to the duty in the same transaction", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      funds_acct = pay_funds_account_fixture(company, admin)

      no_ptax =
        Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

      {:ok, duty} =
        FullCircle.Tugas.create_duty(
          %{"title" => "Pay monthly taxes", "due_date" => "2026-09-15"},
          company,
          admin
        )

      attrs = payment_attrs(contact, good, pur_acct, no_ptax, funds_acct)

      assert {:ok, %{create_payment: payment, create_duty_document: link}} =
               BillPay.create_payment(attrs, company, admin, duty_id: duty.id)

      assert link.duty_id == duty.id
      assert link.doc_type == "Payment"
      assert link.doc_id == payment.id
      assert link.doc_no == payment.payment_no

      duty = FullCircle.Tugas.get_duty!(duty.id, company, admin)
      assert Enum.any?(duty.duty_events, &(&1.action == "linked" and &1.note =~ payment.payment_no))
    end

    test "an invalid duty_id rolls the whole payment back", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      funds_acct = pay_funds_account_fixture(company, admin)

      no_ptax =
        Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

      attrs = payment_attrs(contact, good, pur_acct, no_ptax, funds_acct)

      assert {:error, :duty_for_link, :duty_not_found, _} =
               BillPay.create_payment(attrs, company, admin, duty_id: Ecto.UUID.generate())

      assert [] = Repo.all(from p in FullCircle.BillPay.Payment, where: p.company_id == ^company.id)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/bill_pay_test.exs`
Expected: FAIL — `create_payment/4` undefined.

- [ ] **Step 3: Extend BillPay**

In `lib/full_circle/bill_pay.ex`, change `create_payment/3` (bill_pay.ex:319) and `create_payment_multi/4` (bill_pay.ex:332):

```elixir
  def create_payment(attrs, com, user, opts \\ []) do
    case can?(user, :create_payment, com) do
      true ->
        Multi.new()
        |> create_payment_multi(attrs, com, user, opts)
        |> Repo.transaction()
        |> Accounting.map_period_closed()

      false ->
        :not_authorise
    end
  end

  def create_payment_multi(multi, attrs, com, user, opts \\ []) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    payment_name = :create_payment

    multi
    |> get_gapless_doc_id(gapless_name, "Payment", "PV", com)
    |> Multi.insert(payment_name, fn %{^gapless_name => doc} ->
      make_changeset(Payment, %Payment{}, Map.merge(attrs, %{"payment_no" => doc}), com, user)
    end)
    |> Multi.insert("#{payment_name}_log", fn %{^payment_name => entity} ->
      FullCircle.Sys.log_changeset(
        payment_name,
        entity,
        Map.merge(attrs, %{"payment_no" => entity.payment_no}),
        com,
        user
      )
    end)
    |> Accounting.multi_assert_period_open(
      fn %{^payment_name => doc} -> [doc.payment_date] end,
      com
    )
    |> create_payment_transactions(payment_name, com, user)
    |> maybe_link_duty(opts[:duty_id], com, user)
  end

  defp maybe_link_duty(multi, nil, _com, _user), do: multi

  defp maybe_link_duty(multi, duty_id, com, user) do
    FullCircle.Tugas.link_document_multi(multi, :create_payment, "Payment", duty_id, com, user)
  end
```

- [ ] **Step 4: Run context tests**

Run: `mix test test/full_circle/bill_pay_test.exs`
Expected: PASS (new tests and all pre-existing ones — the default args keep old call sites compiling).

- [ ] **Step 5: Write the failing LiveView test (append to `test/full_circle_web/live/tugas_live_test.exs`)**

```elixir
  describe "make-payment flow" do
    test "duty show links to the prefilled payment form", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")
      assert html =~ "Payment/new?duty_id=#{duty.id}"
    end

    test "payment form mounts with the duty assigned and title prefilled", %{
      conn: conn,
      comp: comp,
      user: user
    } do
      duty = create_duty(comp, user)

      {:ok, _lv, html} =
        live(conn, ~p"/companies/#{comp.id}/Payment/new?duty_id=#{duty.id}")

      assert html =~ "Pay monthly taxes"
    end
  end
```

(Full submit-to-redirect coverage needs the whole payment fixture stack; the Multi is already covered by Step 1's context test. These two LiveView tests pin the mount clause and the entry link.)

- [ ] **Step 6: Run to verify failure, then extend the Payment form**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: the second test FAILS (no duty prefill).

Add a `mount_new` clause in `lib/full_circle_web/live/payment_live/form.ex` ABOVE the catch-all `mount_new(socket, params)` clause (form.ex:95), following the `"obj"`/`"recon"` clause style:

```elixir
  defp mount_new(socket, %{"duty_id" => duty_id}) when is_binary(duty_id) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    duty = FullCircle.Tugas.get_duty!(duty_id, com, user)

    attrs = %{
      payment_no: "...new...",
      descriptions: duty.title
    }

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Payment"))
    |> assign_egg_link(%{}, :purchase)
    |> assign(duty: duty)
    |> assign(:form, to_form(BillPay.make_changeset(Payment, %Payment{}, attrs, com, user)))
  end
```

In `save/3`'s `:new` branch (form.ex:530): pass the opt and branch the redirect. Change the `BillPay.create_payment(params, ...)` call to:

```elixir
    case BillPay.create_payment(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user,
           duty_id: socket.assigns[:duty] && socket.assigns.duty.id
         ) do
```

(`opts[:duty_id]` being `nil`/`false` must no-op — adjust `maybe_link_duty` to also match `false`, or normalize with `duty_id: if(socket.assigns[:duty], do: socket.assigns.duty.id)`.)

And inside the success branch's `:no_recon` arm (form.ex:567), redirect back to the duty when one was attached:

```elixir
          :no_recon ->
            case socket.assigns[:duty] do
              nil ->
                {:noreply,
                 socket
                 |> push_navigate(
                   to: ~p"/companies/#{socket.assigns.current_company.id}/Payment/#{obj.id}/edit"
                 )
                 |> put_flash(:info, gettext("Payment created successfully."))}

              duty ->
                {:noreply,
                 socket
                 |> push_navigate(
                   to: ~p"/companies/#{socket.assigns.current_company.id}/tugas/duties/#{duty.id}"
                 )
                 |> put_flash(
                   :info,
                   "#{obj.payment_no} #{gettext("created and linked to duty.")}"
                 )}
            end
```

Also handle the new error tuple from a broken link step in the same `case` (alongside the existing `{:error, failed_operation, changeset, _}` clause it may already match — verify the shape `{:error, :duty_for_link, :duty_not_found, _}` doesn't crash that clause; if it does, add an explicit clause flashing `gettext("Duty not found.")`).

- [ ] **Step 7: Run all touched tests**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs test/full_circle/bill_pay_test.exs test/full_circle_web/live/payment_live_test.exs`
(Adjust the last path to the actual payment LiveView test file name — find it with `ls test/full_circle_web/live | grep -i payment`.)
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/form.ex \
        test/full_circle/bill_pay_test.exs test/full_circle_web/live/tugas_live_test.exs
git commit -m "feat(tugas): create-and-link payment from a duty (?duty_id= flow)"
```

---

### Task 13: DocPanel on Payment + link/unlink pickers (first demo)

**Files:**
- Create: `lib/full_circle_web/live/tugas_live/components/doc_panel.ex`
- Modify: `lib/full_circle_web/live/payment_live/form.ex` (include DocPanel when `live_action == :edit`)
- Modify: `lib/full_circle_web/live/tugas_live/show.ex` (linked-documents list + "Link document" picker + unlink)
- Test: `test/full_circle_web/live/tugas_live_test.exs` (extend)

**Interfaces:**
- Consumes: `Tugas.linked_duties_for_doc/4`, `search_linkable_docs/4`, `search_duties_for_link/3`, `link_document/5`, `unlink_document/3`, `linkable_doc_types/0`.
- Produces: `FullCircleWeb.TugasLive.Components.DocPanel` — a LiveComponent with attrs `id`, `doc_type`, `doc_id`, `current_company`, `current_user`. Renders nothing when `linked_duties_for_doc` is empty AND the user lacks `:link_duty_document`; otherwise the affirmation panel + picker. Element ids: `#tugas-doc-panel`, per-duty `#linked-duty-<duty_id>`, evidence `#panel-evidence-<doc_id>`, picker form `#duty-link-picker`, unlink buttons `#unlink-<link_id>`.

- [ ] **Step 1: Write the failing tests (append)**

```elixir
  describe "DocPanel on Payment edit + pickers (the affirmation demo)" do
    test "payment edit page shows linked duty, trail and evidence files", %{
      conn: conn,
      comp: comp,
      user: user
    } do
      duty = create_duty(comp, user)

      staged = Path.join(System.tmp_dir!(), "slip-#{Ecto.UUID.generate()}.jpg")
      File.write!(staged, "fake-jpeg-bytes")

      {:ok, _} =
        Tugas.add_progress_event(
          duty,
          "deposited to IRB",
          [%{tmp_path: staged, orig_filename: "bank-in-slip.jpg", content_type: "image/jpeg", size: 15}],
          comp,
          user
        )

      payment =
        FullCircle.Repo.insert!(%FullCircle.BillPay.Payment{
          payment_no: "PV-DEMO01",
          payment_date: ~D[2026-09-10],
          company_id: comp.id
        })

      {:ok, _} = Tugas.link_document(duty, "Payment", payment.id, comp, user)

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/Payment/#{payment.id}/edit")

      assert html =~ "Pay monthly taxes"
      assert html =~ "deposited to IRB"
      assert html =~ "bank-in-slip.jpg"
      assert html =~ "/tugas_files/"
    end

    test "duty show lists linked documents and supervisors can unlink", %{
      conn: conn,
      comp: comp,
      user: user
    } do
      duty = create_duty(comp, user)

      payment =
        FullCircle.Repo.insert!(%FullCircle.BillPay.Payment{
          payment_no: "PV-DEMO02",
          payment_date: ~D[2026-09-10],
          company_id: comp.id
        })

      {:ok, link} = Tugas.link_document(duty, "Payment", payment.id, comp, user)

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")
      assert html =~ "PV-DEMO02"

      lv |> element("#unlink-#{link.id}") |> render_click()
      refute render(lv) =~ "PV-DEMO02"
    end

    test "duty show picker links an existing payment", %{conn: conn, comp: comp, user: user} do
      duty = create_duty(comp, user)

      _payment =
        FullCircle.Repo.insert!(%FullCircle.BillPay.Payment{
          payment_no: "PV-PICK01",
          payment_date: ~D[2026-09-10],
          company_id: comp.id
        })

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tugas/duties/#{duty.id}")

      lv
      |> form("#doc-link-picker", %{"picker" => %{"terms" => "PICK"}})
      |> render_change()

      lv |> element("button[phx-value-doc_no='PV-PICK01']") |> render_click()

      assert render(lv) =~ "PV-PICK01"
      assert [_] = FullCircle.Repo.all(Ecto.Query.from(dd in FullCircle.Tugas.DutyDocument, where: dd.duty_id == ^duty.id))
    end
  end
```

(If the bare `%Payment{}` insert hits NOT NULL constraints, reuse whatever minimal fixture Task 11 settled on. Separately, the first test renders the Payment **edit page**, whose mount/render may require a real payment with details, contact and funds account — if it crashes on a bare row, build the payment with the full fixture stack exactly as `test/full_circle/bill_pay_test.exs` does: `billing_setup()` + `contact_fixture` + `good_fixture` + `pay_funds_account_fixture` + `payment_attrs` + `BillPay.create_payment/3`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Write the DocPanel component**

```elixir
defmodule FullCircleWeb.TugasLive.Components.DocPanel do
  @moduledoc """
  The affirmation view (spec §5): on a whitelisted document page, shows each
  linked duty with its progress trail and EVERY evidence file across the
  duty's events. Never included on print views.
  """
  use FullCircleWeb, :live_component

  alias FullCircle.{Authorization, Tugas}

  @impl true
  def update(assigns, socket) do
    links =
      Tugas.linked_duties_for_doc(
        assigns.doc_type,
        assigns.doc_id,
        assigns.current_company,
        assigns.current_user
      )

    {:ok,
     socket
     |> assign(assigns)
     |> assign(links: links)
     |> assign_new(:duty_candidates, fn -> [] end)}
  end

  @impl true
  def handle_event("search-duty", %{"picker" => %{"terms" => terms}}, socket) do
    candidates =
      Tugas.search_duties_for_link(terms, socket.assigns.current_company, socket.assigns.current_user)

    {:noreply, assign(socket, duty_candidates: candidates)}
  end

  @impl true
  def handle_event("link-duty", %{"duty_id" => duty_id}, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user
    duty = Tugas.get_duty!(duty_id, com, user)

    case Tugas.link_document(duty, socket.assigns.doc_type, socket.assigns.doc_id, com, user) do
      {:ok, _} ->
        send(self(), {:doc_panel_flash, :info,
          gettext("Linked to %{title} — open the duty to record progress or complete it.",
            title: duty.title
          ), ~p"/companies/#{com.id}/tugas/duties/#{duty.id}"})

        {:noreply,
         socket
         |> assign(duty_candidates: [])
         |> assign(
           links: Tugas.linked_duties_for_doc(socket.assigns.doc_type, socket.assigns.doc_id, com, user)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unlink", %{"link_id" => link_id}, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    link = Enum.find(socket.assigns.links, &(&1.id == link_id))

    case link && Tugas.unlink_document(link, com, user) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           links: Tugas.linked_duties_for_doc(socket.assigns.doc_type, socket.assigns.doc_id, com, user)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="border rounded p-3 my-4">
      <div class="font-medium text-xl">{gettext("Tugas")}</div>

      <div :for={link <- @links} id={"linked-duty-#{link.duty_id}"} class="mt-2">
        <div class="flex gap-2 items-center">
          <.link
            navigate={~p"/companies/#{@current_company.id}/tugas/duties/#{link.duty_id}"}
            class="text-blue-600 font-bold"
          >
            {link.duty.title}
          </.link>
          <span class="text-sm">{link.duty.status} · {gettext("due")} {link.duty.due_date}</span>
          <button
            :if={Authorization.can?(@current_user, :unlink_duty_document, @current_company)}
            id={"unlink-#{link.id}"}
            phx-click="unlink"
            phx-value-link_id={link.id}
            phx-target={@myself}
            data-confirm={gettext("Unlink this duty?")}
            class="text-rose-600 text-sm underline"
          >
            {gettext("unlink")}
          </button>
        </div>

        <div :for={event <- link.duty.duty_events} class="ml-3 text-sm border-l pl-2 my-1">
          <span class="font-bold">{event.action}</span>
          · {event.user.email} · {event.inserted_at}
          <span :if={event.note}>— {event.note}</span>
          <div :for={doc <- event.duty_event_documents} id={"panel-evidence-#{doc.id}"} class="ml-2">
            <a
              :if={String.starts_with?(doc.content_type, "image/")}
              href={~p"/companies/#{@current_company.id}/tugas_files/#{doc.id}"}
              target="_blank"
            >
              <img
                src={~p"/companies/#{@current_company.id}/tugas_files/#{doc.id}"}
                alt={doc.orig_filename}
                class="max-h-24 inline-block rounded border"
              />
            </a>
            <a
              href={~p"/companies/#{@current_company.id}/tugas_files/#{doc.id}"}
              target="_blank"
              class="text-blue-600 underline"
            >
              {doc.orig_filename}
            </a>
          </div>
        </div>
      </div>

      <.form
        :if={Authorization.can?(@current_user, :link_duty_document, @current_company)}
        for={%{}}
        id="duty-link-picker"
        phx-change="search-duty"
        phx-target={@myself}
        class="mt-3"
      >
        <input
          type="search"
          name="picker[terms]"
          placeholder={gettext("Link to duty: search by title...")}
          class="rounded border px-2 py-1 w-6/12"
        />
      </.form>
      <div :for={duty <- @duty_candidates} class="text-sm mt-1">
        <button
          phx-click="link-duty"
          phx-value-duty_id={duty.id}
          phx-target={@myself}
          class="text-blue-600 underline"
        >
          {duty.title} ({gettext("due")} {duty.due_date})
        </button>
      </div>
    </div>
    """
  end
end
```

Include it in `PaymentLive.Form`'s render, after the main form markup, only for edits (a new payment has no id yet) and never in print views (print is a separate LiveView, untouched):

```elixir
      <.live_component
        :if={@live_action == :edit}
        module={FullCircleWeb.TugasLive.Components.DocPanel}
        id="tugas-doc-panel"
        doc_type="Payment"
        doc_id={@form.data.id}
        current_company={@current_company}
        current_user={@current_user}
      />
```

And in `PaymentLive.Form` add the flash relay (LiveComponents can't flash directly):

```elixir
  @impl true
  def handle_info({:doc_panel_flash, level, msg, _duty_url}, socket) do
    {:noreply, put_flash(socket, level, msg)}
  end
```

(The spec's "flash includes a direct link to the duty": flashes are plain text in FC — satisfy it by naming the duty in the flash AND keeping the duty title in the panel a click-through link, which the panel already renders. If FC's flash component supports safe HTML, link the URL; don't build custom flash infrastructure for this.)

- [ ] **Step 4: Add linked-documents list + picker to `TugasLive.Show`**

Append to the Show render (below the timeline):

```elixir
      <div class="font-medium text-xl mt-4">{gettext("Linked Documents")}</div>
      <div :for={link <- @links} class="text-sm py-1" id={"duty-link-#{link.id}"}>
        {link.doc_type}
        <.link
          navigate={~p"/companies/#{@current_company.id}/Payment/#{link.doc_id}/edit"}
          class="text-blue-600 underline"
        >
          {link.doc_no}
        </.link>
        <button
          :if={FullCircle.Authorization.can?(@current_user, :unlink_duty_document, @current_company)}
          id={"unlink-#{link.id}"}
          phx-click="unlink"
          phx-value-link_id={link.id}
          data-confirm={gettext("Unlink this document?")}
          class="text-rose-600 underline ml-2"
        >
          {gettext("unlink")}
        </button>
      </div>

      <.form
        :if={FullCircle.Authorization.can?(@current_user, :link_duty_document, @current_company)}
        for={%{}}
        id="doc-link-picker"
        phx-change="search-doc"
        class="mt-2"
      >
        <input
          type="search"
          name="picker[terms]"
          placeholder={gettext("Link a document: search Payment no...")}
          class="rounded border px-2 py-1 w-6/12"
        />
      </.form>
      <div :for={doc <- @doc_candidates} class="text-sm mt-1">
        <button
          phx-click="link-doc"
          phx-value-doc_id={doc.id}
          phx-value-doc_no={doc.doc_no}
          class="text-blue-600 underline"
        >
          Payment {doc.doc_no} ({doc.date})
        </button>
      </div>
```

With handlers + assigns in Show:

```elixir
  # in mount: |> assign(doc_candidates: [])
  # in load_duty/2, also:  |> assign(links: Tugas.duty_links(duty))

  @impl true
  def handle_event("search-doc", %{"picker" => %{"terms" => terms}}, socket) do
    candidates =
      Tugas.search_linkable_docs(
        "Payment",
        terms,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    {:noreply, assign(socket, doc_candidates: candidates)}
  end

  @impl true
  def handle_event("link-doc", %{"doc_id" => doc_id}, socket) do
    case Tugas.link_document(
           socket.assigns.duty,
           "Payment",
           doc_id,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(doc_candidates: [])
         |> put_flash(:info, gettext("Document linked."))
         |> load_duty(socket.assigns.duty.id)}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not link the document."))}
    end
  end

  @impl true
  def handle_event("unlink", %{"link_id" => link_id}, socket) do
    link = Enum.find(socket.assigns.links, &(&1.id == link_id))

    case link &&
           Tugas.unlink_document(
             link,
             socket.assigns.current_company,
             socket.assigns.current_user
           ) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Unlinked.")) |> load_duty(socket.assigns.duty.id)}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      _ ->
        {:noreply, socket}
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/tugas_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Full suite + credo + manual demo**

```bash
mix test && mix credo
```

Expected: everything green. Then the human demo (dev server): create the recurring duty "Pay monthly taxes" → Make Payment → save → back on the duty, add a progress event with a JPG "bank-in slip" → complete → open the Payment edit page → the Tugas panel shows the duty, the trail, and the slip thumbnail.

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle_web/live/tugas_live/components/doc_panel.ex \
        lib/full_circle_web/live/payment_live/form.ex \
        lib/full_circle_web/live/tugas_live/show.ex \
        test/full_circle_web/live/tugas_live_test.exs
git commit -m "feat(tugas): DocPanel affirmation view on Payment and link/unlink pickers"
```

---

## After this plan

- **Phase 4 plan** (separate): `todos` migration + schema, todo list UI, close/cancel, escalate-to-duty (todo gets `duty_id` + status `done` in the duty-create Multi), `:create_todo`/`:close_todo`/`:close_others_todo`/`:escalate_todo` clauses.
- **Phase 5 plan** (separate): mobile Tugas shell, `tasker` in `roles/0`, tasker added to all ~41 `forbid_roles` lists, nav hiding, live_session guard, route-table denial test.
- Post-v1: voice-todo App API port; whitelist expansion (Receipt, Journal, PurInvoice — each: mount clause + multi step + panel include + delete-path rule).
