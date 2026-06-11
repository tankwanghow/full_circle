# P&L Forecast Flat-Rate Tax Estimation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, per-company flat-rate income-tax estimate to the P&L forecast, showing "Estimated Tax" and "Net Profit After Tax" rows, and remove the "Cumulative (YTD)" row.

**Architecture:** A new `pl_forecast_tax_rate` percent in `company.settings` drives a pure `apply_tax/3` step in `FullCircle.Reporting.ProfitLossForecast` that augments each period and the totals map with tax figures. The two LiveViews (interactive + print) render the new rows only when the rate is > 0, and the existing "Trailing" settings modal gains a tax-rate input saved through the same path.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, Decimal, ExUnit.

---

## File Structure

- **Modify** `lib/full_circle/reporting/profit_loss_forecast.ex`
  - Add `tax_rate/1`, `save_tax_rate/2` settings helpers.
  - Add pure `apply_tax/3`; wire it into `pl_forecast/2`; echo `tax_rate` into the result.
  - Remove `cumulative_net` plumbing from `build_periods/2`.
- **Modify** `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`
  - Drop the cumulative row; add the two tax rows (rate-gated); add tax-rate input to the settings modal; extend `save_settings`.
- **Modify** `lib/full_circle_web/live/report_live/profit_loss_forecast_print.ex`
  - Drop the cumulative row; add the two tax rows (rate-gated).
- **Modify** `test/full_circle/reporting/profit_loss_forecast_test.exs`
  - Update `build_periods` tests (no `cumulative_net`); add `apply_tax/3` and `tax_rate`/`save_tax_rate` tests.
- **Modify** `test/full_circle_web/live/profit_loss_forecast_live_test.exs`
  - Assert tax rows hidden at rate 0, shown at rate > 0.

---

## Task 1: Settings helpers — `tax_rate/1` and `save_tax_rate/2`

**Files:**
- Modify: `lib/full_circle/reporting/profit_loss_forecast.ex`
- Test: `test/full_circle/reporting/profit_loss_forecast_test.exs`

- [ ] **Step 1: Write failing unit tests for `tax_rate/1`**

Add this `describe` block inside the existing pure-test module `FullCircle.Reporting.ProfitLossForecastTest` (the one that does NOT use DataCase), after the existing `describe "build_periods/2"` block:

```elixir
  describe "tax_rate/1" do
    test "defaults to 0 when unset" do
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: nil}), d(0))
    end

    test "reads a saved numeric or string rate" do
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => 24}}), d(24))
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => "17.5"}}), d("17.5"))
    end

    test "blank, invalid or negative becomes 0" do
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => ""}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => "abc"}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => -5}}), d(0))
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs:1`
(Or run the file; the new `describe` will error with `UndefinedFunctionError` for `PLF.tax_rate/1`.)
Expected: FAIL — `function FullCircle.Reporting.ProfitLossForecast.tax_rate/1 is undefined`.

- [ ] **Step 3: Implement `tax_rate/1` and `save_tax_rate/2`**

In `lib/full_circle/reporting/profit_loss_forecast.ex`, add a module attribute next to `@trailing_key` (around line 36):

```elixir
  @tax_rate_key "pl_forecast_tax_rate"
```

Add these functions in the "company settings" section (after `save_category_trailing/2`, before `company_with_settings/1`):

