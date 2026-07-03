# CP204A Revisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model CP204A revisions (revised annual estimate at basis-period months 6/9/11) in the P&L Forecast instalment plan, with an 85% prior-year floor warning.

**Architecture:** A `revisions` map column on the existing `tax_instalment_plans` row stores `%{"6" => "5000", ...}` (revision month → revised annual estimate). `FullCircle.Tax.build_schedule/5` walks the year tracking the instalment and estimate *in force*, re-spreading at each revision month. The LiveView adds three revision inputs to the existing `plan-form` (live recompute via the existing `phx-change="plan_changed"`), repoints the penalty/remedy panels at the latest revised estimate, makes Revise fill the next open window, and shows a warn-only 85% floor banner.

**Tech Stack:** Elixir 1.19.5 / Phoenix LiveView 1.1.x / Ecto (binary_id via `FullCircle.Schema`) / Decimal.

**Spec:** `docs/superpowers/specs/2026-07-03-cp204a-revisions-design.md`

## Global Constraints

- All money math uses `Decimal` — never floats.
- All user-facing copy wrapped in `gettext(...)`.
- All new UI must look right in **both light and dark** Tailwind themes.
- Commit directly to `master` (no feature branches — user preference).
- Test runner: `mix test test/full_circle/tax_test.exs` (QueryRepo connect errors in output are known noise; 2 pre-existing failures exist in `pay_run_test` only).
- Existing behavior to preserve: months with `paid > 0` display Instalment Due 0; `paid_by_month/1` drops `_unused_*` keys; `create_or_update_plan/3` sanitizes `"paid_overrides"`.

---

### Task 1: `revisions` column + schema field

**Files:**
- Create: `priv/repo/migrations/20260703030000_add_revisions_to_tax_instalment_plans.exs`
- Modify: `lib/full_circle/tax/instalment_plan.ex`
- Test: `test/full_circle/tax_test.exs` (module `FullCircle.TaxSchemaTest`)

**Interfaces:**
- Produces: `InstalmentPlan.revisions :: map` (string month keys `"6"|"9"|"11"` → string/number revised annual estimate), castable via `InstalmentPlan.changeset/2`. Later tasks read `plan.revisions`.

- [ ] **Step 1: Write the failing test** — add inside the existing `describe "changeset/2"` block in `test/full_circle/tax_test.exs`:

```elixir
    test "accepts a revisions map" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, revisions: %{"6" => "5000"}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :revisions) == %{"6" => "5000"}
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/full_circle/tax_test.exs`
Expected: 1 failure — `get_field(cs, :revisions)` returns `nil` (unknown field).

- [ ] **Step 3: Migration + schema field** — create `priv/repo/migrations/20260703030000_add_revisions_to_tax_instalment_plans.exs`:

```elixir
defmodule FullCircle.Repo.Migrations.AddRevisionsToTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    alter table(:tax_instalment_plans) do
      add :revisions, :map, default: %{}, null: false
    end
  end
end
```

In `lib/full_circle/tax/instalment_plan.ex`, below the `paid_overrides` field add:

```elixir
    # CP204A: %{revision_month => revised annual estimate} — only "6"/"9"/"11" are honoured
    field(:revisions, :map, default: %{})
```

and add `:revisions` to the `cast` list right after `:paid_overrides`.

- [ ] **Step 4: Migrate dev DB and run the test**

