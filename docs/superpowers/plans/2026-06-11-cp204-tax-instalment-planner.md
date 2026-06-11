# CP204 Tax Instalment Planner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-company-per-financial-year CP204 instalment planner: derive a safe CP204 estimate from the P&L forecast's estimated annual tax, spread it into monthly instalments, record tax paid (GL-prefilled), and re-spread the balance when the estimate is revised at any month.

**Architecture:** New `FullCircle.Tax` context + `tax_instalment_plans` table (`paid_overrides` as a JSON `:map`, matching the project's `company.settings` idiom — there is no `embeds_many` anywhere in this codebase). Pure computation functions (suggested estimate, schedule re-spread, under-estimation check) are split from DB/integration functions (GL paid sums, forecast tax). A single LiveView editor page reuses the existing `tributeAutoComplete` account picker and the `ProfitLossForecast` forecast.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, Decimal, ExUnit.

---

## File Structure

- **Create** `priv/repo/migrations/<timestamp>_create_tax_instalment_plans.exs` — table + unique index.
- **Create** `lib/full_circle/tax/instalment_plan.ex` — `FullCircle.Tax.InstalmentPlan` schema + changeset.
- **Create** `lib/full_circle/tax.ex` — `FullCircle.Tax` context: CRUD + computation.
- **Modify** `lib/full_circle/reporting/profit_loss_forecast.ex` — expose public `fy_month_bounds/2`.
- **Create** `lib/full_circle_web/live/tax_live/instalment_plan.ex` — `FullCircleWeb.TaxLive.InstalmentPlan` LiveView.
- **Modify** `lib/full_circle_web/router.ex` — add the route.
- **Modify** `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` — admin-gated menu link.
- **Create** `test/full_circle/tax_test.exs` — context + computation tests.
- **Create** `test/full_circle_web/live/tax_instalment_plan_live_test.exs` — LiveView test.

---

## Task 1: Migration + `InstalmentPlan` schema

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_tax_instalment_plans.exs`
- Create: `lib/full_circle/tax/instalment_plan.ex`
- Test: `test/full_circle/tax_test.exs`

- [ ] **Step 1: Create the migration**

Generate a timestamped file (use the current UTC timestamp in `YYYYMMDDHHMMSS` form, e.g. run `date -u +%Y%m%d%H%M%S`):

`priv/repo/migrations/<timestamp>_create_tax_instalment_plans.exs`:
```elixir
defmodule FullCircle.Repo.Migrations.CreateTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    create table(:tax_instalment_plans) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :tax_paid_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :fy_year, :integer, null: false
      add :tolerance_pct, :decimal, null: false, default: 30
      add :estimate, :decimal, null: false, default: 0
      add :estimate_month, :integer, null: false, default: 1
      add :paid_overrides, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tax_instalment_plans, [:company_id, :fy_year],
             name: :tax_instalment_plans_unique_period
           )
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: creates `tax_instalment_plans`. (If it fails, fix before continuing.)

- [ ] **Step 3: Write the failing changeset test**

`test/full_circle/tax_test.exs`:
```elixir
defmodule FullCircle.TaxSchemaTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.InstalmentPlan

  defp chg(attrs), do: InstalmentPlan.changeset(%InstalmentPlan{}, attrs)

  describe "changeset/2" do
    test "requires company_id and fy_year" do
      refute chg(%{}).valid?
      cs = chg(%{})
      assert %{company_id: _, fy_year: _} = Ecto.Changeset.traverse_errors(cs, & &1)
    end

    test "valid with the minimum fields; defaults applied on struct" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026})
      assert cs.valid?
    end

    test "rejects negative tolerance and out-of-range estimate_month" do
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, tolerance_pct: -1}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, estimate_month: 0}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, estimate_month: 13}).valid?
    end

    test "accepts a paid_overrides map" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, paid_overrides: %{"3" => "100.00"}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :paid_overrides) == %{"3" => "100.00"}
    end
  end
end
```

- [ ] **Step 4: Run it to confirm it fails**

Run: `mix test test/full_circle/tax_test.exs`
Expected: FAIL — `FullCircle.Tax.InstalmentPlan` is undefined.

- [ ] **Step 5: Create the schema**