```elixir
  @doc "Flat income-tax rate (percent) for the forecast, from company settings. 0 when unset/invalid."
  def tax_rate(com) do
    (com.settings || %{})
    |> Map.get(@tax_rate_key)
    |> to_non_neg_decimal()
  end

  @doc "Persist the flat tax-rate percent to settings (blank/invalid/negative -> 0)."
  def save_tax_rate(com, value) do
    rate = to_non_neg_decimal(value)
    settings = Map.put(com.settings || %{}, @tax_rate_key, Decimal.to_string(rate))
    com |> Ecto.Changeset.change(settings: settings) |> Repo.update()
  end

  defp to_non_neg_decimal(nil), do: @zero
  defp to_non_neg_decimal(%Decimal{} = d), do: if(Decimal.compare(d, @zero) == :lt, do: @zero, else: d)
  defp to_non_neg_decimal(n) when is_integer(n) or is_float(n), do: to_non_neg_decimal(Decimal.new("#{n}"))

  defp to_non_neg_decimal(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {d, ""} -> to_non_neg_decimal(d)
      _ -> @zero
    end
  end

  defp to_non_neg_decimal(_), do: @zero
```

- [ ] **Step 4: Run the unit tests to verify they pass**

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs`
Expected: the `tax_rate/1` tests PASS (the build_periods tests still pass for now).

- [ ] **Step 5: Add and run a DB test for `save_tax_rate/2` round-trip**

In the same test file, inside the `FullCircle.Reporting.ProfitLossForecastDBTest` module (the one that `use FullCircle.DataCase`), add:

```elixir
  describe "save_tax_rate/2 and tax_rate/1" do
    test "round-trips through settings", %{com: com} do
      assert Decimal.equal?(PLF.tax_rate(com), d(0))
      {:ok, _} = PLF.save_tax_rate(com, "24")
      com = PLF.company_with_settings(com)
      assert Decimal.equal?(PLF.tax_rate(com), d(24))

      {:ok, _} = PLF.save_tax_rate(com, "")
      com = PLF.company_with_settings(com)
      assert Decimal.equal?(PLF.tax_rate(com), d(0))
    end
  end
```

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle/reporting/profit_loss_forecast.ex test/full_circle/reporting/profit_loss_forecast_test.exs
git commit -m "feat: P&L forecast flat tax-rate settings helpers"
```

---

## Task 2: Pure `apply_tax/3` + remove cumulative from `build_periods/2`

**Files:**
- Modify: `lib/full_circle/reporting/profit_loss_forecast.ex`
- Test: `test/full_circle/reporting/profit_loss_forecast_test.exs`

- [ ] **Step 1: Update the existing `build_periods/2` tests to drop `cumulative_net`**

In `test/full_circle/reporting/profit_loss_forecast_test.exs`, the `describe "build_periods/2"` block currently asserts `cumulative_net`. Remove those two assertion lines so the test no longer references the removed field:

Delete this line from the first test:
```elixir
      assert Decimal.equal?(p1.cumulative_net, d(500))
```
And delete this line:
```elixir
      assert Decimal.equal?(p2.cumulative_net, d(800))      # running 500 + 300
```

- [ ] **Step 2: Write failing tests for `apply_tax/3`**

Add a new `describe` block in the pure-test module `FullCircle.Reporting.ProfitLossForecastTest`:

```elixir
  describe "apply_tax/3" do
    defp periods(nets), do: Enum.map(nets, fn n -> %{net_profit: d(n)} end)
    defp totals(net), do: %{net_profit: d(net)}

    test "rate 0 -> zero tax, after-tax equals net" do
      {ps, ts} = PLF.apply_tax(periods([600, 400]), totals(1000), d(0))
      assert Decimal.equal?(ts.estimated_tax, d(0))
      assert Decimal.equal?(ts.net_profit_after_tax, d(1000))
      assert Enum.all?(ps, &Decimal.equal?(&1.estimated_tax, d(0)))
      assert Decimal.equal?(hd(ps).net_profit_after_tax, d(600))
    end

    test "flat 24% on a profitable year; per-period tax sums to the total" do
      {ps, ts} = PLF.apply_tax(periods([600, 400]), totals(1000), d(24))
      assert Decimal.equal?(ts.estimated_tax, d(240))
      assert Decimal.equal?(ts.net_profit_after_tax, d(760))
      [p1, p2] = ps
      assert Decimal.equal?(p1.estimated_tax, d(144))         # 600 * 0.24
      assert Decimal.equal?(p2.estimated_tax, d(96))          # 400 * 0.24
      assert Decimal.equal?(p1.net_profit_after_tax, d(456))
      sum = Decimal.add(p1.estimated_tax, p2.estimated_tax)
      assert Decimal.equal?(sum, ts.estimated_tax)
    end

    test "annual loss -> zero tax, after-tax equals net" do
      {ps, ts} = PLF.apply_tax(periods([-300, -100]), totals(-400), d(24))
      assert Decimal.equal?(ts.estimated_tax, d(0))
      assert Decimal.equal?(ts.net_profit_after_tax, d(-400))
      assert Enum.all?(ps, &Decimal.equal?(&1.estimated_tax, d(0)))
    end
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs`
Expected: FAIL — `function FullCircle.Reporting.ProfitLossForecast.apply_tax/3 is undefined`.

