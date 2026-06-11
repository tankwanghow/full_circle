# Merge CP204 Planner into the P&L Forecast Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the CP204 instalment planner as a section below the P&L forecast table on the forecast page (reusing the already-computed forecast tax and shared fy_year/as_of), and remove the standalone `/tax_instalment_plan` page.

**Architecture:** The planner UI moves into `FullCircleWeb.ReportLive.ProfitLossForecast` as a function component + `save_plan`/`revise_plan` handlers; all computation stays in `FullCircle.Tax`. The planner reads the forecast's `totals.estimated_tax` (no second `pl_forecast` run for display). The standalone LiveView, route, and menu link are deleted. The print view is unaffected (separate module, no planner).

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, Decimal, ExUnit.

---

## Key facts (read these files first)
- `lib/full_circle_web/live/report_live/profit_loss_forecast.ex` — target page. Has `mount/3` (assigns page_title, current_company, rows, drill, settings_open, trailing, tax_rate); `handle_params/3` (builds `@search` = %{fy_year, granularity, as_of} and calls `run_forecast/2` → `assign_async(:result, ...)`); `handle_event` for "query","drill","close_drill","open_settings","close_settings","save_settings"; `render/1` with a search form, `<.async_html result={@result}>` whose `<:result_html>` renders the financial-year line + `<.pl_table .../>`, then `drill_modal` + `settings_modal`. The forecast result map has `totals.estimated_tax` (Decimal, 0 when tax_rate 0) and `tax_rate`.
- `lib/full_circle_web/live/tax_live/instalment_plan.ex` — the standalone planner being removed. SOURCE of the planner markup + save/revise logic to port (read its `load/3`, `render/1`, `handle_event("save"/"revise"/"validate")`, `money/1`). Note its account-picker is already gone (manual paid only).
- `lib/full_circle/tax.ex` — context (UNCHANGED by this plan): `get_plan/2`, `create_or_update_plan/3`, `suggested_estimate/2`, `under_estimated?/3`, `build_schedule/4`, `schedule/2`, `current_fy_month/3`, `paid_by_month/1`, `forecast_annual_tax/3`.
- `lib/full_circle_web/router.ex` — has `live("/tax_instalment_plan", TaxLive.InstalmentPlan, :index)` (~line 229, added next to profit_loss_forecast).
- `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` — has the admin-gated "Tax Instalment Plan" link.
- `test/full_circle_web/live/tax_instalment_plan_live_test.exs` — the standalone page's tests (to delete; port the meaningful ones).
- `test/full_circle_web/live/profit_loss_forecast_live_test.exs` — where new planner tests go.

---

## Task 1: Embed the planner section into the forecast LiveView

**Files:**
- Modify: `lib/full_circle_web/live/report_live/profit_loss_forecast.ex`
- Test: `test/full_circle_web/live/profit_loss_forecast_live_test.exs`

- [ ] **Step 1: Add an admin mount guard + write a failing test**

The forecast page will now WRITE (save plans), so guard it. Its menu link is already admin-only (commit 5e3c497); this closes the direct-URL gap. In `mount/3`, before the existing assigns, add:
```elixir
    if socket.assigns[:current_role] != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Not authorized."))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}")}
    else
      # ... existing mount body returning {:ok, assign(socket, ...)}
    end
```
Confirm `@current_role` is assigned to this LiveView (it is, via the `ActiveCompany` on_mount hook — verify by reading `lib/full_circle_web/active_company.ex`). Add a failing test to `profit_loss_forecast_live_test.exs` asserting a non-admin (clerk) is redirected. Use `Sys.allow_user_to_access(com, second_user, "clerk", admin)` and the same login helper the file already uses; mirror the non-admin test in the (about-to-be-deleted) `tax_instalment_plan_live_test.exs`.

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs` → the non-admin test FAILS (no guard yet).

- [ ] **Step 2: Implement the guard, run the test**

Add the guard as above. Run the test → the non-admin redirect test PASSES, existing forecast tests still PASS (their setup logs in an admin — confirm; if any used a non-admin they'd now redirect, but the forecast tests use the company creator = admin).

- [ ] **Step 3: Load the plan in handle_params**

In `handle_params/3`, after computing `@search`, also load the plan and schedule (sync — neither needs the forecast). Add to the assigns pipeline:
```elixir
    com = socket.assigns.current_company
    fy_year = safe_int(search.fy_year, default_fy_year(com))
    as_of = parse_date(search.as_of)   # reuse the same parse the page already does

    plan =
      FullCircle.Tax.get_plan(com, fy_year) ||
        %FullCircle.Tax.InstalmentPlan{
          fy_year: fy_year,
          estimate_month: FullCircle.Tax.current_fy_month(com, fy_year, as_of)
        }

    socket =
      socket
      |> assign(search: search, plan: plan, plan_schedule: FullCircle.Tax.schedule_for(plan, com))
      |> run_forecast(search)