`lib/full_circle/tax/instalment_plan.ex`:
```elixir
defmodule FullCircle.Tax.InstalmentPlan do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "tax_instalment_plans" do
    field(:fy_year, :integer)
    field(:tolerance_pct, :decimal, default: Decimal.new(30))
    field(:estimate, :decimal, default: Decimal.new(0))
    field(:estimate_month, :integer, default: 1)
    field(:paid_overrides, :map, default: %{})

    # virtual: account picked via autocomplete (name -> tax_paid_account_id)
    field(:tax_paid_account_name, :string, virtual: true)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:tax_paid_account, FullCircle.Accounting.Account)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :fy_year,
      :tolerance_pct,
      :estimate,
      :estimate_month,
      :paid_overrides,
      :tax_paid_account_name,
      :company_id,
      :tax_paid_account_id
    ])
    |> validate_required([:company_id, :fy_year])
    |> validate_number(:tolerance_pct, greater_than_or_equal_to: 0)
    |> validate_number(:estimate, greater_than_or_equal_to: 0)
    |> validate_inclusion(:estimate_month, 1..12)
    |> unique_constraint([:company_id, :fy_year],
      name: :tax_instalment_plans_unique_period,
      message: "already exists"
    )
  end
end
```

- [ ] **Step 6: Run the test to confirm it passes**

Run: `mix test test/full_circle/tax_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/full_circle/tax/instalment_plan.ex test/full_circle/tax_test.exs
git commit -m "feat: tax_instalment_plans schema + migration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Expose `fy_month_bounds/2` in `ProfitLossForecast`

**Files:**
- Modify: `lib/full_circle/reporting/profit_loss_forecast.ex`
- Test: `test/full_circle/reporting/profit_loss_forecast_test.exs`

The planner needs the 12 closing-day-anchored monthly `{start, end}` tuples for a FY. `ProfitLossForecast` already computes these privately (`period_bounds/3` with `period_months = 1`, anchored on `prev_close/2`). Expose a thin public wrapper so the planner reuses the exact same FY math instead of duplicating it.

- [ ] **Step 1: Write the failing test**

Add to the pure module `FullCircle.Reporting.ProfitLossForecastTest` in `test/full_circle/reporting/profit_loss_forecast_test.exs`:
```elixir
  describe "fy_month_bounds/2" do
    test "returns 12 calendar months for a 31-Dec closing company" do
      com = %{closing_month: 12, closing_day: 31}
      bounds = PLF.fy_month_bounds(com, 2026)
      assert length(bounds) == 12
      assert hd(bounds) == {~D[2026-01-01], ~D[2026-01-31]}
      assert List.last(bounds) == {~D[2026-12-01], ~D[2026-12-31]}
    end

    test "anchors on a non-calendar closing day" do
      com = %{closing_month: 6, closing_day: 30}
      bounds = PLF.fy_month_bounds(com, 2026)
      # FY ends 2026-06-30, so it starts 2025-07-01
      assert hd(bounds) == {~D[2025-07-01], ~D[2025-07-31]}
      assert List.last(bounds) == {~D[2026-06-01], ~D[2026-06-30]}
    end
  end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs`
Expected: FAIL — `fy_month_bounds/2` undefined.

- [ ] **Step 3: Add the public wrapper**

In `lib/full_circle/reporting/profit_loss_forecast.ex`, add (near `prev_close/2`, which is already public):
```elixir
  @doc """
  The 12 closing-day-anchored monthly `{start_date, end_date}` tuples for the
  financial year ending in `fy_year`. Same boundaries the forecast uses.
  """
  def fy_month_bounds(com, fy_year) do
    period_bounds(prev_close(com, fy_year), 1, 12)
  end
