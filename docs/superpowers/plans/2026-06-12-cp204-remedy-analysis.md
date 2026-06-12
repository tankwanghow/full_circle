# CP204 Remedy Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a year-generic Remedy Analysis panel to the P&L Forecast CP204 section that compares planning options for both under-estimation (penalty vs director fee) and over-estimation (refund vs defer remuneration vs revise estimate).

**Architecture:** Extract all arithmetic into pure `FullCircle.Tax.Remedy` and `FullCircle.Tax.PersonalIncome` modules (Decimal throughout). Persist director-scenario inputs on the per-FY `tax_instalment_plans` row. Refactor the existing inline penalty math out of `tax_plan_section/1` into `Remedy.penalty_analysis/4`. The LiveView renders a position-aware comparison table driven by `fy_year`, `as_of`, and the already-computed forecast totals.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.1, Ecto, Decimal, existing `FullCircle.Tax` / `InstalmentPlan` / `ProfitLossForecast` stack.

**Design spec:** `docs/superpowers/specs/2026-06-12-cp204-remedy-analysis-design.md`

---

## File map

| File | Responsibility |
|------|----------------|
| `lib/full_circle/tax/personal_income.ex` | Malaysia YA resident progressive brackets |
| `lib/full_circle/tax/remedy.ex` | Position detection, under/over analysis, scenario comparison |
| `lib/full_circle/tax.ex` | Thin delegates to Remedy (optional; keeps public API stable) |
| `lib/full_circle/tax/instalment_plan.ex` | New `remedy_director_count`, `remedy_existing_income` fields |
| `priv/repo/migrations/..._add_remedy_fields_to_tax_instalment_plans.exs` | Migration |
| `lib/full_circle_web/live/report_live/profit_loss_forecast.ex` | Refactor banner + new remedy panel |
| `test/full_circle/tax/remedy_test.exs` | Pure computation tests |
| `test/full_circle/tax/personal_income_test.exs` | Bracket tests |
| `test/full_circle_web/live/profit_loss_forecast_live_test.exs` | Panel visibility + save |

---

## Task 1: Personal income tax brackets

**Files:**
- Create: `lib/full_circle/tax/personal_income.ex`
- Create: `test/full_circle/tax/personal_income_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.Tax.PersonalIncomeTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.PersonalIncome

  defp d(n), do: Decimal.new("#{n}")

  describe "tax_on_income/1" do
    test "zero and negative return 0" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d(0)), d(0))
      assert Decimal.equal?(PersonalIncome.tax_on_income(d(-1)), d(0))
    end

    test "first RM5,000 is tax-free" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d(5000)), d(0))
    end

    test "RM 4,303,155.54 matches Kim Poh single-director fixture" do
      # Hand-verified against LHDN YA2025 resident schedule
      assert Decimal.equal?(PersonalIncome.tax_on_income(d("4303155.54")), d("1219346.66"))
    end

    test "RM 1,434,385.18 matches Kim Poh three-director split fixture" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d("1434385.18")), d("370027.85"))
    end
  end

  describe "tax_on_additional/2" do
    test "marginal tax on top of existing income" do
      base = PersonalIncome.tax_on_income(d(360000))
      total = PersonalIncome.tax_on_income(d(360000 + 500000))
      extra = PersonalIncome.tax_on_additional(d(360000), d(500000))
      assert Decimal.equal?(extra, Decimal.sub(total, base))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/tax/personal_income_test.exs`  
