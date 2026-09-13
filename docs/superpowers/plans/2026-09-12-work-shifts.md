# Work Shifts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make attendance shift-aware instead of calendar-day-aware, so a shift crossing midnight is one shift paid in full, a day can hold any number of IN/OUT pairs, and anything the system cannot pair reads as blank-and-red rather than being silently truncated into a plausible-looking number.

**Architecture:** Declarative `work_shifts` (seeded with General 08:00 / 9 / 12) plus dated `employee_work_shifts`; an employee with no effective row resolves to General. Each punch stores *which instance it belongs to* (`work_shift_id` + `work_shift_date`), while hours, pay date and anomalies are **derived on read** from that grouping — so a clerk's edit can never leave a stale total, which is the trap `rebuild_day_flags/3` falls into today. The instance boundary is a derived cutover, never configured.

**Tech Stack:** Elixir 1.19.5 / OTP 28.3.1, Phoenix 1.8.3, LiveView 1.1.x, Ecto + PostgreSQL, Timex, Tailwind 3.4, Gettext (en + zh).

**Spec:** `docs/superpowers/specs/2026-09-12-work-shifts-design.md`

## Global Constraints

- **OT must not change.** It stays `worked − Employee.work_hours_per_day` (7.5 default). `normal_hour` is display-only and must never become an OT threshold — 94% of employee-days (5,955 of 6,336) exceed 7.5 h worked, so moving that threshold would be a large silent pay cut.
- **The backfill must be behaviour-preserving.** General's derived cutover is 02:00 and there are **zero punches between 22:00 and 06:59** in all 23,902 rows, so grouping must come out identical. Task 3 carries a hard gate; if it fails, the backfill is wrong and does not ship. The gate must test the punch's local time against **the cutover** — asserting that `work_shift_date` equals the expression it was just assigned from is a tautology that passes on any data.
- **Blank the hours, never block the pay slip.** Measured on the restored production database, **328 of 6,619 employee-days already have an odd punch count** (283 of them a single punch), across **68 employee-months**, 61 already paid. Most are not errors: three off-site employees punch once on every day they work (Rajeswari 115/115, Hazriq 75/75, Isrol 28/65), and no missing punch exists to recover. An anomalous instance therefore shows blank hours and a red row — which is exactly what those days do today — and payroll is untouched. There is no pay-slip gate, no `unresolved_shift_dates`, and `PaySlipOp` is not modified by this plan.
- **Blank is not zero.** An anomalous instance has `worked = nil`. A real zero-hour day (punch in, straight out) stays `0.0`. The two must never be conflated — `holiday_pay_days/2` tests `wh == 0.0` and would misread nil as absence.
- **The window never judges a punch.** `start_time` / `normal_hour` exist to group and to display. A punch is never anomalous for falling outside them — 34.5% of real punches fall outside 08:00–17:00.
- **Never run bare `mix format`** — it rewrites ~14 already-unformatted files on master. Format only files you touched: `mix format <path> <path>`.
- **Commit directly to `master`.** Solo workflow, no feature branches.
- Schemas use `use FullCircle.Schema` (binary_id PK and FKs). Migrations inherit `migration_primary_key: [name: :id, type: :binary_id]` and `migration_timestamps: [type: :timestamptz]` from `config/config.exs:39-40`, so plain `create table/2` and plain `timestamps/1` are already correct.
- Anomalies are exactly two: an odd punch count in an instance, and a span greater than `max_hour`. Nothing else.

### Additions made during planning

1. **`is_default`** on `work_shifts` (boolean, one true row per company, enforced by a partial unique index). Resolving General by the literal string `"General"` would break the moment someone renames it, and the fallback path runs on every punch. The spec has been updated to match.
2. **The default shift is seeded by `Sys.create_company/2`, not only by the migration.** A migration seeds the companies that exist when it runs; every company created afterwards — including every test fixture, since migrations run against an empty `companies` table — would have no `is_default` row, and `HR.default_work_shift/1` is `Repo.get_by!`, so the first punch in a new tenant would raise. It joins the default accounts, tax codes, gapless doc ids and salary types already seeded there (`sys.ex:484-530`).
3. **The spec's pay-slip block is dropped**, on the evidence in the constraint above — it would have demanded impossible repairs from off-site staff and made 61 already-paid employee-months unre-runnable. The red row, which those days already have today, is the whole signal.

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `lib/full_circle/hr/work_shift.ex` | Schema, changeset, and the cutover / nominal-end arithmetic. Pure functions, no Repo. |
| `lib/full_circle/hr/employee_work_shift.ex` | Assignment schema + changeset, including overlap rejection. |
| `lib/full_circle/hr/shift_instance.ex` | Grouping and derivation: pairs, hours, pay date, anomaly, punch kind, flag. Pure — takes punches, returns a struct. |
| `lib/full_circle_web/live/work_shift_live/{index,form,index_component}.ex` | Work Shifts maintenance page. |
| `priv/repo/migrations/*_create_work_shifts.exs` | The two tables + seed General. |
| `priv/repo/migrations/*_add_work_shift_to_time_attendences.exs` | Columns, drop dead `shift_id`, backfill. |
| `test/full_circle/work_shift_test.exs` | Arithmetic, resolution, grouping, derivation, backfill gate. |
| `test/full_circle_web/live/work_shift_live_test.exs` | CRUD page + assignment UI. |

**Modified**

| File | Change |
|---|---|
| `lib/full_circle/hr.ex` | `shift_for/3`, `resolve_punch_shift/2`, `rebuild_instance/4`, instance queries, monthly totals, `holiday_pay_days/2`, fingerprint import + dedupe, the `emp_time_list` CTE, the pay-slip edit lock keyed to the instance pay date |
| `lib/full_circle/sys.ex` | Seed the default shift in `create_company/2` |
| `lib/full_circle/HR/timeattend.ex` | New fields; `flag` no longer required |
| `lib/full_circle/punch_gate.ex` | Replace `rebuild_day_flags/3` with instance re-resolution |
| `lib/full_circle/hr/finger_print_import.ex` | Stop emitting `flag: nil` past index 6 |
| `lib/full_circle_web/live/helpers.ex` | Delete `make_timeattend_list/2` |
| `lib/full_circle_web/live/time_attend_live/punch_time_component.ex` | Render N punches, wrap, drop the 6-tuple destructure |
| `lib/full_circle_web/live/time_attend_live/{punch_index_component,punch_card_component,punch_card,form_component}.ex` | Use instances; drop the flag dropdown |
| `lib/full_circle_web/live/employee_live/form.ex` | Assignment section |
| `lib/full_circle/authorization.ex`, `router.ex`, `dashboard_live.ex` | Permissions, routes, link |
| `priv/gettext/{en,zh}/LC_MESSAGES/default.po` | New msgids |
| `.claude/skills/{punch-card-payroll,finger-print-import,qr-gate-punch}.md` | Document the shift model |

`hr.ex` is already ~1,400 lines. Rather than growing it further with the grouping maths, that logic goes in `lib/full_circle/hr/shift_instance.ex` as pure functions; `hr.ex` keeps only the Repo-touching wrappers. Same split `PunchGate` already uses for `PhotoPruner`.

---

## Task 1: `work_shifts`, `employee_work_shifts`, and the cutover arithmetic

**Files:**
- Create: `priv/repo/migrations/20260912090000_create_work_shifts.exs`
- Create: `lib/full_circle/hr/work_shift.ex`, `lib/full_circle/hr/employee_work_shift.ex`
- Create: `test/full_circle/work_shift_test.exs`
- Modify: `lib/full_circle/sys.ex` (seed the default shift in `create_company/2`)

**Interfaces:**
- Produces: `FullCircle.HR.WorkShift` with `name, start_time, normal_hour, max_hour, is_default, company_id`; `changeset/2`.
- Produces: `WorkShift.cutover_time(%WorkShift{}) :: Time.t()` and `WorkShift.nominal_end(%WorkShift{}) :: Time.t()` — pure, no Repo.
- Produces: `FullCircle.HR.EmployeeWorkShift` with `employee_id, work_shift_id, effective_from, effective_to`; `changeset/2` rejecting overlaps.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle/work_shift_test.exs`:

```elixir
defmodule FullCircle.WorkShiftTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.HR.{WorkShift, EmployeeWorkShift}
  alias FullCircle.Repo

  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  defp shift(company, attrs) do
    %WorkShift{}
    |> WorkShift.changeset(
      Map.merge(
        %{
          company_id: company.id,
          name: "Night",
          start_time: ~T[17:00:00],
          normal_hour: "9",
          max_hour: "12"
        },
        attrs
      )
    )
    |> Repo.insert()
  end

  describe "cutover_time/1" do
    test "General 08:00 with max 12 cuts over at 02:00", ctx do
      {:ok, ws} =
        shift(ctx.company, %{name: "General", start_time: ~T[08:00:00]})

      assert WorkShift.cutover_time(ws) == ~T[02:00:00]
    end

    test "Night 17:00 with max 12 cuts over at 11:00", ctx do
      {:ok, ws} = shift(ctx.company, %{})
      assert WorkShift.cutover_time(ws) == ~T[11:00:00]
    end

    test "a wider tolerance pulls the cutover closer to the start", ctx do
      {:ok, ws} = shift(ctx.company, %{start_time: ~T[08:00:00], max_hour: "16"})
      # 08:00 + (24+16)/2 = 08:00 + 20h = 04:00
      assert WorkShift.cutover_time(ws) == ~T[04:00:00]
    end
  end

  describe "nominal_end/1" do
    test "start plus normal_hour, for display only", ctx do
      {:ok, gen} = shift(ctx.company, %{name: "General", start_time: ~T[08:00:00]})
      assert WorkShift.nominal_end(gen) == ~T[17:00:00]

      {:ok, night} = shift(ctx.company, %{})
      assert WorkShift.nominal_end(night) == ~T[02:00:00]
    end
  end

  describe "WorkShift changeset" do
    test "requires the core fields", ctx do
      cs = WorkShift.changeset(%WorkShift{}, %{company_id: ctx.company.id})
      refute cs.valid?
      assert %{name: _, start_time: _, normal_hour: _, max_hour: _} = errors_on(cs)
    end

    test "max_hour must be at least normal_hour", ctx do
      assert {:error, cs} =
               shift(ctx.company, %{normal_hour: "12", max_hour: "9"})

      assert %{max_hour: _} = errors_on(cs)
    end

    test "max_hour must be under 24", ctx do
      assert {:error, cs} = shift(ctx.company, %{max_hour: "24"})
      assert %{max_hour: _} = errors_on(cs)
    end

    test "name is unique per company", ctx do
      assert {:ok, _} = shift(ctx.company, %{name: "Night"})
      assert {:error, cs} = shift(ctx.company, %{name: "Night"})
      assert %{name: _} = errors_on(cs)
    end

    # The fixture company already owns the seeded General default (see the
    # "General is seeded" describe below), so this asserts against that one
    # rather than creating a first default of its own.
    test "only one default per company", ctx do
      assert {:error, cs} = shift(ctx.company, %{name: "B", is_default: true})
      assert %{is_default: _} = errors_on(cs)
    end
  end

  describe "General is seeded" do
    test "every company gets exactly one default General shift", ctx do
      # company_fixture/2 calls Sys.create_company/2, which seeds this the same
      # way it seeds default accounts, tax codes and salary types. The migration
      # only covers companies that existed when it ran.
      gen = Repo.get_by!(WorkShift, company_id: ctx.company.id, is_default: true)
      assert gen.name == "General"
      assert gen.start_time == ~T[08:00:00]
      assert Decimal.equal?(gen.normal_hour, Decimal.new("9"))
      assert Decimal.equal?(gen.max_hour, Decimal.new("12"))
      assert WorkShift.cutover_time(gen) == ~T[02:00:00]
      assert WorkShift.nominal_end(gen) == ~T[17:00:00]
    end

    test "a company created after the migration still has one", ctx do
      other = company_fixture(ctx.admin, %{name: "Second Co #{System.unique_integer([:positive])}"})

      assert %WorkShift{name: "General"} =
               FullCircle.HR.default_work_shift(other)
    end
  end

  describe "EmployeeWorkShift changeset" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      {:ok, ws} = shift(ctx.company, %{})
      %{emp: emp, ws: ws}
    end

    defp assign(emp, ws, from, to \\ nil) do
      %EmployeeWorkShift{}
      |> EmployeeWorkShift.changeset(%{
        employee_id: emp.id,
        work_shift_id: ws.id,
        effective_from: from,
        effective_to: to
      })
      |> Repo.insert()
    end

    test "accepts a dated assignment", ctx do
      assert {:ok, a} = assign(ctx.emp, ctx.ws, ~D[2026-05-01], ~D[2026-05-31])
      assert a.effective_from == ~D[2026-05-01]
    end

    test "effective_to may be open ended", ctx do
      assert {:ok, a} = assign(ctx.emp, ctx.ws, ~D[2026-05-01])
      assert is_nil(a.effective_to)
    end

    test "effective_to cannot precede effective_from", ctx do
      assert {:error, cs} = assign(ctx.emp, ctx.ws, ~D[2026-05-31], ~D[2026-05-01])
      assert %{effective_to: _} = errors_on(cs)
    end

    test "overlapping ranges for one employee are rejected", ctx do
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-05-01], ~D[2026-05-31])
      assert {:error, cs} = assign(ctx.emp, ctx.ws, ~D[2026-05-15], ~D[2026-06-15])
      assert %{effective_from: _} = errors_on(cs)
    end

    test "an open ended range blocks anything after it", ctx do
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-05-01])
      assert {:error, cs} = assign(ctx.emp, ctx.ws, ~D[2026-09-01])
      assert %{effective_from: _} = errors_on(cs)
    end

    test "adjacent, non overlapping ranges are fine", ctx do
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-05-01], ~D[2026-05-31])
      assert {:ok, _} = assign(ctx.emp, ctx.ws, ~D[2026-06-01], ~D[2026-06-30])
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mix test test/full_circle/work_shift_test.exs`
Expected: FAIL — `FullCircle.HR.WorkShift` is undefined.

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20260912090000_create_work_shifts.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.CreateWorkShifts do
  use Ecto.Migration

  def up do
    create table(:work_shifts) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :start_time, :time, null: false
      add :normal_hour, :decimal, null: false
      add :max_hour, :decimal, null: false
      add :is_default, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:work_shifts, [:company_id, :name])
    # At most one default per company; the fallback path runs on every punch,
    # so it must not depend on a name someone can rename.
    create unique_index(:work_shifts, [:company_id],
             where: "is_default",
             name: :work_shifts_one_default_per_company
           )

    create table(:employee_work_shifts) do
      add :employee_id, references(:employees, on_delete: :delete_all), null: false
      add :work_shift_id, references(:work_shifts, on_delete: :delete_all), null: false
      add :effective_from, :date, null: false
      add :effective_to, :date

      timestamps()
    end

    create index(:employee_work_shifts, [:employee_id, :effective_from])

    # Seed one General per existing company. 08:00 / 9 / 12 gives a nominal
    # 08:00-17:00 and a derived cutover of 02:00, which sits inside the empty
    # 22:00-07:00 band so grouping matches today exactly.
    execute("""
    insert into work_shifts (id, company_id, name, start_time, normal_hour, max_hour,
                             is_default, inserted_at, updated_at)
    select gen_random_uuid(), c.id, 'General', time '08:00', 9, 12, true, now(), now()
      from companies c
    """)
  end

  def down do
    drop table(:employee_work_shifts)
    drop table(:work_shifts)
  end
end
```

- [ ] **Step 4: Write the `WorkShift` schema**

Create `lib/full_circle/hr/work_shift.ex`:

```elixir
defmodule FullCircle.HR.WorkShift do
  @moduledoc """
  A shift definition: when it nominally starts, how long it nominally runs, and
  how long it is allowed to run before we stop believing it.

  `normal_hour` is **display only** — `start_time + normal_hour` is the
  human-readable end (08:00 + 9 = 17:00). It is never an operand in pay;
  overtime keeps reading `Employee.work_hours_per_day`.

  `max_hour` is a tolerance, not a duration. It is deliberately looser than
  `normal_hour` because 57% of real employee-days already span more than nine
  hours. It does two jobs: it is the anomaly threshold, and it derives the
  cutover.

  There is no `end_time`: it is derivable and nothing needs it stored.
  """
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "work_shifts" do
    field(:name, :string)
    field(:start_time, :time)
    field(:normal_hour, :decimal)
    field(:max_hour, :decimal)
    field(:is_default, :boolean, default: false)

    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  @doc """
  The time of day that separates one instance of this shift from the next.

  Midpoint between the latest possible end (`start_time + max_hour`) and the
  next day's `start_time`, which puts it in the deadest part of the off-period:

      cutover = (start_time + (24 + max_hour) / 2) mod 24

  General 08:00/12 gives 02:00; Night 17:00/12 gives 11:00.
  """
  def cutover_time(%__MODULE__{start_time: start_time, max_hour: max_hour}) do
    shift_by(start_time, (24 + Decimal.to_float(max_hour)) / 2)
  end

  @doc "Human-readable end of the shift. Display only — never used in pay."
  def nominal_end(%__MODULE__{start_time: start_time, normal_hour: normal_hour}) do
    shift_by(start_time, Decimal.to_float(normal_hour))
  end

  defp shift_by(%Time{} = t, hours) do
    total = Integer.mod(t.hour * 60 + t.minute + round(hours * 60), 24 * 60)
    Time.new!(div(total, 60), rem(total, 60), 0)
  end

  def changeset(st, attrs) do
    st
    |> cast(attrs, [:name, :start_time, :normal_hour, :max_hour, :is_default, :company_id])
    |> validate_required([:name, :start_time, :normal_hour, :max_hour, :company_id])
    |> validate_number(:normal_hour, greater_than: 0, less_than_or_equal_to: 24)
    |> validate_number(:max_hour, greater_than: 0, less_than: 24)
    |> validate_max_not_below_normal()
    |> unique_constraint(:name,
      name: :work_shifts_company_id_name_index,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:is_default,
      name: :work_shifts_one_default_per_company,
      message: gettext("there is already a default shift")
    )
  end

  defp validate_max_not_below_normal(cs) do
    normal = get_field(cs, :normal_hour)
    max = get_field(cs, :max_hour)

    if normal && max && Decimal.compare(max, normal) == :lt do
      add_error(cs, :max_hour, gettext("must not be less than normal hour"))
    else
      cs
    end
  end
end
```

- [ ] **Step 5: Write the `EmployeeWorkShift` schema**

Create `lib/full_circle/hr/employee_work_shift.ex`:

```elixir
defmodule FullCircle.HR.EmployeeWorkShift do
  @moduledoc """
  Assigns an employee to a shift for a date range.

  Dated so that re-running an old month still sees that month's roster.
  An employee with **no effective row** resolves to the company's default
  (General) shift, so most staff never need a row here.
  """
  use FullCircle.Schema
  import Ecto.Changeset
  import Ecto.Query
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Repo

  schema "employee_work_shifts" do
    field(:effective_from, :date)
    field(:effective_to, :date)

    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:work_shift, FullCircle.HR.WorkShift)

    timestamps(type: :utc_datetime)
  end

  def changeset(st, attrs) do
    st
    |> cast(attrs, [:employee_id, :work_shift_id, :effective_from, :effective_to])
    |> validate_required([:employee_id, :work_shift_id, :effective_from])
    |> validate_to_after_from()
    |> validate_no_overlap()
  end

  defp validate_to_after_from(cs) do
    from = get_field(cs, :effective_from)
    to = get_field(cs, :effective_to)

    if from && to && Date.compare(to, from) == :lt do
      add_error(cs, :effective_to, gettext("must not be before effective from"))
    else
      cs
    end
  end

  # Two ranges overlap when each starts on or before the other ends. A nil
  # effective_to is an open end, so it overlaps everything after its start.
  defp validate_no_overlap(cs) do
    emp_id = get_field(cs, :employee_id)
    from = get_field(cs, :effective_from)
    to = get_field(cs, :effective_to)
    id = get_field(cs, :id)

    if emp_id && from do
      clash? =
        from(e in __MODULE__,
          where: e.employee_id == ^emp_id,
          where: is_nil(e.effective_to) or e.effective_to >= ^from
        )
        |> exclude_self(id)
        |> exclude_starting_after(to)
        |> Repo.exists?()

      if clash?,
        do: add_error(cs, :effective_from, gettext("overlaps an existing assignment")),
        else: cs
    else
      cs
    end
  end

  defp exclude_self(query, nil), do: query
  defp exclude_self(query, id), do: from(e in query, where: e.id != ^id)

  defp exclude_starting_after(query, nil), do: query
  defp exclude_starting_after(query, to), do: from(e in query, where: e.effective_from <= ^to)
end
```

- [ ] **Step 6: Seed the default shift for every *new* company**

The migration seeds the companies that exist when it runs. Everything created afterwards — every new tenant, and **every test fixture**, since migrations run against an empty `companies` table — would have no `is_default` row, and `HR.default_work_shift/1` is `Repo.get_by!`. The first punch in such a company would raise.

In `lib/full_circle/sys.ex`, add a step to the `create_company/2` Multi, immediately after `:create_default_salary_types` (around `sys.ex:515-530`), following the same `insert_all` shape it already uses:

```elixir
    |> Multi.insert_all(
      :create_default_work_shift,
      FullCircle.HR.WorkShift,
      fn %{create_company: c} ->
        time = DateTime.truncate(Timex.now(), :second)

        [
          %{
            company_id: c.id,
            name: "General",
            start_time: ~T[08:00:00],
            normal_hour: Decimal.new("9"),
            max_hour: Decimal.new("12"),
            is_default: true,
            inserted_at: time,
            updated_at: time
          }
        ]
      end
    )
```

`insert_all` autogenerates the `binary_id` primary key exactly as it does for the salary types above it, so no explicit `id` is needed.

- [ ] **Step 7: Migrate and run the tests**

```bash
mix ecto.migrate
mix test test/full_circle/work_shift_test.exs
```
Expected: PASS — including `"a company created after the migration still has one"`, which fails without Step 6.

- [ ] **Step 8: Format and commit**

```bash
mix format priv/repo/migrations/20260912090000_create_work_shifts.exs \
  lib/full_circle/hr/work_shift.ex lib/full_circle/hr/employee_work_shift.ex \
  lib/full_circle/sys.ex test/full_circle/work_shift_test.exs
git add -A
git commit -m "feat(hr): work_shifts and employee_work_shifts with derived cutover

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 2: Resolving a punch to a shift and an instance

**Files:**
- Modify: `lib/full_circle/hr.ex`
- Modify: `test/full_circle/work_shift_test.exs`

**Interfaces:**
- Consumes: `WorkShift.cutover_time/1` (Task 1).
- Produces: `HR.default_work_shift(company) :: %WorkShift{}` — the company's `is_default` row.
- Produces: `HR.shift_for(employee_id, company, %Date{}) :: %WorkShift{}` — the effective assignment, else the default.
- Produces: `HR.instance_anchor(%WorkShift{}, %DateTime{} = local) :: Date.t()` — the local date of the instance's opening boundary.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle/work_shift_test.exs`:

```elixir
  describe "shift_for/3 and instance_anchor/2" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      {:ok, night} = shift(ctx.company, %{})
      gen = FullCircle.HR.default_work_shift(ctx.company)
      %{emp: emp, night: night, gen: gen}
    end

    defp local(ctx, s), do: Timex.parse!(s, "{RFC3339}") |> DateTime.shift_zone!(ctx.company.timezone)

    test "an unassigned employee resolves to General", ctx do
      ws = FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-05-05])
      assert ws.id == ctx.gen.id
      assert ws.is_default
    end

    test "an assignment wins inside its range and not outside it", ctx do
      Repo.insert!(%EmployeeWorkShift{
        employee_id: ctx.emp.id,
        work_shift_id: ctx.night.id,
        effective_from: ~D[2026-05-01],
        effective_to: ~D[2026-05-31]
      })

      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-05-15]).id == ctx.night.id
      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-04-30]).id == ctx.gen.id
      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2026-06-01]).id == ctx.gen.id
    end

    test "an open ended assignment applies from its start onward", ctx do
      Repo.insert!(%EmployeeWorkShift{
        employee_id: ctx.emp.id,
        work_shift_id: ctx.night.id,
        effective_from: ~D[2026-05-01]
      })

      assert FullCircle.HR.shift_for(ctx.emp.id, ctx.company, ~D[2027-01-01]).id == ctx.night.id
    end

    test "General anchors every punch to its own calendar day", ctx do
      # 07:00 and 21:00 both sit after the 02:00 cutover, so both anchor to 5/5.
      assert FullCircle.HR.instance_anchor(ctx.gen, local(ctx, "2026-05-05T07:00:00+08:00")) ==
               ~D[2026-05-05]

      assert FullCircle.HR.instance_anchor(ctx.gen, local(ctx, "2026-05-05T21:00:00+08:00")) ==
               ~D[2026-05-05]
    end

    test "General still groups a punch just past midnight with the day before", ctx do
      assert FullCircle.HR.instance_anchor(ctx.gen, local(ctx, "2026-05-06T00:30:00+08:00")) ==
               ~D[2026-05-05]
    end

    test "Night groups 17:00 and the following 02:00 into one instance", ctx do
      a = FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-05T17:00:00+08:00"))
      b = FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-06T02:00:00+08:00"))
      assert a == ~D[2026-05-05]
      assert b == ~D[2026-05-05]
    end

    test "a punch exactly on the cutover opens the later instance", ctx do
      # Night cutover is 11:00.
      assert FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-06T11:00:00+08:00")) ==
               ~D[2026-05-06]

      assert FullCircle.HR.instance_anchor(ctx.night, local(ctx, "2026-05-06T10:59:59+08:00")) ==
               ~D[2026-05-05]
    end

    test "drift of several hours does not change the instance", ctx do
      for t <- ["2026-05-06T01:00:00+08:00", "2026-05-06T02:00:00+08:00", "2026-05-06T04:00:00+08:00"] do
        assert FullCircle.HR.instance_anchor(ctx.night, local(ctx, t)) == ~D[2026-05-05]
      end
    end
  end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle/work_shift_test.exs`
Expected: FAIL — `HR.default_work_shift/1` is undefined.

- [ ] **Step 3: Implement the three functions**