```
(`period_bounds/3`, `add_months/2`, `clamp_date/3` already exist as private helpers in this module — no change needed to them.)

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/profit_loss_forecast.ex test/full_circle/reporting/profit_loss_forecast_test.exs
git commit -m "feat: expose ProfitLossForecast.fy_month_bounds/2 for reuse

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Pure computation in `FullCircle.Tax`

**Files:**
- Create: `lib/full_circle/tax.ex`
- Test: `test/full_circle/tax_test.exs` (add a new module)

Implement the pure, DB-free core. DB/integration functions come in Task 4.

- [ ] **Step 1: Write failing unit tests**

Append a new module to `test/full_circle/tax_test.exs`:
```elixir
defmodule FullCircle.TaxComputeTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax

  defp d(n), do: Decimal.new("#{n}")

  describe "suggested_estimate/2" do
    test "reduces by the tolerance" do
      assert Decimal.equal?(Tax.suggested_estimate(d(130000), d(30)), d(100000))
    end

    test "tolerance 0 returns the forecast unchanged" do
      assert Decimal.equal?(Tax.suggested_estimate(d(50000), d(0)), d(50000))
    end

    test "non-positive forecast returns 0" do
      assert Decimal.equal?(Tax.suggested_estimate(d(0), d(30)), d(0))
      assert Decimal.equal?(Tax.suggested_estimate(d(-100), d(30)), d(0))
    end
  end

  describe "under_estimated?/3" do
    test "true below the floor, false at/above it" do
      # floor = 130000/1.3 = 100000
      assert Tax.under_estimated?(d(99999), d(130000), d(30))
      refute Tax.under_estimated?(d(100000), d(130000), d(30))
      refute Tax.under_estimated?(d(120000), d(130000), d(30))
    end
  end

  describe "build_schedule/4" do
    # 12 monthly bounds for a 31-Dec FY (only dates matter for labels here)
    defp bounds do
      for m <- 1..12, do: {Date.new!(2026, m, 1), Date.new!(2026, m, Date.days_in_month(Date.new!(2026, m, 1)))}
    end

    test "spreads estimate evenly from month 1 with no paid" do
      rows = Tax.build_schedule(bounds(), %{}, d(120000), 1)
      assert length(rows) == 12
      assert Enum.all?(rows, &Decimal.equal?(&1.instalment_due, d(10000)))
      # no paid -> balance = estimate - cumulative_paid(0) = estimate, every month
      assert Decimal.equal?(hd(rows).balance, d(120000))
      assert Decimal.equal?(List.last(rows).balance, d(120000))
    end

    test "re-spreads remaining balance from estimate_month over remaining months" do
      # paid 10000 in each of months 1..3 (before estimate_month 4), estimate revised to 120000 at month 4
      paid = %{1 => d(10000), 2 => d(10000), 3 => d(10000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 4)
      # paid_to_date = 30000; remaining = 9; forward = (120000-30000)/9 = 10000
      assert Decimal.equal?(Enum.at(rows, 0).instalment_due, d(0))   # month 1 < estimate_month
      assert Decimal.equal?(Enum.at(rows, 3).instalment_due, d(10000)) # month 4
      assert Decimal.equal?(Enum.at(rows, 11).instalment_due, d(10000))
    end

    test "forward instalment floored at 0 when already over-paid" do
      paid = %{1 => d(200000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 2)
      assert Decimal.equal?(Enum.at(rows, 1).instalment_due, d(0))
    end

    test "estimate 0 -> all due 0" do
      rows = Tax.build_schedule(bounds(), %{}, d(0), 1)
      assert Enum.all?(rows, &Decimal.equal?(&1.instalment_due, d(0)))
    end
  end

  describe "current_fy_month/3" do
    test "maps a date to its FY month index, clamped to 1..12" do
      com = %{closing_month: 12, closing_day: 31}
      assert Tax.current_fy_month(com, 2026, ~D[2026-01-15]) == 1
      assert Tax.current_fy_month(com, 2026, ~D[2026-07-10]) == 7
      assert Tax.current_fy_month(com, 2026, ~D[2025-01-01]) == 1   # before FY -> 1
      assert Tax.current_fy_month(com, 2026, ~D[2027-05-01]) == 12  # after FY -> 12
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mix test test/full_circle/tax_test.exs`
Expected: FAIL — `FullCircle.Tax` undefined.

- [ ] **Step 3: Create `lib/full_circle/tax.ex` with the pure core**

```elixir
defmodule FullCircle.Tax do
  @moduledoc """
  CP204 income-tax instalment planning. Pure computation (estimate, schedule
  re-spread, under-estimation check) plus DB/integration helpers that pull the
  forecast tax and GL-paid amounts. A planning aid, not a filed tax computation.
  """

  import Ecto.Query, warn: false
  alias FullCircle.Repo
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Tax.InstalmentPlan
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  # ---- pure computation ----

  @doc "Safe minimum CP204 estimate = forecast_tax / (1 + tolerance/100). 0 when forecast <= 0."
  def suggested_estimate(forecast_tax, tolerance_pct) do
    if Decimal.compare(forecast_tax, @zero) != :gt do
      @zero
    else
      divisor = Decimal.add(@hundred, tolerance_pct)
      Decimal.div(Decimal.mult(forecast_tax, @hundred), divisor)
    end
  end

  @doc "True when the chosen estimate is below the penalty-free floor (= suggested_estimate)."
  def under_estimated?(estimate, forecast_tax, tolerance_pct) do
    Decimal.compare(estimate, suggested_estimate(forecast_tax, tolerance_pct)) == :lt
  end

  @doc """
  Build the 12-month instalment schedule. `month_bounds` is the list of 12
  `{start, end}` tuples; `paid_by_month` is `%{month_no => Decimal}`. The whole
  schedule reflects only the current `estimate`, re-spread from `estimate_month`.
  """
  def build_schedule(month_bounds, paid_by_month, estimate, estimate_month) do
    paid_to_date =
      Enum.reduce(1..(estimate_month - 1)//1, @zero, fn m, acc ->
        Decimal.add(acc, Map.get(paid_by_month, m, @zero))
      end)

    remaining = 12 - estimate_month + 1
    forward = Decimal.div(max_zero(Decimal.sub(estimate, paid_to_date)), Decimal.new(remaining))

    {rows, _cum_paid} =
      month_bounds
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {{ps, pe}, m}, cum_paid ->
        due = if m >= estimate_month, do: forward, else: @zero
        paid = Map.get(paid_by_month, m, @zero)
        cum_paid2 = Decimal.add(cum_paid, paid)

        row = %{
          month_no: m,
          period_start: ps,
          period_end: pe,
          instalment_due: due,
          paid: paid,
          balance: Decimal.sub(estimate, cum_paid2)
        }

        {row, cum_paid2}
      end)

    rows
  end

  @doc "FY month index (1..12) containing `as_of`, clamped to the range."
  def current_fy_month(com, fy_year, as_of) do
    bounds = PLF.fy_month_bounds(com, fy_year)

    cond do
      Date.compare(as_of, elem(hd(bounds), 0)) == :lt -> 1
      Date.compare(as_of, elem(List.last(bounds), 1)) == :gt -> 12
      true ->
        bounds
        |> Enum.with_index(1)
        |> Enum.find_value(1, fn {{ps, pe}, m} ->
          if Date.compare(as_of, ps) != :lt and Date.compare(as_of, pe) != :gt, do: m
        end)
    end
  end

  defp max_zero(d), do: if(Decimal.compare(d, @zero) == :lt, do: @zero, else: d)
end
```
NOTE: the `1..(estimate_month - 1)//1` range is empty when `estimate_month == 1` (correct: no prior months). Keep the explicit `//1` step so the range is well-formed.

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/full_circle/tax_test.exs`
Expected: PASS (both the schema module from Task 1 and this compute module).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax.ex test/full_circle/tax_test.exs
git commit -m "feat: FullCircle.Tax pure CP204 estimate/schedule computation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `FullCircle.Tax` DB/integration functions

**Files:**
- Modify: `lib/full_circle/tax.ex`
- Test: `test/full_circle/tax_test.exs` (add a DataCase module)

Add: `forecast_annual_tax/3`, `paid_by_month/2`, `schedule/3` (wires forecast/paid into the pure core), `get_plan/2`, `create_or_update_plan/3`.

- [ ] **Step 1: Write failing DB tests**

Append a DataCase module to `test/full_circle/tax_test.exs`. Mirror the fixtures used in `test/full_circle/reporting/profit_loss_forecast_test.exs` (`FullCircle.SysFixtures`, `UserAccountsFixtures`, `AccountingFixtures`, the `company_fixture(admin, %{closing_month: 12, closing_day: 31})` + `account_fixture` + a `txn!` helper). Read that file to copy the exact fixture/helper shapes.
```elixir
defmodule FullCircle.TaxDBTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Tax
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  defp d(n), do: Decimal.new("#{n}")

  defp txn!(com, account_id, date, amount) do
    %Transaction{}
    |> Transaction.changeset(%{
      doc_type: "Journal", doc_no: "J#{System.unique_integer([:positive])}",
      doc_date: date, particulars: "t", amount: amount,
      company_id: com.id, account_id: account_id
    })
    |> Repo.insert!()
  end

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{closing_month: 12, closing_day: 31})
    tax_acc = account_fixture(%{account_type: "Asset", name: "Tax Paid #{System.unique_integer([:positive])}"}, com, admin)
    %{admin: admin, com: com, tax_acc: tax_acc}
  end

  describe "create_or_update_plan/3 and get_plan/2" do
    test "creates then updates the singleton per (company, fy)", %{com: com, admin: admin} do
      assert is_nil(Tax.get_plan(com, 2026))
      {:ok, plan} = Tax.create_or_update_plan(%{"fy_year" => 2026, "tolerance_pct" => "30", "estimate" => "100000", "estimate_month" => 1}, com, admin)
      assert plan.fy_year == 2026

      {:ok, plan2} = Tax.create_or_update_plan(%{"fy_year" => 2026, "estimate" => "120000"}, com, admin)
      assert plan2.id == plan.id
      assert Decimal.equal?(plan2.estimate, d(120000))
      assert Tax.get_plan(com, 2026).id == plan.id
    end
  end

  describe "paid_by_month/2" do
    test "sums GL postings into FY months and applies overrides", %{com: com, admin: admin, tax_acc: tax_acc} do
      txn!(com, tax_acc.id, ~D[2026-02-10], 5000)
      txn!(com, tax_acc.id, ~D[2026-02-20], 3000)
      txn!(com, tax_acc.id, ~D[2026-05-01], 4000)

      {:ok, plan} =
        Tax.create_or_update_plan(
          %{"fy_year" => 2026, "tax_paid_account_id" => tax_acc.id, "paid_overrides" => %{"5" => "9999"}},
          com, admin
        )

      pm = Tax.paid_by_month(plan, com)
      assert Decimal.equal?(Map.get(pm, 2), d(8000))   # 5000 + 3000
      assert Decimal.equal?(Map.get(pm, 5), d(9999))   # override beats GL 4000
      assert Decimal.equal?(Map.get(pm, 1, d(0)), d(0))
    end

    test "no account -> zeros plus overrides only", %{com: com, admin: admin} do
      {:ok, plan} = Tax.create_or_update_plan(%{"fy_year" => 2026, "paid_overrides" => %{"3" => "100"}}, com, admin)
      pm = Tax.paid_by_month(plan, com)
      assert Decimal.equal?(Map.get(pm, 3), d(100))
      assert Decimal.equal?(Map.get(pm, 1, d(0)), d(0))
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mix test test/full_circle/tax_test.exs`
Expected: FAIL — `get_plan/2`, `create_or_update_plan/3`, `paid_by_month/2` undefined.

- [ ] **Step 3: Add the DB/integration functions to `lib/full_circle/tax.ex`**

Add inside the module (after the pure section):
```elixir
  # ---- DB / integration ----

  @doc "The forecast's estimated annual tax for the FY, as of `as_of`."
  def forecast_annual_tax(com, fy_year, as_of) do
    PLF.pl_forecast(%{fy_year: fy_year, granularity: :monthly, as_of: as_of}, com).totals.estimated_tax
  end

  @doc "`%{month_no => Decimal}` paid amounts: GL sum per FY month for the nominated account, overridden by `paid_overrides`."
  def paid_by_month(%InstalmentPlan{} = plan, com) do
    bounds = PLF.fy_month_bounds(com, plan.fy_year)
    gl = gl_paid_by_month(plan.tax_paid_account_id, bounds, com)

    overrides =
      for {k, v} <- plan.paid_overrides || %{}, into: %{} do
        {to_int(k), to_decimal(v)}
      end

    Map.merge(gl, overrides)
  end

  @doc "Full schedule for the plan: pure `build_schedule/4` fed with forecast/GL data."
  def schedule(%InstalmentPlan{} = plan, com) do
    bounds = PLF.fy_month_bounds(com, plan.fy_year)
    build_schedule(bounds, paid_by_month(plan, com), plan.estimate || @zero, plan.estimate_month || 1)
  end

  def get_plan(com, fy_year) do
    Repo.one(from p in InstalmentPlan, where: p.company_id == ^com.id and p.fy_year == ^fy_year)
  end

  @doc "Create or update the (company, fy_year) singleton plan."
  def create_or_update_plan(attrs, com, _user) do
    fy_year = attrs["fy_year"] || attrs[:fy_year]
    plan = get_plan(com, fy_year) || %InstalmentPlan{}
    attrs = Map.put(attrs, "company_id", com.id)

    plan
    |> InstalmentPlan.changeset(attrs)
    |> Repo.insert_or_update()
  end

  # bucket GL postings to `account_id` into FY months by which bound contains the doc_date
  defp gl_paid_by_month(nil, _bounds, _com), do: %{}

  defp gl_paid_by_month(account_id, bounds, com) do
    fy_start = elem(hd(bounds), 0)
    fy_end = elem(List.last(bounds), 1)

    txns =
      from(t in Transaction,
        where:
          t.company_id == ^com.id and t.account_id == ^account_id and
            t.doc_date >= ^fy_start and t.doc_date <= ^fy_end,
        select: %{date: t.doc_date, amount: t.amount}
      )
      |> Repo.all()

    indexed = Enum.with_index(bounds, 1)

    Enum.reduce(txns, %{}, fn %{date: dt, amount: amt}, acc ->
      case Enum.find(indexed, fn {{ps, pe}, _m} ->
             Date.compare(dt, ps) != :lt and Date.compare(dt, pe) != :gt
           end) do
        {_b, m} -> Map.update(acc, m, to_decimal(amt), &Decimal.add(&1, to_decimal(amt)))
        nil -> acc
      end
    end)
  end

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
```
NOTE on sign: `gl_paid_by_month` sums the raw posted `Transaction.amount`. Instalments are debits to a debit-normal tax-paid account, so they sum to positive paid amounts. Document this assumption in the LiveView help text (Task 5).

- [ ] **Step 4: Run to confirm pass**

Run: `mix test test/full_circle/tax_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax.ex test/full_circle/tax_test.exs
git commit -m "feat: FullCircle.Tax CRUD + GL paid + forecast integration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: LiveView page + route + menu link