```
where `schedule_for/2` handles an unsaved (id nil) plan. Since `Tax.schedule/2` pattern-matches `%InstalmentPlan{}` and calls `paid_by_month/1` (reads `paid_overrides`, defaults `%{}`) it already works for an unsaved struct — so just call `FullCircle.Tax.schedule(plan, com)` directly (no new function needed). Use that. Keep the existing `run_forecast` call.

(Read the file's actual `handle_params` to merge these assigns cleanly with the existing `assign(search: search)`.)

- [ ] **Step 4: Add `save_plan` and `revise_plan` handlers**

Port from the standalone planner, renamed to avoid clashing with `save_settings`:
```elixir
  @impl true
  def handle_event("save_plan", %{"plan" => params}, socket) do
    com = socket.assigns.current_company

    case FullCircle.Tax.create_or_update_plan(params, com, socket.assigns.current_user) do
      {:ok, plan} ->
        {:noreply, assign(socket, plan: plan, plan_schedule: FullCircle.Tax.schedule(plan, com))}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the tax plan."))}
    end
  end

  @impl true
  def handle_event("revise_plan", _params, socket) do
    com = socket.assigns.current_company
    fy_year = safe_int(socket.assigns.search.fy_year, default_fy_year(com))
    as_of = parse_date(socket.assigns.search.as_of)
    plan = socket.assigns.plan

    forecast_tax = FullCircle.Tax.forecast_annual_tax(com, fy_year, as_of)
    tol = plan.tolerance_pct || Decimal.new(30)
    suggested = FullCircle.Tax.suggested_estimate(forecast_tax, tol)

    attrs = %{
      "fy_year" => fy_year,
      "tolerance_pct" => Decimal.to_string(tol),
      "estimate" => Decimal.to_string(suggested),
      "estimate_month" => FullCircle.Tax.current_fy_month(com, fy_year, as_of),
      "paid_overrides" => plan.paid_overrides || %{}
    }

    case FullCircle.Tax.create_or_update_plan(attrs, com, socket.assigns.current_user) do
      {:ok, plan} -> {:noreply, assign(socket, plan: plan, plan_schedule: FullCircle.Tax.schedule(plan, com))}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not revise the estimate."))}
    end
  end
```
NOTE: `revise_plan` does its own `forecast_annual_tax` call (infrequent button click) rather than depending on the async result — simpler than reaching into `@result`. The per-render DISPLAY still reuses the async result (Step 5), so there's no extra forecast run on normal renders.

If the file lacks a `parse_date/1` helper, reuse its existing date-parsing inline (read how `run_forecast`/`handle_params` parses `as_of`) — don't introduce a redundant helper.

- [ ] **Step 5: Render the planner section below the table (inside the async result block)**

Read the existing `<:result_html>` block. After `<.pl_table .../>` (still inside `<% f = @result.result %>` scope), add a call to a new `tax_plan_section/1` function component, passing the forecast tax from the result plus the plan/schedule assigns:
```elixir
            <.tax_plan_section
              :if={is_map(f)}
              forecast_tax={f.totals.estimated_tax}
              plan={@plan}
              schedule={@plan_schedule}
              fy_year={@search.fy_year}
            />
```
Implement `tax_plan_section/1` (port the standalone planner's markup, MINUS its own query form — fy_year/as_of come from the forecast page's search form). It renders:
- A heading e.g. "CP204 Tax Instalment Plan".
- Summary: Forecast annual tax (`money(@forecast_tax)`), Suggested estimate (`money(suggested)` where `suggested = FullCircle.Tax.suggested_estimate(@forecast_tax, tol)`), Tolerance % input, Chosen estimate input (prefill with `@plan.estimate` if > 0, else `suggested`).
- A zero-rate hint shown when `Decimal.compare(@forecast_tax, Decimal.new(0)) != :gt`: gettext("Set a tax rate in Trailing settings to get a suggested estimate.").
- Under-estimation banner when `FullCircle.Tax.under_estimated?(chosen, @forecast_tax, tol)` (compute `chosen` = displayed estimate). Use the SAME red banner text as the standalone page so the existing assertion ports.
- A `<.form phx-submit="save_plan">` containing: hidden `plan[fy_year]`, hidden `plan[estimate_month]` (value `@plan.estimate_month || 1`), the tolerance + estimate inputs, the 12-row schedule table (Month / Instalment Due / Tax Paid editable input `plan[paid_overrides][<month_no>]` / Balance) from `@schedule`, a Save button (`<.button>`), and a Revise button (`type="button" phx-click="revise_plan"`).
- A `money/1` helper rounding to 2dp (port it; if the forecast LiveView already has a money/compact helper, reuse the rounding approach — the planner wants 2dp delimited, distinct from the table's `compact/1`; name it `plan_money/1` if `money/1` would clash).
- Light + dark theme classes (port the standalone styling).

IMPORTANT: gate this section to the INTERACTIVE page only — it lives in `profit_loss_forecast.ex`, NOT the print module, so it is automatically excluded from print. Do not add it to `profit_loss_forecast_print.ex`.

- [ ] **Step 6: Tests for the embedded planner**

In `profit_loss_forecast_live_test.exs` add:
- planner section renders below the table (assert "Instalment Due" and "Suggested estimate" text present on the default page).
- saving a plan persists: drive `form("#...plan form id...")` submit with a chosen estimate + a paid cell, assert `FullCircle.Tax.get_plan(com, fy_year)` reflects it. (Mirror the working approach from the deleted standalone test: fire submit on the full rendered form; read fy_year from the rendered hidden input.)
- under-estimation banner renders when estimate is below the floor — port the end-to-end positive-rate test from the standalone test (set `PLF.save_tax_rate(com, "24")` + post profitable transactions, save a low estimate, assert the banner substring).

Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs` — all PASS.
Run: `mix compile --warnings-as-errors 2>&1 | tail -10` — clean.

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle_web/live/report_live/profit_loss_forecast.ex test/full_circle_web/live/profit_loss_forecast_live_test.exs
git commit -m "feat: embed CP204 instalment planner below the P&L forecast table

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Remove the standalone planner page