Run: `mix ecto.migrate && mix test test/full_circle/tax_test.exs`
Expected: all pass (test DB migrates automatically).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/20260703030000_add_revisions_to_tax_instalment_plans.exs lib/full_circle/tax/instalment_plan.ex test/full_circle/tax_test.exs
git commit -m "feat(tax): revisions column on tax_instalment_plans for CP204A"
```

---

### Task 2: `revision_months/0`, `revisions_by_month/1`, `latest_estimate/1`

**Files:**
- Modify: `lib/full_circle/tax.ex`
- Test: `test/full_circle/tax_test.exs` (module `FullCircle.TaxComputeTest`)

**Interfaces:**
- Consumes: `plan.revisions` map from Task 1; existing private `to_month/1` (strict int parse, nil on junk) in `lib/full_circle/tax.ex`.
- Produces:
  - `FullCircle.Tax.revision_months() :: [6, 9, 11]`
  - `FullCircle.Tax.revisions_by_month(%InstalmentPlan{}) :: %{integer => Decimal.t()}` — only months 6/9/11, blank/unparseable dropped, explicit `"0"` kept.
  - `FullCircle.Tax.latest_estimate(%InstalmentPlan{}) :: Decimal.t()` — revisions[11] ‖ [9] ‖ [6] ‖ estimate ‖ 0.

- [ ] **Step 1: Write the failing tests** — add to `FullCircle.TaxComputeTest` (before the `current_fy_month/3` describe):

```elixir
  describe "revisions_by_month/1 and latest_estimate/1" do
    test "keeps only revision months with parseable values" do
      plan = %FullCircle.Tax.InstalmentPlan{
        revisions: %{"6" => "5000", "7" => "1234", "9" => "", "11" => "abc", "_unused_6" => ""}
      }

      r = Tax.revisions_by_month(plan)
      assert Decimal.equal?(r[6], d(5000))
      assert map_size(r) == 1
    end

    test "explicit zero is a valid revision" do
      plan = %FullCircle.Tax.InstalmentPlan{revisions: %{"9" => "0"}}
      assert Decimal.equal?(Tax.revisions_by_month(plan)[9], d(0))
    end

    test "latest_estimate precedence is 11 -> 9 -> 6 -> original" do
      base = %FullCircle.Tax.InstalmentPlan{estimate: d(8500)}
      assert Decimal.equal?(Tax.latest_estimate(base), d(8500))
      assert Decimal.equal?(Tax.latest_estimate(%{base | revisions: %{"6" => "5000"}}), d(5000))

      assert Decimal.equal?(
               Tax.latest_estimate(%{base | revisions: %{"6" => "5000", "9" => "7000"}}),
               d(7000)
             )

      assert Decimal.equal?(
               Tax.latest_estimate(%{base | revisions: %{"6" => "5000", "11" => "6000"}}),
               d(6000)
             )
    end

    test "revision_months/0" do
      assert Tax.revision_months() == [6, 9, 11]
    end
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `mix test test/full_circle/tax_test.exs`
Expected: 4 failures — `UndefinedFunctionError` for `revisions_by_month/1`, `latest_estimate/1`, `revision_months/0`.

- [ ] **Step 3: Implement** — in `lib/full_circle/tax.ex`, below the `@hundred` module attribute add:

```elixir
  # LHDN allows CP204 revision (Form CP204A) in the 6th, 9th and — permanently
  # from YA 2024 (s.107C amendment) — 11th month of the basis period.
  @revision_months [6, 9, 11]

  @doc "FY basis-period months in which LHDN allows a CP204 revision (Form CP204A)."
  def revision_months, do: @revision_months
```

Below `paid_by_month/1` add:

```elixir
  @doc """
  `%{revision_month => Decimal}` CP204A revised annual estimates from the plan.
  Only months 6/9/11 are honoured; blank/unparseable values are dropped
  (blank means "not revised"); an explicit 0 is a valid revision.
  """
  def revisions_by_month(%InstalmentPlan{} = plan) do
    Enum.reduce(plan.revisions || %{}, %{}, fn {k, v}, acc ->
      m = to_month(k)

      case if(m in @revision_months, do: parse_decimal(v)) do
        %Decimal{} = dec -> Map.put(acc, m, dec)
        _ -> acc
      end
    end)
  end

  @doc "The estimate in force at year end: latest revision (11 -> 9 -> 6) or the original."
  def latest_estimate(%InstalmentPlan{} = plan) do
    rev = revisions_by_month(plan)
    rev[11] || rev[9] || rev[6] || plan.estimate || @zero
  end
```