**Files:**
- Create: `lib/full_circle_web/live/tax_live/instalment_plan.ex`
- Modify: `lib/full_circle_web/router.ex`
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`
- Test: `test/full_circle_web/live/tax_instalment_plan_live_test.exs`

- [ ] **Step 1: Add the route**

In `lib/full_circle_web/router.ex`, next to the forecast routes (after the `live("/profit_loss_forecast", ...)` line ~228):
```elixir
      live("/tax_instalment_plan", TaxLive.InstalmentPlan, :index)
```

- [ ] **Step 2: Add the admin-gated menu link**

In `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, right after the `profit_loss_forecast` link (the `:if={@current_role == "admin"}` one), add:
```elixir
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/tax_instalment_plan"}
          class="button red"
        >
          {gettext("Tax Instalment Plan")}
        </.link>
```

- [ ] **Step 3: Write the failing LiveView test**

Read `test/full_circle_web/live/profit_loss_forecast_live_test.exs` first to mirror its setup (login, company assign, route helper). Then create `test/full_circle_web/live/tax_instalment_plan_live_test.exs`:
```elixir
defmodule FullCircleWeb.TaxLive.InstalmentPlanTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  # mirror the helpers/imports used by profit_loss_forecast_live_test.exs

  # setup: log in an admin user with an active company (copy from the forecast live test)

  test "renders the planner and recomputes on revise", %{conn: conn, company: com} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/tax_instalment_plan")
    assert html =~ "Tax Instalment Plan"
    assert html =~ "Estimated annual tax" or html =~ "Suggested"

    # set a tolerance + tax rate is 0 by default so forecast tax may be 0; just assert the page is interactive
    assert render(lv) =~ "Instalment"
  end
end
```
ADAPT the setup block to the real `ConnCase`/login helpers this project uses (copy from the forecast live test). The assertions can be loosened to whatever stable text the page renders; the goal is that the route mounts, auto-initialises a plan, and renders the schedule table without crashing.