Expected: FAIL — module `FullCircle.Tax.PersonalIncome` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule FullCircle.Tax.PersonalIncome do
  @moduledoc """
  Malaysia resident individual income tax (YA2025 schedule).
  Planning aid only — no reliefs, no non-resident rates.
  """

  @zero Decimal.new(0)

  # {upper_limit_exclusive_in_band_cumulative, rate}
  @brackets [
    {5_000, "0.00"},
    {20_000, "0.01"},
    {35_000, "0.03"},
    {50_000, "0.06"},
    {70_000, "0.11"},
    {100_000, "0.19"},
    {400_000, "0.25"},
    {600_000, "0.26"},
    {2_000_000, "0.28"},
    {:infinity, "0.30"}
  ]

  def tax_on_income(income) do
    income = to_decimal(income)
    if Decimal.compare(income, @zero) != :gt, do: @zero, else: tax_in_band(income)
  end

  def tax_on_additional(existing, additional) do
    Decimal.sub(tax_on_income(Decimal.add(existing, additional)), tax_on_income(existing))
  end

  defp tax_in_band(income) do
    Enum.reduce(@brackets, {@zero, @zero}, fn {limit, rate_str}, {acc, prev_top} ->
      rate = Decimal.new(rate_str)
      top =
        case limit do
          :infinity -> income
          n -> Decimal.min(income, Decimal.new(n))
        end

      band = Decimal.sub(top, prev_top) |> Decimal.max(@zero)
      {Decimal.add(acc, Decimal.mult(band, rate)), top}
    end)
    |> elem(0)
    |> Decimal.round(2)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/tax/personal_income_test.exs`  
Expected: PASS (tune Kim Poh expected values if rounding differs by ≤ RM 1).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax/personal_income.ex test/full_circle/tax/personal_income_test.exs
git commit -m "feat: add Malaysia personal income tax bracket helper for remedy analysis"
```

---

## Task 2: Remedy position detection + under-estimation analysis

**Files:**
- Create: `lib/full_circle/tax/remedy.ex`
- Create: `test/full_circle/tax/remedy_test.exs`
- Modify: `lib/full_circle/tax.ex` (add delegates)

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule FullCircle.Tax.RemedyTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.Remedy

  defp d(n), do: Decimal.new("#{n}")

  describe "estimate_position/3" do
    test ":under when estimate below floor and forecast above ceiling" do
      # Kim Poh FY2025: forecast 6,005,257.33, estimate 3,825,000, tol 30%
      assert Remedy.estimate_position(d("6005257.3344"), d(3825000), d(30)) == :under
    end

    test ":over when forecast below estimate but not under" do
      assert Remedy.estimate_position(d(400000), d(500000), d(30)) == :over
    end

    test ":within when estimate near forecast" do
      assert Remedy.estimate_position(d(100000), d(90000), d(30)) == :within
    end
  end

  describe "penalty_analysis/4" do
    test "Kim Poh FY2025 under-estimation figures" do
      a =
        Remedy.penalty_analysis(
          d("6005257.3344"),
          d(3825000),
          d(30),
          d(24)
        )

      assert a.position == :under
      assert Decimal.equal?(a.penalty, d("103275.73"))
      assert Decimal.equal?(a.director_fee_needed, d("4303155.56"))
      assert Decimal.equal?(a.excess_tax, d("1032757.3344"))
      assert Decimal.equal?(a.penalty_ceiling, d(4972500))
    end

    test "no penalty when within tolerance" do
      a = Remedy.penalty_analysis(d(130000), d(100000), d(30), d(24))
      assert a.position == :within
      assert Decimal.equal?(a.penalty, d(0))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/tax/remedy_test.exs`  
Expected: FAIL — `FullCircle.Tax.Remedy` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule FullCircle.Tax.Remedy do
  @moduledoc """
  CP204 remedy analysis: under-estimation (penalty vs director fee) and
  over-estimation (refund vs defer remuneration). Pure Decimal math.
  """

  alias FullCircle.Tax.PersonalIncome

  @zero Decimal.new(0)
  @hundred Decimal.new(100)
  @penalty_rate Decimal.new("0.10")

  def estimate_position(forecast_tax, chosen_estimate, tolerance_pct) do
    floor = suggested_floor(forecast_tax, tolerance_pct)
    ceiling = penalty_ceiling(chosen_estimate, tolerance_pct)

    cond do
      Decimal.compare(chosen_estimate, floor) == :lt and
          Decimal.compare(forecast_tax, ceiling) == :gt ->
        :under

      Decimal.compare(forecast_tax, chosen_estimate) == :lt ->
        :over

      true ->
        :within
    end
  end

  def penalty_analysis(forecast_tax, chosen_estimate, tolerance_pct, corp_rate) do
    position = estimate_position(forecast_tax, chosen_estimate, tolerance_pct)
    ceiling = penalty_ceiling(chosen_estimate, tolerance_pct)
    excess_tax = max_zero(Decimal.sub(forecast_tax, ceiling))
    penalty = Decimal.mult(excess_tax, @penalty_rate)
    rate = corp_rate_percent(corp_rate)

    director_fee_needed =
      if Decimal.compare(rate, @zero) == :gt do
        Decimal.div(excess_tax, Decimal.div(rate, @hundred))
      else
        @zero
      end

    %{
      position: position,
      suggested_floor: suggested_floor(forecast_tax, tolerance_pct),
      penalty_ceiling: ceiling,
      excess_tax: excess_tax,
      penalty: penalty,
      director_fee_needed: director_fee_needed,
      profit_ceiling:
        if(Decimal.compare(rate, @zero) == :gt,
          do: Decimal.div(Decimal.mult(ceiling, @hundred), rate),
          else: @zero
        ),
      excess_profit:
        if(Decimal.compare(rate, @zero) == :gt,
          do: Decimal.div(Decimal.mult(excess_tax, @hundred), rate),
          else: @zero
        )
    }
  end

  def suggested_floor(forecast_tax, tolerance_pct) do
    if Decimal.compare(forecast_tax, @zero) != :gt do
      @zero
    else
      divisor = Decimal.add(@hundred, tolerance_pct)
      Decimal.div(Decimal.mult(forecast_tax, @hundred), divisor)
    end
  end

  def penalty_ceiling(chosen_estimate, tolerance_pct) do
    multiplier = Decimal.add(@hundred, tolerance_pct) |> Decimal.div(@hundred)
    Decimal.mult(chosen_estimate, multiplier)
  end

  defp corp_rate_percent(%Decimal{} = r), do: r
  defp corp_rate_percent(n), do: Decimal.new("#{n}")
  defp max_zero(d), do: if(Decimal.compare(d, @zero) == :lt, do: @zero, else: d)
end
```