- [ ] **Step 4: Remove `cumulative_net` from `build_periods/2`**

In `lib/full_circle/reporting/profit_loss_forecast.ex`, replace the current `build_periods/2` (the `map_reduce` over `@zero` that adds `cumulative_net`) with a plain `map`:

```elixir
  @doc "Build the per-period P&L line rows (with subtotals and margins) — pure."
  def build_periods(bounds, by_type) do
    Enum.zip(bounds, by_type)
    |> Enum.with_index(1)
    |> Enum.map(fn {{{ps, pe}, {bt, src}}, idx} ->
      l = lines(bt)

      Map.merge(l, %{
        n: idx,
        period_start: ps,
        period_end: pe,
        source: src,
        gross_margin: margin(l.gross_profit, l.revenue),
        net_margin: margin(l.net_profit, l.revenue)
      })
    end)
  end
```

- [ ] **Step 5: Implement `apply_tax/3` and wire it into `pl_forecast/2`**

Add the pure function in the "internals" section (e.g. after `totals/1`):

```elixir
  @doc """
  Augment each period and the totals map with `:estimated_tax` and
  `:net_profit_after_tax`, using a flat `rate` (percent). Tax is charged on the
  full-year net profit (loss => 0); per-period tax is allocated by the effective
  rate so the per-period figures sum to the annual total. Pure.
  """
  def apply_tax(periods, totals, %Decimal{} = rate) do
    net = totals.net_profit
    tax_total = Decimal.mult(max_zero(net), Decimal.div(rate, Decimal.new(100)))

    eff =
      if Decimal.compare(net, @zero) == :gt, do: Decimal.div(tax_total, net), else: @zero

    periods =
      Enum.map(periods, fn p ->
        tax = Decimal.mult(p.net_profit, eff)
        Map.merge(p, %{estimated_tax: tax, net_profit_after_tax: Decimal.sub(p.net_profit, tax)})
      end)

    totals =
      Map.merge(totals, %{
        estimated_tax: tax_total,
        net_profit_after_tax: Decimal.sub(net, tax_total)
      })

    {periods, totals}
  end

  defp max_zero(d), do: if(Decimal.compare(d, @zero) == :lt, do: @zero, else: d)
```

Then in `pl_forecast/2`, replace the tail that builds `periods` and the result map. Currently:

```elixir
    periods = build_periods(bounds, by_type)

    %{
      fy_year: fy_year,
      ...
      periods: periods,
      totals: totals(periods)
    }
```

becomes:

```elixir
    periods = build_periods(bounds, by_type)
    rate = tax_rate(com)
    {periods, totals} = apply_tax(periods, totals(periods), rate)

    %{
      fy_year: fy_year,
      ...
      periods: periods,
      totals: totals,
      tax_rate: rate
    }
```

(Keep all the existing keys between `fy_year:` and `periods:` unchanged — only `periods`/`totals` wiring changes and `tax_rate:` is added.)

- [ ] **Step 6: Run the full forecast test file**