- [ ] **Step 4: Run to confirm failure**

Run: `mix test test/full_circle_web/live/tax_instalment_plan_live_test.exs`
Expected: FAIL — module/route not found.

- [ ] **Step 5: Implement the LiveView**

`lib/full_circle_web/live/tax_live/instalment_plan.ex`:
```elixir
defmodule FullCircleWeb.TaxLive.InstalmentPlan do
  use FullCircleWeb, :live_view
  alias FullCircle.Tax
  alias FullCircle.Tax.InstalmentPlan
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Tax Instalment Plan"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    com = socket.assigns.current_company
    today = Date.utc_today()
    fy_year = safe_int(params["fy_year"], default_fy_year(com))

    as_of =
      case Date.from_iso8601(to_string(params["as_of"])) do
        {:ok, d} -> d
        _ -> today
      end

    {:noreply, socket |> assign(fy_year: fy_year, as_of: as_of) |> load(com, fy_year, as_of)}
  end

  defp load(socket, com, fy_year, as_of) do
    plan = Tax.get_plan(com, fy_year) || %InstalmentPlan{fy_year: fy_year, estimate_month: Tax.current_fy_month(com, fy_year, as_of)}
    forecast_tax = Tax.forecast_annual_tax(com, fy_year, as_of)
    suggested = Tax.suggested_estimate(forecast_tax, plan.tolerance_pct || Decimal.new(30))
    estimate = if Decimal.compare(plan.estimate || Decimal.new(0), Decimal.new(0)) == :gt, do: plan.estimate, else: suggested
    plan = %{plan | estimate: estimate}

    assign(socket,
      plan: plan,
      forecast_tax: forecast_tax,
      suggested: suggested,
      schedule: schedule_for(plan, com),
      under: Tax.under_estimated?(estimate, forecast_tax, plan.tolerance_pct || Decimal.new(30)),
      account_name: (plan.tax_paid_account_id && account_name(plan, com)) || ""
    )
  end

  defp schedule_for(%InstalmentPlan{id: nil} = plan, com), do: Tax.build_schedule(PLF.fy_month_bounds(com, plan.fy_year), %{}, plan.estimate, plan.estimate_month || 1)
  defp schedule_for(plan, com), do: Tax.schedule(plan, com)

  defp account_name(plan, _com) do
    case FullCircle.Repo.get(FullCircle.Accounting.Account, plan.tax_paid_account_id) do
      nil -> ""
      acc -> acc.name
    end
  end

  @impl true
  def handle_event("query", %{"fy_year" => fy, "as_of" => as_of}, socket) do
    {:noreply,
     push_navigate(socket,
       to: "/companies/#{socket.assigns.current_company.id}/tax_instalment_plan?#{URI.encode_query(%{fy_year: fy, as_of: as_of})}"
     )}
  end

  # resolve the account autocomplete name -> id
  @impl true
  def handle_event("validate", %{"_target" => ["plan", "tax_paid_account_name"], "plan" => params}, socket) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket, params, "tax_paid_account_name", "tax_paid_account_id",
        &FullCircle.Accounting.get_account_by_name/3
      )

    {:noreply, assign(socket, pending: params)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("revise", _params, socket) do
    com = socket.assigns.current_company
    fy = socket.assigns.fy_year
    as_of = socket.assigns.as_of
    forecast_tax = Tax.forecast_annual_tax(com, fy, as_of)
    plan = socket.assigns.plan
    suggested = Tax.suggested_estimate(forecast_tax, plan.tolerance_pct || Decimal.new(30))

    {:noreply,
     save_plan(socket, %{
       "fy_year" => fy,
       "estimate" => Decimal.to_string(suggested),
       "estimate_month" => Tax.current_fy_month(com, fy, as_of),
       "tolerance_pct" => Decimal.to_string(plan.tolerance_pct || Decimal.new(30)),
       "tax_paid_account_id" => plan.tax_paid_account_id,
       "paid_overrides" => plan.paid_overrides || %{}
     })}
  end

  @impl true
  def handle_event("save", %{"plan" => params}, socket) do
    {:noreply, save_plan(socket, params)}
  end

  defp save_plan(socket, params) do
    com = socket.assigns.current_company

    case Tax.create_or_update_plan(params, com, socket.assigns.current_user) do
      {:ok, _plan} -> load(socket, com, socket.assigns.fy_year, socket.assigns.as_of)
      {:error, _cs} -> put_flash(socket, :error, gettext("Could not save plan."))
    end
  end

  defp default_fy_year(com) do
    today = Date.utc_today()
    fy_end_this = PLF.prev_close(com, today.year + 1)
    if Date.compare(today, fy_end_this) != :gt, do: today.year, else: today.year + 1
  end

  defp safe_int(s, default) do
    case Integer.parse(to_string(s)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp money(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp money(other), do: to_string(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full px-4 mx-auto mb-10">
      <p class="text-2xl text-center font-medium">{@page_title}</p>

      <div class="border rounded bg-amber-200 dark:bg-amber-900 dark:border-amber-700 p-2 w-10/12 mx-auto">
        <.form for={%{}} id="query-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2">
            <div class="col-span-2">
              <.input label={gettext("For The Year")} name="fy_year" type="number" value={@fy_year} />
            </div>
            <div class="col-span-2">
              <.input label={gettext("As Of")} name="as_of" type="date" value={Date.to_iso8601(@as_of)} />
            </div>
            <div class="col-span-2 mt-6">
              <.button>{gettext("Query")}</.button>
            </div>
          </div>
        </.form>
        <p class="text-sm text-gray-600 dark:text-gray-300 mt-2">
          {gettext("A CP204 planning aid built on the P&L forecast's estimated tax (an accounting-profit proxy, not a filed tax computation). 'Tax paid' sums postings to the nominated account.")}
        </p>
      </div>

      <.form for={%{}} id="plan-form" phx-change="validate" phx-submit="save" autocomplete="off" class="w-10/12 mx-auto mt-3">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3 items-end">
          <div>
            <label class="text-sm">{gettext("Forecast annual tax")}</label>
            <p class="font-mono font-semibold">{money(@forecast_tax)}</p>
          </div>
          <div>
            <label class="text-sm">{gettext("Suggested estimate")}</label>
            <p class="font-mono">{money(@suggested)}</p>
          </div>
          <div>
            <.input name="plan[tolerance_pct]" type="number" step="0.01" min="0"
              label={gettext("Tolerance %")} value={Decimal.to_string(@plan.tolerance_pct || Decimal.new(30))} />
          </div>
          <div>
            <.input name="plan[estimate]" type="number" step="0.01" min="0"
              label={gettext("Chosen estimate")} value={Decimal.to_string(@plan.estimate || Decimal.new(0))} />
          </div>
          <div class="col-span-2">
            <input type="hidden" name="plan[tax_paid_account_id]" value={@plan.tax_paid_account_id} />
            <.input name="plan[tax_paid_account_name]" label={gettext("Tax paid account")}
              value={@account_name} phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="} />
          </div>
          <input type="hidden" name="plan[fy_year]" value={@fy_year} />
          <input type="hidden" name="plan[estimate_month]" value={@plan.estimate_month || 1} />
          <div class="flex gap-2">
            <.button class="blue button">{gettext("Save")}</.button>
            <button type="button" phx-click="revise" class="gray button">{gettext("Revise (refresh estimate)")}</button>
          </div>
        </div>

        <p :if={@under} class="mt-2 text-red-700 dark:text-red-400 font-medium">
          {gettext("Chosen estimate is below the penalty-free floor — under-estimation penalty risk.")}
        </p>

        <table class="text-sm text-right border dark:border-gray-700 mx-auto mt-4 w-full">
          <thead class="bg-gray-200 dark:bg-gray-700">
            <tr>
              <th class="px-2 text-left">{gettext("Month")}</th>
              <th class="px-2">{gettext("Instalment Due")}</th>
              <th class="px-2">{gettext("Tax Paid")}</th>
              <th class="px-2">{gettext("Balance")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @schedule} class="border-b dark:border-gray-700 odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900">
              <td class="px-2 text-left">{Date.to_iso8601(r.period_start)} → {Date.to_iso8601(r.period_end)}</td>
              <td class="px-2 font-mono">{money(r.instalment_due)}</td>
              <td class="px-2 font-mono">
                <input type="number" step="0.01" name={"plan[paid_overrides][#{r.month_no}]"}
                  value={Decimal.to_string(r.paid)} class="w-28 text-right border rounded px-1 dark:bg-gray-700 dark:border-gray-600" />
              </td>
              <td class="px-2 font-mono">{money(r.balance)}</td>
            </tr>
          </tbody>
        </table>
      </.form>
    </div>
    """
  end
end
```
NOTES for the implementer:
- The paid-override inputs post as `plan[paid_overrides][<month_no>]`, producing a `%{"1" => "...", ...}` map that the changeset's `:map` field accepts directly. On `save`, every month's paid cell is written as an override (acceptable: it snapshots the GL-prefilled value). If you prefer to only store cells the user actually changed, that is a future refinement — for v1, storing all 12 is fine and keeps the schedule stable.
- Confirm the `.input` component supports passing `name=` (not `field=`) and arbitrary attrs like `phx-hook`/`url`; the advance form (`lib/full_circle_web/live/advance_live/form.ex`) uses `field={@form[:funds_account_name]}` with `phx-hook="tributeAutoComplete"`. If `.input` requires a `field`, build a tiny `to_form` for the plan instead of raw `name=`. Adapt to whatever the project's `.input` supports — read `core_components.ex` for the `input/1` signature.
- Verify the autocomplete URL `schema=account` is correct against `lib/full_circle_web/controllers/autocomplete_controller.ex` (the `"account"` clause exists).