Add to `lib/full_circle/hr.ex` (and add `alias FullCircle.HR.{WorkShift, EmployeeWorkShift}` to the module's aliases):

```elixir
  @doc "The company's default (General) shift — the fallback for unassigned employees."
  def default_work_shift(company) do
    Repo.get_by!(WorkShift, company_id: company.id, is_default: true)
  end

  @doc """
  The shift an employee works on `date`: their effective assignment, else the
  company default. Most staff have no assignment row at all.
  """
  def shift_for(employee_id, company, %Date{} = date) do
    from(ews in EmployeeWorkShift,
      join: ws in WorkShift,
      on: ws.id == ews.work_shift_id,
      where: ews.employee_id == ^employee_id,
      where: ws.company_id == ^company.id,
      where: ews.effective_from <= ^date,
      where: is_nil(ews.effective_to) or ews.effective_to >= ^date,
      order_by: [desc: ews.effective_from],
      limit: 1,
      select: ws
    )
    |> Repo.one() || default_work_shift(company)
  end

  @doc """
  The local date identifying the shift instance a punch belongs to.

  Instances run `[cutover(D), cutover(D+1))`, and the anchor is D. A punch at or
  after the cutover opens that day's instance; one before it still belongs to
  the previous day's.
  """
  def instance_anchor(%WorkShift{} = shift, %DateTime{} = local) do
    cutover = WorkShift.cutover_time(shift)
    date = DateTime.to_date(local)

    if Time.compare(DateTime.to_time(local), cutover) in [:gt, :eq],
      do: date,
      else: Date.add(date, -1)
  end
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle/work_shift_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/hr.ex test/full_circle/work_shift_test.exs
git add -A
git commit -m "feat(hr): resolve a punch to its work shift and instance anchor

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 3: `time_attendences` columns, backfill, and the equality gate

**Files:**
- Create: `priv/repo/migrations/20260912091000_add_work_shift_to_time_attendences.exs`
- Modify: `lib/full_circle/HR/timeattend.ex`
- Modify: `test/full_circle/work_shift_test.exs`

**Interfaces:**
- Consumes: `HR.default_work_shift/1`, `HR.instance_anchor/2` (Task 2).
- Produces: `TimeAttend` fields `work_shift_id`, `work_shift_date`, `punch_kind`, cast by all three changesets.

The whole safety argument for this migration is that General's cutover (02:00) sits inside a nine-hour band with **zero** historical punches, so instance grouping must come out identical to calendar-day grouping. That is not an assumption to take on trust — the migration asserts it and refuses to complete if it is false.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle/work_shift_test.exs`:

```elixir
  describe "time_attendences shift columns" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    defp punch!(ctx, iso) do
      Repo.insert!(%FullCircle.HR.TimeAttend{
        company_id: ctx.company.id,
        employee_id: ctx.emp.id,
        user_id: ctx.admin.id,
        punch_time: Timex.parse!(iso, "{RFC3339}") |> DateTime.truncate(:second),
        flag: "1_IN_1",
        status: "Draft",
        input_medium: "Manual"
      })
    end

    test "the schema carries the new fields", _ctx do
      fields = FullCircle.HR.TimeAttend.__schema__(:fields)
      assert :work_shift_id in fields
      assert :work_shift_date in fields
      assert :punch_kind in fields
      refute :shift_id in fields
    end

    test "the dead shift_id column is gone from the table", _ctx do
      {:ok, r} =
        Repo.query(
          "select count(*) from information_schema.columns
            where table_name = 'time_attendences' and column_name = 'shift_id'"
        )

      assert [[0]] = r.rows
    end

    test "General anchors match the calendar date for the whole working day", ctx do
      gen = FullCircle.HR.default_work_shift(ctx.company)

      for iso <- [
            "2026-05-05T07:00:00+08:00",
            "2026-05-05T12:00:00+08:00",
            "2026-05-05T17:00:00+08:00",
            "2026-05-05T21:00:00+08:00"
          ] do
        ta = punch!(ctx, iso)
        local = DateTime.shift_zone!(ta.punch_time, ctx.company.timezone)

        assert FullCircle.HR.instance_anchor(gen, local) == DateTime.to_date(local),
               "#{iso} must anchor to its own calendar date or the backfill gate is unsafe"
      end
    end

    test "a punch inside the dead band is exactly what the gate exists to catch", ctx do
      # 01:00 is before General's 02:00 cutover, so it anchors to the previous
      # day. No such punch exists in 23,902 rows of history, which is why the
      # backfill is safe - and why the migration asserts it rather than assuming.
      gen = FullCircle.HR.default_work_shift(ctx.company)
      ta = punch!(ctx, "2026-05-06T01:00:00+08:00")
      local = DateTime.shift_zone!(ta.punch_time, ctx.company.timezone)

      assert FullCircle.HR.instance_anchor(gen, local) == ~D[2026-05-05]
      refute FullCircle.HR.instance_anchor(gen, local) == DateTime.to_date(local)
    end
  end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle/work_shift_test.exs`
Expected: FAIL — `:work_shift_id` is not in `TimeAttend.__schema__(:fields)`.

- [ ] **Step 3: Write the migration**

Create `priv/repo/migrations/20260912091000_add_work_shift_to_time_attendences.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.AddWorkShiftToTimeAttendences do
  use Ecto.Migration

  def up do
    alter table(:time_attendences) do
      add :work_shift_id, references(:work_shifts, on_delete: :nilify_all)
      add :work_shift_date, :date
      add :punch_kind, :string

      # Dead since 2023: a :string column never mapped in the schema, whose
      # index was already dropped in 20260609000823 as "unused anywhere in lib/".
      remove :shift_id
    end

    create index(:time_attendences, [:company_id, :employee_id, :work_shift_id, :work_shift_date],
             name: :time_attendences_instance_index
           )

    # Every existing punch belongs to its company's General shift.
    execute("""
    update time_attendences ta
       set work_shift_id = ws.id,
           work_shift_date = (ta.punch_time at time zone c.timezone)::date
      from companies c
      join work_shifts ws on ws.company_id = c.id and ws.is_default
     where ta.company_id = c.id
    """)

    # Derive punch_kind and the display flag from position within the instance.
    execute("""
    with numbered as (
      select id,
             row_number() over (partition by employee_id, work_shift_id, work_shift_date
                                order by punch_time) rn
        from time_attendences
       where work_shift_id is not null
    )
    update time_attendences ta
       set punch_kind = case when mod(n.rn, 2) = 1 then 'IN' else 'OUT' end,
           flag = ((n.rn + 1) / 2)::text
                  || '_' || (case when mod(n.rn, 2) = 1 then 'IN' else 'OUT' end)
                  || '_' || ((n.rn + 1) / 2)::text
      from numbered n
     where ta.id = n.id
    """)

    # CUTOVER GATE. The backfill above writes the punch's local *date* as the
    # anchor. That is only correct where the punch's local *time* is at or after
    # its shift's cutover; a punch before the cutover belongs to the previous
    # day's instance, which is exactly the regrouping this migration claims does
    # not happen. So test the punch against the cutover, not against the
    # expression it was just assigned from - comparing work_shift_date with
    # (punch_time at time zone tz)::date is a tautology that passes on any data.
    #
    # cutover = (start_time + (24 + max_hour)/2) mod 24, the same arithmetic as
    # WorkShift.cutover_time/1. For the seeded General (08:00 / 12) that is
    # 02:00, and there are zero punches between 22:00 and 06:59 in 23,902 rows.
    execute("""
    do $$
    declare bad integer;
    begin
      select count(*) into bad
        from time_attendences ta
        join companies c on c.id = ta.company_id
        join work_shifts ws on ws.id = ta.work_shift_id
       where (ta.punch_time at time zone c.timezone)::time
             < ((ws.start_time + make_interval(mins => ((24 + ws.max_hour) * 30)::int))::time);

      if bad > 0 then
        raise exception
          'work shift backfill regroups % punches across a cutover - backfill is not behaviour preserving', bad;
      end if;
    end $$;
    """)
  end

  def down do
    drop index(:time_attendences, [], name: :time_attendences_instance_index)

    alter table(:time_attendences) do
      remove :work_shift_id
      remove :work_shift_date
      remove :punch_kind
      add :shift_id, :string
    end
  end
end
```

- [ ] **Step 4: Add the fields to the schema**

In `lib/full_circle/HR/timeattend.ex`, add to the `schema` block after `field(:client_id, :string)`:

```elixir
    field(:work_shift_date, :date)
    field(:punch_kind, :string)
    belongs_to(:work_shift, FullCircle.HR.WorkShift)
```

Then add `:work_shift_id`, `:work_shift_date` and `:punch_kind` to the `cast` list of **all three** changesets (`finger_print_log_changeset/2`, `changeset_gate/2`, `data_entry_changeset/2`). Leave every `validate_required` list untouched for now — Task 5 removes `:flag` from them, along with the derivation that replaces it.

- [ ] **Step 5: Migrate and run the tests**

```bash
mix ecto.migrate
mix test test/full_circle/work_shift_test.exs
```
Expected: PASS, and the migration completes without raising — which is itself the gate passing on your dev database.

- [ ] **Step 6: Prove the gate on real data**

```bash
mix ecto.rollback -n 1 && mix ecto.migrate
```
Expected: completes silently. On a database with a punch before its shift's cutover it would instead abort with `work shift backfill regroups N punches across a cutover`. That is the intended behaviour — investigate rather than weaken the gate.

Then check hours parity directly. The cutover gate proves the *grouping* is unchanged; this proves the *hours* are, reproducing `count_hours_work/1` in SQL (pairs 1-2, 3-4, …, an unpaired last punch contributing 0.0) for both groupings and diffing them:

```bash
PGPASSWORD=... psql -h localhost -U full_circle -d full_circle_dev -c "
with numbered as (
  select ta.employee_id, ta.punch_time, ta.work_shift_id, ta.work_shift_date,
         (ta.punch_time at time zone c.timezone)::date as cal_date
    from time_attendences ta join companies c on c.id = ta.company_id),
cal as (
  select employee_id, cal_date,
         sum(case when rn % 2 = 1 and nxt is not null
                  then extract(epoch from (nxt - punch_time))/3600.0 else 0 end) wh
    from (select *, row_number() over w rn, lead(punch_time) over w nxt from numbered
          window w as (partition by employee_id, cal_date order by punch_time)) x
   group by 1,2),
ins as (
  select employee_id, work_shift_id, work_shift_date,
         sum(case when rn % 2 = 1 and nxt is not null
                  then extract(epoch from (nxt - punch_time))/3600.0 else 0 end) wh
    from (select *, row_number() over w rn, lead(punch_time) over w nxt from numbered
          window w as (partition by employee_id, work_shift_id, work_shift_date order by punch_time)) x
   group by 1,2,3)
select count(*) as mismatched_days
  from cal join ins
    on ins.employee_id = cal.employee_id and ins.work_shift_date = cal.cal_date
 where round(cal.wh::numeric, 4) is distinct from round(ins.wh::numeric, 4);"
```
Expected: `0`. Measured on the current restore, both sides total **51,608.84 h over 6,619 employee-days**.

Note what this comparison deliberately does *not* do: it does not compare against the new `nil`. An odd day is rescued to `0.0` today and becomes `nil` after Task 7, and 328 employee-days are odd — comparing those two directly would fail a gate they are not evidence against. The parity that matters is the pairing arithmetic, which is what this measures.

- [ ] **Step 7: Format and commit**

```bash
mix format priv/repo/migrations/20260912091000_add_work_shift_to_time_attendences.exs \
  lib/full_circle/HR/timeattend.ex test/full_circle/work_shift_test.exs
git add -A
git commit -m "feat(hr): attach punches to work shift instances, with a backfill gate

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 4: Grouping and derivation

**Files:**
- Create: `lib/full_circle/hr/shift_instance.ex`
- Create: `test/full_circle/shift_instance_test.exs`

**Interfaces:**
- Consumes: `WorkShift` (Task 1).
- Produces: `FullCircle.HR.ShiftInstance` struct with `employee_id, work_shift_id, work_shift_date, punches, worked, span_hours, pay_date, anomaly`.
- Produces: `ShiftInstance.build(punches, %WorkShift{}, timezone) :: %ShiftInstance{} | nil`.
- Produces: `ShiftInstance.punch_kind(index) :: "IN" | "OUT"` and `ShiftInstance.flag(index) :: String.t()`, both 1-based.

Pure functions only — no Repo — so the maths is testable without a database and `hr.ex` does not grow another 200 lines.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle/shift_instance_test.exs`:

```elixir
defmodule FullCircle.ShiftInstanceTest do
  use ExUnit.Case, async: true

  alias FullCircle.HR.{ShiftInstance, WorkShift, TimeAttend}

  @tz "Asia/Kuala_Lumpur"

  defp night,
    do: %WorkShift{
      id: "ws-night",
      name: "Night",
      start_time: ~T[17:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12")
    }

  defp general,
    do: %WorkShift{
      id: "ws-gen",
      name: "General",
      start_time: ~T[08:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12"),
      is_default: true
    }

  defp p(iso),
    do: %TimeAttend{
      employee_id: "emp-1",
      work_shift_date: ~D[2026-05-05],
      punch_time: Timex.parse!(iso, "{RFC3339}")
    }

  describe "build/3 hours" do
    test "a night shift drifting early in and late out is paid in full" do
      punches = [
        p("2026-05-05T16:45:00+08:00"),
        p("2026-05-05T20:00:00+08:00"),
        p("2026-05-05T20:30:00+08:00"),
        p("2026-05-06T02:20:00+08:00")
      ]

      inst = ShiftInstance.build(punches, night(), @tz)

      assert_in_delta inst.worked, 9.083, 0.001
      assert is_nil(inst.anomaly)
      assert inst.pay_date == ~D[2026-05-06]
      assert inst.work_shift_date == ~D[2026-05-05]
    end

    test "a General day pays the same as calendar day grouping does today" do
      punches = [
        p("2026-05-05T07:00:00+08:00"),
        p("2026-05-05T12:00:00+08:00"),
        p("2026-05-05T13:00:00+08:00"),
        p("2026-05-05T17:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)

      assert_in_delta inst.worked, 9.0, 0.001
      assert inst.pay_date == ~D[2026-05-05]
      assert is_nil(inst.anomaly)
    end

    test "four pairs are all paid, with no ceiling at three" do
      punches =
        Enum.map(
          [
            "2026-05-05T08:00:00+08:00",
            "2026-05-05T10:00:00+08:00",
            "2026-05-05T10:30:00+08:00",
            "2026-05-05T12:30:00+08:00",
            "2026-05-05T13:30:00+08:00",
            "2026-05-05T15:30:00+08:00",
            "2026-05-05T16:00:00+08:00",
            "2026-05-05T18:00:00+08:00"
          ],
          &p/1
        )

      inst = ShiftInstance.build(punches, general(), @tz)

      assert length(inst.punches) == 8
      assert_in_delta inst.worked, 8.0, 0.001
      assert is_nil(inst.anomaly)
    end

    test "punches arriving out of order are sorted before pairing" do
      punches = [
        p("2026-05-05T17:00:00+08:00"),
        p("2026-05-05T08:00:00+08:00")
      ]

      assert_in_delta ShiftInstance.build(punches, general(), @tz).worked, 9.0, 0.001
    end

    test "a genuine zero hour day is 0.0, not nil" do
      punches = [
        p("2026-05-05T08:00:00+08:00"),
        p("2026-05-05T08:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)
      assert inst.worked == 0.0
      assert is_nil(inst.anomaly)
    end
  end

  describe "build/3 anomalies" do
    test "an odd punch count is a missing punch, and hours are blank" do
      punches = [
        p("2026-05-05T08:00:00+08:00"),
        p("2026-05-05T12:00:00+08:00"),
        p("2026-05-05T13:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)
      assert inst.anomaly == :missing_punch
      assert is_nil(inst.worked)
    end

    test "a single punch is a missing punch" do
      inst = ShiftInstance.build([p("2026-05-05T08:00:00+08:00")], general(), @tz)
      assert inst.anomaly == :missing_punch
      assert is_nil(inst.worked)
    end

    # Both punches are inside one General window (cutover 02:00), which is what
    # :too_long requires. Note that 08:00 on the 5th with 17:00 on the *6th* is
    # NOT this case - those are two instances of one punch each, two
    # :missing_punch days. Task 7 covers that; feeding both to build/3 here
    # would test an input the resolver cannot produce.
    test "a span beyond max_hour is too_long, and hours are blank" do
      punches = [
        p("2026-05-05T07:00:00+08:00"),
        p("2026-05-05T21:00:00+08:00")
      ]

      inst = ShiftInstance.build(punches, general(), @tz)
      assert inst.anomaly == :too_long
      assert is_nil(inst.worked)
      assert_in_delta inst.span_hours, 14.0, 0.001
    end

    test "a span exactly at max_hour is not an anomaly" do
      punches = [
        p("2026-05-05T08:00:00+08:00"),
        p("2026-05-05T20:00:00+08:00")
      ]

      assert is_nil(ShiftInstance.build(punches, general(), @tz).anomaly)
    end

    test "no punches means no instance" do
      assert is_nil(ShiftInstance.build([], general(), @tz))
    end
  end

  describe "punch_kind/1 and flag/1" do
    test "odd positions are IN, even are OUT" do
      assert ShiftInstance.punch_kind(1) == "IN"
      assert ShiftInstance.punch_kind(2) == "OUT"
      assert ShiftInstance.punch_kind(7) == "IN"
      assert ShiftInstance.punch_kind(8) == "OUT"
    end

    test "flags number the pair and do not stop at three" do
      assert ShiftInstance.flag(1) == "1_IN_1"
      assert ShiftInstance.flag(2) == "1_OUT_1"
      assert ShiftInstance.flag(5) == "3_IN_3"
      assert ShiftInstance.flag(6) == "3_OUT_3"
      assert ShiftInstance.flag(7) == "4_IN_4"
      assert ShiftInstance.flag(8) == "4_OUT_4"
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle/shift_instance_test.exs`
Expected: FAIL — `FullCircle.HR.ShiftInstance` is undefined.

- [ ] **Step 3: Write the module**

Create `lib/full_circle/hr/shift_instance.ex`:

```elixir
defmodule FullCircle.HR.ShiftInstance do
  @moduledoc """
  One occurrence of a shift: the punches inside it, and everything derived from
  them.

  Nothing here is stored. Punches carry their grouping (`work_shift_id` +
  `work_shift_date`); hours, pay date and anomaly are computed from that
  grouping on every read, so a clerk editing a punch cannot leave a stale total
  behind — the failure mode `rebuild_day_flags/3` has today.

  `worked` is `nil`, never `0.0`, when the instance is anomalous. A real
  zero-hour day must stay distinguishable from "we cannot say", because
  `holiday_pay_days/2` reads `wh == 0.0` as a genuine absence.
  """

  alias FullCircle.HR.WorkShift

  defstruct [
    :employee_id,
    :work_shift_id,
    :work_shift_date,
    :punches,
    :worked,
    :span_hours,
    :pay_date,
    :anomaly
  ]

  @doc """
  Builds an instance from the punches grouped under it.

  `punches` need not be sorted. `timezone` is the company timezone and is used
  only to place the pay date, which is the local date of the **last** punch —
  the day the shift ended.
  """
  def build([], _shift, _timezone), do: nil

  def build(punches, %WorkShift{} = shift, timezone) do
    punches = Enum.sort_by(punches, & &1.punch_time, DateTime)
    first = hd(punches)
    last = List.last(punches)
    span = DateTime.diff(last.punch_time, first.punch_time) / 3600
    anomaly = anomaly_for(length(punches), span, shift)

    %__MODULE__{
      employee_id: first.employee_id,
      work_shift_id: shift.id,
      work_shift_date: first.work_shift_date,
      punches: punches,
      span_hours: span,
      anomaly: anomaly,
      worked: if(is_nil(anomaly), do: worked_hours(punches), else: nil),
      pay_date: last.punch_time |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    }
  end

  # Exactly two anomalies. A punch is never anomalous merely for falling
  # outside the shift's nominal window: 34.5% of real punches do.
  defp anomaly_for(count, span, %WorkShift{max_hour: max_hour}) do
    cond do
      rem(count, 2) == 1 -> :missing_punch
      span > Decimal.to_float(max_hour) -> :too_long
      true -> nil
    end
  end

  # Only reached when the count is even, so every chunk is a full pair.
  defp worked_hours(punches) do
    punches
    |> Enum.chunk_every(2)
    |> Enum.reduce(0.0, fn [in_p, out_p], acc ->
      acc + DateTime.diff(out_p.punch_time, in_p.punch_time) / 3600
    end)
  end

  @doc "Punch kind by 1-based position within the instance."
  def punch_kind(index) when rem(index, 2) == 1, do: "IN"
  def punch_kind(_index), do: "OUT"

  @doc """
  The legacy display label by 1-based position, with no ceiling at three pairs.
  Kept so existing rows and reports still read sensibly; it is no longer the
  pairing key.
  """
  def flag(index) do
    pair = div(index + 1, 2)
    "#{pair}_#{punch_kind(index)}_#{pair}"
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/full_circle/shift_instance_test.exs`
Expected: PASS, including `worked == 9.083` for the drifted night shift and `:too_long` for the 14-hour span.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/hr/shift_instance.ex test/full_circle/shift_instance_test.exs
git add -A
git commit -m "feat(hr): derive hours, pay date and anomalies per shift instance

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 5: Assign on write, renumber the instance, and fix the fingerprint importer

**Files:**
- Modify: `lib/full_circle/hr.ex:261-277` (`insert_time_attendence_from_log/2`), `:300-356` (manual CRUD — **including `delete_time_attendence_by_id/3`**, the path the punch row uses)
- Modify: `lib/full_circle/hr/finger_print_import.ex:99-110`
- Modify: `lib/full_circle/punch_gate.ex:194-223` (`rebuild_day_flags/3`), `:225-268` (`insert_punch/6`)
- Modify: `lib/full_circle/HR/timeattend.ex`
- Modify: `test/full_circle/work_shift_test.exs`

**Interfaces:**
- Consumes: `HR.shift_for/3`, `HR.instance_anchor/2` (Task 2); `ShiftInstance.punch_kind/1`, `ShiftInstance.flag/1` (Task 4).
- Produces: `HR.punch_shift_attrs(employee_id, company, %DateTime{} = punch_time) :: %{work_shift_id: binary, work_shift_date: Date.t()}`.
- Produces: `HR.rebuild_instance(company, employee_id, work_shift_id, work_shift_date) :: :ok` — renumbers `punch_kind` and `flag` by time order. **Replaces `PunchGate.rebuild_day_flags/3`, which is deleted.**
- Produces: `HR.reassign_punch(%TimeAttend{}, company) :: {:ok, %TimeAttend{}}` — resolves and rebuilds, including the instance a punch left.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle/work_shift_test.exs`:

```elixir
  describe "assignment on write" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      {:ok, {device, _}} = FullCircle.PunchGate.create_device("Gate 1", ctx.company, ctx.admin)
      {:ok, night} = shift(ctx.company, %{})
      %{emp: emp, device: device, night: night}
    end

    defp jpeg_upload do
      path = Path.join(System.tmp_dir!(), "face-#{System.unique_integer([:positive])}.jpg")

      File.write!(
        path,
        Base.decode64!(
          "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
        )
      )

      %Plug.Upload{path: path, filename: "face.jpg", content_type: "image/jpeg"}
    end

    defp gate_punch(ctx, iso) do
      FullCircle.PunchGate.ingest_punch(ctx.device, %{
        "employee_id" => ctx.emp.id,
        "punched_at" => Timex.parse!(iso, "{RFC3339}") |> DateTime.truncate(:second),
        "client_id" => Ecto.UUID.generate(),
        "photo" => jpeg_upload()
      })
    end

    defp instance_punches(ctx, date) do
      import Ecto.Query

      Repo.all(
        from t in FullCircle.HR.TimeAttend,
          where: t.employee_id == ^ctx.emp.id and t.work_shift_date == ^date,
          order_by: [asc: t.punch_time]
      )
    end

    test "a gate punch is assigned to General and numbered", ctx do
      assert {:ok, ta} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      ta = Repo.reload!(ta)

      assert ta.work_shift_id == FullCircle.HR.default_work_shift(ctx.company).id
      assert ta.work_shift_date == ~D[2026-05-05]
      assert ta.punch_kind == "IN"
      assert ta.flag == "1_IN_1"
    end

    test "a fourth pair keeps numbering instead of wrapping to 1_IN_1", ctx do
      for iso <- [
            "2026-05-05T08:00:00+08:00",
            "2026-05-05T10:00:00+08:00",
            "2026-05-05T10:30:00+08:00",
            "2026-05-05T12:30:00+08:00",
            "2026-05-05T13:30:00+08:00",
            "2026-05-05T15:30:00+08:00",
            "2026-05-05T16:00:00+08:00",
            "2026-05-05T18:00:00+08:00"
          ] do
        assert {:ok, _} = gate_punch(ctx, iso)
      end

      flags = instance_punches(ctx, ~D[2026-05-05]) |> Enum.map(& &1.flag)

      assert flags == [
               "1_IN_1",
               "1_OUT_1",
               "2_IN_2",
               "2_OUT_2",
               "3_IN_3",
               "3_OUT_3",
               "4_IN_4",
               "4_OUT_4"
             ]
    end

    test "an assigned night worker's 02:00 punch joins the previous evening", ctx do
      Repo.insert!(%EmployeeWorkShift{
        employee_id: ctx.emp.id,
        work_shift_id: ctx.night.id,
        effective_from: ~D[2026-05-01]
      })

      assert {:ok, _} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")
      assert {:ok, _} = gate_punch(ctx, "2026-05-06T02:00:00+08:00")

      punches = instance_punches(ctx, ~D[2026-05-05])
      assert length(punches) == 2
      assert Enum.map(punches, & &1.punch_kind) == ["IN", "OUT"]
      assert instance_punches(ctx, ~D[2026-05-06]) == []
    end

    test "editing a punch time out of an instance renumbers both", ctx do
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      assert {:ok, b} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")

      b
      |> Ecto.Changeset.change(%{
        punch_time: Timex.parse!("2026-05-07T09:00:00+08:00", "{RFC3339}") |> DateTime.truncate(:second)
      })
      |> Repo.update!()
      |> FullCircle.HR.reassign_punch(ctx.company)

      assert [left] = instance_punches(ctx, ~D[2026-05-05])
      assert left.flag == "1_IN_1"
      assert [moved] = instance_punches(ctx, ~D[2026-05-07])
      assert moved.flag == "1_IN_1"
      assert moved.punch_kind == "IN"
    end

    test "rebuild_day_flags is gone", _ctx do
      refute function_exported?(FullCircle.PunchGate, :rebuild_day_flags, 3)
    end
  end

  describe "fingerprint import" do
    setup ctx do
      %{emp: employee_fixture(%{}, ctx.company, ctx.admin)}
    end

    test "a seventh and eighth punch are stored, not silently discarded", ctx do
      times = [
        ~T[08:00:00],
        ~T[10:00:00],
        ~T[10:30:00],
        ~T[12:30:00],
        ~T[13:30:00],
        ~T[15:30:00],
        ~T[16:00:00],
        ~T[18:00:00]
      ]

      for t <- times do
        entry = %{
          employee_id: ctx.emp.id,
          employee_name: ctx.emp.name,
          company_id: ctx.company.id,
          user_id: ctx.admin.id,
          status: "Draft",
          input_medium: "FingerPrint",
          punch_time_local: NaiveDateTime.new!(~D[2026-05-05], t),
          punch_time:
            DateTime.new!(~D[2026-05-05], t, ctx.company.timezone)
            |> DateTime.shift_zone!("Etc/UTC")
            |> DateTime.truncate(:second)
        }

        FullCircle.HR.insert_time_attendence_from_log(entry, ctx.company)
      end

      import Ecto.Query

      count =
        Repo.one(
          from t in FullCircle.HR.TimeAttend,
            where: t.employee_id == ^ctx.emp.id,
            select: count(t.id)
        )

      assert count == 8
    end
  end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle/work_shift_test.exs`
Expected: FAIL — `HR.reassign_punch/2` is undefined, flags wrap at `3_OUT_3`, and the fingerprint count is 6 rather than 8.

- [ ] **Step 3: Add the assignment and renumbering functions**

Add to `lib/full_circle/hr.ex` (alias `FullCircle.HR.ShiftInstance` at the top):

```elixir
  @doc """
  Which instance a punch belongs to, as changeset attrs.

  Resolution uses the punch's own local date to pick the shift, then that
  shift's cutover to pick the instance.
  """
  def punch_shift_attrs(employee_id, company, %DateTime{} = punch_time) do
    local = DateTime.shift_zone!(punch_time, company.timezone)
    shift = shift_for(employee_id, company, DateTime.to_date(local))

    %{work_shift_id: shift.id, work_shift_date: instance_anchor(shift, local)}
  end

  @doc """
  Renumbers `punch_kind` and the display `flag` across one instance, in time
  order. Replaces the old per-calendar-day flag rebuild, which wrapped at six.
  """
  def rebuild_instance(company, employee_id, work_shift_id, work_shift_date) do
    from(t in TimeAttend,
      where: t.company_id == ^company.id,
      where: t.employee_id == ^employee_id,
      where: t.work_shift_id == ^work_shift_id,
      where: t.work_shift_date == ^work_shift_date,
      order_by: [asc: t.punch_time, asc: t.id]
    )
    |> Repo.all()
    |> Enum.with_index(1)
    |> Enum.each(fn {ta, i} ->
      kind = ShiftInstance.punch_kind(i)
      flag = ShiftInstance.flag(i)

      if ta.punch_kind != kind or ta.flag != flag do
        ta |> Ecto.Changeset.change(%{punch_kind: kind, flag: flag}) |> Repo.update!()
      end
    end)

    :ok
  end

  @doc """
  Resolves a punch to its instance and renumbers it — plus the instance it just
  left, when a time edit moved it.
  """
  def reassign_punch(%TimeAttend{} = ta, company) do
    old_id = ta.work_shift_id
    old_date = ta.work_shift_date
    attrs = punch_shift_attrs(ta.employee_id, company, ta.punch_time)

    {:ok, ta} = ta |> Ecto.Changeset.change(attrs) |> Repo.update()

    rebuild_instance(company, ta.employee_id, ta.work_shift_id, ta.work_shift_date)

    # A time edit can move a punch between instances; the one it left has to be
    # renumbered too, or it keeps a gap in its sequence.
    moved? = old_id != ta.work_shift_id or old_date != ta.work_shift_date

    if not is_nil(old_id) and moved? do
      rebuild_instance(company, ta.employee_id, old_id, old_date)
    end

    {:ok, ta}
  end
```

- [ ] **Step 4: Call it from every write path**

`lib/full_circle/punch_gate.ex` — delete `rebuild_day_flags/3` entirely and drop `@flags`. In `insert_punch/6`, replace the `:flags` step:

```elixir
    |> Ecto.Multi.run(:flags, fn _repo, %{photo: ta} ->
      {:ok, ta} = FullCircle.HR.reassign_punch(ta, company)
      {:ok, ta}
    end)
```

The initial insert's `flag: "1_IN_1"` in `TimeAttend.changeset_gate/2` stays as a placeholder; `reassign_punch/2` overwrites it a moment later with the correct position.

`lib/full_circle/hr.ex` — after a successful `Repo.insert(cs)` in `create_time_attendence_by_entry/3` and `Repo.update(cs)` in `update_time_attendence/4`, pipe through the reassign; after `Repo.delete(ta)` in `delete_time_attendence/3`, rebuild what it left:

```elixir
          else
            with {:ok, ta} <- Repo.insert(cs) do
              reassign_punch(ta, com)
            end
```

```elixir
          else
            with {:ok, ta} <- Repo.update(cs) do
              reassign_punch(ta, com)
            end
```

```elixir
      true ->
        with {:ok, ta} <- Repo.delete(ta) do
          rebuild_instance(com, ta.employee_id, ta.work_shift_id, ta.work_shift_date)
          {:ok, ta}
        end
```

**`delete_time_attendence_by_id/3` (`hr.ex:342-356`) needs the same treatment, and it is the one that matters** — it is what the punch row calls (`punch_time_component.ex:65`); `delete_time_attendence/3` above is reached from the TimeAttend index only. Miss it and every punch a clerk clears from the punch card leaves a hole in the numbering (`1_IN_1`, `1_OUT_1`, `3_IN_3`, …):

```elixir
          true ->
            with {:ok, ta} <- Repo.delete(ta) do
              rebuild_instance(com, ta.employee_id, ta.work_shift_id, ta.work_shift_date)
              {:ok, ta}
            end
```

Add a test for that path specifically, since it is the one the UI exercises:

```elixir
    test "clearing a punch from the row renumbers what is left", ctx do
      assert {:ok, a} = gate_punch(ctx, "2026-05-05T08:00:00+08:00")
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T12:00:00+08:00")
      assert {:ok, _} = gate_punch(ctx, "2026-05-05T17:00:00+08:00")

      FullCircle.HR.delete_time_attendence_by_id(a.id, ctx.company, ctx.admin)

      assert ["1_IN_1", "1_OUT_1"] =
               instance_punches(ctx, ~D[2026-05-05]) |> Enum.map(& &1.flag)
    end
```

`insert_time_attendence_from_log/2` — the dedupe must stop comparing `flag`, which is `NULL` for the very rows it needs to catch (`flag = NULL` is never true in SQL, so those rows re-insert on every import). Position is no longer known at import time, so match on employee and time alone:

```elixir
  def insert_time_attendence_from_log(entry, com) do
    ptu = entry.punch_time |> Timex.shift(minutes: -5)
    ptd = entry.punch_time |> Timex.shift(minutes: 5)

    got? =
      from(ta in TimeAttend,
        where: ta.employee_id == ^entry.employee_id,
        where: ta.company_id == ^com.id,
        where: ta.punch_time >= ^ptu,
        where: ta.punch_time <= ^ptd
      )
      |> Repo.exists?()

    if !got? do
      with {:ok, ta} <- %TimeAttend{} |> TimeAttend.finger_print_log_changeset(entry) |> Repo.insert() do
        reassign_punch(ta, com)
      end
    end
  end
```

- [ ] **Step 5: Stop the fingerprint importer emitting nil flags**

`lib/full_circle/hr/finger_print_import.ex:99-110` — `fill_flags_to_map/1`'s `true -> %{stamp: t, flag: nil}` branch is what makes punch 7 fail `validate_required` and vanish. Position now comes from `rebuild_instance/4`, so the import only needs a placeholder:

```elixir
  defp fill_flags_to_map(tl) do
    # Position within the shift is derived after insert by HR.rebuild_instance/4,
    # so this only has to be a value that passes validation. It used to emit nil
    # past the sixth punch, which failed validate_required and silently dropped
    # the punch.
    Enum.map(tl, fn t -> %{stamp: t, flag: "1_IN_1"} end)
  end
```

- [ ] **Step 6: Stop requiring `flag`**

In `lib/full_circle/HR/timeattend.ex`, remove `:flag` from the `validate_required` list of all three changesets. It is now a derived label, written by `rebuild_instance/4`, not something a caller supplies.

- [ ] **Step 7: Run the tests**

Run: `mix test test/full_circle/work_shift_test.exs test/full_circle/punch_gate_test.exs test/full_circle/shift_instance_test.exs`
Expected: PASS. `punch_gate_test.exs` covers the gate's existing behaviour and must stay green — note its `"ingest writes QRGate row, photo file, infers 1_IN_1"` test still passes, because a lone first punch is still position 1.

- [ ] **Step 8: Format and commit**

```bash
mix format lib/full_circle/hr.ex lib/full_circle/punch_gate.ex \
  lib/full_circle/hr/finger_print_import.ex lib/full_circle/HR/timeattend.ex \
  test/full_circle/work_shift_test.exs
git add -A
git commit -m "feat(hr): assign punches to instances on write, drop the 6-flag ring

Replaces PunchGate.rebuild_day_flags/3, which wrapped at six flags per
calendar day. Also fixes the fingerprint importer silently discarding
punches past the sixth, and its dedupe comparing flag = NULL.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 6: The punch row — remove the six-slot ceiling

**Files:**
- Modify: `lib/full_circle_web/live/helpers.ex:295-320` (delete `make_timeattend_list/2` and `make_timeattend/3`)
- Modify: `lib/full_circle_web/live/time_attend_live/punch_time_component.ex:185-324`
- Modify: `lib/full_circle_web/live/time_attend_live/punch_card.ex:675-700` (the `{:updated_punch, ...}` handler)
- Modify: `lib/full_circle_web/live/time_attend_live/punch_index_component.ex:14`, `punch_card_component.ex:14`
- Modify: `lib/full_circle_web/live/time_attend_live/form_component.ex:189-196`
- Create: `test/full_circle_web/live/punch_row_test.exs`

**Interfaces:**
- Consumes: `ShiftInstance.punch_kind/1` (Task 4).
- Produces: `FullCircleWeb.Helpers.punch_slots(time_list, company) :: [tuple]` — the punches in time order plus trailing blanks, length `max(6, count + 1)`.

Three things make this more than a loop change, and all are load-bearing:

- **The blank slots are the add-a-punch affordance.** Typing into one fires `new_time_attendence/2` (`punch_time_component.ex:34-35, 80-92`). Render only real punches and a clerk can no longer add the missing punch — the single action the anomaly flow asks of them.
- **The row budgets to exactly 100%** — six slots at `w-[11.666%]` plus HW/NH/OT at `w-[10%]`. Eight punches is 93.3% inside a 70% budget, so under `flex-nowrap` the hours columns get pushed off the row.
- **The parent destructures six tuples too.** `punch_card.ex:675-700` matches `[{_,_,_,_,_}, × 6] = Enum.map(tis, &tis_core/1)` on every `{:updated_punch, ...}` message. Removing the ceiling in the component alone means the first edit on a seven-punch day raises `MatchError` in the LiveView, not in the component — Step 6 below fixes it in the same commit.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/punch_row_test.exs`:

```elixir
defmodule FullCircleWeb.PunchRowTest do
  use FullCircle.DataCase, async: true

  alias FullCircleWeb.Helpers

  @company %{timezone: "Asia/Kuala_Lumpur"}

  defp entry(iso, id),
    do: [Timex.parse!(iso, "{RFC3339}"), id, "Draft", "x", "", ""]

  test "a four punch day still renders six slots, as today" do
    list = [
      entry("2026-05-05T07:00:00+08:00", "a"),
      entry("2026-05-05T12:00:00+08:00", "b"),
      entry("2026-05-05T13:00:00+08:00", "c"),
      entry("2026-05-05T17:00:00+08:00", "d")
    ]

    slots = Helpers.punch_slots(list, @company)
    assert length(slots) == 6
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time != nil end) == 4
  end

  test "a six punch day renders six slots with none blank" do
    list =
      for {h, i} <- Enum.with_index(~w(07 09 10 12 13 17)) do
        entry("2026-05-05T#{h}:00:00+08:00", "id#{i}")
      end

    slots = Helpers.punch_slots(list, @company)
    assert length(slots) == 6
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time == nil end) == 0
  end

  test "an eight punch day renders nine slots, eight filled plus one blank" do
    list =
      for {h, i} <- Enum.with_index(~w(07 08 09 10 11 12 13 14)) do
        entry("2026-05-05T#{h}:00:00+08:00", "id#{i}")
      end

    slots = Helpers.punch_slots(list, @company)
    assert length(slots) == 9
    assert Enum.count(slots, fn {time, _, _, _, _, _} -> time != nil end) == 8
  end

  test "blank slots carry a _new_ id so typing into one creates a punch" do
    slots = Helpers.punch_slots([entry("2026-05-05T07:00:00+08:00", "a")], @company)

    blanks = Enum.filter(slots, fn {time, _, _, _, _, _} -> time == nil end)
    assert length(blanks) == 5
    assert Enum.all?(blanks, fn {_, id, _, _, _, _} -> String.starts_with?(id, "_new_") end)
  end

  test "punches come back in time order regardless of input order" do
    list = [
      entry("2026-05-05T17:00:00+08:00", "late"),
      entry("2026-05-05T07:00:00+08:00", "early")
    ]

    assert [{_, "early", _, _, _, _}, {_, "late", _, _, _, _} | _] =
             Helpers.punch_slots(list, @company)
  end

  test "an empty day still renders six blank slots" do
    slots = Helpers.punch_slots(nil, @company)
    assert length(slots) == 6
    assert Enum.all?(slots, fn {time, _, _, _, _, _} -> time == nil end)
  end

  test "make_timeattend_list is gone" do
    refute function_exported?(FullCircleWeb.Helpers, :make_timeattend_list, 2)
  end