Run: `mix test test/full_circle/reporting/profit_loss_forecast_test.exs`
Expected: PASS (build_periods, apply_tax, settings, and DB tests).

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle/reporting/profit_loss_forecast.ex test/full_circle/reporting/profit_loss_forecast_test.exs
git commit -m "feat: compute flat tax estimate in P&L forecast; drop cumulative line"
```

---

## Task 3: Interactive LiveView — rows, gating, settings input

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`
- Test: `test/full_circle_web/live/profit_loss_forecast_live_test.exs`

- [ ] **Step 1: Write a failing LiveView test for row visibility**

Open `test/full_circle_web/live/profit_loss_forecast_live_test.exs` and add a test that drives the settings modal. Use the existing setup in that file (it already logs in and navigates to the report). Add inside the main `describe`:

```elixir
    test "tax rows hidden at rate 0, shown after setting a rate", %{conn: conn, com: com} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/profit_loss_forecast")
      refute html =~ "Net Profit After Tax"

      lv |> element("button", "Trailing") |> render_click()

      lv
      |> form("form[phx-submit=save_settings]", %{"tax_rate" => "24"})
      |> render_submit()

      assert render(lv) =~ "Net Profit After Tax"
      assert render(lv) =~ "Estimated Tax"
    end
```

NOTE: match the variable names/assigns the existing tests in this file use (e.g. how `com` and login are set up). If the file's tests reference the company differently, mirror that exact pattern.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs`
Expected: FAIL — "Net Profit After Tax" is not present (and/or the form lacks a `tax_rate` field).

- [ ] **Step 3: Update the `@rows` list**

In `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`, replace the tail of `@rows` (the `Net Profit`, `Net Margin %`, `Cumulative (YTD)` entries, lines ~18-20) with:

```elixir
    %{label: "Net Profit", key: :net_profit, kind: :subtotal},
    %{label: "Net Margin %", key: :net_margin, kind: :margin},
    %{label: "Estimated Tax", key: :estimated_tax, kind: :tax},
    %{label: "Net Profit After Tax", key: :net_profit_after_tax, kind: :tax}
```

- [ ] **Step 4: Gate and label the tax rows in `pl_table/1`**

The `pl_table` component receives `@rows`. Pass the forecast's `tax_rate` so it can filter and label. Update the call site in `render/1` (around line 200):

```elixir
            <.pl_table rows={@rows} periods={f.periods} totals={f.totals}
              estimated={f.estimated_types} tax_rate={f.tax_rate} />
```

Add the attr and filtering to `pl_table/1`. Add near the other `attr` declarations:

```elixir
  attr :tax_rate, :any, default: nil
```

At the top of the `pl_table/1` function body (before `~H`), compute the visible rows:

```elixir
  defp pl_table(assigns) do
    assigns = assign(assigns, :rows, visible_rows(assigns.rows, assigns.tax_rate))

    ~H"""
```

Add the helper and a rate-aware label:

```elixir
  defp visible_rows(rows, tax_rate) do
    if tax_positive?(tax_rate),
      do: rows,
      else: Enum.reject(rows, &(&1.kind == :tax))
  end

  defp tax_positive?(%Decimal{} = r), do: Decimal.compare(r, Decimal.new(0)) == :gt
  defp tax_positive?(_), do: false

  defp row_label(%{key: :estimated_tax}, tax_rate), do: "Estimated Tax (#{rate_label(tax_rate)}%)"
  defp row_label(row, _tax_rate), do: row.label

  defp rate_label(%Decimal{} = r), do: r |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp rate_label(_), do: "0"
```

In the table body, the label cell currently renders `{row.label}`. Replace that with the rate-aware label (pass `@tax_rate`):

```elixir
            <td class={["text-left px-2 sticky left-0", row_label_bg(row)]}>
              {row_label(row, @tax_rate)}<span :if={Map.get(row, :type) in @estimated} class="text-amber-600 dark:text-amber-400">*</span>
            </td>
```

- [ ] **Step 5: Remove dead cumulative styling/handling**