Next to the private `to_decimal/1` helpers add (note: unlike `to_decimal/1`, this returns `nil` — not 0 — for blank/junk):

```elixir
  defp parse_decimal(%Decimal{} = dec), do: dec
  defp parse_decimal(n) when is_integer(n) or is_float(n), do: Decimal.new("#{n}")

  defp parse_decimal(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {dec, _} -> dec
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/tax_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax.ex test/full_circle/tax_test.exs
git commit -m "feat(tax): CP204A revision helpers (revision_months, revisions_by_month, latest_estimate)"
```

---

### Task 3: `build_schedule/5` revision segments + `schedule/2` wiring

**Files:**
- Modify: `lib/full_circle/tax.ex` (`build_schedule`, `schedule`)
- Test: `test/full_circle/tax_test.exs` (module `FullCircle.TaxComputeTest`)

**Interfaces:**
- Consumes: `revisions_by_month/1` from Task 2.
- Produces: `build_schedule(month_bounds, paid_by_month, estimate, estimate_month, revisions \\ %{})` where `revisions :: %{integer => Decimal.t()}`. Row maps gain key `estimate_in_force :: Decimal.t()`; `balance` becomes `estimate_in_force − cumulative paid`. `schedule/2` passes the plan's revisions automatically — the LiveView needs no schedule-call change.

- [ ] **Step 1: Write the failing tests** — add to `FullCircle.TaxComputeTest` inside the `describe "build_schedule/4"` block (rename the describe to `"build_schedule"`):

```elixir
    test "single revision at month 6 re-spreads from month 6" do
      rows = Tax.build_schedule(bounds(), %{}, d(8500), 1, %{6 => d(5000)})
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 0).instalment_due, 2), d("708.33"))
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 4).instalment_due, 2), d("708.33"))
      # payable before 6 = 5 x 708.33..; (5000 - 3541.66..) / 7
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 5).instalment_due, 2), d("208.33"))
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 11).instalment_due, 2), d("208.33"))
      assert Decimal.equal?(Enum.at(rows, 4).estimate_in_force, d(8500))
      assert Decimal.equal?(Enum.at(rows, 5).estimate_in_force, d(5000))
    end

    test "later revision supersedes the earlier one" do
      rows = Tax.build_schedule(bounds(), %{}, d(12000), 1, %{6 => d(9000), 9 => d(15000)})
      assert Decimal.equal?(Enum.at(rows, 0).instalment_due, d(1000))
      # (9000 - 5000) / 7
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 5).instalment_due, 2), d("571.43"))
      # payable before 9 = 5000 + 3 x 571.42..; (15000 - 6714.28..) / 4
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 8).instalment_due, 2), d("2071.43"))
      assert Decimal.equal?(Enum.at(rows, 11).estimate_in_force, d(15000))
    end

    test "revision below what is already payable floors remaining dues at 0" do
      rows = Tax.build_schedule(bounds(), %{}, d(12000), 1, %{9 => d(5000)})
      assert Decimal.equal?(Enum.at(rows, 8).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 11).instalment_due, d(0))
    end

    test "revision before estimate_month is ignored" do
      rows = Tax.build_schedule(bounds(), %{}, d(12000), 8, %{6 => d(5000)})
      assert Decimal.equal?(Enum.at(rows, 5).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 7).instalment_due, d(2400))
      assert Decimal.equal?(Enum.at(rows, 7).estimate_in_force, d(12000))
    end

    test "balance tracks the estimate in force; settled months still count as payable" do
      rows = Tax.build_schedule(bounds(), %{1 => d(1000)}, d(12000), 1, %{6 => d(6000)})
      # month 1 paid -> displayed due 0, but its scheduled 1000 still counts toward payable
      assert Decimal.equal?(Enum.at(rows, 0).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 0).balance, d(11000))
      # (6000 - 5 x 1000) / 7
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 5).instalment_due, 2), d("142.86"))
      assert Decimal.equal?(Enum.at(rows, 5).balance, d(5000))
    end

    test "no revisions -> original spread, estimate-based balance, in_force = estimate (regression)" do
      rows = Tax.build_schedule(bounds(), %{1 => d(1000)}, d(120000), 1)
      assert Decimal.equal?(Enum.at(rows, 1).instalment_due, d(10000))
      assert Decimal.equal?(Enum.at(rows, 0).balance, d(119000))
      assert Enum.all?(rows, &Decimal.equal?(&1.estimate_in_force, d(120000)))
    end
```