Add to `lib/full_circle/tax.ex`:

```elixir
defdelegate estimate_position(forecast_tax, chosen_estimate, tolerance_pct),
  to: FullCircle.Tax.Remedy

defdelegate penalty_analysis(forecast_tax, chosen_estimate, tolerance_pct, corp_rate),
  to: FullCircle.Tax.Remedy
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/tax/remedy_test.exs`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax/remedy.ex lib/full_circle/tax.ex test/full_circle/tax/remedy_test.exs
git commit -m "feat: add CP204 estimate position and penalty analysis"
```

---

## Task 3: Under-estimation remedy comparison

**Files:**
- Modify: `lib/full_circle/tax/remedy.ex`
- Modify: `test/full_circle/tax/remedy_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
describe "under_remedy_comparison/5" do
  test "Kim Poh: 1 director — penalty is cheaper" do
    a = Remedy.penalty_analysis(d("6005257.3344"), d(3825000), d(30), d(24))

    c = Remedy.under_remedy_comparison(a, d(24), 1, d(0))

    assert c.recommendation == :pay_penalty
    assert Decimal.compare(c.delta, @zero) == :gt  # penalty total lower
    assert Decimal.equal?(c.pay_penalty.total, d("6108533.06"))
  end

  test "3 directors — director fee can be cheaper" do
    a = Remedy.penalty_analysis(d("6005257.3344"), d(3825000), d(30), d(24))
    c = Remedy.under_remedy_comparison(a, d(24), 3, d(0))
    assert c.recommendation == :director_fee
  end

  test "existing income raises personal tax" do
    a = Remedy.penalty_analysis(d("6005257.3344"), d(3825000), d(30), d(24))
    c0 = Remedy.under_remedy_comparison(a, d(24), 1, d(0))
    c1 = Remedy.under_remedy_comparison(a, d(24), 1, d(360000))
    assert Decimal.compare(c1.director_fee.personal_tax, c0.director_fee.personal_tax) == :gt
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/tax/remedy_test.exs:LINE`  
Expected: FAIL — `under_remedy_comparison/5` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
@marginal_threshold Decimal.new(5000)

def under_remedy_comparison(analysis, corp_rate, director_count, existing_income_per_director) do
  forecast_tax = Decimal.add(analysis.penalty_ceiling, analysis.excess_tax)
  fee = analysis.director_fee_needed
  count = max(director_count, 1)
  per_share = Decimal.div(fee, Decimal.new(count))

  personal_tax =
    Enum.reduce(1..count, @zero, fn _, acc ->
      Decimal.add(
        acc,
        PersonalIncome.tax_on_additional(existing_income_per_director, per_share)
      )
    end)

  pay_penalty = %{
    company_tax: forecast_tax,
    penalty: analysis.penalty,
    personal_tax: @zero,
    total: Decimal.add(forecast_tax, analysis.penalty),
    refund: @zero
  }

  company_tax_after = analysis.penalty_ceiling

  director_fee = %{
    company_tax: company_tax_after,
    penalty: @zero,
    personal_tax: personal_tax,
    total: Decimal.add(company_tax_after, personal_tax),
    fee_amount: fee,
    extra_cash_movement:
      Decimal.sub(
        fee,
        Decimal.add(analysis.excess_tax, analysis.penalty)
      )
  }

  delta = Decimal.sub(director_fee.total, pay_penalty.total)

  breakeven_rate =
    if Decimal.compare(fee, @zero) == :gt do
      Decimal.add(
        corp_rate,
        Decimal.mult(Decimal.div(analysis.penalty, fee), @hundred)
      )
    else
      @zero
    end

  recommendation =
    cond do
      Decimal.abs(delta) |> Decimal.compare(@marginal_threshold) != :gt -> :marginal
      Decimal.compare(delta, @zero) == :gt -> :pay_penalty
      true -> :director_fee
    end

  %{
    pay_penalty: pay_penalty,
    director_fee: director_fee,
    delta: delta,
    breakeven_effective_rate: breakeven_rate,
    recommendation: recommendation
  }
end
```