In the same file:
- In `row_class/1`, delete the `%{kind: :cumulative}` clause; add a `:tax` clause so tax rows are styled like subtotals:

```elixir
  defp row_class(%{kind: :subtotal}), do: "font-bold bg-gray-50 dark:bg-gray-800/60"
  defp row_class(%{kind: :tax}), do: "font-bold bg-amber-50 dark:bg-amber-900/30"
  defp row_class(%{kind: :margin}), do: "italic text-gray-600 dark:text-gray-400"
  defp row_class(_), do: "odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900"
```

- In `row_label_bg/1`, delete the `%{kind: :cumulative}` clause and add `:tax`:

```elixir
  defp row_label_bg(%{kind: :subtotal}), do: "bg-gray-50 dark:bg-gray-800"
  defp row_label_bg(%{kind: :tax}), do: "bg-amber-50 dark:bg-amber-900"
  defp row_label_bg(_), do: "bg-white dark:bg-gray-900"
```

- Delete the `total_cell/3` cumulative clause entirely:

```elixir
  defp total_cell(_totals, periods, %{kind: :cumulative}) do
    case List.last(periods) do
      nil -> compact(Decimal.new(0))
      p -> compact(p.cumulative_net)
    end
  end
```

(The remaining `total_cell/3` clauses for `:margin` and the generic key handle the tax rows via the generic `compact` path.)

- [ ] **Step 6: Add the tax-rate input to the settings modal and extend `save_settings`**

In `settings_modal/1`, after the trailing-days grid `</div>` and before the buttons row, add:

```elixir
          <div class="mt-4">
            <label class="text-sm font-medium" for="tax_rate">{gettext("Estimated tax rate %")}</label>
            <input type="number" min="0" step="0.01" id="tax_rate" name="tax_rate"
              value={Decimal.to_string(@tax_rate)}
              class="border rounded px-2 py-1 w-full dark:bg-gray-700 dark:border-gray-600" />
            <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
              {gettext("Flat percentage of forecast net profit — a planning estimate, not a tax computation. 0 hides the tax rows.")}
            </p>
          </div>
```

Add `attr :tax_rate, :any, required: true` to `settings_modal/1`, and pass it from `render/1`:

```elixir
    <.settings_modal :if={@settings_open} trailing={@trailing} tax_rate={@tax_rate} />
```

In `mount/1`, add `tax_rate: Decimal.new(0)` to the initial assigns (next to `trailing: %{}`).

In `handle_event("open_settings", ...)`, also assign the current rate:

```elixir
  def handle_event("open_settings", _params, socket) do
    {:noreply,
     assign(socket,
       settings_open: true,
       trailing: PLF.category_trailing(socket.assigns.current_company),
       tax_rate: PLF.tax_rate(socket.assigns.current_company)
     )}
  end
```

Update `handle_event("save_settings", ...)` to capture and persist both the trailing map and the tax rate:

```elixir
  def handle_event("save_settings", %{"trailing" => trailing} = params, socket) do
    com = socket.assigns.current_company
    {:ok, _} = PLF.save_category_trailing(com, trailing)
    {:ok, _} = PLF.save_tax_rate(com, params["tax_rate"])
    com = PLF.company_with_settings(com)

    {:noreply,
     socket
     |> assign(current_company: com, settings_open: false)
     |> run_forecast(socket.assigns.search)}
  end
```

- [ ] **Step 7: Run the LiveView test**

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs`
Expected: PASS.

- [ ] **Step 8: Compile-check and commit**

Run: `mix compile --warnings-as-errors`
Expected: no warnings (confirms no dead references to `cumulative_net` remain).

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex test/full_circle_web/live/profit_loss_forecast_live_test.exs
git commit -m "feat: P&L forecast tax rows + tax-rate setting; remove cumulative row"
```

---