- [ ] **Step 2: Run to verify failures**

Run: `mix test test/full_circle/tax_test.exs`
Expected: new tests fail (`build_schedule/5` undefined; `estimate_in_force` key missing).

- [ ] **Step 3: Implement** — in `lib/full_circle/tax.ex`, replace the whole `build_schedule/4` (doc + function) with:

```elixir
  @doc """
  Build the 12-month instalment schedule. `month_bounds` is the list of 12
  `{start, end}` tuples; `paid_by_month` is `%{month_no => Decimal}`;
  `revisions` is `%{revision_month => revised annual estimate}` (see
  `revisions_by_month/1`). The original `estimate` spreads evenly from
  `estimate_month`; at each revision month the instalment re-spreads as
  `(revised estimate - payable so far) / remaining months`, where payable =
  paid before `estimate_month` + scheduled instalments since. A month with
  tax already paid is settled — its displayed due is 0, but its scheduled
  instalment still counts toward payable. `balance` and `estimate_in_force`
  track the estimate in force each month.
  """
  def build_schedule(month_bounds, paid_by_month, estimate, estimate_month, revisions \\ %{}) do
    paid_to_date =
      Enum.reduce(1..(estimate_month - 1)//1, @zero, fn m, acc ->
        Decimal.add(acc, Map.get(paid_by_month, m, @zero))
      end)

    remaining = 12 - estimate_month + 1
    forward = Decimal.div(max_zero(Decimal.sub(estimate, paid_to_date)), Decimal.new(remaining))

    init = %{forward: forward, in_force: estimate, payable: paid_to_date}

    {months, _} =
      Enum.map_reduce(1..12, init, fn m, acc ->
        acc =
          case Map.fetch(revisions, m) do
            {:ok, revised} when m >= estimate_month ->
              new_forward =
                Decimal.div(
                  max_zero(Decimal.sub(revised, acc.payable)),
                  Decimal.new(12 - m + 1)
                )

              %{acc | forward: new_forward, in_force: revised}

            _ ->
              acc
          end

        scheduled = if m >= estimate_month, do: acc.forward, else: @zero
        {%{scheduled: scheduled, in_force: acc.in_force}, %{acc | payable: Decimal.add(acc.payable, scheduled)}}
      end)

    {rows, _cum_paid} =
      month_bounds
      |> Enum.zip(months)
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {{{ps, pe}, month}, m}, cum_paid ->
        paid = Map.get(paid_by_month, m, @zero)

        due =
          if Decimal.compare(paid, @zero) == :gt,
            do: @zero,
            else: month.scheduled

        cum_paid2 = Decimal.add(cum_paid, paid)

        row = %{
          month_no: m,
          period_start: ps,
          period_end: pe,
          instalment_due: due,
          paid: paid,
          estimate_in_force: month.in_force,
          balance: Decimal.sub(month.in_force, cum_paid2)
        }

        {row, cum_paid2}
      end)

    rows
  end
```

Then update `schedule/2` to pass revisions:

```elixir
  @doc "Full schedule for the plan: pure `build_schedule/5` fed with manual paid data and CP204A revisions."
  def schedule(%InstalmentPlan{} = plan, com) do
    bounds = PLF.fy_month_bounds(com, plan.fy_year)

    build_schedule(
      bounds,
      paid_by_month(plan),
      plan.estimate || @zero,
      plan.estimate_month || 1,
      revisions_by_month(plan)
    )
  end
```

