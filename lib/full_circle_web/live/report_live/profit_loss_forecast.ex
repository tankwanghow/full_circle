defmodule FullCircleWeb.ReportLive.ProfitLossForecast do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  # Display rows: account-type lines are drillable (carry :type); subtotals, margins
  # and the tax rows are computed. Tax rows (:tax) render only when tax_rate > 0.
  @rows [
    %{label: "Revenue", key: :revenue, type: "Revenue", kind: :line},
    %{label: "Cost of Goods Sold", key: :cogs, type: "Cost Of Goods Sold", kind: :line},
    %{label: "Gross Profit", key: :gross_profit, kind: :subtotal},
    %{label: "Gross Margin %", key: :gross_margin, kind: :margin},
    %{label: "Direct Costs", key: :direct_costs, type: "Direct Costs", kind: :line},
    %{label: "Overhead", key: :overhead, type: "Overhead", kind: :line},
    %{label: "Expenses", key: :expenses, type: "Expenses", kind: :line},
    %{label: "Operating Profit", key: :operating_profit, kind: :subtotal},
    %{label: "Other Income", key: :other_income, type: "Other Income", kind: :line},
    %{label: "Depreciation", key: :depreciation, type: "Depreciation", kind: :line},
    %{label: "Net Profit", key: :net_profit, kind: :subtotal},
    %{label: "Net Margin %", key: :net_margin, kind: :margin},
    %{label: "Estimated Tax", key: :estimated_tax, kind: :tax},
    %{label: "Net Profit After Tax", key: :net_profit_after_tax, kind: :tax}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_role] != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Not authorized."))
       |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}")}
    else
      com = PLF.company_with_settings(socket.assigns.current_company)

      {:ok,
       assign(socket,
         page_title: gettext("Profit & Loss Forecast"),
         current_company: com,
         rows: @rows,
         drill: nil,
         settings_open: false,
         trailing: %{},
         tax_rate: Decimal.new(0),
         plan: nil,
         plan_schedule: []
       )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    p = params["search"] || %{}

    search = %{
      fy_year: p["fy_year"] || "#{default_fy_year(socket.assigns.current_company)}",
      granularity: p["granularity"] || "monthly",
      as_of: p["as_of"] || Date.to_iso8601(Date.utc_today())
    }

    com = socket.assigns.current_company
    fy_year = safe_int(search.fy_year, default_fy_year(com))

    as_of =
      case Date.from_iso8601(to_string(search.as_of)) do
        {:ok, date} -> date
        _ -> Date.utc_today()
      end

    plan =
      FullCircle.Tax.get_plan(com, fy_year) ||
        %FullCircle.Tax.InstalmentPlan{
          fy_year: fy_year,
          estimate_month: FullCircle.Tax.current_fy_month(com, fy_year, as_of)
        }

    {:noreply,
     socket
     |> assign(search: search, plan: plan, plan_schedule: FullCircle.Tax.schedule(plan, com))
     |> run_forecast(search)}
  end

  @impl true
  def handle_event("query", %{"search" => s}, socket) do
    qry = %{
      "search[fy_year]" => s["fy_year"],
      "search[granularity]" => s["granularity"],
      "search[as_of]" => s["as_of"]
    }

    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/profit_loss_forecast?#{URI.encode_query(qry)}"
     )}
  end

  @impl true
  def handle_event("drill", %{"type" => type, "from" => from, "to" => to}, socket) do
    com = socket.assigns.current_company

    rows =
      PLF.period_category_transactions(
        type,
        Date.from_iso8601!(from),
        Date.from_iso8601!(to),
        com
      )

    total = Enum.reduce(rows, Decimal.new(0), fn r, a -> Decimal.add(a, r.amount) end)

    {:noreply, assign(socket, drill: %{type: type, from: from, to: to, rows: rows, total: total})}
  end

  @impl true
  def handle_event("close_drill", _params, socket), do: {:noreply, assign(socket, drill: nil)}

  @impl true
  def handle_event("open_settings", _params, socket) do
    {:noreply,
     assign(socket,
       settings_open: true,
       trailing: PLF.category_trailing(socket.assigns.current_company),
       tax_rate: PLF.tax_rate(socket.assigns.current_company)
     )}
  end

  @impl true
  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, settings_open: false)}

  @impl true
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

    as_of =
      case Date.from_iso8601(to_string(socket.assigns.search.as_of)) do
        {:ok, date} -> date
        _ -> Date.utc_today()
      end

    plan = socket.assigns.plan
    tol = (plan && plan.tolerance_pct) || Decimal.new(30)
    forecast_tax = FullCircle.Tax.forecast_annual_tax(com, fy_year, as_of)
    suggested = FullCircle.Tax.suggested_estimate(forecast_tax, tol)

    attrs = %{
      "fy_year" => fy_year,
      "tolerance_pct" => Decimal.to_string(tol),
      "estimate" => Decimal.to_string(suggested),
      "estimate_month" => FullCircle.Tax.current_fy_month(com, fy_year, as_of),
      "paid_overrides" => (plan && plan.paid_overrides) || %{}
    }

    case FullCircle.Tax.create_or_update_plan(attrs, com, socket.assigns.current_user) do
      {:ok, plan} ->
        {:noreply, assign(socket, plan: plan, plan_schedule: FullCircle.Tax.schedule(plan, com))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not revise the estimate."))}
    end
  end

  defp run_forecast(socket, search) do
    com = socket.assigns.current_company
    year = safe_int(search.fy_year, Date.utc_today().year)
    gran = if search.granularity == "quarterly", do: :quarterly, else: :monthly

    as_of =
      case Date.from_iso8601(to_string(search.as_of)) do
        {:ok, date} -> date
        _ -> Date.utc_today()
      end

    assign_async(socket, :result, fn ->
      {:ok, %{result: PLF.pl_forecast(%{fy_year: year, granularity: gran, as_of: as_of}, com)}}
    end)
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-full px-4 mx-auto mb-10">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>

      <div class="border rounded bg-amber-200 dark:bg-amber-900 dark:border-amber-700 text-center p-2 w-10/12 mx-auto">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2 tracking-tighter">
            <div class="col-span-2">
              <.input label={gettext("For The Year")} name="search[fy_year]" type="number"
                id="search_fy_year" value={@search.fy_year} />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Period")}
                name="search[granularity]"
                type="select"
                id="search_granularity"
                options={[{gettext("Monthly"), "monthly"}, {gettext("Quarterly"), "quarterly"}]}
                value={@search.granularity}
              />
            </div>
            <div class="col-span-2">
              <.input label={gettext("Trailing From")} name="search[as_of]" type="date"
                id="search_as_of" value={@search.as_of} />
            </div>
            <div class="col-span-3 mt-6 flex items-center gap-2 flex-wrap">
              <.button>{gettext("Query")}</.button>
              <button type="button" phx-click="open_settings" class="gray button">
                {gettext("Trailing")}
              </button>
              <.link
                :if={@result.ok? && is_map(@result.result)}
                navigate={
                  ~p"/companies/#{@current_company.id}/profit_loss_forecast/print?#{[fy_year: @search.fy_year, granularity: @search.granularity, as_of: @search.as_of]}"
                }
                target="_blank"
                class="blue button"
              >
                {gettext("Print")}
              </.link>
            </div>
          </div>
          <p class="text-sm text-gray-500 dark:text-gray-400 mt-2">
              {gettext("Income and expenses both shown positive. Actual columns are the real posted P&L for elapsed periods (click a figure to see the transactions); Forecast columns project each category from its own trailing window (set via the Trailing button).")}
            </p>
            <p class="text-sm text-amber-700 dark:text-amber-400 mt-1">
              {gettext("* Not posted during the year (booked as a single annual lump, e.g. depreciation) — estimated evenly across the whole year. Applies to every column, including Actual.")}
            </p>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% f = @result.result %>
          <div :if={is_map(f)} class="mt-3">
            <p class="text-center font-medium mb-1">
              {gettext("Financial year")} {Date.to_iso8601(f.start_date)} → {Date.to_iso8601(f.fy_end)}
            </p>
            <.pl_table rows={@rows} periods={f.periods} totals={f.totals} estimated={f.estimated_types} tax_rate={f.tax_rate} />
            <.tax_plan_section
              :if={is_map(f) and @plan}
              forecast_tax={f.totals.estimated_tax}
              plan={@plan}
              schedule={@plan_schedule}
              fy_year={@search.fy_year}
            />
          </div>
        </:result_html>
      </.async_html>

      <.drill_modal :if={@drill} drill={@drill} />
      <.settings_modal :if={@settings_open} trailing={@trailing} tax_rate={@tax_rate} />
    </div>
    """
  end

  attr :forecast_tax, :any, required: true
  attr :plan, :any, required: true
  attr :schedule, :list, required: true
  attr :fy_year, :any, required: true

  defp tax_plan_section(assigns) do
    tol = assigns.plan.tolerance_pct || Decimal.new(30)
    suggested = FullCircle.Tax.suggested_estimate(assigns.forecast_tax, tol)

    chosen =
      if assigns.plan.estimate && Decimal.compare(assigns.plan.estimate, Decimal.new(0)) == :gt,
        do: assigns.plan.estimate,
        else: suggested

    under = FullCircle.Tax.under_estimated?(chosen, assigns.forecast_tax, tol)

    assigns =
      assign(assigns,
        tol: tol,
        suggested: suggested,
        chosen: chosen,
        under: under
      )

    ~H"""
    <div class="mt-6 w-full">
      <p class="text-xl font-semibold text-center mb-3">{gettext("CP204 Tax Instalment Plan")}</p>

      <%!-- Summary box --%>
      <div class="border rounded bg-amber-50 dark:bg-amber-950/30 dark:border-amber-800 p-3 mb-3">
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3 items-end">
          <div>
            <p class="text-xs text-gray-500 dark:text-gray-400">{gettext("Forecast annual tax")}</p>
            <p class="font-mono font-semibold text-sm">{plan_money(@forecast_tax)}</p>
          </div>
          <div>
            <p class="text-xs text-gray-500 dark:text-gray-400">{gettext("Suggested estimate")}</p>
            <p class="font-mono text-sm">{plan_money(@suggested)}</p>
          </div>
        </div>
        <p
          :if={Decimal.compare(@forecast_tax, Decimal.new(0)) != :gt}
          class="text-sm text-gray-500 dark:text-gray-400 mt-2"
        >
          {gettext("Set a tax rate in Trailing settings to get a suggested estimate.")}
        </p>
      </div>

      <%!-- Under-estimation banner --%>
      <div
        :if={@under}
        class="mb-3 rounded border border-red-400 bg-red-100 dark:bg-red-950/40 dark:border-red-700 px-3 py-2 text-red-700 dark:text-red-400 font-medium"
      >
        {gettext(
          "Chosen estimate is below the penalty-free floor — under-estimation penalty risk."
        )}
      </div>

      <%!-- Plan form --%>
      <.form
        for={%{}}
        id="plan-form"
        phx-submit="save_plan"
        autocomplete="off"
        class="w-full"
      >
        <input type="hidden" name="plan[fy_year]" value={@fy_year} />
        <input type="hidden" name="plan[estimate_month]" value={@plan.estimate_month || 1} />

        <div class="border rounded bg-amber-50 dark:bg-amber-950/30 dark:border-amber-800 p-3 mb-3">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-3 items-end">
            <div>
              <.input
                name="plan[tolerance_pct]"
                id="plan_tolerance_pct"
                type="number"
                step="0.01"
                min="0"
                label={gettext("Tolerance %")}
                value={Decimal.to_string(@tol)}
              />
            </div>
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
            <div class="flex gap-2 items-end">
              <.button class="blue button">{gettext("Save")}</.button>
              <button type="button" phx-click="revise_plan" class="gray button">
                {gettext("Revise")}
              </button>
            </div>
          </div>
        </div>

        <%!-- Instalment schedule table --%>
        <div class="overflow-x-auto">
          <table class="text-sm text-right border dark:border-gray-700 whitespace-nowrap w-full">
            <thead class="bg-gray-200 dark:bg-gray-700 dark:text-gray-100">
              <tr>
                <th class="px-2 text-left">{gettext("Month")}</th>
                <th class="px-2">{gettext("Instalment Due")}</th>
                <th class="px-2">{gettext("Tax Paid (editable)")}</th>
                <th class="px-2">{gettext("Balance")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={r <- @schedule}
                class="border-b dark:border-gray-700 odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900"
              >
                <td class="px-2 text-left">
                  {Date.to_iso8601(r.period_start)} → {Date.to_iso8601(r.period_end)}
                </td>
                <td class="px-2 font-mono">{plan_money(r.instalment_due)}</td>
                <td class="px-2 font-mono">
                  <input
                    type="number"
                    step="0.01"
                    name={"plan[paid_overrides][#{r.month_no}]"}
                    value={Decimal.to_string(Decimal.round(r.paid, 2))}
                    class="w-32 text-right border rounded px-1 dark:bg-gray-700 dark:border-gray-600 dark:text-gray-100"
                  />
                </td>
                <td class="px-2 font-mono">{plan_money(r.balance)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.form>
    </div>
    """
  end

  defp plan_money(%Decimal{} = d),
    do: Number.Delimit.number_to_delimited(Decimal.round(d, 2))

  defp plan_money(nil), do: "0.00"
  defp plan_money(other), do: to_string(other)

  attr :trailing, :map, required: true
  attr :tax_rate, :any, required: true

  defp settings_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center">
      <div class="absolute inset-0 bg-black/40" phx-click="close_settings"></div>
      <div class="relative z-10 w-11/12 max-w-md rounded shadow-lg bg-white dark:bg-gray-800 dark:text-gray-100 p-4">
        <p class="font-bold">{gettext("Run-rate Trailing Days per Category")}</p>
        <p class="text-sm text-gray-500 dark:text-gray-400 mb-3">
          {gettext("How many days of recent history each category's forecast is averaged from. Saved per company.")}
        </p>
        <form phx-submit="save_settings">
          <div class="grid grid-cols-2 gap-2 items-center">
            <%= for type <- FullCircle.Reporting.ProfitLossForecast.categories() do %>
              <label class="text-sm" for={"tr_#{type}"}>{type}</label>
              <input
                type="number"
                min="1"
                id={"tr_#{type}"}
                name={"trailing[#{type}]"}
                value={Map.get(@trailing, type, FullCircle.Reporting.ProfitLossForecast.default_trailing())}
                class="border rounded px-2 py-1 dark:bg-gray-700 dark:border-gray-600"
              />
            <% end %>
          </div>
          <div class="mt-4">
            <label class="text-sm font-medium" for="tax_rate">{gettext("Estimated tax rate %")}</label>
            <input type="number" min="0" step="0.01" id="tax_rate" name="tax_rate"
              value={Decimal.to_string(@tax_rate)}
              class="border rounded px-2 py-1 w-full dark:bg-gray-700 dark:border-gray-600" />
            <p class="text-xs text-gray-500 dark:text-gray-400 mt-1">
              {gettext("Flat percentage of forecast net profit — a planning estimate, not a tax computation. 0 hides the tax rows.")}
            </p>
          </div>
          <div class="flex justify-end gap-2 mt-4">
            <button type="button" phx-click="close_settings" class="gray button">{gettext("Cancel")}</button>
            <.button class="blue button">{gettext("Save")}</.button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :periods, :list, required: true
  attr :totals, :map, required: true
  attr :estimated, :list, default: []
  attr :tax_rate, :any, default: nil

  defp pl_table(assigns) do
    assigns = assign(assigns, :rows, visible_rows(assigns.rows, assigns.tax_rate))

    ~H"""
    <div class="overflow-x-auto">
      <table class="text-sm text-right border dark:border-gray-700 whitespace-nowrap mx-auto">
        <thead class="bg-gray-200 dark:bg-gray-700 dark:text-gray-100">
          <tr>
            <th class="text-left px-2 sticky left-0 bg-gray-200 dark:bg-gray-700">{gettext("Category")}</th>
            <th :for={p <- @periods} class={["px-2", p.source == :actual && "bg-sky-100 dark:bg-sky-950"]}>
              <div>{Date.to_iso8601(p.period_start)}</div>
              <div class="text-[10px] font-normal">
                {Date.to_iso8601(p.period_end)} ·
                {if p.source == :actual, do: gettext("Actual"), else: gettext("Forecast")}
              </div>
            </th>
            <th class="px-2 border-l-2 dark:border-gray-600">{gettext("Total")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class={["border-b dark:border-gray-700", row_class(row)]}>
            <td class={["text-left px-2 sticky left-0", row_label_bg(row)]}>
              {row_label(row, @tax_rate)}<span :if={Map.get(row, :type) in @estimated} class="text-amber-600 dark:text-amber-400">*</span>
            </td>
            <td
              :for={p <- @periods}
              class={["font-mono px-2", p.source == :actual && "bg-sky-50 dark:bg-sky-950/40"]}
            >
              <span
                :if={drillable?(row, p)}
                class="cursor-pointer underline decoration-dotted hover:text-sky-700 dark:hover:text-sky-300"
                phx-click="drill"
                phx-value-type={row.type}
                phx-value-from={Date.to_iso8601(p.period_start)}
                phx-value-to={Date.to_iso8601(p.period_end)}
              >{cell(p, row)}</span>
              <span :if={!drillable?(row, p)}>{cell(p, row)}</span>
            </td>
            <td class="font-mono px-2 border-l-2 dark:border-gray-600 font-semibold">{total_cell(@totals, @periods, row)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

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

  defp drillable?(%{kind: :line, type: _}, %{source: :actual}), do: true
  defp drillable?(_, _), do: false

  defp row_class(%{kind: :subtotal}), do: "font-bold bg-gray-50 dark:bg-gray-800/60"
  defp row_class(%{kind: :tax}), do: "font-bold bg-amber-50 dark:bg-amber-900/30"
  defp row_class(%{kind: :margin}), do: "italic text-gray-600 dark:text-gray-400"
  defp row_class(_), do: "odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900"

  defp row_label_bg(%{kind: :subtotal}), do: "bg-gray-50 dark:bg-gray-800"
  defp row_label_bg(%{kind: :tax}), do: "bg-amber-50 dark:bg-amber-900"
  defp row_label_bg(_), do: "bg-white dark:bg-gray-900"

  defp cell(period, %{kind: :margin, key: key}), do: pct(Map.get(period, key))
  defp cell(period, %{key: key}), do: compact(Map.get(period, key))

  defp total_cell(totals, _periods, %{kind: :margin, key: key}), do: pct(Map.get(totals, key))
  defp total_cell(totals, _periods, %{key: key}), do: compact(Map.get(totals, key))

  # Exact (drill-down). Table cells use compact/1.
  defp money(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp money(other), do: to_string(other)

  # Compact, readable money: 1.35M / 1.34K / plain.
  defp compact(%Decimal{} = d) do
    f = Decimal.to_float(d)
    a = abs(f)

    cond do
      a >= 1.0e9 -> :erlang.float_to_binary(f / 1.0e9, decimals: 2) <> "B"
      a >= 1.0e6 -> :erlang.float_to_binary(f / 1.0e6, decimals: 2) <> "M"
      a >= 1.0e3 -> :erlang.float_to_binary(f / 1.0e3, decimals: 2) <> "K"
      true -> :erlang.float_to_binary(f, decimals: 0)
    end
  end

  defp compact(other), do: to_string(other)

  defp pct(%Decimal{} = d), do: "#{Decimal.round(d, 1)}%"
  defp pct(other), do: to_string(other)

  attr :drill, :map, required: true

  defp drill_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center">
      <div class="absolute inset-0 bg-black/40" phx-click="close_drill"></div>
      <div class="relative z-10 w-11/12 max-w-3xl max-h-[80vh] overflow-auto rounded shadow-lg bg-white dark:bg-gray-800 dark:text-gray-100 p-4">
        <div class="flex items-center justify-between mb-2">
          <p class="font-bold">
            {@drill.type}
            <span class="font-normal text-gray-500 dark:text-gray-400 text-sm">
              ({@drill.from} → {@drill.to})
            </span>
          </p>
          <button type="button" phx-click="close_drill" class="text-gray-500 hover:text-gray-800 dark:hover:text-gray-200 text-xl leading-none">×</button>
        </div>
        <table class="w-full text-sm text-right">
          <thead class="bg-gray-200 dark:bg-gray-700 dark:text-gray-100">
            <tr>
              <th class="text-center px-1">{gettext("Date")}</th>
              <th class="text-left px-1">{gettext("Type")}</th>
              <th class="text-left px-1">{gettext("Doc No")}</th>
              <th class="text-left px-1">{gettext("Account")}</th>
              <th class="text-left px-1">{gettext("Particulars")}</th>
              <th class="px-1">{gettext("Amount")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @drill.rows} class="border-b dark:border-gray-700">
              <td class="text-center px-1">{Date.to_iso8601(r.date)}</td>
              <td class="text-left px-1">{r.doc_type}</td>
              <td class="text-left px-1">{r.doc_no}</td>
              <td class="text-left px-1">{r.account}</td>
              <td class="text-left px-1">{r.particulars}</td>
              <td class="font-mono px-1">{money(r.amount)}</td>
            </tr>
            <tr :if={@drill.rows == []}>
              <td colspan="6" class="text-center px-1 py-2 text-gray-500">{gettext("No transactions.")}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr class="border-t-2 dark:border-gray-600 font-bold">
              <td colspan="5" class="text-right px-1">{gettext("Total")}</td>
              <td class="font-mono px-1">{money(@drill.total)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
    """
  end
end