**Files:**
- Delete: `lib/full_circle_web/live/tax_live/instalment_plan.ex`
- Delete: `test/full_circle_web/live/tax_instalment_plan_live_test.exs`
- Modify: `lib/full_circle_web/router.ex`
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`

- [ ] **Step 1: Delete the route**

In `router.ex`, remove the `live("/tax_instalment_plan", TaxLive.InstalmentPlan, :index)` line.

- [ ] **Step 2: Delete the menu link**

In `dashboard_live.ex`, remove the admin-gated "Tax Instalment Plan" `<.link>` that navigates to `/tax_instalment_plan`.

- [ ] **Step 3: Delete the standalone LiveView + its test**

```bash
git rm lib/full_circle_web/live/tax_live/instalment_plan.ex test/full_circle_web/live/tax_instalment_plan_live_test.exs
```
(Ensure any meaningful assertions from that test were ported into the forecast live test in Task 1 — admin redirect, schedule render, banner render. If not, port them now.)

- [ ] **Step 4: Confirm no dangling references**

Run: `grep -rn "TaxLive.InstalmentPlan\|tax_instalment_plan" lib/ test/` — should be EMPTY (the context `FullCircle.Tax` and schema `FullCircle.Tax.InstalmentPlan` remain and are fine; only the WEB route/module/menu references must be gone).

- [ ] **Step 5: Compile + test**

Run: `mix compile --warnings-as-errors 2>&1 | tail -10` — clean (no reference to the deleted module).
Run: `mix test test/full_circle_web/live/profit_loss_forecast_live_test.exs test/full_circle/tax_test.exs` — all PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: remove standalone CP204 page (now embedded in forecast)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Full verification

**Files:** none.

- [ ] **Step 1:** `mix compile --warnings-as-errors` — clean.
- [ ] **Step 2:** `mix test test/full_circle/tax_test.exs test/full_circle_web/live/profit_loss_forecast_live_test.exs` — all PASS.
- [ ] **Step 3:** `mix test` — PASS except the 2 known pre-existing `pay_run_test.exs` failures (unrelated; confirmed at the base commit). No NEW failures.
- [ ] **Step 4 (manual smoke):** open the forecast page as admin → planner appears below the table; set a tax rate via Trailing → forecast tax + suggested estimate become non-zero; edit a paid cell + Save → schedule/balance update and persist; Revise → estimate resets to suggested and re-spreads from the current month; the under-estimation banner appears when the chosen estimate is set below the floor. Verify the standalone `/tax_instalment_plan` URL is gone (404/redirect). Check light + dark themes. Confirm the print view still shows only the forecast (no planner).

---

## Self-Review Notes
- **Coverage:** embed below table reusing forecast `estimated_tax` (Task 1 Step 5); shared fy_year/as_of (Step 3); zero-rate hint (Step 5); admin guard on the now-writable page (Step 1); standalone removed (Task 2); print unaffected (separate module). Decisions honored: merge / remove standalone / always-show + hint.
- **No second forecast run on render** — display reuses `@result`; only `revise_plan` (a button) runs its own forecast.
- **Handler names** `save_plan`/`revise_plan` don't collide with the existing `save_settings`/`query`/`drill`.
- **Context/schema unchanged** — `FullCircle.Tax` and `InstalmentPlan` stay; only the web layer moves.
- **Dark/light** carried over from the standalone planner markup.