## Task 4: Print view — same rows, rate-gated

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast_print.ex`

- [ ] **Step 1: Update the `@rows` list**

In `lib/full_circle_web/live/report_live/profit_loss_forecast_print.ex`, replace the `Net Profit` / `Net Margin %` / `Cumulative (YTD)` entries at the end of `@rows` with:

```elixir
    %{label: "Net Profit", key: :net_profit, kind: :subtotal},
    %{label: "Net Margin %", key: :net_margin, kind: :margin},
    %{label: "Estimated Tax", key: :estimated_tax, kind: :tax},
    %{label: "Net Profit After Tax", key: :net_profit_after_tax, kind: :tax}
```

- [ ] **Step 2: Filter rows by tax rate in `mount/1`**

The print view assigns `rows: @rows` directly. Change it to filter against the forecast's `tax_rate`. Replace the `assign(... rows: @rows ...)` in `mount/1` with:

```elixir
    rows =
      if Decimal.compare(forecast.tax_rate, Decimal.new(0)) == :gt,
        do: @rows,
        else: Enum.reject(@rows, &(&1.kind == :tax))

    {:ok,
     socket
     |> assign(page_title: gettext("Profit & Loss Forecast"), rows: rows, forecast: forecast)}
```

- [ ] **Step 3: Remove the dead cumulative `total_cell` clause and add tax styling**

Delete this clause from the print view:

```elixir
  defp total_cell(_t, periods, %{kind: :cumulative}) do
    case List.last(periods) do
      nil -> money(Decimal.new(0))
      p -> money(p.cumulative_net)
    end
  end
```

In `style/1`, replace the `tr.cumulative` CSS rule with a `tr.tax` rule:

```elixir
      table.pl tr.tax td { font-weight: bold; background: #fff7e6; }
```

(The generic `total_cell/3` and `cell/2` clauses already handle `:tax` rows via `money/1`.)

- [ ] **Step 4: Compile-check**

Run: `mix compile --warnings-as-errors`
Expected: no warnings, no reference to `cumulative_net`.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast_print.ex
git commit -m "feat: P&L forecast print view tax rows; remove cumulative row"
```

---

## Task 5: Full suite + manual smoke check

**Files:** none (verification only)

- [ ] **Step 1: Run the full forecast-related test set**

Run:
```bash
mix test test/full_circle/reporting/profit_loss_forecast_test.exs test/full_circle_web/live/profit_loss_forecast_live_test.exs
```
Expected: all PASS.

- [ ] **Step 2: Run the whole suite to catch regressions**

Run: `mix test`
Expected: PASS (no other report depended on `cumulative_net`; if any did, the failure points to it — fix by removing that reference).

- [ ] **Step 3: Credo**

Run: `mix credo lib/full_circle/reporting/profit_loss_forecast.ex lib/full_circle_web/live/report_live/profit_loss_forecast.ex lib/full_circle_web/live/report_live/profit_loss_forecast_print.ex`
Expected: no new issues.

- [ ] **Step 4: Manual smoke (optional but recommended)**

Start the server, open a company's P&L forecast, confirm: no Cumulative row; open "Trailing", set tax rate to 24, save; confirm "Estimated Tax (24%)" and "Net Profit After Tax" rows appear and that the print view matches. Set rate back to 0 and confirm rows disappear. Verify in both light and dark themes (amber tax rows must read well in both).

---

## Self-Review Notes

- **Spec coverage:** settings key + default 0 (Task 1); computation/loss-floor/effective-rate + cumulative removal (Task 2); display rows + gating + settings UI (Task 3); print view (Task 4); testing (Tasks 1, 2, 3, 5). All spec sections covered.
- **Type consistency:** result keys `:estimated_tax`, `:net_profit_after_tax`, `:tax_rate` used consistently across context, both views, and tests; row `kind: :tax` consistent across both views' `@rows`, `row_class`, `row_label_bg`, and CSS.
- **Dark/light:** amber tints chosen for tax rows in both views per the project's two-theme rule.