- [ ] **Step 4: Run the full tax test file** (existing schedule tests must also still pass)

Run: `mix test test/full_circle/tax_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax.ex test/full_circle/tax_test.exs
git commit -m "feat(tax): CP204A revision segments in the instalment schedule"
```

---

### Task 4: Sanitize `"revisions"` on save

**Files:**
- Modify: `lib/full_circle/tax.ex` (`create_or_update_plan/3` + new private helper)
- Test: `test/full_circle/tax_test.exs` (module `FullCircle.TaxDBTest`)

**Interfaces:**
- Consumes: `parse_decimal/1`, `to_month/1`, `@revision_months` from Task 2; existing `sanitize_overrides/1` pattern.
- Produces: `create_or_update_plan/3` persists `revisions` containing only `"6"/"9"/"11"` keys with parseable values (blank dropped, `"0"` kept). Raw form params (with `_unused_*` keys) are safe to pass.

- [ ] **Step 1: Write the failing test** — add to `FullCircle.TaxDBTest`, inside `describe "create_or_update_plan/3 and get_plan/2"`:

```elixir
    test "saving keeps only valid CP204A revisions", %{com: com, admin: admin} do
      {:ok, plan} =
        Tax.create_or_update_plan(
          %{
            "fy_year" => 2026,
            "revisions" => %{"6" => "5000", "7" => "999", "9" => "", "11" => "0", "_unused_6" => ""}
          },
          com,
          admin
        )

      assert plan.revisions == %{"6" => "5000", "11" => "0"}
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/tax_test.exs`
Expected: 1 failure — stored map still contains `"7"`, `"9"`, `"_unused_6"`.

- [ ] **Step 3: Implement** — in `create_or_update_plan/3` extend the attrs pipeline:

```elixir
    attrs =
      attrs
      |> Map.put("company_id", com.id)
      |> Map.replace_lazy("paid_overrides", &sanitize_overrides/1)
      |> Map.replace_lazy("revisions", &sanitize_revisions/1)
```

Next to `sanitize_overrides/1` add:

```elixir
  # Keep only CP204A revision months with parseable values (blank = not revised).
  defp sanitize_revisions(m) when is_map(m) do
    for {k, v} <- m, to_month(k) in @revision_months, parse_decimal(v) != nil, into: %{}, do: {k, v}
  end

  defp sanitize_revisions(other), do: other
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/tax_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/tax.ex test/full_circle/tax_test.exs
git commit -m "feat(tax): sanitize CP204A revisions on plan save"
```

---

### Task 5: LiveView plan panel — revision inputs, latest-estimate analysis

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`

**Interfaces:**
- Consumes: `FullCircle.Tax.latest_estimate/1`, `FullCircle.Tax.revision_months/0` (Task 2). The existing `phx-change="plan_changed"` handler already casts `plan[revisions][...]` into the ephemeral plan via `InstalmentPlan.changeset` — no handler change needed.
- Produces: form fields named `plan[revisions][6|9|11]`; `@chosen` (banner/remedy input) = latest revised estimate. Task 7 adds `prior_latest` to this component.

- [ ] **Step 1: Repoint the analysis at the latest estimate** — in `tax_plan_section/1`, replace:

```elixir
    chosen =
      if assigns.plan.estimate && Decimal.compare(assigns.plan.estimate, Decimal.new(0)) == :gt,
        do: assigns.plan.estimate,
        else: suggested
```

with:

```elixir
    original =
      if assigns.plan.estimate && Decimal.compare(assigns.plan.estimate, Decimal.new(0)) == :gt,
        do: assigns.plan.estimate,
        else: suggested

    latest = FullCircle.Tax.latest_estimate(assigns.plan)

    # Penalty/remedy checks run against the estimate in force (latest CP204A).
    chosen =
      if Decimal.compare(latest, Decimal.new(0)) == :gt,
        do: latest,
        else: suggested
