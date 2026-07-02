# Statutory Config Implementation Plan (Phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-company, effective-dated statutory config in the database — rate tables, PayScript calcs, file-format stubs — with a DB-backed PayScript env, `calculate_pay/2` dispatch (legacy fallback), the statutory-bundle format with export/import + `mix statutory.validate`, seeding for existing and new companies, and golden parity tests against `SalaryNoteCalFunc`.

**Architecture:** Three new schemas under `FullCircle.HR.*` + one context module `FullCircle.StatutoryConfig` (resolution, bundles, seeding, calculation entry point). `FullCircle.StatutoryConfig.DbEnv` implements the `FullCircle.PayScript.Env` behaviour (Phase 1). The shipped Malaysia template is itself a bundle JSON at `priv/statutory_templates/malaysia.json`, generated from the legacy module so no rates are hand-transcribed.

**Tech Stack:** Ecto (binary_id via `FullCircle.Schema`), Jason (already a dep), PayScript engine from Phase 1 (`docs/superpowers/plans/2026-07-02-payscript-engine.md` — must be implemented first).

## Global Constraints

- Phase 1 must be complete: `FullCircle.PayScript.{parse/1, eval/3, validate/2, calc_deps/1, check_cycles/1, standard_variables/0}` and `FullCircle.PayScript.Env` behaviour exist and their tests pass.
- All three tables are per-company with unique `(company_id, code, effective_from)`; codes match `~r/^[a-z0-9_]+$/`.
- Version resolution everywhere: greatest `effective_from <= Timex.end_of_month(pay_year, pay_month)`.
- Legacy `SalaryNoteCalFunc` is **not deleted** in this phase — it is the fallback and the parity oracle. Deletion happens in Phase 4.
- Behavior parity is absolute: for every seeded code, PayScript-from-DB must equal `SalaryNoteCalFunc.calculate_value/3` exactly on the test grid.
- No `String.to_atom` on data: the legacy fallback maps `cal_func` strings through a fixed literal map.
- Known pre-existing failures: 2 `pay_run_test` failures are unrelated; `credo` is not installed.

## File Structure

| File | Responsibility |
|---|---|
| `priv/repo/migrations/<ts>_create_statutory_config.exs` | Three tables + indexes |
| `lib/full_circle/HR/statutory_rate_table.ex` | Schema + changeset (bracket validation) |
| `lib/full_circle/HR/statutory_calc.ex` | Schema + changeset (PayScript validation) |
| `lib/full_circle/HR/statutory_file_format.ex` | Schema + changeset (shape only; deep validation Phase 4) |
| `lib/full_circle/statutory_config.ex` | Context: resolution, save (auth+log), calculate entry point, bundles, seeding |
| `lib/full_circle/statutory_config/db_env.ex` | `PayScript.Env` impl: DB lookup/ytd_sum/calc |
| `lib/full_circle/statutory_config/cache.ex` | ETS read-through cache for resolved versions |
| `lib/mix/tasks/statutory.gen_template.ex` | One-shot generator: legacy tables + reference scripts → `priv/statutory_templates/malaysia.json` |
| `lib/mix/tasks/statutory.validate.ex` | Offline bundle validator for agents |
| `priv/statutory_templates/malaysia.json` | Shipped standard Malaysia bundle (generated, committed) |
| Modify: `lib/full_circle/salary_note_cal_func.ex` | `defp` → `def` for `socso_table/0`, `eis_table/0`, `pcb_table_normal/0` (needed by generator + parity tests) |
| Modify: `lib/full_circle/pay_slip_op.ex` | dispatch via StatutoryConfig with legacy fallback |
| Modify: `lib/full_circle/sys.ex` | seed statutory config in `create_company/2` Multi |
| Modify: `lib/full_circle/application.ex` | add `FullCircle.StatutoryConfig.Cache` to the supervision tree |
| Tests | `test/full_circle/statutory_config_test.exs`, `test/full_circle/statutory_config/db_env_test.exs`, `test/full_circle/statutory_config/bundle_test.exs`, `test/full_circle/statutory_parity_test.exs` |

Design deviation from the spec (note for the record): the spec sketched two SOCSO table versions (5-column pre-SKBBK, 6-column from 2026-06-01). The legacy code ships one 6-column table and gates SKBBK by the `socso_24hour` calc's existence, so for exact parity we seed **one** 6-column `socso` table effective `1957-01-01` and give the `socso_24hour` **calc** `effective_from: 2026-06-01`. Effective dating is still exercised (calc-level) and tested.

---