Add delegate in `tax.ex`:

```elixir
defdelegate under_remedy_comparison(analysis, corp_rate, director_count, existing_income),
  to: FullCircle.Tax.Remedy
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/tax/remedy_test.exs`  
Expected: PASS (tune totals to ±RM 1 if bracket rounding differs).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax/remedy.ex lib/full_circle/tax.ex test/full_circle/tax/remedy_test.exs
git commit -m "feat: compare under-estimation penalty vs director fee remedies"
```

---

## Task 4: Over-estimation analysis + remedy comparison

**Files:**
- Modify: `lib/full_circle/tax/remedy.ex`
- Modify: `test/full_circle/tax/remedy_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
describe "over_analysis/5" do
  test "computes overpayment and expected refund" do
    a = Remedy.over_analysis(d(400000), d(500000), d(30), d(24), d(480000))

    assert a.position == :over
    assert Decimal.equal?(a.overpayment_tax, d(100000))
    assert Decimal.equal?(a.expected_refund, d(80000))  # paid 480k - tax 400k
    assert Decimal.equal?(a.deferral_needed, d("416666.67"))  # 100k / 24%
  end

  test "headroom_tax before crossing into penalty zone" do
    a = Remedy.over_analysis(d(400000), d(500000), d(30), d(24), d(500000))
    # ceiling = 650k, headroom = 250k
    assert Decimal.equal?(a.headroom_tax, d(250000))
  end
end