end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle_web/live/punch_row_test.exs`
Expected: FAIL — `Helpers.punch_slots/2` is undefined.

- [ ] **Step 3: Replace the slot builder**

In `lib/full_circle_web/live/helpers.ex`, delete `make_timeattend_list/2` and its private `make_timeattend/3`, and add:

```elixir
  @min_punch_slots 6

  @doc """
  Punches for one instance in time order, followed by blank slots.

  Length is `max(6, count + 1)`. The minimum of six keeps the row looking
  exactly as it does today for every day in history — none has ever exceeded
  six punches — and the trailing blank is the add-a-punch affordance: typing
  into a `_new_` slot is how a clerk records a missing punch.
  """
  def punch_slots(time_list, com) do
    punches =
      (time_list || [])
      |> Enum.map(fn [time, id, status, flag | rest] ->
        {Timex.format!(Timex.to_datetime(time, com.timezone), "%H:%M", :strftime), id, status,
         flag, Timex.to_datetime(time, com.timezone), Enum.at(rest, 0) || ""}
      end)
      |> Enum.sort_by(fn {_, _, _, _, dt, _} -> dt end, DateTime)

    blanks = max(@min_punch_slots, length(punches) + 1) - length(punches)

    punches ++
      for _ <- 1..blanks//1 do
        {nil, "_new_#{FullCircle.Helpers.gen_temp_id(31)}", "normal", nil, nil, ""}
      end
  end