### Task 1: Migration and schemas

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_statutory_config.exs` (use `mix ecto.gen.migration create_statutory_config`)
- Create: `lib/full_circle/HR/statutory_rate_table.ex`
- Create: `lib/full_circle/HR/statutory_calc.ex`
- Create: `lib/full_circle/HR/statutory_file_format.ex`
- Test: `test/full_circle/statutory_config_test.exs` (changeset section)

**Interfaces:**
- Produces schemas `FullCircle.HR.StatutoryRateTable` (fields `code`, `effective_from :: Date`, `columns :: {:array, :string}`, `rows :: {:array, {:array, :float}}`, `company_id`), `FullCircle.HR.StatutoryCalc` (fields `code`, `name`, `effective_from`, `script :: :string`, `company_id`), `FullCircle.HR.StatutoryFileFormat` (fields `code`, `name`, `effective_from`, `renderer` default `"text"`, `spec :: :map`, `company_id`). Each has `changeset/2`.
- Changeset rules produced (later tasks and Phase 3 forms rely on these exact error keys):
  - all: `code` required + format `~r/^[a-z0-9_]+$/`, `effective_from` required, `company_id` required, unique constraint name `:<table>_unique_code_effective`.
  - rate table: `columns` length >= 3; `rows` non-empty; every row length == `length(columns)`; brackets validated on the first two columns — each `from < to`, rows sorted ascending, `row[n].to == row[n+1].from` (contiguous, matching legacy `value > from and value <= to` semantics). Errors go on `:rows`.
  - calc: `script` required and must pass `FullCircle.PayScript.validate(script, %{})` (variables only — table/calc cross-checks happen at save time in Task 2 where company context exists); each validation error message is added on `:script`.
  - file format: `renderer` in `["text"]`; `spec` must be a map. (Deep spec validation is Phase 4.)

- [ ] **Step 1: Write the failing changeset tests**

```elixir
# test/full_circle/statutory_config_test.exs
defmodule FullCircle.StatutoryConfigSchemaTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.HR.{StatutoryCalc, StatutoryRateTable, StatutoryFileFormat}

  @com_id Ecto.UUID.generate()

  defp table_attrs(over \\ %{}) do
    Map.merge(
      %{
        code: "socso",
        effective_from: ~D[1957-01-01],
        columns: ["wage_from", "wage_to", "employee"],
        rows: [[0.0, 30.0, 0.1], [30.0, 50.0, 0.2]],
        company_id: @com_id
      },
      over
    )
  end

  test "valid rate table changeset" do
    assert %{valid?: true} = StatutoryRateTable.changeset(%StatutoryRateTable{}, table_attrs())
  end

  test "code format is enforced on all three schemas" do
    for {mod, attrs} <- [
          {StatutoryRateTable, table_attrs(%{code: "Bad Code"})},
          {StatutoryCalc,
           %{code: "Bad Code", name: "x", effective_from: ~D[2026-01-01], script: "result = 1", company_id: @com_id}},
          {StatutoryFileFormat,
           %{code: "Bad Code", name: "x", effective_from: ~D[2026-01-01], renderer: "text", spec: %{}, company_id: @com_id}}
        ] do
      cs = mod.changeset(struct(mod), attrs)
      assert %{code: [_ | _]} = errors_on(cs)
    end
  end

  test "rate table rejects row width mismatch, non-contiguous and inverted brackets" do
    assert %{rows: [_ | _]} =
             errors_on(StatutoryRateTable.changeset(%StatutoryRateTable{}, table_attrs(%{rows: [[0.0, 30.0]]})))

    assert %{rows: [msg | _]} =
             errors_on(
               StatutoryRateTable.changeset(
                 %StatutoryRateTable{},
                 table_attrs(%{rows: [[0.0, 30.0, 0.1], [40.0, 50.0, 0.2]]})
               )
             )

    assert msg =~ "contiguous"

    assert %{rows: [_ | _]} =
             errors_on(StatutoryRateTable.changeset(%StatutoryRateTable{}, table_attrs(%{rows: [[30.0, 0.0, 0.1]]})))
  end

  test "calc script must parse and validate" do
    cs =
      StatutoryCalc.changeset(%StatutoryCalc{}, %{
        code: "x",
        name: "X",
        effective_from: ~D[2026-01-01],
        script: "a = wage_typo\nresult = a",
        company_id: @com_id
      })

    assert %{script: [msg | _]} = errors_on(cs)
    assert msg =~ "unknown identifier 'wage_typo'"
  end

  test "file format renderer restricted to text" do
    cs =
      StatutoryFileFormat.changeset(%StatutoryFileFormat{}, %{
        code: "epf_form_a",
        name: "EPF",
        effective_from: ~D[2026-01-01],
        renderer: "xlsx",
        spec: %{},
        company_id: @com_id
      })

    assert %{renderer: [_ | _]} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/statutory_config_test.exs`
Expected: compilation error — schemas undefined.

- [ ] **Step 3: Write the migration**

```elixir
defmodule FullCircle.Repo.Migrations.CreateStatutoryConfig do
  use Ecto.Migration

  def change do
    create table(:statutory_rate_tables) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :effective_from, :date, null: false
      add :columns, {:array, :string}, null: false
      add :rows, :jsonb, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:statutory_rate_tables, [:company_id, :code, :effective_from],
             name: :statutory_rate_tables_unique_code_effective
           )

    create table(:statutory_calcs) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :effective_from, :date, null: false
      add :script, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:statutory_calcs, [:company_id, :code, :effective_from],
             name: :statutory_calcs_unique_code_effective
           )

    create table(:statutory_file_formats) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :effective_from, :date, null: false
      add :renderer, :string, null: false, default: "text"
      add :spec, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:statutory_file_formats, [:company_id, :code, :effective_from],
             name: :statutory_file_formats_unique_code_effective
           )
  end