describe "over_remedy_comparison/2" do
  test "defer vs refund — same group tax, different timing" do
    a = Remedy.over_analysis(d(400000), d(500000), d(30), d(24), d(500000))
    c = Remedy.over_remedy_comparison(a)

    assert Decimal.equal?(c.accept_refund.group_tax, d(400000))
    assert Decimal.equal?(c.defer_remuneration.group_tax, d(500000))
    assert c.recommendation == :accept_refund
    assert Decimal.equal?(c.accept_refund.expected_refund, d(100000))
    assert Decimal.equal?(c.defer_remuneration.expected_refund, d(0))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/tax/remedy_test.exs`  
Expected: FAIL — `over_analysis/5` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
def over_analysis(forecast_tax, chosen_estimate, tolerance_pct, corp_rate, instalments_paid) do
  position = estimate_position(forecast_tax, chosen_estimate, tolerance_pct)
  overpayment_tax = max_zero(Decimal.sub(chosen_estimate, forecast_tax))
  ceiling = penalty_ceiling(chosen_estimate, tolerance_pct)
  headroom_tax = max_zero(Decimal.sub(ceiling, forecast_tax))
  rate = corp_rate_percent(corp_rate)

  deferral_needed =
    if Decimal.compare(rate, @zero) == :gt do
      Decimal.div(overpayment_tax, Decimal.div(rate, @hundred))
    else
      @zero
    end

  %{
    position: position,
    overpayment_tax: overpayment_tax,
    expected_refund: max_zero(Decimal.sub(instalments_paid, forecast_tax)),
    headroom_tax: headroom_tax,
    deferral_needed: deferral_needed,
    revised_estimate: forecast_tax,
    instalments_paid: instalments_paid
  }
end

def over_remedy_comparison(analysis) do
  accept_refund = %{
    group_tax: Decimal.sub(analysis.instalments_paid, analysis.expected_refund),
    expected_refund: analysis.expected_refund,
    personal_tax: @zero,
    note: :cash_returned_from_lhdn
  }

  # Align tax to estimate by deferring remuneration (no fee deducted this YA)
  defer = %{
    group_tax:
      Decimal.add(
        Decimal.sub(analysis.instalments_paid, analysis.expected_refund),
        analysis.overpayment_tax
      ),
    expected_refund: max_zero(Decimal.sub(analysis.instalments_paid, analysis.group_tax_for_estimate(analysis))),
    personal_tax: @zero,
    deferral_needed: analysis.deferral_needed,
    note: :fees_deferred_to_next_ya
  }

  # group_tax_for_estimate helper:
  # chosen_estimate = forecast + overpayment_tax

  revise = %{
    saving_vs_current: analysis.overpayment_tax,
    revised_estimate: analysis.revised_estimate,
    note: :use_revise_button
  }

  %{
    accept_refund: accept_refund,
    defer_remuneration: defer,
    revise_estimate: revise,
    recommendation: :accept_refund
  }
end
```

Implement `group_tax_for_estimate/1` as a private function returning `chosen_estimate` equivalent (`forecast + overpayment`).

**Important:** `accept_refund.group_tax` must equal `forecast_tax` — verify in tests via
`instalments_paid - expected_refund`.

Add delegates in `tax.ex`.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/tax/remedy_test.exs`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax/remedy.ex lib/full_circle/tax.ex test/full_circle/tax/remedy_test.exs
git commit -m "feat: add over-estimation refund vs defer-remuneration remedy analysis"
```

---

## Task 5: Migration + schema fields

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_add_remedy_fields_to_tax_instalment_plans.exs`
- Modify: `lib/full_circle/tax/instalment_plan.ex`
- Modify: `test/full_circle/tax_test.exs` (schema tests)

- [ ] **Step 1: Write the failing schema test**

Add to `FullCircle.TaxSchemaTest`:

```elixir
test "accepts remedy director fields" do
  cs =
    chg(%{
      company_id: Ecto.UUID.generate(),
      fy_year: 2026,
      remedy_director_count: 3,
      remedy_existing_income: "360000"
    })

  assert cs.valid?
  assert Ecto.Changeset.get_field(cs, :remedy_director_count) == 3
end

test "rejects remedy_director_count < 1" do
  refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, remedy_director_count: 0}).valid?
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/tax_test.exs`  
Expected: FAIL — unknown fields.

- [ ] **Step 3: Create migration**

```elixir
defmodule FullCircle.Repo.Migrations.AddRemedyFieldsToTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    alter table(:tax_instalment_plans) do
      add :remedy_director_count, :integer, null: false, default: 1
      add :remedy_existing_income, :decimal, null: false, default: 0
    end
  end
end
```

Update `instalment_plan.ex` schema + changeset:

```elixir
field(:remedy_director_count, :integer, default: 1)
field(:remedy_existing_income, :decimal, default: Decimal.new(0))
```

Cast + validate `remedy_director_count` in `1..20` (reasonable cap).

- [ ] **Step 4: Migrate and run tests**

Run: `mix ecto.migrate && mix test test/full_circle/tax_test.exs`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations lib/full_circle/tax/instalment_plan.ex test/full_circle/tax_test.exs
git commit -m "feat: persist remedy director scenario on tax instalment plans"
```