```

and add `original: original,` to the `assign(assigns, ...)` call in the same function.

- [ ] **Step 2: Rename the estimate input and add the revision inputs** — in the plan summary panel, replace the "Chosen estimate" input block:

```heex
            <div>
              <.input
                name="plan[estimate]"
                id="plan_estimate"
                type="number"
                step="0.01"
                min="0"
                label={gettext("Chosen estimate")}
                value={Decimal.to_string(@chosen)}
              />
            </div>
```

with:

```heex
            <div>
              <.input
                name="plan[estimate]"
                id="plan_estimate"
                type="number"
                step="0.01"
                min="0"
                label={gettext("Original estimate")}
                value={Decimal.to_string(@original)}
              />
            </div>
```

Directly below the closing `</div>` of that `grid grid-cols-2 md:grid-cols-5` block (still inside the amber panel div), add:

```heex
          <div class="grid grid-cols-3 gap-3 items-end mt-2">
            <div :for={r <- FullCircle.Tax.revision_months()}>
              <.input
                name={"plan[revisions][#{r}]"}
                id={"plan_revision_#{r}"}
                type="number"
                step="0.01"
                min="0"
                label={gettext("CP204A @ month %{m}", m: r)}
                value={Map.get(@plan.revisions || %{}, "#{r}")}
              />
            </div>
          </div>
          <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
            {gettext("Enter the revised annual estimate (not the monthly instalment). Blank = not revised. Instalments re-spread from the revision month.")}
          </p>
```

- [ ] **Step 3: Delegate the badge helper** — replace:

```elixir
  # LHDN allows CP204 revision (Form CP204A) in the 6th, 9th and — permanently
  # from YA 2024 (s.107C amendment) — 11th month of the basis period.
  defp revision_month?(month_no), do: month_no in [6, 9, 11]
```

with:

```elixir
  defp revision_month?(month_no), do: month_no in FullCircle.Tax.revision_months()
```

Also update the table footnote text from
`"The CP204 estimate can be revised (Form CP204A) in the 6th, 9th and 11th month of the basis period — marked above."` to:

```
"The CP204 estimate can be revised (Form CP204A) in the 6th, 9th and 11th month of the basis period — marked above. Enter revisions in the CP204A fields; instalments re-spread from that month."
```

- [ ] **Step 4: Compile and verify the live path end-to-end** via tidewave `project_eval`, simulating `plan_changed` params:

Run: `mix compile --warnings-as-errors`
Then eval (tidewave `project_eval`):

```elixir
params = %{
  "fy_year" => "2026", "estimate_month" => "1", "estimate" => "8500", "tolerance_pct" => "30",
  "revisions" => %{"6" => "5000", "9" => "", "11" => "", "_unused_6" => ""},
  "paid_overrides" => %{}
}

plan =
  %FullCircle.Tax.InstalmentPlan{}
  |> FullCircle.Tax.InstalmentPlan.changeset(params)
  |> Ecto.Changeset.apply_changes()

FullCircle.Tax.schedule(plan, %{closing_month: 12, closing_day: 31})
|> Enum.map(&{&1.month_no, Decimal.round(&1.instalment_due, 2) |> Decimal.to_string()})
```

Expected: months 1–5 → `"708.33"`, months 6–12 → `"208.33"`.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex
git commit -m "feat(report): CP204A revision inputs in the P&L forecast tax plan"
```

---