```

- [ ] **Step 4: Point the two components at it**

`punch_index_component.ex:14` and `punch_card_component.ex:14` — replace

```elixir
    tis = FullCircleWeb.Helpers.make_timeattend_list(assigns.obj.time_list, assigns.company)
```

with

```elixir
    tis = FullCircleWeb.Helpers.punch_slots(assigns.obj.time_list, assigns.company)
```

- [ ] **Step 5: Make the component handle N slots**

In `lib/full_circle_web/live/time_attend_live/punch_time_component.ex` (adding `alias FullCircle.HR.ShiftInstance`), replace the fixed six-element destructure and its `tl` construction (lines 185-204) with:

```elixir
    tis = Enum.map(socket.assigns.tis, &pad_tis/1)

    tl =
      Enum.map(tis, fn {_ti, id, st, fl, dt, _p} -> [dt, id, st, fl] end)

    filled = tl |> Enum.reject(fn [dt | _] -> is_nil(dt) end) |> Enum.map(fn [dt | _] -> dt end)

    ordered? =
      filled
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> DateTime.compare(a, b) == :lt end)

    span =
      case filled do
        [] -> 0.0
        [_] -> 0.0
        list -> DateTime.diff(List.last(list), hd(list)) / 3600
      end

    # The same rule the query uses, so the component cannot disagree with the
    # row it is rendering. Out-of-order punches stay a red-row signal of their
    # own - they are not an anomaly the query knows about.
    anomaly = ShiftInstance.anomaly(length(filled), span, max_hour(socket))

    # Blank, not a partial sum. HR.wh/1 chunks in twos and rescues the leftover
    # to 0.0, so an odd day would otherwise show the hours of its complete pairs
    # as if that were the day's total.
    wh = if is_nil(anomaly), do: HR.wh(tl), else: nil

    tl_ok? = is_nil(anomaly) and ordered?
```

with

```elixir
  # The row's shift, when Task 7 has put it there; the seeded General tolerance
  # otherwise, which is what every existing row resolves to anyway.
  defp max_hour(socket) do
    case socket.assigns.obj do
      %{work_shift: %FullCircle.HR.WorkShift{max_hour: m}} -> m
      _ -> Decimal.new("12")
    end
  end
```

and `nh` / `ot` guarded the same way:

```elixir
    socket
    |> assign(wh: wh)
    |> assign(nh: wh && HR.nh(wh, socket.assigns.obj.work_hours_per_day))
    |> assign(ot: wh && HR.ot(wh, socket.assigns.obj.work_hours_per_day))
```

Then delete the old `case [!is_nil(dt1), ...]` block entirely — it is replaced by the above and no longer compiles once `dt1`..`dt6` are gone.

Two notes on why this matters beyond tidiness. `update/2` runs `update_working_hours/1` on **every** render (`punch_time_component.ex:18-20`), so whatever the component computes overwrites the `nil` Task 7 puts on the row — without this change the blanking works everywhere except the screen it was built for. And `Number.Delimit.number_to_delimited/1` returns `nil` for `nil` (`deps/number/lib/number/delimit.ex:83`), so a blank cell renders empty rather than raising; no template guard is needed.

In `render/1`, wrap the punch forms so wrapping cannot displace the hours columns. Replace `<div class="flex flex-nowrap gap-1">` (line 273) and its closing with:

```heex
    <div class="flex flex-nowrap gap-1">
      <div class="w-[70%] flex flex-wrap gap-1">
        <%= if !is_nil(@tis) do %>
          <%= for o <- @tis do %>
            <% {time, id, status, flag, datetime, photo} = pad_tis(o) %>
            <.form
              for={}
              autocomplete="off"
              phx-change="punch_time_changed"
              phx-target={@myself}
              class="w-[16.666%]"
            >
```

(`w-[16.666%]` is one sixth **of the 70% wrapper**, so a slot keeps the same on-screen width it has today.) Close the new wrapper `</div>` immediately before the `worked-hours` div at line 318, leaving HW/NH/OT outside it at their existing `w-[10%]`.

- [ ] **Step 6: Make the parent accept N slots**

`lib/full_circle_web/live/time_attend_live/punch_card.ex:675-700` rebuilds `time_list` from the message the component sends, and destructures exactly six tuples to do it. Replace the whole `[{_ti1, ...}, ...] = Enum.map(tis, &tis_core/1)` block and its `tl = [...]` literal with:

```elixir
    tl =
      tis
      |> Enum.map(&tis_core/1)
      |> Enum.map(fn {_ti, id, st, fl, dt} -> [dt, id, st, fl] end)
```

`tis_core/1` stays as it is. Without this, the component happily renders seven slots and the first edit on that row crashes the LiveView with a `MatchError` here.

- [ ] **Step 7: Resolve a typed time inside its instance, not against the row date**

`add_date_to/2` (`punch_time_component.ex:258-262`) stitches the typed `HH:MM` onto `socket.assigns.obj.dd`. That is correct only while a row is a calendar day. After Task 7 a row is a **pay date**, so on a Night instance that ended at 02:00 on 6 May, the 17:00 slot displays on the 6 May row — and re-typing it would store *6 May 17:00*, which is past Night's 11:00 cutover and therefore the **next** instance. The clerk's only repair action would tear the shift in half.

Resolve the typed time into the instance's own window instead. The instance anchor is on the row (`work_shift_date`, carried through Task 7's CTE); the window is `[cutover(anchor), cutover(anchor + 1))`:

```elixir
  # A time-only input has to be placed on one of two candidate dates: the
  # instance's anchor day, or the day after it. Exactly one of them puts the
  # time inside the instance's half-open window.
  defp add_date_to(pt, socket) do
    %{company: com, obj: obj} = socket.assigns
    {:ok, time} = Time.from_iso8601(pt <> ":00")

    anchor = Map.get(obj, :work_shift_date) || Timex.to_date(obj.dd)

    date =
      case Map.get(obj, :work_shift) do
        %FullCircle.HR.WorkShift{} = ws ->
          if Time.compare(time, FullCircle.HR.WorkShift.cutover_time(ws)) in [:gt, :eq],
            do: anchor,
            else: Date.add(anchor, 1)

        # Before Task 7 lands the shift on the row, a row is still a calendar
        # day and the old behaviour is the correct one.
        _ ->
          Timex.to_date(obj.dd)
      end

    DateTime.new!(date, time, com.timezone)
  end
```

**Ordering note:** the fields this reads (`work_shift_date`, `work_shift`) arrive with Task 7's CTE, and rows are not keyed by pay date until then either. The fallback clause above keeps this step correct if it is committed first; if you prefer, fold it into Task 7 instead — it is the same edit either way.

For General (cutover 02:00, anchor = pay date) every plausible punch time is `>= 02:00`, so this returns the row's own date and nothing about today's behaviour changes. For Night (cutover 11:00) a typed `17:00` lands on the anchor and a typed `02:00` lands on the day after — which is exactly how the instance is shaped.

`obj.work_shift` must therefore be preloaded onto the row; Task 7's CTE already joins `work_shifts` for `max_hour`, so add `start_time` to the same select rather than issuing another query.

Add to `test/full_circle_web/live/punch_row_test.exs`:

```elixir
  test "a typed time on a night row lands in that instance, not the next one" do
    night = %FullCircle.HR.WorkShift{
      start_time: ~T[17:00:00],
      normal_hour: Decimal.new("9"),
      max_hour: Decimal.new("12")
    }

    # Instance anchored 5 May, paid on 6 May. 17:00 belongs to the 5th.
    assert ~D[2026-05-05] =
             FullCircleWeb.TimeAttendLive.PunchTimeComponent.slot_date(
               "17:00", ~D[2026-05-05], night
             )

    # 02:00 is before the 11:00 cutover, so it is the morning after.
    assert ~D[2026-05-06] =
             FullCircleWeb.TimeAttendLive.PunchTimeComponent.slot_date(
               "02:00", ~D[2026-05-05], night
             )
  end
```

Expose the date arithmetic as a public `slot_date/3` so it is testable without a socket; `add_date_to/2` becomes a thin wrapper around it.

- [ ] **Step 8: Drop the hard-coded flag dropdown**

`lib/full_circle_web/live/time_attend_live/form_component.ex:189-196` — delete the whole `<div class="col-span-2">` holding the `field={@form[:flag]}` select. Flag is derived by `HR.rebuild_instance/4` from position; letting a clerk pick one would immediately be overwritten.

- [ ] **Step 9: Run the tests**

Run: `mix test test/full_circle_web/live/punch_row_test.exs test/full_circle_web/live/ test/full_circle/`
Expected: PASS.

- [ ] **Step 10: Look at it**

```bash
mix phx.server
```

Open `/companies/<id>/PunchIndex`. A normal four-punch day must look **identical** to before. Then add four more punches to one employee on one day via the blank slots and confirm the row wraps to a second line with HW/NH/OT still on the first. Check both light and dark theme.

- [ ] **Step 11: Format and commit**

```bash
mix format lib/full_circle_web/live/helpers.ex \
  lib/full_circle_web/live/time_attend_live/punch_time_component.ex \
  lib/full_circle_web/live/time_attend_live/punch_card.ex \
  lib/full_circle_web/live/time_attend_live/punch_index_component.ex \
  lib/full_circle_web/live/time_attend_live/punch_card_component.ex \
  lib/full_circle_web/live/time_attend_live/form_component.ex \
  test/full_circle_web/live/punch_row_test.exs
git add -A
git commit -m "feat(hr): render every punch in a day, not the first six

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 7: Group the punch query by instance and blank anomalous hours

**Files:**
- Modify: `lib/full_circle/hr/shift_instance.ex` (expose the anomaly rule)
- Modify: `lib/full_circle/hr.ex:1207-1222` (the `emp_time_list` CTE), `:1334-1350` (`unzip_all_time_list/1`)
- Modify: `lib/full_circle_web/live/time_attend_live/punch_card.ex:873-923` (monthly totals)
- Modify: `test/full_circle/work_shift_test.exs`

**Interfaces:**
- Produces: `ShiftInstance.anomaly(count, span_hours, max_hour) :: :missing_punch | :too_long | nil` — the single source of truth for the rule, called by both `ShiftInstance.build/3` and the SQL-fed read path.
- Produces: an `anomaly` key on every punch-card row, and `wh` / `nh` / `ot` as `nil` when it is set.