---

## Task 6: Refactor LiveView banner to use Remedy module

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`

- [ ] **Step 1: Replace inline penalty math in `tax_plan_section/1`**

Remove lines that compute `multiplier`, `ceiling`, `excess`, `penalty`, `profit_ceiling`, `excess_profit` inline.

Replace with:

```elixir
analysis =
  FullCircle.Tax.Remedy.penalty_analysis(
    assigns.forecast_tax,
    chosen,
    tol,
    assigns.tax_rate || Decimal.new(0)
  )

instalments_paid =
  Enum.reduce(assigns.schedule, Decimal.new(0), fn r, acc ->
    Decimal.add(acc, r.paid)
  end)

over = FullCircle.Tax.Remedy.over_analysis(
  assigns.forecast_tax,
  chosen,
  tol,
  assigns.tax_rate || Decimal.new(0),
  instalments_paid
)
```

Use `analysis.penalty`, `analysis.excess_tax`, etc. in the existing banner assigns.
Set `under` to `analysis.position == :under`.

- [ ] **Step 2: Verify existing LiveView tests still pass**

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs`  
Expected: PASS (no UI change yet).

- [ ] **Step 3: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex
git commit -m "refactor: drive CP204 penalty banner from Tax.Remedy"
```

---

## Task 7: Remedy comparison panel UI

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`
- Modify: `test/full_circle_web/live/profit_loss_forecast_live_test.exs`

- [ ] **Step 1: Write failing LiveView tests**

```elixir
test "remedy panel shows under-estimation comparison when estimate too low", %{conn: conn, company: com} do
  {:ok, _} = PLF.save_tax_rate(com, "24")
  # ... post profitable txns (copy from existing under-estimation banner test) ...
  {:ok, lv, _html} =
    live(conn, ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026")

  # save low estimate
  lv |> form("#plan-form", %{"plan" => %{"estimate" => "1000", ...}}) |> render_submit()

  html = render(lv)
  assert html =~ "Remedy comparison"
  assert html =~ "Pay penalty"
  assert html =~ "Director fee"
end

test "remedy panel shows over-estimation comparison when estimate too high", %{conn: conn, company: com} do
  {:ok, _} = PLF.save_tax_rate(com, "24")
  # post modest profit yielding forecast_tax ~ 24_000
  {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026")

  lv |> form("#plan-form", %{"plan" => %{"estimate" => "100000", ...}}) |> render_submit()

  html = render(lv)
  assert html =~ "Remedy comparison"
  assert html =~ "Accept refund"
  assert html =~ "Defer remuneration"
end

test "no remedy panel when within tolerance", %{conn: conn, company: com} do
  # estimate ≈ suggested — assert html does NOT contain "Remedy comparison"
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs`  
Expected: FAIL — strings not found.

- [ ] **Step 3: Add `remedy_panel/1` function component**

Insert after the under-estimation banner in `tax_plan_section/1`, visible when
`analysis.position in [:under, :over]`:

```elixir
attr :analysis, :map, required: true
attr :over, :map, required: true
attr :plan, :any, required: true
attr :tax_rate, :any, required: true
attr :forecast_tax, :any, required: true

defp remedy_panel(assigns) do
  comparison =
    case assigns.analysis.position do
      :under ->
        FullCircle.Tax.Remedy.under_remedy_comparison(
          assigns.analysis,
          assigns.tax_rate,
          assigns.plan.remedy_director_count || 1,
          assigns.plan.remedy_existing_income || Decimal.new(0)
        )

      :over ->
        FullCircle.Tax.Remedy.over_remedy_comparison(assigns.over)
    end

  assigns = assign(assigns, comparison: comparison)

  ~H"""
  <div class="mb-3 rounded border border-blue-300 bg-blue-50 dark:bg-blue-950/30 dark:border-blue-700 px-3 py-2 text-sm">
    <p class="font-semibold">{gettext("Remedy comparison")}</p>

    <div class="grid grid-cols-2 gap-3 mt-2 items-end">
      <.input
        name="plan[remedy_director_count]"
        type="number"
        min="1"
        max="20"
        label={gettext("Directors")}
        value={@plan.remedy_director_count || 1}
      />
      <.input
        name="plan[remedy_existing_income]"
        type="number"
        step="0.01"
        min="0"
        label={gettext("Existing income per director (RM)")}
        value={Decimal.to_string(@plan.remedy_existing_income || 0)}
      />
    </div>

    <%= if @analysis.position == :under do %>
      <%!-- two-column table: Pay penalty | Director fee --%>
      <%!-- show company_tax, penalty, personal_tax, TOTAL, recommendation, breakeven rate, extra_cash_movement --%>
    <% else %>
      <%!-- two-column table: Accept refund | Defer remuneration --%>
      <%!-- show group_tax, expected_refund, deferral_needed, revise hint --%>
      <%!-- warning: paying director fees now worsens overpayment --%>
    <% end %>

    <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
      {gettext("Planning aid only — not filed tax advice. Personal tax excludes reliefs and EPF.")}
    </p>
  </div>
  """
end
```