### Task 6: Revise button fills the next open CP204A window

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex` (`handle_event("revise_plan", ...)`)

**Interfaces:**
- Consumes: `FullCircle.Tax.revision_months/0`, `current_fy_month/3`, `suggested_estimate/2`, `forecast_annual_tax/3`, `create_or_update_plan/3`.
- Produces: Revise writes `plan.revisions["6"|"9"|"11"]` and never touches `estimate`/`estimate_month`.

- [ ] **Step 1: Replace the handler** — replace the entire `handle_event("revise_plan", ...)` clause with:

```elixir
  @impl true
  def handle_event("revise_plan", _params, socket) do
    # Revise fills the NEXT open CP204A window (6/9/11) at/after the as-of
    # month with the forecast-suggested estimate, then saves. It works off the
    # on-screen plan (kept live by "plan_changed") and never touches the
    # original estimate/estimate_month.
    com = socket.assigns.current_company
    fy_year = safe_int(socket.assigns.search.fy_year, default_fy_year(com))

    as_of =
      case Date.from_iso8601(to_string(socket.assigns.search.as_of)) do
        {:ok, date} -> date
        _ -> Date.utc_today()
      end

    cur = FullCircle.Tax.current_fy_month(com, fy_year, as_of)

    case Enum.find(FullCircle.Tax.revision_months(), &(&1 >= cur)) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("No CP204A window left this year."))}

      window ->
        plan = socket.assigns.plan
        tol = plan.tolerance_pct || Decimal.new(30)
        forecast_tax = FullCircle.Tax.forecast_annual_tax(com, fy_year, as_of)
        suggested = FullCircle.Tax.suggested_estimate(forecast_tax, tol)

        attrs = %{
          "fy_year" => fy_year,
          "tolerance_pct" => Decimal.to_string(tol),
          "estimate" => Decimal.to_string(plan.estimate || Decimal.new(0)),
          "estimate_month" => plan.estimate_month || 1,
          "paid_overrides" => plan.paid_overrides || %{},
          "revisions" =>
            Map.put(plan.revisions || %{}, "#{window}", Decimal.to_string(suggested))
        }

        case FullCircle.Tax.create_or_update_plan(attrs, com, socket.assigns.current_user) do
          {:ok, plan} ->
            {:noreply,
             assign(socket, plan: plan, plan_schedule: FullCircle.Tax.schedule(plan, com))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not revise the estimate."))}
        end
    end
  end
```

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Verify window selection logic** via tidewave `project_eval`:

```elixir
com = %{closing_month: 12, closing_day: 31}

for {date, want} <- [
      {~D[2026-03-10], 6},
      {~D[2026-06-15], 6},
      {~D[2026-07-01], 9},
      {~D[2026-10-05], 11},
      {~D[2026-12-01], nil}
    ] do
  cur = FullCircle.Tax.current_fy_month(com, 2026, date)
  got = Enum.find(FullCircle.Tax.revision_months(), &(&1 >= cur))
  {date, got == want}
end
```

Expected: all `true`.

- [ ] **Step 4: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex
git commit -m "feat(report): Revise fills the next open CP204A window"
```

---

### Task 7: 85% prior-year floor warning

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex` (`mount`, `handle_params`, `tax_plan_section`)

**Interfaces:**
- Consumes: `FullCircle.Tax.get_plan/2`, `latest_estimate/1`.
- Produces: assign `@prior_latest :: Decimal.t() | nil`; warn-only banner in the plan section.

- [ ] **Step 1: Load the prior-year latest estimate** — in `mount/3`'s `assign` list add `prior_latest: nil,`. In `handle_params/3`, right after the `plan = ...` binding, add:

```elixir
    prior_plan = FullCircle.Tax.get_plan(com, fy_year - 1)
    prior_latest = prior_plan && FullCircle.Tax.latest_estimate(prior_plan)
```

and add `prior_latest: prior_latest` to that function's `assign(...)` call.

- [ ] **Step 2: Pass into the section** — at the `<.tax_plan_section` call site add `prior_latest={@prior_latest}`, and in `tax_plan_section`'s attrs add:

```elixir
  attr :prior_latest, :any, default: nil
```

In the function body (after `chosen`), compute:

```elixir
    floor =
      if assigns.prior_latest && Decimal.compare(assigns.prior_latest, Decimal.new(0)) == :gt,
        do: Decimal.mult(assigns.prior_latest, Decimal.new("0.85")),
        else: nil

    floor_breach? =
      floor != nil and assigns.plan.estimate != nil and
        Decimal.compare(assigns.plan.estimate, Decimal.new(0)) == :gt and
        Decimal.compare(assigns.plan.estimate, floor) == :lt
```

and add `floor: floor, floor_breach?: floor_breach?,` to the `assign(assigns, ...)` call.

- [ ] **Step 3: Banner markup** — directly above the existing position banner (`<%!-- Estimate position banner --%>`), add:

```heex
      <%!-- s.107C(3): estimate must be >= 85% of last year's latest estimate --%>
      <div
        :if={@floor_breach?}
        class="mb-3 rounded border border-amber-400 bg-amber-50 dark:bg-amber-950/30 dark:border-amber-700 px-3 py-2 text-sm"
      >
        <p class="font-semibold">{gettext("Below the 85% floor (s.107C(3))")}</p>
        <p class="mt-1">
          {gettext("Original estimate")}
          <span class="font-mono font-semibold">{plan_money(@plan.estimate)}</span>
          {gettext("is below 85% of last year's latest estimate")}
          <span class="font-mono">{plan_money(@prior_latest)}</span>
          — {gettext("floor")}
          <span class="font-mono font-semibold">{plan_money(@floor)}</span>.
          {gettext("File at least the floor and revise down at the 6th month (CP204A), or appeal to LHDN.")}
        </p>
      </div>
```

- [ ] **Step 4: Compile and verify** —

Run: `mix compile --warnings-as-errors`
Then tidewave `project_eval` sanity check of the floor math:

```elixir
prior = %FullCircle.Tax.InstalmentPlan{estimate: Decimal.new(10000), revisions: %{}}
latest = FullCircle.Tax.latest_estimate(prior)
floor = Decimal.mult(latest, Decimal.new("0.85"))
{Decimal.to_string(floor), Decimal.compare(Decimal.new(5000), floor) == :lt}
```

Expected: `{"8500.00", true}` (or `{"8500", true}` depending on normalization — the comparison must be `true`).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex
git commit -m "feat(report): warn when the CP204 estimate breaches the 85% prior-year floor"
```

---

### Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Full tax + remedy suite**

Run: `mix test test/full_circle/tax_test.exs test/full_circle/tax/remedy_test.exs`
Expected: 0 failures.

- [ ] **Step 2: Whole-project compile + broader tests**

Run: `mix compile --warnings-as-errors && mix test`
Expected: only the 2 known pre-existing `pay_run_test` failures.

- [ ] **Step 3: End-to-end advice-table scenario** via tidewave `project_eval` — original 8,500 filed, revision 5,000 at month 6, paid entered for months 1–5:

```elixir
params = %{
  "fy_year" => "2026", "estimate_month" => "1", "estimate" => "8500", "tolerance_pct" => "30",
  "revisions" => %{"6" => "5000"},
  "paid_overrides" => %{"1" => "708.33", "2" => "708.33", "3" => "708.33", "4" => "708.33", "5" => "708.33"}
}

plan =
  %FullCircle.Tax.InstalmentPlan{}
  |> FullCircle.Tax.InstalmentPlan.changeset(params)
  |> Ecto.Changeset.apply_changes()

FullCircle.Tax.schedule(plan, %{closing_month: 12, closing_day: 31})
|> Enum.map(&{&1.month_no, Decimal.round(&1.instalment_due, 2) |> Decimal.to_string(),
              Decimal.round(&1.balance, 2) |> Decimal.to_string()})
```

Expected: months 1–5 due `"0.00"` (settled) with balance falling from `7791.67`; months 6–12 due `"208.33"` with month-6 balance `1458.35` (5,000 − 3,541.65) and year-end balance ≈ `1458.35` (paid stops at month 5 in this sim).

- [ ] **Step 4: Browser check (user)** — load the report in dev, confirm the three CP204A inputs recompute the table live, Revise fills the correct slot, and the floor banner reads correctly in light and dark themes.