- [ ] **Step 6: Run the LiveView test and compile**

Run: `mix compile --warnings-as-errors 2>&1 | tail -20`
Run: `mix test test/full_circle_web/live/tax_instalment_plan_live_test.exs`
Expected: compile clean; test passes. Iterate on the view until green (especially the `.input` adaptation).

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle_web/live/tax_live/instalment_plan.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/tax_instalment_plan_live_test.exs
git commit -m "feat: CP204 tax instalment planner LiveView + route + menu link

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Targeted tests**

Run:
```bash
mix test test/full_circle/tax_test.exs test/full_circle/reporting/profit_loss_forecast_test.exs test/full_circle_web/live/tax_instalment_plan_live_test.exs
```
Expected: all PASS.

- [ ] **Step 2: Full suite**

Run: `mix test`
Expected: PASS except the 2 known pre-existing `pay_run_test.exs` failures (unrelated — confirmed present before this work). No NEW failures.

- [ ] **Step 3: Compile clean**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 4: Manual smoke (recommended)**

Start the server, log in as admin, open the company dashboard → "Tax Instalment Plan". Confirm: the page mounts; setting a P&L forecast tax rate (so forecast tax > 0) makes the suggested estimate non-zero; Revise refreshes the estimate and re-spreads the schedule from the current month; editing a Tax Paid cell + Save updates balances; the under-estimation banner appears when the chosen estimate is set below the suggested floor. Check both light and dark themes.