**`PaySlipOp` is deliberately not in that list.** An earlier draft blocked the pay slip for a month containing an anomalous instance. It does not, for the reason in the Global Constraints: 328 employee-days are already odd, most of them off-site staff with no missing punch to recover, and 61 of the 68 affected employee-months are already paid. The red row is the signal, and it is the same signal those days carry today.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle/work_shift_test.exs`:

```elixir
  describe "anomalous instances read as blank, and pay anyway" do
    setup ctx do
      emp = employee_fixture(%{}, ctx.company, ctx.admin)
      %{emp: emp}
    end

    defp manual_punch!(ctx, iso) do
      ta =
        Repo.insert!(%FullCircle.HR.TimeAttend{
          company_id: ctx.company.id,
          employee_id: ctx.emp.id,
          user_id: ctx.admin.id,
          punch_time: Timex.parse!(iso, "{RFC3339}") |> DateTime.truncate(:second),
          status: "Draft",
          input_medium: "Manual"
        })

      {:ok, ta} = FullCircle.HR.reassign_punch(ta, ctx.company)
      ta
    end

    defp day(ctx, date) do
      FullCircle.HR.punch_card_query(5, 2026, ctx.emp.id, ctx.company)
      |> Enum.find(fn r -> Timex.to_date(r.dd) == date end)
    end

    test "a complete day carries hours and no anomaly", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      manual_punch!(ctx, "2026-05-05T17:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert is_nil(row.anomaly)
      assert_in_delta row.wh, 9.0, 0.001
    end

    test "a missing punch out blanks the hours instead of paying 0.0", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert row.anomaly == :missing_punch
      assert is_nil(row.wh)
      assert is_nil(row.nh)
      assert is_nil(row.ot)
    end

    test "adding the missing punch restores the hours", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      assert day(ctx, ~D[2026-05-05]).anomaly == :missing_punch

      manual_punch!(ctx, "2026-05-05T17:00:00+08:00")
      row = day(ctx, ~D[2026-05-05])
      assert is_nil(row.anomaly)
      assert_in_delta row.wh, 9.0, 0.001
    end

    # The cutover splits these two punches into separate instances: General cuts
    # over at 02:00, so 08:00 on the 5th and 17:00 on the 6th are two days, each
    # holding one punch. This is NOT one 33-hour :too_long instance - an earlier
    # draft said it was, and a test asserting that would fail.
    test "punches a day apart are two instances, each missing a punch", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      manual_punch!(ctx, "2026-05-06T17:00:00+08:00")

      assert day(ctx, ~D[2026-05-05]).anomaly == :missing_punch
      assert day(ctx, ~D[2026-05-06]).anomaly == :missing_punch
    end

    # :too_long needs both punches inside one window.
    test "a fourteen hour span inside one instance is too long", ctx do
      manual_punch!(ctx, "2026-05-05T07:00:00+08:00")
      manual_punch!(ctx, "2026-05-05T21:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert row.anomaly == :too_long
      assert is_nil(row.wh)
    end

    test "a genuine zero hour day stays 0.0, not nil", ctx do
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")
      manual_punch!(ctx, "2026-05-05T08:00:00+08:00")

      row = day(ctx, ~D[2026-05-05])
      assert is_nil(row.anomaly)
      assert row.wh == 0.0
    end

    # The off-site case: one punch every working day, for a whole month, and the
    # pay slip must still generate. Nothing in this feature gates payroll.
    test "a month of single punch days still pays", ctx do
      for d <- 4..8 do
        manual_punch!(ctx, "2026-05-0#{d}T08:00:00+08:00")
      end

      rows = FullCircle.HR.punch_card_query(5, 2026, ctx.emp.id, ctx.company)
      assert Enum.count(rows, fn r -> r.anomaly == :missing_punch end) == 5

      acc = FullCircle.ReceiveFundFixtures.funds_account_fixture(ctx.company, ctx.admin)

      assert {:ok, _} =
               FullCircle.PaySlipOp.pay(
                 Repo.reload!(ctx.emp),
                 5,
                 2026,
                 acc.id,
                 ctx.company,
                 ctx.admin
               )
    end
  end

  describe "anomaly/3 is the single rule" do
    test "odd count, then span, then clean" do
      alias FullCircle.HR.ShiftInstance
      max = Decimal.new("12")

      assert ShiftInstance.anomaly(3, 4.0, max) == :missing_punch
      assert ShiftInstance.anomaly(2, 33.0, max) == :too_long
      assert ShiftInstance.anomaly(2, 12.0, max) == nil
      assert ShiftInstance.anomaly(4, 9.0, max) == nil
    end
  end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle/work_shift_test.exs`
Expected: FAIL — `ShiftInstance.anomaly/3` is undefined and the punch-card rows carry no `anomaly` key.

- [ ] **Step 3: Make the anomaly rule public**

In `lib/full_circle/hr/shift_instance.ex`, replace the private `anomaly_for/3` with a public `anomaly/3` so the SQL-fed read path uses the same rule rather than a second copy of it:

```elixir
  @doc """
  The single anomaly rule, shared by the struct builder and the SQL-fed read
  path. Exactly two anomalies: an odd punch count, and a span beyond the
  shift's tolerance. A punch is never anomalous for falling outside the
  nominal window — 34.5% of real punches do.
  """
  def anomaly(count, span_hours, max_hour) do
    cond do
      rem(count, 2) == 1 -> :missing_punch
      span_hours > Decimal.to_float(max_hour) -> :too_long
      true -> nil
    end
  end
```

and change `build/3`'s call site to `anomaly = anomaly(length(punches), span, shift.max_hour)`.

- [ ] **Step 4: Group the punch query by instance**

In `lib/full_circle/hr.ex`, replace the `emp_time_list` CTE (lines 1207-1222) with an instance-shaped pair of CTEs. The outer query's join at line 1231 changes from `eidsh.dd = etl.dd_utc` to the same shape, so leave it as is:

```sql
          emp_instance as (
            select ta.employee_id,
                   ta.work_shift_id,
                   ta.work_shift_date,
                   count(*) as punch_count,
                   extract(epoch from (max(ta.punch_time) - min(ta.punch_time))) / 3600.0 as span_hours,
                   (max(ta.punch_time) at time zone '#{com.timezone}')::date as pay_date,
                   array_agg(
                     (ta.punch_time at time zone '#{com.timezone}')::varchar
                     || '|' || ta.id::varchar
                     || '|' || ta.status
                     || '|' || coalesce(ta.flag, '')
                     || '|' || coalesce(ta.photo_path, '')
                     || '|' || coalesce(pd.name, '')
                     order by ta.punch_time
                   ) time_list
              from time_attendences ta
              left join punch_devices pd on pd.id = ta.punch_device_id
             where ta.company_id = '#{com.id}'
               and ta.work_shift_id is not null
             group by ta.employee_id, ta.work_shift_id, ta.work_shift_date),
          emp_time_list as (
            select ei.employee_id, ds.dd as dd_utc, ei.time_list,
                   ei.punch_count, ei.span_hours, ws.max_hour
              from emp_instance ei
              join work_shifts ws on ws.id = ei.work_shift_id
              cross join date_series ds
             where (ds.dd at time zone '#{com.timezone}')::date = ei.pay_date)
```

Two deliberate changes beyond the grouping: `coalesce(ta.flag, '')` — a NULL `flag` would have made the whole `||` expression NULL and nulled the array element, crashing `unzip_time_list/1` — and `order by ta.punch_time` alone, since `flag` is no longer a tiebreaker that means anything.

Add `punch_count`, `span_hours` and `max_hour` to the outer `select` alongside `etl.time_list`.

- [ ] **Step 5: Blank the hours on an anomalous instance**

In `lib/full_circle/hr.ex`, `unzip_all_time_list/1` (line 1334) currently always computes `wh`. Make it respect the anomaly:

```elixir
  def unzip_all_time_list(ps) do
    ps
    |> Enum.map(fn t ->
      ut = Map.get(t, :time_list) |> unzip_time_list()
      idg = Map.get(t, :idg)
      nwh = Decimal.to_float(Map.get(t, :work_hours_per_day) || Decimal.new("0.00001"))

      anomaly =
        case {Map.get(t, :punch_count), Map.get(t, :span_hours), Map.get(t, :max_hour)} do
          {nil, _, _} -> nil
          {_, _, nil} -> nil
          {count, span, max} -> ShiftInstance.anomaly(count, to_float(span), max)
        end

      # nil, never 0.0: a real zero-hour day must stay distinguishable from
      # "we cannot say", because holiday_pay_days reads 0.0 as a genuine absence.
      {wh, nh, ot} =
        if is_nil(anomaly) do
          w = wh(ut)
          {w, nh(w, nwh), ot(w, nwh)}
        else
          {nil, nil, nil}
        end

      Map.merge(t, %{
        time_list: ut,
        wh: wh,
        nh: nh,
        ot: ot,
        anomaly: anomaly,
        id: idg,
        work_hours_per_day: nwh
      })
    end)
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(f) when is_float(f), do: f
  defp to_float(i) when is_integer(i), do: i * 1.0
  defp to_float(nil), do: 0.0
```

Add `alias FullCircle.HR.ShiftInstance` to `hr.ex` if Task 5 has not already.

- [ ] **Step 6: Make the monthly totals skip anomalies**

In `lib/full_circle_web/live/time_attend_live/punch_card.ex`, all five totals divide by `work_hours_per_day` and would crash on nil. Replace lines 873-923:

```elixir
  # An anomalous day contributes nothing: its hours are unknown. It does not
  # block anything - the red row is the signal, exactly as it is today.
  defp holiday_pay_days(objs, com) do
    by_date = Map.new(objs, fn x -> {Timex.to_date(x.dd), x} end)

    objs
    |> Enum.map(fn x ->
      d = Timex.to_date(x.dd)
      prev = neighbour(by_date, d, -1, x.employee_id, com)
      next = neighbour(by_date, d, 1, x.employee_id, com)

      cond do
        is_nil(x.sholi_list) -> 0.0
        is_nil(x.nh) -> 0.0
        x.nh <= x.work_hours_per_day / 2 -> 0.0
        is_nil(prev) or is_nil(next) -> 0.0
        # nil means unknown, not absent - do not pay a holiday we cannot verify.
        is_nil(prev.wh) or is_nil(next.wh) -> 0.0
        prev.wh == 0.0 or next.wh == 0.0 -> 0.0
        true -> x.nh / x.work_hours_per_day
      end
    end)
    |> Enum.sum()
  end

  # The day before the 1st and the day after the last are in another month, so
  # they are not in `objs` and must still be fetched. Indexing the list instead
  # (`Enum.at(objs, i - 1)`) silently returns the *last* day of the month for
  # i == 0, which would pay or withhold a holiday on the strength of a day three
  # or four weeks later.
  defp neighbour(by_date, date, offset, emp_id, com) do
    d = Date.add(date, offset)

    case Map.get(by_date, d) do
      nil -> HR.punch_by_date(emp_id, d, com)
      row -> row
    end
  end

  defp sunday_pay_days(tdw, ot, sc, dim, ewdpw) do
    rest_day_per_week = 7 - ewdpw
    expected_work_days = dim - sc * rest_day_per_week
    dw = tdw - ot
    sw = dw - expected_work_days
    if(sw > 0.0, do: sw, else: 0.0)
  end

  defp normal_pay_days(objs), do: sum_days(objs, :nh)

  defp sunday_count(objs) do
    Enum.count(objs, fn x -> x.dd |> Timex.weekday() |> Timex.day_shortname() == "Sun" end)
  end

  defp days_in_month(objs) do
    if objs != [], do: Timex.days_in_month(Enum.at(objs, 1).dd), else: 0
  end

  defp total_day_worked(objs), do: sum_days(objs, :wh)

  defp ot_day_worked(objs), do: sum_days(objs, :ot)

  defp sum_days(objs, key) do
    objs
    |> Enum.map(fn x ->
      case Map.get(x, key) do
        nil -> 0.0
        hours -> hours / x.work_hours_per_day
      end
    end)
    |> Enum.sum()
  end
```

The `holiday_pay_days/2` rewrite is the substantive one, and it has two independent bugs to avoid. It previously re-queried the **previous and next calendar date** with `HR.punch_by_date/3`; under pay-date grouping that is the wrong neighbour, and a `nil` there would read as a zero-hour absence and silently withhold holiday pay. But replacing the query with a plain index into the month's own list breaks the month edges: `Enum.at(objs, i - 1)` at `i == 0` is `Enum.at(objs, -1)`, the **last day of the month**, and the last day of the month has no `i + 1` at all. The version above reads the month's rows when it can and falls back to the existing query for the two days that sit outside it.

- [ ] **Step 7: Key the pay-slip edit lock to the pay date**

Not a gate — the opposite direction. `pay_slip_exists_for_period?/3` freezes attendance editing once a month is paid, and both callers hand it the punch's **own calendar date**: `punch_locked_by_payslip?/3` from the punch's `punch_time_local` (`hr.ex:295`), and `delete_time_attendence_by_id/3` from `ta.punch_time` shifted to the company timezone (`hr.ex:349-353`).

For General those are the same day. For a night shift they are not: an OUT at 02:00 on 1 June belongs to May's instance and May's pay slip, but is keyed to June — so it stays editable after May is paid, and freezes as soon as June is. Both directions are wrong.

In `lib/full_circle/hr.ex`, resolve the punch's instance and use **the pay date of that instance** — the local date of its last punch:

```elixir
  @doc """
  The date whose pay slip governs this punch: the local date its instance ended
  on, not the local date of the punch itself. They differ for any shift that
  crosses midnight.
  """
  def punch_pay_date(%TimeAttend{work_shift_id: nil} = ta, com),
    do: ta.punch_time |> Timex.to_datetime(com.timezone) |> Timex.to_date()

  def punch_pay_date(%TimeAttend{} = ta, com) do
    from(t in TimeAttend,
      where: t.company_id == ^com.id,
      where: t.employee_id == ^ta.employee_id,
      where: t.work_shift_id == ^ta.work_shift_id,
      where: t.work_shift_date == ^ta.work_shift_date,
      order_by: [desc: t.punch_time],
      limit: 1,
      select: t.punch_time
    )
    |> Repo.one()
    |> case do
      nil -> ta.punch_time
      last -> last
    end
    |> Timex.to_datetime(com.timezone)
    |> Timex.to_date()
  end
```

`delete_time_attendence_by_id/3` calls `punch_pay_date(ta, com)` in place of its inline date arithmetic. The create/update path goes through `punch_locked_by_payslip?/3`, which only has a `NaiveDateTime` and no saved row yet — there, resolve the shift for the employee and use the instance the punch *would* join:

```elixir
  defp punch_locked_by_payslip?(emp_id, %NaiveDateTime{} = ptl, com) do
    local = DateTime.from_naive!(ptl, com.timezone)
    shift = shift_for(emp_id, com, NaiveDateTime.to_date(ptl))
    anchor = instance_anchor(shift, local)

    # Last punch already in that instance, if any - a new punch joining an
    # existing night shift is governed by the same pay slip as the rest of it.
    pay_date =
      from(t in TimeAttend,
        where: t.company_id == ^com.id and t.employee_id == ^emp_id,
        where: t.work_shift_id == ^shift.id and t.work_shift_date == ^anchor,
        order_by: [desc: t.punch_time],
        limit: 1,
        select: t.punch_time
      )
      |> Repo.one()
      |> case do
        nil -> local
        last -> Timex.to_datetime(last, com.timezone)
      end
      |> Timex.to_date()

    pay_slip_exists_for_period?(emp_id, pay_date, com)
  end
```

For every General punch this returns the punch's own date, so nothing about today's behaviour changes.

- [ ] **Step 8: Verify the SQL did not move existing numbers**

```bash
mix test test/full_circle/work_shift_test.exs test/full_circle/shift_instance_test.exs
mix test
```

Then check the rewritten CTE against real data — this is the read-path counterpart to Task 3's migration gate:

```bash
mix run -e '
com = FullCircle.Repo.all(FullCircle.Sys.Company) |> hd()
rows =
  FullCircle.Repo.all(FullCircle.HR.Employee)
  |> Enum.flat_map(fn e -> FullCircle.HR.punch_card_query(5, 2026, e.id, com) end)

worked = Enum.reject(rows, fn r -> is_nil(r.time_list) end)
bad = Enum.filter(worked, fn r -> r.anomaly != nil end)
IO.puts("days with punches: #{length(worked)} | anomalous: #{length(bad)}")
IO.inspect(Enum.map(bad, fn r -> {r.name, r.dd} end), limit: :infinity)
'
```

Expected for May 2026: **68 anomalous days**, all `:missing_punch`, and **zero** `:too_long`. That number is not a failure — it is the odd-punch population the Global Constraints describe, and those same days render red today. What would be a failure is a `:too_long`, or an anomaly count that does not match this SQL, which measures the same thing without the new code:

```bash
PGPASSWORD=... psql -h localhost -U full_circle -d full_circle_dev -t -A -c "
select count(*) from (
  select ta.employee_id, (ta.punch_time at time zone c.timezone)::date dd, count(*) n
    from time_attendences ta join companies c on c.id = ta.company_id
   group by 1,2) d
 where d.n % 2 = 1
   and date_trunc('month', d.dd) = date '2026-05-01';"
```

Both sides must print the same number. A mismatch means the instance grouping moved a punch, and Task 3's cutover gate missed it.

- [ ] **Step 9: Format and commit**

```bash
mix format lib/full_circle/hr.ex lib/full_circle/hr/shift_instance.ex \
  lib/full_circle_web/live/time_attend_live/punch_card.ex \
  test/full_circle/work_shift_test.exs
git add -A
git commit -m "feat(hr): blank the hours on an unpairable shift instance

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 8: Work Shifts maintenance page

**Files:**
- Create: `lib/full_circle_web/live/work_shift_live/{index,index_component,form}.ex`
- Create: `test/full_circle_web/live/work_shift_live_test.exs`
- Modify: `lib/full_circle/hr.ex` (`save_work_shift/4`, `delete_work_shift/3`)
- Modify: `lib/full_circle/authorization.ex`, `lib/full_circle_web/router.ex`, `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`

**Interfaces:**
- Consumes: `WorkShift` + `WorkShift.cutover_time/1` + `WorkShift.nominal_end/1` (Task 1); `HR.reassign_punch/2` (Task 5).
- Produces: `Authorization.can?(user, :create_work_shift | :update_work_shift | :delete_work_shift, company)` — admin, manager, supervisor. Required by `StdInterface`, which derives the action atom from the klass name.
- Produces: `HR.save_work_shift(shift, attrs, company, user)` — re-resolves the shift's punches when the cutover moves.
- Produces: `HR.delete_work_shift(shift, company, user)` — refuses the default row and any shift still in use.

**Two rules the maintenance page has to enforce, or the stored grouping goes stale:**

1. **Editing `start_time` or `max_hour` moves the cutover.** Every punch on that shift was anchored with the *old* cutover, and nothing re-resolves them, so the stored `work_shift_date` silently stops agreeing with the arithmetic that produced it. A save that changes either field must re-resolve that shift's punches:

```elixir
  def save_work_shift(%WorkShift{} = ws, attrs, com, user) do
    moved? =
      Map.has_key?(attrs, "start_time") or Map.has_key?(attrs, "max_hour") or
        Map.has_key?(attrs, :start_time) or Map.has_key?(attrs, :max_hour)

    with {:ok, updated} <- StdInterface.save(ws, WorkShift, "work_shift", attrs, com, user) do
      if moved? and cutover_changed?(ws, updated) do
        from(t in TimeAttend,
          where: t.company_id == ^com.id and t.work_shift_id == ^updated.id
        )
        |> Repo.all()
        |> Enum.each(&reassign_punch(&1, com))
      end

      {:ok, updated}
    end
  end

  defp cutover_changed?(before, aft),
    do: WorkShift.cutover_time(before) != WorkShift.cutover_time(aft)
```

Re-resolving is idempotent, so a save that does not move the cutover costs one comparison and nothing else.

2. **The default row must not be deletable.** `time_attendences.work_shift_id` is `on_delete: :nilify_all` and `HR.default_work_shift/1` is `Repo.get_by!` — deleting the default orphans every punch in the company *and* makes the next punch raise. Refuse it, and refuse deleting any shift still referenced:

```elixir
  def delete_work_shift(%WorkShift{is_default: true}, _com, _user),
    do: {:error, :default_shift}

  def delete_work_shift(%WorkShift{} = ws, com, user) do
    cond do
      Repo.exists?(from t in TimeAttend, where: t.work_shift_id == ^ws.id) ->
        {:error, :shift_in_use}

      Repo.exists?(from a in EmployeeWorkShift, where: a.work_shift_id == ^ws.id) ->
        {:error, :shift_assigned}

      true ->
        StdInterface.delete(ws, "work_shift", com, user)
    end
  end
```

with tests:

```elixir
  test "the default shift cannot be deleted", ctx do
    gen = FullCircle.HR.default_work_shift(ctx.comp)
    assert {:error, :default_shift} = FullCircle.HR.delete_work_shift(gen, ctx.comp, ctx.user)
  end

  test "moving the cutover re-resolves that shift's punches", ctx do
    # Night 17:00/12 -> cutover 11:00, so a 02:00 punch anchors to the day before.
    {:ok, night} = ...
    # assign, punch 02:00, then widen max_hour so the cutover moves to 08:00
    # and the same punch now anchors to its own calendar date.
  end
```

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/work_shift_live_test.exs`:

```elixir
defmodule FullCircleWeb.WorkShiftLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  alias FullCircle.Repo

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, comp: comp}
  end

  defp member_conn(comp, role) do
    u = user_fixture()

    Repo.insert!(%FullCircle.Sys.CompanyUser{
      company_id: comp.id,
      user_id: u.id,
      role: role
    })

    build_conn() |> log_in_user(u)
  end

  test "lists the seeded General shift with its derived times", %{conn: conn, comp: comp} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/work_shifts")

    assert html =~ "Work Shifts"
    assert html =~ "General"
    assert html =~ "08:00"
    # nominal end and cutover are shown so the arithmetic is never a mystery
    assert html =~ "17:00"
    assert html =~ "02:00"
  end

  test "creates a night shift and shows its derived cutover", %{conn: conn, comp: comp} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/work_shifts/new")

    html =
      lv
      |> form("#work-shift-form",
        work_shift: %{
          name: "Night",
          start_time: "17:00",
          normal_hour: "9",
          max_hour: "12"
        }
      )
      |> render_submit()

    assert html =~ "Night" or render(lv) =~ "Night"
    ws = Repo.get_by!(FullCircle.HR.WorkShift, company_id: comp.id, name: "Night")
    assert FullCircle.HR.WorkShift.cutover_time(ws) == ~T[11:00:00]
    refute ws.is_default
  end

  test "rejects max_hour below normal_hour", %{conn: conn, comp: comp} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/work_shifts/new")

    html =
      lv
      |> form("#work-shift-form",
        work_shift: %{name: "Bad", start_time: "08:00", normal_hour: "12", max_hour: "9"}
      )
      |> render_submit()

    assert html =~ "must not be less than normal hour"
  end

  test "a clerk is bounced to the dashboard", %{comp: comp} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(member_conn(comp, "clerk"), ~p"/companies/#{comp.id}/work_shifts")

    assert to == "/companies/#{comp.id}/dashboard"
  end

  test "a supervisor is allowed in", %{comp: comp} do
    {:ok, _lv, html} = live(member_conn(comp, "supervisor"), ~p"/companies/#{comp.id}/work_shifts")
    assert html =~ "Work Shifts"
  end
end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle_web/live/work_shift_live_test.exs`
Expected: FAIL — no route for `/work_shifts`.

- [ ] **Step 3: Add the permissions**

In `lib/full_circle/authorization.ex`, next to the `:manage_punch_device` clause (line 274):

```elixir
  def can?(user, :create_work_shift, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :update_work_shift, company),
    do: allow_roles(~w(admin manager supervisor), company, user)

  def can?(user, :delete_work_shift, company),
    do: allow_roles(~w(admin manager supervisor), company, user)
```

Shift definitions change how everyone's hours are grouped, so this stays with the roles that can already pair punch devices — clerks may edit punches but not redefine what a shift is.

- [ ] **Step 4: Add the routes**

In `lib/full_circle_web/router.ex`, after `live("/punch_devices", ...)` (line 199):

```elixir
      live("/work_shifts", WorkShiftLive.Index, :index)
      live("/work_shifts/new", WorkShiftLive.Form, :new)
      live("/work_shifts/:work_shift_id/edit", WorkShiftLive.Form, :edit)
```

- [ ] **Step 5: Write the index**

Create `lib/full_circle_web/live/work_shift_live/index.ex`:

```elixir
defmodule FullCircleWeb.WorkShiftLive.Index do
  use FullCircleWeb, :live_view

  import Ecto.Query, warn: false

  alias FullCircle.Authorization
  alias FullCircle.HR.WorkShift
  alias FullCircle.Repo
  alias FullCircleWeb.WorkShiftLive.IndexComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-8/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <p class="text-center text-sm mb-2 text-gray-600 dark:text-gray-400">
        {gettext("An employee with no assignment works the default shift.")}
      </p>
      <div class="text-center mb-2">
        <.link navigate={~p"/companies/#{@current_company.id}/work_shifts/new"} class="blue button">
          {gettext("New Work Shift")}
        </.link>
      </div>
      <div class="font-medium flex flex-row text-center tracking-tighter bg-amber-200 dark:bg-amber-800">
        <div class="w-[26%] border-y border-amber-400 py-1">{gettext("Name")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Starts")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Nominal End")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Normal Hour")}</div>
        <div class="w-[14%] border-y border-amber-400 py-1">{gettext("Max Hour")}</div>
        <div class="w-[18%] border-y border-amber-400 py-1">{gettext("Cutover")}</div>
      </div>
      <div id="objects_list">
        <.live_component
          :for={obj <- @objects}
          module={IndexComponent}
          id={obj.id}
          obj={obj}
          current_company={@current_company}
        />
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company

    if Authorization.can?(socket.assigns.current_user, :update_work_shift, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Work Shifts"))
       |> assign(objects: list_shifts(company))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Not Authorized!"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  defp list_shifts(company) do
    from(w in WorkShift, where: w.company_id == ^company.id, order_by: [desc: w.is_default, asc: w.name])
    |> Repo.all()
  end
end
```

Create `lib/full_circle_web/live/work_shift_live/index_component.ex`:

```elixir
defmodule FullCircleWeb.WorkShiftLive.IndexComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.HR.WorkShift

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-row text-center tracking-tighter border-b border-gray-300 dark:border-gray-600 py-1 hover:bg-gray-100 dark:hover:bg-gray-700"
    >
      <div class="w-[26%]">
        <.link
          navigate={~p"/companies/#{@current_company.id}/work_shifts/#{@obj.id}/edit"}
          class="text-blue-700 dark:text-blue-400"
        >
          {@obj.name}
        </.link>
        <span :if={@obj.is_default} class="ml-1 text-xs text-gray-500">
          {gettext("(default)")}
        </span>
      </div>
      <div class="w-[14%]">{Calendar.strftime(@obj.start_time, "%H:%M")}</div>
      <div class="w-[14%]">{Calendar.strftime(WorkShift.nominal_end(@obj), "%H:%M")}</div>
      <div class="w-[14%]">{@obj.normal_hour}</div>
      <div class="w-[14%]">{@obj.max_hour}</div>
      <div class="w-[18%]">{Calendar.strftime(WorkShift.cutover_time(@obj), "%H:%M")}</div>
    </div>
    """
  end
end
```

- [ ] **Step 6: Write the form**

Create `lib/full_circle_web/live/work_shift_live/form.ex`:

```elixir
defmodule FullCircleWeb.WorkShiftLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.HR.WorkShift
  alias FullCircle.StdInterface

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-6/12">
      <p class="w-full text-2xl text-center font-medium">{@page_title}</p>
      <.form for={@form} id="work-shift-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <.input field={@form[:name]} label={gettext("Name")} />
        <.input field={@form[:start_time]} type="time" label={gettext("Starts")} />
        <.input field={@form[:normal_hour]} type="number" step="0.25" label={gettext("Normal Hour")} />
        <.input field={@form[:max_hour]} type="number" step="0.25" label={gettext("Max Hour")} />
        <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
          {gettext(
            "Normal Hour sets the displayed end time only. Max Hour is the tolerance: a shift longer than this is flagged, and it also places the cutover that separates one shift from the next."
          )}
        </p>
        <p :if={@derived} class="mt-1 text-sm font-medium">
          {gettext("Nominal end")}: {@derived.nominal_end} · {gettext("Cutover")}: {@derived.cutover}
        </p>
        <div class="text-center mt-3">
          <.button phx-disable-with={gettext("Saving...")}>{gettext("Save")}</.button>
          <.link navigate={~p"/companies/#{@current_company.id}/work_shifts"} class="orange button">
            {gettext("Back")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    obj =
      case params["work_shift_id"] do
        nil -> %WorkShift{start_time: ~T[08:00:00], normal_hour: Decimal.new("9"), max_hour: Decimal.new("12")}
        id -> StdInterface.get!(WorkShift, id)
      end

    {:ok,
     socket
     |> assign(page_title: if(obj.id, do: gettext("Edit Work Shift"), else: gettext("New Work Shift")))
     |> assign(obj: obj)
     |> assign_form(WorkShift.changeset(obj, %{}))}
  end

  @impl true
  def handle_event("validate", %{"work_shift" => attrs}, socket) do
    cs = WorkShift.changeset(socket.assigns.obj, attrs) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  @impl true
  def handle_event("save", %{"work_shift" => attrs}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    obj = socket.assigns.obj

    result =
      if obj.id,
        do: StdInterface.update(WorkShift, "work_shift", obj, attrs, company, user),
        else: StdInterface.create(WorkShift, "work_shift", attrs, company, user)

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved."))
         |> push_navigate(to: ~p"/companies/#{company.id}/work_shifts")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Not Authorized!"))
         |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}

      {:error, _, cs, _} ->
        {:noreply, assign_form(socket, cs)}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp assign_form(socket, cs) do
    obj = Ecto.Changeset.apply_changes(cs)

    derived =
      if obj.start_time && obj.normal_hour && obj.max_hour do
        %{
          nominal_end: Calendar.strftime(WorkShift.nominal_end(obj), "%H:%M"),
          cutover: Calendar.strftime(WorkShift.cutover_time(obj), "%H:%M")
        }
      end

    socket |> assign(form: to_form(cs, as: :work_shift)) |> assign(derived: derived)
  end
end
```

- [ ] **Step 7: Add the dashboard link**

In `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, after the Punch Devices link (line 120's closing `</.link>`):

```elixir
        <.link
          :if={FullCircle.Authorization.can?(@current_user, :update_work_shift, @current_company)}
          navigate={~p"/companies/#{@current_company.id}/work_shifts"}
          class="button orange"
        >
          {gettext("Work Shifts")}
        </.link>
```

- [ ] **Step 8: Run the tests**

Run: `mix test test/full_circle_web/live/work_shift_live_test.exs`
Expected: PASS.

- [ ] **Step 9: Format and commit**

```bash
mix format lib/full_circle_web/live/work_shift_live/*.ex \
  lib/full_circle/authorization.ex lib/full_circle_web/router.ex \
  lib/full_circle_web/live/dashboard_live/dashboard_live.ex \
  test/full_circle_web/live/work_shift_live_test.exs
git add -A
git commit -m "feat(hr): Work Shifts maintenance page with derived end and cutover

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 9: Assigning an employee to a shift

**Files:**
- Modify: `lib/full_circle_web/live/employee_live/form.ex`
- Modify: `lib/full_circle/hr.ex`
- Modify: `test/full_circle_web/live/work_shift_live_test.exs`

**Interfaces:**
- Consumes: `EmployeeWorkShift.changeset/2` (Task 1), `HR.rebuild_instance/4` (Task 5).
- Produces: `HR.list_employee_work_shifts(employee_id) :: [%EmployeeWorkShift{}]`, `HR.assign_work_shift(attrs, company, user)`, `HR.unassign_work_shift(id, company, user)` — the last two re-resolve affected punches.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle_web/live/work_shift_live_test.exs`:

```elixir
  describe "assignment" do
    setup %{comp: comp, user: user} do
      emp = FullCircle.HRFixtures.employee_fixture(%{}, comp, user)

      {:ok, night} =
        %FullCircle.HR.WorkShift{}
        |> FullCircle.HR.WorkShift.changeset(%{
          company_id: comp.id,
          name: "Night",
          start_time: ~T[17:00:00],
          normal_hour: "9",
          max_hour: "12"
        })
        |> Repo.insert()

      %{emp: emp, night: night}
    end

    test "assigning re-resolves existing punches into the new instance", ctx do
      a =
        Repo.insert!(%FullCircle.HR.TimeAttend{
          company_id: ctx.comp.id,
          employee_id: ctx.emp.id,
          user_id: ctx.user.id,
          punch_time: Timex.parse!("2026-05-05T17:00:00+08:00", "{RFC3339}") |> DateTime.truncate(:second),
          status: "Draft",
          input_medium: "Manual"
        })

      b =
        Repo.insert!(%FullCircle.HR.TimeAttend{
          company_id: ctx.comp.id,
          employee_id: ctx.emp.id,
          user_id: ctx.user.id,
          punch_time: Timex.parse!("2026-05-06T02:00:00+08:00", "{RFC3339}") |> DateTime.truncate(:second),
          status: "Draft",
          input_medium: "Manual"
        })

      {:ok, _} = FullCircle.HR.reassign_punch(a, ctx.comp)
      {:ok, _} = FullCircle.HR.reassign_punch(b, ctx.comp)

      # Under General these are two separate days, each with one punch.
      assert Repo.reload!(a).work_shift_date == ~D[2026-05-05]
      assert Repo.reload!(b).work_shift_date == ~D[2026-05-06]

      {:ok, _} =
        FullCircle.HR.assign_work_shift(
          %{
            "employee_id" => ctx.emp.id,
            "work_shift_id" => ctx.night.id,
            "effective_from" => "2026-05-01"
          },
          ctx.comp,
          ctx.user
        )

      # Under Night they are one instance anchored to 5 May.
      assert Repo.reload!(a).work_shift_date == ~D[2026-05-05]
      assert Repo.reload!(b).work_shift_date == ~D[2026-05-05]
      assert Repo.reload!(a).punch_kind == "IN"
      assert Repo.reload!(b).punch_kind == "OUT"
    end

    test "the employee form lists assignments and offers General as the default", ctx do
      {:ok, _lv, html} =
        live(ctx.conn, ~p"/companies/#{ctx.comp.id}/employees/#{ctx.emp.id}/edit")

      assert html =~ "Work Shift"
      assert html =~ "General"
    end
  end
```

- [ ] **Step 2: Run and watch it fail**

Run: `mix test test/full_circle_web/live/work_shift_live_test.exs`
Expected: FAIL — `HR.assign_work_shift/3` is undefined.

- [ ] **Step 3: Add the context functions**

Add to `lib/full_circle/hr.ex`:

```elixir
  def list_employee_work_shifts(employee_id) do
    from(e in EmployeeWorkShift,
      join: w in WorkShift,
      on: w.id == e.work_shift_id,
      where: e.employee_id == ^employee_id,
      order_by: [desc: e.effective_from],
      preload: [work_shift: w]
    )
    |> Repo.all()
  end

  @doc """
  Assigns a shift, then re-resolves every punch the assignment now covers —
  an assignment changes which instance existing punches belong to.
  """
  def assign_work_shift(attrs, company, user) do
    if can?(user, :update_work_shift, company) do
      with {:ok, a} <- %EmployeeWorkShift{} |> EmployeeWorkShift.changeset(attrs) |> Repo.insert() do
        reresolve_range(a.employee_id, company, a.effective_from, a.effective_to)
        {:ok, a}
      end
    else
      :not_authorise
    end
  end

  def unassign_work_shift(id, company, user) do
    if can?(user, :update_work_shift, company) do
      a = Repo.get!(EmployeeWorkShift, id)

      with {:ok, a} <- Repo.delete(a) do
        reresolve_range(a.employee_id, company, a.effective_from, a.effective_to)
        {:ok, a}
      end
    else
      :not_authorise
    end
  end

  # An assignment changes which instance existing punches belong to, so every
  # punch in range is re-resolved and both the instances they left and the ones
  # they joined are renumbered.
  #
  # The window is padded a day either side because a cutover can pull a punch
  # into the neighbouring day's instance. Bounds are built in company-local time
  # and then shifted to UTC, because punch_time is UTC.
  defp reresolve_range(employee_id, company, from_date, to_date) do
    tz = company.timezone

    from_utc =
      DateTime.new!(Date.add(from_date, -1), ~T[00:00:00], tz)
      |> DateTime.shift_zone!("Etc/UTC")

    to_utc =
      case to_date do
        nil ->
          DateTime.new!(~D[9999-12-31], ~T[00:00:00], "Etc/UTC")

        d ->
          DateTime.new!(Date.add(d, 2), ~T[00:00:00], tz)
          |> DateTime.shift_zone!("Etc/UTC")
      end

    punches =
      from(t in TimeAttend,
        where: t.company_id == ^company.id,
        where: t.employee_id == ^employee_id,
        where: t.punch_time >= ^from_utc and t.punch_time < ^to_utc,
        order_by: [asc: t.punch_time]
      )
      |> Repo.all()

    before = Enum.map(punches, &{&1.work_shift_id, &1.work_shift_date})

    after_ =
      Enum.map(punches, fn ta ->
        attrs = punch_shift_attrs(ta.employee_id, company, ta.punch_time)
        ta |> Ecto.Changeset.change(attrs) |> Repo.update!()
        {attrs.work_shift_id, attrs.work_shift_date}
      end)

    (before ++ after_)
    |> Enum.uniq()
    |> Enum.reject(fn {ws_id, date} -> is_nil(ws_id) or is_nil(date) end)
    |> Enum.each(fn {ws_id, date} -> rebuild_instance(company, employee_id, ws_id, date) end)

    :ok
  end
```

- [ ] **Step 4: Add the form section**

In `lib/full_circle_web/live/employee_live/form.ex`, add a section rendering `@work_shift_assignments` — each row showing the shift name and effective range with a remove button, plus a small add form (shift select, effective from, effective to). Assign it in `mount/3` with `HR.list_employee_work_shifts(employee_id)` and the company's shifts, and state the fallback in the UI.

Two guards this section needs, both of which the rest of the employee form does not:

- **`:create_employee` / `:update_employee` include `clerk`** (`authorization.ex:265-272`) while `:update_work_shift` does not (admin / manager / supervisor). A clerk opening an employee must see the assignments read-only — no add form, no Remove button — or they get a section whose every action fails authorization. Compute `@can_assign_shift = can?(@current_user, :update_work_shift, @current_company)` in `mount/3` and gate the controls on it.
- **A new employee has no id.** On `live_action == :new` the employee is an unsaved changeset, and an `employee_work_shifts` row cannot reference it. Render the section only when there is a saved id, with a one-line note that shifts can be assigned after saving. (An employee with no assignment works the default shift anyway, so nothing is lost by the order.)

```heex
<div :if={@employee_id && @can_assign_shift} class="mt-4 border-t pt-3">
```

for the editable form, and a `:if={@employee_id && !@can_assign_shift}` read-only variant listing the same rows without controls:

```heex
<div class="mt-4 border-t pt-3">
  <p class="font-medium">{gettext("Work Shift")}</p>
  <p class="text-sm text-gray-600 dark:text-gray-400">
    {gettext("No assignment means this employee works the default shift (General).")}
  </p>
  <div :for={a <- @work_shift_assignments} class="flex flex-row gap-2 items-center py-1">
    <div class="w-[30%]">{a.work_shift.name}</div>
    <div class="w-[25%]">{a.effective_from}</div>
    <div class="w-[25%]">{a.effective_to || gettext("open")}</div>
    <.button type="button" phx-click="unassign_shift" phx-value-id={a.id} class="red">
      {gettext("Remove")}
    </.button>
  </div>
</div>
```

Wire `handle_event("assign_shift", ...)` to `HR.assign_work_shift/3` and `handle_event("unassign_shift", ...)` to `HR.unassign_work_shift/3`, reloading `@work_shift_assignments` after each and flashing changeset errors (the overlap message included).

- [ ] **Step 5: Run the tests**

Run: `mix test test/full_circle_web/live/work_shift_live_test.exs test/full_circle_web/live/`
Expected: PASS.

- [ ] **Step 6: Format and commit**

```bash
mix format lib/full_circle/hr.ex lib/full_circle_web/live/employee_live/form.ex \
  test/full_circle_web/live/work_shift_live_test.exs
git add -A
git commit -m "feat(hr): assign employees to work shifts and re-resolve their punches

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Task 10: Gettext, skills, and full-suite verification

**Files:**
- Modify: `priv/gettext/{en,zh}/LC_MESSAGES/default.po`
- Modify: `.claude/skills/{punch-card-payroll,finger-print-import,qr-gate-punch}.md`

- [ ] **Step 1: Extract and translate**

```bash
mix gettext.extract --merge
```

Fill the new msgids in `priv/gettext/zh/LC_MESSAGES/default.po`:

| msgid | zh msgstr |
|---|---|
| `Work Shifts` | `班次` |
| `Work Shift` | `班次` |
| `New Work Shift` | `新增班次` |
| `Edit Work Shift` | `修改班次` |
| `Starts` | `开始时间` |
| `Nominal End` | `名义结束` |
| `Normal Hour` | `正常时数` |
| `Max Hour` | `最长时数` |
| `Cutover` | `分界时间` |
| `(default)` | `（预设）` |
| `open` | `无限期` |
| `must not be less than normal hour` | `不可少于正常时数` |
| `overlaps an existing assignment` | `与现有指派重叠` |
| `there is already a default shift` | `已经有预设班次` |
| `An employee with no assignment works the default shift.` | `没有指派的员工使用预设班次。` |
| `No assignment means this employee works the default shift (General).` | `没有指派表示此员工使用预设班次（General）。` |
| `Unresolved punches on: %{dates}` | `未处理的打卡日期：%{dates}` |

Leave any msgid that already has a translation alone.

- [ ] **Step 2: Update the skills**

Add to `.claude/skills/punch-card-payroll.md`:

```markdown
## Shifts, not calendar days

Attendance groups by **shift instance**, not by calendar day. Each punch stores
`work_shift_id` + `work_shift_date`; hours, pay date and anomalies are derived
on read (`FullCircle.HR.ShiftInstance`), never stored, so a clerk's edit cannot
leave a stale total.

- `work_shifts`: `name`, `start_time`, `normal_hour`, `max_hour`. There is no
  `end_time` — it is `start_time + normal_hour`, display only. **`normal_hour`
  is never an OT threshold**; OT is still `worked − Employee.work_hours_per_day`.
- `max_hour` is a tolerance (~12), not the shift length (~9). 57% of real
  employee-days span more than nine hours, so conflating them would flag half of
  history.
- **Cutover** = `(start_time + (24 + max_hour) / 2) mod 24` — General 02:00,
  Night 11:00. An instance is `[cutover(D), cutover(D+1))` and `work_shift_date`
  is D. Pay date is the local date of the **last** punch: the day it ended.
- `employee_work_shifts` is dated. **No effective row means the company's
  default (General) shift**, so most staff need no row.
- Two anomalies only: an odd punch count, and a span over `max_hour`. A punch is
  never anomalous for falling outside the nominal window — 34.5% of real punches
  are. An anomalous instance has `worked = nil` (**never `0.0`** — a real
  zero-hour day must stay distinguishable) and renders red.
- **Nothing gates payroll.** An anomaly is a display state, not a lock: 5% of
  employee-days are odd, and the heaviest cases are off-site staff (lorry
  drivers) who punch once a day by design and have no missing punch to recover.
  `PaySlipOp` does not know this feature exists. Do not add a block here without
  first re-measuring that population.
- A time-only input on a punch row resolves **inside the instance window**, not
  against the row's date — rows are keyed by pay date, so on a night shift those
  are different days (`PunchTimeComponent.slot_date/3`).
- No ceiling on pairs. `PunchGate.rebuild_day_flags/3` is gone; `flag` is a
  derived label written by `HR.rebuild_instance/4` and numbers past `3_OUT_3`.
```

Add to `.claude/skills/finger-print-import.md`:

```markdown
## Punches past the sixth

`fill_flags_to_map/1` used to emit `flag: nil` past index 6. Since
`finger_print_log_changeset` requires `:flag` and
`insert_time_attendence_from_log/2` never checked the insert result, **those
punches were silently discarded and never stored**. Its dedupe also compared
`ta.flag == ^entry.flag`, which is `flag = NULL` for exactly those rows and
never true.

Position is now derived after insert by `HR.rebuild_instance/4`, the import
writes a placeholder flag, and the dedupe matches on employee + a ±5 minute
window only. Do not reintroduce a flag comparison there.
```

Add to `.claude/skills/qr-gate-punch.md`, replacing the IN/OUT flag-rebuild sentence:

```markdown
The gate no longer rebuilds flags per calendar day. `insert_punch/6` calls
`HR.reassign_punch/2`, which resolves the punch to its shift instance
(`work_shift_id` + `work_shift_date`) and renumbers `punch_kind` and `flag`
across that instance. A night shift's 02:00 punch joins the previous evening's
instance rather than opening a new day.
```

- [ ] **Step 3: Run the whole suite**

```bash
mix test
```
Expected: PASS with no failures. In particular `punch_gate_test.exs`, `punch_attendance_controller_test.exs`, `punch_photo_controller_test.exs`, `punch_query_photo_test.exs` and any payslip tests must stay green — together they are the evidence that behaviour did not move for the 23,902 existing punches.

If anything fails, fix it before committing. Do not commit a red suite.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(skills): record the shift instance model

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EVknXqbVEgvFNnMbxUqdXG"
```

---

## Self-review notes

**Spec coverage.** `work_shifts` shape and the `normal_hour`/`max_hour` split (T1); dated assignment with overlap rejection and the default-shift fallback (T1, T2); seeding in both the migration and `Sys.create_company/2` (T1); derived cutover (T1); instance anchoring and attribution to the ending day (T2, T4); `time_attendences` columns, dead `shift_id` dropped, backfill under the cutover gate and the hours-parity check (T3); pairing with no ceiling, hours, anomalies, nil-not-zero (T4); write-path assignment replacing `rebuild_day_flags/3` on every path including `delete_time_attendence_by_id/3`, fingerprint silent-discard and dedupe fixes, `flag` no longer required (T5); the punch row with `slots = max(6, count + 1)`, the flex-wrap wrapper, the parent's N-slot handler and instance-aware time entry (T6); the instance-grouped CTE, blanked hours and totals, the `holiday_pay_days/2` rewrite, the pay-slip edit lock keyed to the pay date (T7); maintenance page, permissions, cutover-move re-resolution and delete protection (T8); assignment UI, authorization and re-resolution (T9); gettext and skills (T10).

**Corrections made after review.** Six things in the first draft were wrong and are fixed above, each with the measurement that settled it:

| Was | Is |
|---|---|
| Backfill gate compared `work_shift_date` with the expression it was assigned from — a tautology | Compares the punch's local time against the shift's cutover (T3); measured 0 violations in 23,902 rows |
| General seeded only by the migration | Also seeded by `Sys.create_company/2` (T1) — otherwise every new tenant and every test fixture raises in `default_work_shift/1` |
| `IN 5/5 08:00` + `OUT 6/5 17:00` treated as one 33-hour `:too_long` | Two instances, two `:missing_punch` (T4, T7) — General's 02:00 cutover splits them, which is the whole point of the cutover |
| Pay slip blocked on an anomalous month | Nothing blocks (T7) — 328 employee-days are already odd, most of them off-site staff with no missing punch to recover, and 61 of 68 affected employee-months are already paid |
| `holiday_pay_days/2` indexed `Enum.at(objs, i - 1)` | Falls back to `punch_by_date/3` at the month edges (T7) — index `-1` is the last day of the month, not yesterday |
| Component recomputed `wh` over the query's `nil`, and the parent matched 6 tuples | Component applies the same `anomaly/3` rule and blanks; parent maps N slots (T6) |

**Shippable milestone.** Tasks 1–5 change no visible behaviour: they add the model, backfill it under the cutover gate, and swap the flag engine. That is a sensible place to stop, verify against production data, and continue later. Tasks 6–9 are what make night shifts usable.

**Riskiest tasks, in order.** T3 (the backfill — gated in SQL, and the gate is the point), T7 (the SQL rewrite — the May 2026 anomaly count must match the pre-change SQL exactly), T5 (every write path must call the re-resolver, including the delete path the punch row uses, or punches silently keep stale positions), T6 (the typed-time rule is the difference between a night shift being repairable and being corrupted by its own repair).

**Deliberately not built:** rotating rosters, shift swaps, lateness reporting, night-shift allowances, clock-time OT, removal of the `flag` column — all explicit non-goals in the spec. Also not built: any representation of "this employee's attendance is not measured". With nothing gating payroll it earns nothing, and the off-site staff it would describe already read correctly without it.

**Known, accepted limitation.** `EmployeeWorkShift.validate_no_overlap/1` is a `Repo.exists?` check in a changeset, not an exclusion constraint, so two simultaneous assignment saves for one employee could still overlap. Adding a real constraint needs `btree_gist` and a `daterange` column; on a floor with a handful of shift workers and one clerk assigning them, the changeset check is the proportionate answer.