Wire inputs into the existing `#plan-form` (same `save_plan` handler). Update
`InstalmentPlan.changeset` cast list in `create_or_update_plan` path — already
handled if fields are in changeset.

- [ ] **Step 4: Run LiveView tests**

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs`  
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex test/full_circle_web/live/profit_loss_forecast_live_test.exs
git commit -m "feat: add CP204 remedy comparison panel to P&L forecast"
```

---

## Task 8: Over-estimation banner (green/amber)

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`
- Modify: `test/full_circle_web/live/profit_loss_forecast_live_test.exs`

The existing banner only speaks in under-estimation terms. Extend it:

- [ ] **Step 1: Write failing test**

```elixir
test "over-estimation banner shows expected refund", %{conn: conn, company: com} do
  # estimate >> forecast
  html = render(lv)
  assert html =~ "Over-estimated"
  assert html =~ "Expected refund"
end
```

- [ ] **Step 2: Extend banner conditional**

When `analysis.position == :over`, render amber banner:

```
Over-estimated — forecast tax is below the chosen estimate.
Expected refund (instalments paid − forecast tax): RM X.
Deferring RM Y of director remuneration would align tax to the estimate.
```

When `:within`, keep existing green "Within the margin" text.

- [ ] **Step 3: Run tests and commit**

```bash
mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs
git commit -m "feat: show over-estimation refund banner on CP204 planner"
```

---

## Task 9: Final verification

- [ ] **Step 1: Run full test suite for touched modules**

```bash
mix test test/full_circle/tax/personal_income_test.exs test/full_circle/tax/remedy_test.exs test/full_circle/tax_test.exs test/full_circle_web/live/profit_loss_forecast_live_test.exs
```

Expected: all PASS.

- [ ] **Step 2: Run credo on new files**

```bash
mix credo lib/full_circle/tax/personal_income.ex lib/full_circle/tax/remedy.ex lib/full_circle_web/live/report_live/profit_loss_forecast.ex
```

- [ ] **Step 3: Manual smoke test**

1. Open Kim Poh FY2025 — under-estimation remedy panel with penalty vs director fee.
2. Switch to a FY where estimate > forecast — over-estimation panel with refund vs defer.
3. Change `fy_year` dropdown — plan + remedy inputs reload per year.
4. Save remedy director count → persists on reload.
5. Confirm print view unchanged (no remedy panel).

---

## Spec coverage checklist

| Requirement | Task |
|-------------|------|
| Under-estimation penalty analysis | Task 2 |
| Under-estimation remedy comparison | Task 3 |
| Over-estimation refund analysis | Task 4 |
| Over-estimation defer remuneration | Task 4 |
| Revise estimate hint (over) | Task 7 UI |
| Year-generic via fy_year/as_of | Tasks 6–7 (no year branches) |
| Director count + existing income inputs | Task 5, 7 |
| Pure Decimal tests | Tasks 1–4 |
| LiveView panel | Tasks 7–8 |
| Print view excluded | Task 7 (no print changes) |
| Refactor inline math | Task 6 |

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-12-cp204-remedy-analysis.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — implement task-by-task in this session with checkpoints

Which approach?