---

## Self-Review Notes

- **Spec coverage:** table/schema with `paid_overrides` map (Task 1); FY-month reuse (Task 2); `suggested_estimate`/`under_estimated?`/`build_schedule`/`current_fy_month` (Task 3); `forecast_annual_tax`/`paid_by_month`/`schedule`/CRUD (Task 4); LiveView page + route + admin menu + Revise/Save + GL-prefilled editable paid + under-estimation banner + honesty note (Task 5); verification (Task 6). Deferred per spec: CP204 print, revision history, statutory month enforcement.
- **Type consistency:** `InstalmentPlan` fields and the `%{month_no => Decimal}` paid map, `build_schedule/4` arg order, and `schedule/2` vs `schedule/3` — NOTE: the pure tests call `build_schedule/4`; the integration `schedule/2` (plan, com) wraps it. The LiveView calls `Tax.schedule(plan, com)` for persisted plans and `Tax.build_schedule(...)` for an unsaved plan. Keep `schedule/2` (not /3) — `as_of` is not needed because `estimate_month` already encodes the as-of month at save/revise time.
- **Decimal:** all money uses `Decimal`; division uses `Decimal.div` (forecast-grade; no penny-reconciliation needed for a planning aid).
- **Dark/light:** amber controls + gray/white striped table rows have dark variants per the project's two-theme rule.