end
```

Note: `rows` is `:jsonb` because Ecto's `{:array, {:array, :float}}` maps cleanly onto jsonb; keep the schema field type `{:array, {:array, :float}}` and Ecto handles (de)serialization. If `mix ecto.migrate` complains, use `add :rows, {:array, {:array, :float}}` (Postgres `float8[][]` is avoided intentionally — jsonb keeps bundle round-trips lossless).

- [ ] **Step 4: Write the schemas**

```elixir
# lib/full_circle/HR/statutory_rate_table.ex
defmodule FullCircle.HR.StatutoryRateTable do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "statutory_rate_tables" do
    field(:code, :string)
    field(:effective_from, :date)
    field(:columns, {:array, :string})
    field(:rows, {:array, {:array, :float}})
    belongs_to(:company, FullCircle.Sys.Company)
    timestamps(type: :utc_datetime)
  end

  def changeset(rt, attrs) do
    rt
    |> cast(attrs, [:code, :effective_from, :columns, :rows, :company_id])
    |> validate_required([:code, :effective_from, :columns, :rows, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_length(:columns, min: 3)
    |> validate_brackets()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :statutory_rate_tables_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end

  defp validate_brackets(cs) do
    columns = get_field(cs, :columns) || []
    rows = get_field(cs, :rows) || []
    width = length(columns)

    cond do
      rows == [] ->
        add_error(cs, :rows, gettext("must have at least one row"))

      Enum.any?(rows, fn r -> length(r) != width end) ->
        add_error(cs, :rows, gettext("every row must have one value per column"))

      Enum.any?(rows, fn [from, to | _] -> from >= to end) ->
        add_error(cs, :rows, gettext("bracket 'from' must be less than 'to'"))

      not contiguous?(rows) ->
        add_error(cs, :rows, gettext("brackets must be contiguous and ascending"))

      true ->
        cs
    end
  end

  defp contiguous?(rows) do
    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [[_, to | _], [from, _ | _]] -> to == from end)
  end
end
```

```elixir
# lib/full_circle/HR/statutory_calc.ex
defmodule FullCircle.HR.StatutoryCalc do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "statutory_calcs" do
    field(:code, :string)
    field(:name, :string)
    field(:effective_from, :date)
    field(:script, :string)
    belongs_to(:company, FullCircle.Sys.Company)
    timestamps(type: :utc_datetime)
  end

  def changeset(sc, attrs) do
    sc
    |> cast(attrs, [:code, :name, :effective_from, :script, :company_id])
    |> validate_required([:code, :name, :effective_from, :script, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_script()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :statutory_calcs_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end

  # Structural validation only (variables, functions, arg shapes). Table/calc
  # cross-checks need the company's full config and run in StatutoryConfig.save_*.
  defp validate_script(cs) do
    case get_field(cs, :script) do
      nil ->
        cs

      script ->
        case FullCircle.PayScript.validate(script, %{}) do
          :ok -> cs
          {:error, errors} ->
            Enum.reduce(errors, cs, fn e, acc -> add_error(acc, :script, Exception.message(e)) end)
        end
    end
  end
end
```

```elixir
# lib/full_circle/HR/statutory_file_format.ex
defmodule FullCircle.HR.StatutoryFileFormat do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "statutory_file_formats" do
    field(:code, :string)
    field(:name, :string)
    field(:effective_from, :date)
    field(:renderer, :string, default: "text")
    field(:spec, :map)
    belongs_to(:company, FullCircle.Sys.Company)
    timestamps(type: :utc_datetime)
  end

  def changeset(ff, attrs) do
    ff
    |> cast(attrs, [:code, :name, :effective_from, :renderer, :spec, :company_id])
    |> validate_required([:code, :name, :effective_from, :renderer, :spec, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_inclusion(:renderer, ["text"])
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :statutory_file_formats_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end
end
```

- [ ] **Step 5: Migrate and run tests**

Run: `mix ecto.migrate && mix test test/full_circle/statutory_config_test.exs`
Expected: migration applies; all changeset tests PASS.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations lib/full_circle/HR/statutory_rate_table.ex lib/full_circle/HR/statutory_calc.ex lib/full_circle/HR/statutory_file_format.ex test/full_circle/statutory_config_test.exs
git commit -m "feat(statutory): schemas and migration for statutory config"
```

---

### Task 2: Context — save, resolution, cache

**Files:**
- Create: `lib/full_circle/statutory_config.ex`
- Create: `lib/full_circle/statutory_config/cache.ex`
- Modify: `lib/full_circle/application.ex` (add `FullCircle.StatutoryConfig.Cache` to `children`, anywhere after the Repos)
- Modify: `lib/full_circle/authorization.ex` (add clause)
- Test: extend `test/full_circle/statutory_config_test.exs`

**Interfaces:**
- Consumes: Task 1 schemas; `FullCircle.Sys.log_entry_for/insert_log_for` conventions (mirror how `FullCircle.StdInterface.create/4` writes logs — read `lib/full_circle/std_interface.ex` before implementing).
- Produces (used by Tasks 3–6 and Phase 3):
  - `StatutoryConfig.save_rate_table(attrs, company, user) :: {:ok, %StatutoryRateTable{}} | {:error, changeset} | :not_authorise`
  - `StatutoryConfig.save_calc(attrs, company, user)` — same shape; **additionally** validates the script against the company's post-save universe: `PayScript.validate(script, %{tables: tables_map(company_id, date), calcs: calc_codes(company_id) ++ [attrs.code]})` and `PayScript.check_cycles/1` over the company's effective scripts with this one substituted; failures land on the changeset `:script` field.
  - `StatutoryConfig.save_file_format(attrs, company, user)` — same shape.
  - `StatutoryConfig.effective_calc(company_id, code, %Date{}) :: %StatutoryCalc{} | nil`
  - `StatutoryConfig.effective_table(company_id, code, %Date{}) :: %StatutoryRateTable{} | nil`
  - `StatutoryConfig.effective_file_format(company_id, code, %Date{}) :: %StatutoryFileFormat{} | nil`
  - `StatutoryConfig.calc_codes(company_id) :: [String.t()]` (distinct codes, any version)
  - `StatutoryConfig.tables_map(company_id, %Date{}) :: %{code => [columns]}` (effective versions)
  - `StatutoryConfig.list_versions(kind, company_id)` with `kind in [:table, :calc, :file_format]` → all rows ordered `code, effective_from desc` (for Phase 3 index screens and bundle export).
  - Authorization: `can?(user, :manage_statutory_config, company)` → admin only, following the existing `allow_roles(~w(admin), company, user)` pattern in `lib/full_circle/authorization.ex`.
  - `Cache.fetch({company_id, kind, code}, fun)` read-through; `Cache.invalidate(company_id)` deletes all entries for a company; saves call it. Cached value: the full sorted version list for that code; resolution picks from it in memory.

- [ ] **Step 1: Write the failing tests** (append to `test/full_circle/statutory_config_test.exs`; use `FullCircle.SysFixtures.company_fixture/2` and `FullCircle.UserAccountsFixtures.user_fixture/0` the same way `test/full_circle/hr_test.exs` does — read that file's setup block first and copy its setup)

```elixir
describe "save/resolution" do
  setup do
    # copy the {company, user} setup pattern from test/full_circle/hr_test.exs
    ...same setup as hr_test.exs, returning %{com: com, user: user}...
  end

  test "save_calc persists and effective_calc resolves by date", %{com: com, user: user} do
    {:ok, _v1} =
      StatutoryConfig.save_calc(
        %{code: "socso_24hour", name: "SKBBK", effective_from: ~D[2026-06-01], script: "result = 1"},
        com,
        user
      )

    {:ok, _v2} =
      StatutoryConfig.save_calc(
        %{code: "socso_24hour", name: "SKBBK", effective_from: ~D[2027-01-01], script: "result = 2"},
        com,
        user
      )

    assert StatutoryConfig.effective_calc(com.id, "socso_24hour", ~D[2026-05-31]) == nil
    assert %{script: "result = 1"} = StatutoryConfig.effective_calc(com.id, "socso_24hour", ~D[2026-06-30])
    assert %{script: "result = 2"} = StatutoryConfig.effective_calc(com.id, "socso_24hour", ~D[2027-03-31])
  end

  test "save_calc rejects unknown table reference and calc cycles", %{com: com, user: user} do
    assert {:error, cs} =
             StatutoryConfig.save_calc(
               %{code: "a", name: "A", effective_from: ~D[2026-01-01],
                 script: ~s|result = lookup("ghost", wages, "employee")|},
               com,
               user
             )

    assert %{script: [msg | _]} = errors_on(cs)
    assert msg =~ "unknown table 'ghost'"

    {:ok, _} =
      StatutoryConfig.save_calc(
        %{code: "b", name: "B", effective_from: ~D[2026-01-01], script: ~s|result = calc("c")|},
        com, user)

    assert {:error, cs} =
             StatutoryConfig.save_calc(
               %{code: "c", name: "C", effective_from: ~D[2026-01-01], script: ~s|result = calc("b")|},
               com, user)

    assert %{script: [msg | _]} = errors_on(cs)
    assert msg =~ "cycle"
  end

  test "non-admin cannot save", %{com: com} do
    clerk = ...create a user with role "clerk" in com, same pattern hr_test.exs uses...
    assert :not_authorise =
             StatutoryConfig.save_calc(
               %{code: "x", name: "X", effective_from: ~D[2026-01-01], script: "result = 1"},
               com, clerk)
  end

  test "cache is invalidated on save", %{com: com, user: user} do
    {:ok, _} = StatutoryConfig.save_calc(%{code: "x", name: "X", effective_from: ~D[2026-01-01], script: "result = 1"}, com, user)
    assert %{script: "result = 1"} = StatutoryConfig.effective_calc(com.id, "x", ~D[2026-06-30])
    {:ok, _} = StatutoryConfig.save_calc(%{code: "x", name: "X", effective_from: ~D[2026-03-01], script: "result = 9"}, com, user)
    assert %{script: "result = 9"} = StatutoryConfig.effective_calc(com.id, "x", ~D[2026-06-30])
  end
end
```

(The two `...` lines above are the only permitted pattern-copies: they refer to concrete setup code that already exists in `test/full_circle/hr_test.exs`; copy it verbatim from there at implementation time.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/statutory_config_test.exs`
Expected: FAIL — `StatutoryConfig` undefined.

- [ ] **Step 3: Implement Cache, context, authorization clause**

```elixir
# lib/full_circle/statutory_config/cache.ex
defmodule FullCircle.StatutoryConfig.Cache do
  @moduledoc false
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  def fetch(key, fun) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = fun.()
        :ets.insert(@table, {key, value})
        value
    end
  end

  def invalidate(company_id) do
    :ets.match_delete(@table, {{company_id, :_, :_}, :_})
    :ok
  end
end
```

```elixir
# lib/full_circle/statutory_config.ex
defmodule FullCircle.StatutoryConfig do
  @moduledoc """
  Per-company, effective-dated statutory configuration: rate tables, PayScript
  calcs and file format specs. See docs/superpowers/specs/2026-07-02-statutory-zero-redeploy-design.md.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias FullCircle.{PayScript, Repo, Sys}
  alias FullCircle.HR.{StatutoryCalc, StatutoryFileFormat, StatutoryRateTable}
  alias FullCircle.StatutoryConfig.Cache

  @kinds %{table: StatutoryRateTable, calc: StatutoryCalc, file_format: StatutoryFileFormat}

  # -- resolution -------------------------------------------------------------

  def effective_calc(company_id, code, date), do: effective(:calc, company_id, code, date)
  def effective_table(company_id, code, date), do: effective(:table, company_id, code, date)
  def effective_file_format(company_id, code, date), do: effective(:file_format, company_id, code, date)

  defp effective(kind, company_id, code, date) do
    versions(kind, company_id, code)
    |> Enum.find(fn v -> Date.compare(v.effective_from, date) != :gt end)
  end

  # newest first, cached
  defp versions(kind, company_id, code) do
    Cache.fetch({company_id, kind, code}, fn ->
      schema = @kinds[kind]

      from(r in schema,
        where: r.company_id == ^company_id and r.code == ^code,
        order_by: [desc: r.effective_from]
      )
      |> Repo.all()
    end)
  end

  def list_versions(kind, company_id) do
    schema = @kinds[kind]

    from(r in schema, where: r.company_id == ^company_id, order_by: [asc: r.code, desc: r.effective_from])
    |> Repo.all()
  end

  def calc_codes(company_id) do
    from(c in StatutoryCalc, where: c.company_id == ^company_id, distinct: true, select: c.code)
    |> Repo.all()
  end

  def tables_map(company_id, date) do
    from(t in StatutoryRateTable, where: t.company_id == ^company_id, distinct: true, select: t.code)
    |> Repo.all()
    |> Map.new(fn code ->
      case effective_table(company_id, code, date) do
        nil -> {code, []}
        t -> {code, t.columns}
      end
    end)
  end

  # -- save (Phase 3 admin UI + bundle import call these) -----------------------

  def save_rate_table(attrs, company, user),
    do: save(:table, StatutoryRateTable.changeset(%StatutoryRateTable{}, put_company(attrs, company)), company, user)

  def save_file_format(attrs, company, user),
    do: save(:file_format, StatutoryFileFormat.changeset(%StatutoryFileFormat{}, put_company(attrs, company)), company, user)

  def save_calc(attrs, company, user) do
    cs = StatutoryCalc.changeset(%StatutoryCalc{}, put_company(attrs, company))
    cs = if cs.valid?, do: cross_validate_calc(cs, company), else: cs
    save(:calc, cs, company, user)
  end

  defp put_company(attrs, company) do
    attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("company_id", company.id)
  end

  defp cross_validate_calc(cs, company) do
    import Ecto.Changeset
    code = get_field(cs, :code)
    script = get_field(cs, :script)
    date = get_field(cs, :effective_from)

    schema = %{
      tables: tables_map(company.id, date),
      calcs: Enum.uniq(calc_codes(company.id) ++ [code])
    }

    cs =
      case PayScript.validate(script, schema) do
        :ok -> cs
        {:error, errors} -> Enum.reduce(errors, cs, &add_error(&2, :script, Exception.message(&1)))
      end

    sources =
      company.id
      |> calc_codes()
      |> Map.new(fn c ->
        {c, (effective_calc(company.id, c, date) || %{script: "result = 0"}).script}
      end)
      |> Map.put(code, script)

    case PayScript.check_cycles(sources) do
      :ok -> cs
      {:error, e} -> add_error(cs, :script, Exception.message(e))
    end
  end

  defp save(_kind, cs, company, user) do
    if FullCircle.Authorization.can?(user, :manage_statutory_config, company) do
      case Repo.insert(cs) do
        {:ok, record} ->
          Cache.invalidate(company.id)
          Sys.insert_log_for(record_multi_stub(record), user, company)
          {:ok, record}

        {:error, cs} ->
          {:error, cs}
      end
    else
      :not_authorise
    end
  end
end
```

**Logging note:** the `Sys.insert_log_for(record_multi_stub(record), ...)` line above is a placeholder for whatever the codebase's real audit-log call is — before implementing, read `lib/full_circle/std_interface.ex` `create/4` and copy its exact `Multi`+log pattern (wrap the insert in a `Multi` with `Sys.log_entry` like StdInterface does) instead of a bare `Repo.insert`. The test only asserts save/resolve behavior, so match StdInterface's mechanism precisely rather than inventing a new one.

Authorization clause to add in `lib/full_circle/authorization.ex`, next to the other admin-only clauses:

```elixir
  def can?(user, :manage_statutory_config, company),
    do: allow_roles(~w(admin), company, user)
```

Supervision: in `lib/full_circle/application.ex`, add `FullCircle.StatutoryConfig.Cache,` to the `children` list after the Repo entries.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/statutory_config_test.exs`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/statutory_config.ex lib/full_circle/statutory_config/cache.ex lib/full_circle/application.ex lib/full_circle/authorization.ex test/full_circle/statutory_config_test.exs
git commit -m "feat(statutory): config context with effective-date resolution and cache"
```

---

### Task 3: DbEnv and the calculation entry point

**Files:**
- Create: `lib/full_circle/statutory_config/db_env.ex`
- Modify: `lib/full_circle/statutory_config.ex` (add `calculate/3`, `script_context/2`)
- Test: `test/full_circle/statutory_config/db_env_test.exs`

**Interfaces:**
- Consumes: `PayScript.eval/3`, `PayScript.Env` behaviour, Task 2 resolution functions, `FullCircle.HR.SalaryNote`/`SalaryType` schemas.
- Produces:
  - `DbEnv` implements `FullCircle.PayScript.Env`. State: `%{company_id: id, date: %Date{}, context: %{String.t() => term}, employee_id: id, pay_month: int, pay_year: int}`.
    - `lookup/4`: `effective_table` → bracket `value > from and value <= to` on first two columns → named column; no row → `{:ok, 0.0}`; unknown table/column → `{:error, "unknown table 'x'"}` / `{:error, "unknown column 'c' in table 'x'"}`; **no table version effective** → `{:error, "no version of table 'x' effective on <date>"}`.
    - `ytd_sum/3`: sums `sn.quantity * sn.unit_price` over `salary_notes` joined to `salary_types` for `employee_id`, `extract(year from note_date) == pay_year`, `extract(month from note_date) < pay_month`, filtered by `st.statutory_code in keys` (`:code`) / `st.type in keys` (`:type`) / `st.name in keys` (`:name`) — same query shape as the legacy `y/x/z/k` functions in `salary_note_cal_func.ex`.
    - `calc/2`: `effective_calc` → `PayScript.eval(script, state.context, {DbEnv, state})` → Decimal → `{:ok, Decimal.to_float(dec)}`; nil → `{:error, "no version of calc 'x' effective on <date>"}`; eval error → pass through with `"in calc 'x': "` prefix. **No memoization** — inputs include changeset amounts that can change between recalculations; recomputation matches legacy behavior exactly (legacy PCB also recomputes EPF).
  - `StatutoryConfig.script_context(emp, cs) :: %{String.t() => term}` — exactly `PayScript.standard_variables()`, derived the same way legacy does: `wages`/`bonus` from `fetch_field!(cs, :addition_amount/:bonus_amount) |> Decimal.to_float()`, `age = Timex.end_of_month(pay_year, pay_month) |> Timex.diff(emp.dob, :years)`, `malaysian = emp.nationality |> String.trim() |> String.downcase() |> String.starts_with?("malays")`, `partner_working = emp.partner_working in ["true", "Yes"]`, `children = emp.children`, `service_years` from `emp.service_since` (0 if nil), `nationality`/`marital_status` passed through.
  - `StatutoryConfig.calculate(code, emp, cs) :: {:ok, Decimal.t()} | {:error, PayScript.Error.t()} | :not_found` — `:not_found` when the company has no version of `code` effective for the slip month (triggers legacy fallback in Task 6).

- [ ] **Step 1: Write the failing tests** — DataCase, non-async (DB). Seed a company + employee via fixtures (same setup as `test/full_circle/salary_note_cal_func_test.exs` — read it first and reuse its employee/pay-slip-changeset helpers; it already builds `cs` structs for `calculate_value/3`). Cover: `lookup` happy/boundary/no-row/no-version; `ytd_sum` by `:type`, `:name` list, `:code` with actual salary notes inserted; `calc` chain (`pcb`-style calc calling a constant calc); `calculate/3` returning `:not_found` for unseeded code; `calculate/3` error path (script `result = 1/0` seeded → `{:error, %Error{}}`).

- [ ] **Step 2: Run to verify failures**, **Step 3: implement** (code per the Interfaces block above — `DbEnv` is ~90 lines; `ytd_sum` copies the legacy query shape from `salary_note_cal_func.ex` `y/0`-style functions with the three filter variants), **Step 4: run tests to green**.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/statutory_config/db_env.ex lib/full_circle/statutory_config.ex test/full_circle/statutory_config/db_env_test.exs
git commit -m "feat(statutory): DB-backed PayScript env and calculate entry point"
```

---

### Task 4: Malaysia template bundle + generator + offline validator

**Files:**
- Modify: `lib/full_circle/salary_note_cal_func.ex` — change `defp socso_table`, `defp eis_table`, `defp pcb_table_normal` to `def` (3-line diff; no behavior change).
- Create: `lib/mix/tasks/statutory.gen_template.ex`
- Create: `priv/statutory_templates/malaysia.json` (generated by the task, then committed)
- Modify: `lib/full_circle/statutory_config.ex` (add `template_bundle/0`, `validate_bundle/1`, `export_bundle/2`, `import_bundle/3`)
- Create: `lib/mix/tasks/statutory.validate.ex`
- Test: `test/full_circle/statutory_config/bundle_test.exs`

**Interfaces:**
- Produces:
  - Bundle map shape (string keys, spec section 7): `%{"bundle_version" => 1, "source" => str, "rate_tables" => [%{"code","effective_from","columns","rows"}], "calcs" => [%{"code","name","effective_from","script"}], "file_formats" => [%{"code","name","effective_from","renderer","spec"}]}`.
  - `StatutoryConfig.template_bundle() :: map` — reads + decodes `priv/statutory_templates/malaysia.json` via `Application.app_dir(:full_circle, "priv/statutory_templates/malaysia.json")`.
  - `StatutoryConfig.validate_bundle(map) :: :ok | {:error, [String.t()]}` — checks bundle_version, every entry through its schema changeset (with a dummy company_id), scripts against the bundle's own tables+calc codes, `check_cycles` across bundle calcs. Pure — no DB.
  - `StatutoryConfig.import_bundle(map, company, user) :: {:ok, counts} | {:error, [String.t()]} | :not_authorise` — validate_bundle first, then upsert each entry (`on_conflict: {:replace_all_except, [:id, :inserted_at]}`, `conflict_target: [:company_id, :code, :effective_from]`), in one `Multi`, then `Cache.invalidate`.
  - `StatutoryConfig.export_bundle(company_id, date) :: map` — all versions? No: the **currently effective set** as of `date` (one entry per code per kind), matching spec section 7.
  - `mix statutory.validate <path.json>` — decodes and runs `validate_bundle/1`; prints "bundle OK" and exits 0, or prints each error and exits 1 (use `Mix.raise` for the failure exit).
  - `mix statutory.gen_template` — writes `priv/statutory_templates/malaysia.json` from the legacy tables + the reference scripts (below). Idempotent; run once at build time and whenever the reference scripts change.
- Template contents (the generator embeds these):
  - Tables (all effective `1957-01-01`): `socso` — columns `["wage_from","wage_to","employer","employee","employer_only","employee_24hour"]`, rows `SalaryNoteCalFunc.socso_table()`; `eis` — columns `["wage_from","wage_to","employer","employee","total"]`, rows `SalaryNoteCalFunc.eis_table()`; `pcb_normal` — columns `["p_from","p_to","m","r","b13","b2"]`, rows `SalaryNoteCalFunc.pcb_table_normal()`.
  - Constant calcs (effective `1957-01-01`): `epf_relief_cap = 4000`, `pcb_individual_deduction = 9000`, `pcb_spouse_deduction = 4000`, `pcb_child_deduction = 2000` (scripts like `result = 4000`).
  - Calc scripts: `epf_employer`, `epf_employee`, `socso_employee`, `socso_24hour` (effective `2026-06-01`!), `pcb_employee` — **exactly the reference scripts from Task 6 of the Phase 1 plan** (`@epf_employer_script` etc. in `test/full_circle/pay_script_acceptance_test.exs`); plus three more in the same style:
    - `socso_employer`: `result = if(age >= 60, lookup("socso", wages, "employer_only"), lookup("socso", wages, "employer"))`
    - `socso_employer_only`: `result = lookup("socso", wages, "employer_only")`
    - `eis_employer`: `result = if(age < 60 and malaysian, lookup("eis", wages, "employer"), 0)`
    - `eis_employee`: `result = if(age < 60 and malaysian, lookup("eis", wages, "employee"), 0)`
    - `eis_employer_only`: `result = lookup("eis", wages, "employer")` (reporting-only code today; seeded so the code remains valid for `SalaryType.statutory_code`)
  - `file_formats: []` in this phase (Phase 4 adds the five specs and regenerates).
- The generator keeps scripts as module attributes in the mix task — single source of truth for seeds; the Phase 1 acceptance test scripts must be updated to reference parity but MAY stay duplicated (they are tests pinning behavior; drift is caught by Task 6 parity).

- [ ] **Step 1: Write failing bundle tests** — round-trip (`import_bundle(template_bundle(), com, user)` then `export_bundle(com.id, ~D[2026-06-30])` re-exports every code), `validate_bundle` catches: bad script, unknown table ref, cycle, malformed row; import rejects what validate rejects; re-import (same effective dates) is idempotent (upsert, count unchanged); `mix statutory.validate` green/red paths via `Mix.Task.rerun("statutory.validate", [path])` on a tmp file.
- [ ] **Step 2: verify failures.**
- [ ] **Step 3: implement** — make legacy tables public, write generator task, run `mix statutory.gen_template`, implement bundle functions + validator task per Interfaces.
- [ ] **Step 4: run to green.** Also run `mix test test/full_circle/salary_note_cal_func_test.exs` — legacy tests unaffected by the `defp`→`def` change.
- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/salary_note_cal_func.ex lib/mix/tasks/ priv/statutory_templates/malaysia.json lib/full_circle/statutory_config.ex test/full_circle/statutory_config/bundle_test.exs
git commit -m "feat(statutory): malaysia template bundle, import/export and mix statutory.validate"
```

---

### Task 5: Seeding — data migration and new-company hook

**Files:**
- Modify: `lib/full_circle/statutory_config.ex` (add `seed_company!/1`)
- Create: `priv/repo/migrations/<timestamp>_seed_statutory_config.exs`
- Modify: `lib/full_circle/sys.ex` (`create_company/2` Multi)
- Test: extend `test/full_circle/statutory_config/bundle_test.exs`

**Interfaces:**
- `StatutoryConfig.seed_company!(company_id) :: :ok` — inserts the template bundle rows via `Repo.insert_all` per kind (timestamps truncated like the `create_default_accounts` pattern in `sys.ex`), `on_conflict: :nothing` on `[:company_id, :code, :effective_from]` so it is idempotent and never overwrites operator edits. No auth (system-level; callers are the migration and `create_company`).
- Data migration: `execute` nothing — instead use the migration module to iterate `from(c in "companies", select: c.id)` with `repo().all` and call... **No** — migrations must not call app code that may drift. Do it the standard safe way: the migration re-implements the insert with the JSON file read directly (`File.read!` + `Jason.decode!` + `execute`-free `repo().insert_all` on table-name strings with explicit maps, generating `Ecto.UUID` ids). Keep the migration self-contained.
- `Sys.create_company/2`: add after `:create_default_salary_types`:

```elixir
    |> Multi.run(:create_default_statutory_config, fn _repo, %{create_company: c} ->
      FullCircle.StatutoryConfig.seed_company!(c.id)
      {:ok, nil}
    end)
```

- [ ] **Step 1: failing tests** — `seed_company!` seeds all template codes and is idempotent; `Sys.create_company` (via `company_fixture`) leaves the new company with `calc_codes/1` returning the 14 template codes.
- [ ] **Step 2: verify failures. Step 3: implement. Step 4: `mix ecto.migrate` + tests green.** Also assert existing dev DB migration ran: `mix ecto.migrate` output shows the seed migration.
- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/statutory_config.ex priv/repo/migrations lib/full_circle/sys.ex test/full_circle/statutory_config/bundle_test.exs
git commit -m "feat(statutory): seed statutory config for existing and new companies"
```

---

### Task 6: Dispatch in calculate_pay + golden parity tests

**Files:**
- Modify: `lib/full_circle/pay_slip_op.ex` (`calculate_pay/2`)
- Test: `test/full_circle/statutory_parity_test.exs`

**Interfaces:**
- Consumes: `StatutoryConfig.calculate/3` (Task 3), seeded config (Task 5), legacy `SalaryNoteCalFunc.calculate_value/3`.
- Produces: in `calculate_pay/2`, the `if !is_nil(x.cal_func)` branch becomes:

```elixir
        if !is_nil(x.cal_func) do
          val =
            case FullCircle.StatutoryConfig.calculate(x.cal_func, emp, cs) do
              {:ok, dec} ->
                dec

              :not_found ->
                SalaryNoteCalFunc.calculate_value(legacy_cal_func!(x.cal_func), emp, cs)

              {:error, e} ->
                raise e
            end
          ...unchanged changeset_on_payslip call...
```

with a fixed literal map (no atom creation from data):

```elixir
  @legacy_cal_funcs %{
    "epf_employer" => :epf_employer,
    "epf_employee" => :epf_employee,
    "socso_employer" => :socso_employer,
    "socso_employee" => :socso_employee,
    "socso_employer_only" => :socso_employer_only,
    "socso_24hour" => :socso_24hour,
    "eis_employer" => :eis_employer,
    "eis_employee" => :eis_employee,
    "pcb_employee" => :pcb_employee
  }

  defp legacy_cal_func!(code), do: Map.fetch!(@legacy_cal_funcs, code)
```

(`Map.fetch!` raising on a truly unknown code is correct — it is a config error and must not be silent. `raise e` on `{:error, e}` surfaces script runtime errors; Phase 3 catches this in the form and renders `Exception.message(e)`.)

- Golden parity tests (`use FullCircle.DataCase`, seeded company via `seed_company!`, employee + changeset built with the **same helpers as `test/full_circle/salary_note_cal_func_test.exs`** — read that file first and reuse its builders):
  - Grid over codes `epf_employer epf_employee socso_employer socso_employee socso_employer_only socso_24hour eis_employer eis_employee`:
    wages ∈ {10.0, 29.5, 30.0, 2950.0, 3000.0, 4999.0, 5000.0, 5001.0, 5999.0, 6000.0, 8000.0} × age ∈ {35, 59, 60, 61} × malaysian ∈ {true, false} × bonus ∈ {0.0, 500.0} — assert `Decimal.equal?(payscript_result, legacy_result)` for every cell (`StatutoryConfig.calculate/3` vs `SalaryNoteCalFunc.calculate_value/3`).
  - PCB: insert prior-months salary notes (the YTD fixtures pattern from `salary_note_cal_func_test.exs`), then assert equality for: mid-year married/2-children case, single case, December (`pay_month = 12`), and the EPF-cap-saturated case (YTD EPF ≥ 4000).
  - Effective-date test: a company with `socso_24hour` calc effective 2026-06-01 → `calculate/3` for a May 2026 slip returns `:not_found` (falls back to legacy), for June returns `{:ok, _}` equal to legacy.
  - Fallback test: delete the company's `epf_employee` calc rows → `calculate_pay` output for the slip is unchanged (legacy path).

- [ ] **Step 1: write the parity tests (failing only because dispatch not wired / or green-on-arrival for pure-calc comparisons — either is fine; the dispatch test must fail first).**
- [ ] **Step 2: verify. Step 3: implement dispatch. Step 4: run parity file + `mix test test/full_circle/pay_slip_op_test.exs test/full_circle/salary_note_cal_func_test.exs test/full_circle/pay_run_test.exs`** — expected: all green except the 2 known pre-existing `pay_run_test` failures (compare against a pre-change run to confirm no new failures).

If any parity cell disagrees: the seeded script or DbEnv is wrong, never the legacy oracle — use superpowers:systematic-debugging.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_slip_op.ex test/full_circle/statutory_parity_test.exs
git commit -m "feat(statutory): dispatch pay slip calcs through statutory config with legacy fallback"
```

---

## Out of scope (later phases)

- Admin LiveViews, bundle import/export UI, preview panels — Phase 3.
- `SalaryType.statutory_code` validation switch and dynamic reporting columns — Phase 3.
- FileSpec renderer, the five file-format specs, deleting `SalaryNoteCalFunc` and `hr/statutory/*_format.ex` — Phase 4.
