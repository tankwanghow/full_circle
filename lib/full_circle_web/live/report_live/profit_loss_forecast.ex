defmodule FullCircleWeb.ReportLive.ProfitLossForecast do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  # Display rows: account-type lines are drillable (carry :type); subtotals, margins
  # and the cumulative line are computed.
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
    %{label: "Cumulative (YTD)", key: :cumulative_net, kind: :cumulative}
  ]

  @impl true
  def mount(_params, _session, socket) do
    com = PLF.company_with_settings(socket.assigns.current_company)

    {:ok,
     assign(socket,
       page_title: gettext("Profit & Loss Forecast"),
       current_company: com,
       rows: @rows,
       drill: nil,
       settings_open: false,
       trailing: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    p = params["search"] || %{}

    search = %{
      fy_year: p["fy_year"] || "#{default_fy_year(socket.assigns.current_company)}",
      granularity: p["granularity"] || "monthly"
    }

    {:noreply, socket |> assign(search: search) |> run_forecast(search)}
  end

  @impl true
  def handle_event("query", %{"search" => s}, socket) do
    qry = %{
      "search[fy_year]" => s["fy_year"],
      "search[granularity]" => s["granularity"]
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
      PLF.period_category_transactions(type, Date.from_iso8601!(from), Date.from_iso8601!(to), com)

    total = Enum.reduce(rows, Decimal.new(0), fn r, a -> Decimal.add(a, r.amount) end)

    {:noreply,
     assign(socket, drill: %{type: type, from: from, to: to, rows: rows, total: total})}
  end

  @impl true
  def handle_event("close_drill", _params, socket), do: {:noreply, assign(socket, drill: nil)}

  @impl true
  def handle_event("open_settings", _params, socket) do
    {:noreply,
     assign(socket,
       settings_open: true,
       trailing: PLF.category_trailing(socket.assigns.current_company)
     )}
  end

  @impl true
  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, settings_open: false)}

  @impl true
  def handle_event("save_settings", %{"trailing" => trailing}, socket) do
    com = socket.assigns.current_company
    {:ok, _} = PLF.save_category_trailing(com, trailing)
    com = PLF.company_with_settings(com)

    {:noreply,
     socket
     |> assign(current_company: com, settings_open: false)
     |> run_forecast(socket.assigns.search)}
  end

  defp run_forecast(socket, search) do
    com = socket.assigns.current_company
    year = safe_int(search.fy_year, Date.utc_today().year)
    gran = if search.granularity == "quarterly", do: :quarterly, else: :monthly

    assign_async(socket, :result, fn ->
      {:ok, %{result: PLF.pl_forecast(%{fy_year: year, granularity: gran}, com)}}
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
            <div class="col-span-3">
              <.input label={gettext("For The Year")} name="search[fy_year]" type="number"
                id="search_fy_year" value={@search.fy_year} />
            </div>
            <div class="col-span-3">
              <.input
                label={gettext("Period")}
                name="search[granularity]"
                type="select"
                id="search_granularity"
                options={[{gettext("Monthly"), "monthly"}, {gettext("Quarterly"), "quarterly"}]}
                value={@search.granularity}
              />
            </div>
            <div class="col-span-4 mt-6 flex items-center gap-2 flex-wrap">
              <.button>{gettext("Query")}</.button>
              <button type="button" phx-click="open_settings" class="gray button">
                {gettext("Trailing")}
              </button>
              <.link
                :if={@result.ok? && is_map(@result.result)}
                navigate={
                  ~p"/companies/#{@current_company.id}/profit_loss_forecast/print?#{[fy_year: @search.fy_year, granularity: @search.granularity]}"
                }
                target="_blank"
                class="blue button"
              >
                {gettext("Print")}
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% f = @result.result %>
          <div :if={is_map(f)} class="mt-3">
            <p class="text-center font-medium mb-1">
              {gettext("Financial year")} {Date.to_iso8601(f.start_date)} → {Date.to_iso8601(f.fy_end)}
            </p>
            <.pl_table rows={@rows} periods={f.periods} totals={f.totals} estimated={f.estimated_types} />
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-2">
              {gettext("Income and expenses both shown positive. Actual columns are the real posted P&L for elapsed periods (click a figure to see the transactions); Forecast columns project each category from its own trailing window (set via the Trailing button).")}
            </p>
            <p :if={f.estimated_types != []} class="text-sm text-amber-700 dark:text-amber-400 mt-1">
              {gettext("* No activity in the trailing window — estimated evenly across the whole year from last year's total (e.g. depreciation booked once at year-end). Applies to every column, including Actual.")}
            </p>
          </div>
        </:result_html>
      </.async_html>

      <.drill_modal :if={@drill} drill={@drill} />
      <.settings_modal :if={@settings_open} trailing={@trailing} />
    </div>
    """
  end

  attr :trailing, :map, required: true

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

  defp pl_table(assigns) do
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
              {row.label}<span :if={Map.get(row, :type) in @estimated} class="text-amber-600 dark:text-amber-400">*</span>
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

  defp drillable?(%{kind: :line, type: _}, %{source: :actual}), do: true
  defp drillable?(_, _), do: false

  defp row_class(%{kind: :subtotal}), do: "font-bold bg-gray-50 dark:bg-gray-800/60"
  defp row_class(%{kind: :margin}), do: "italic text-gray-600 dark:text-gray-400"
  defp row_class(%{kind: :cumulative}), do: "font-semibold bg-green-50 dark:bg-green-900/40"
  defp row_class(_), do: "odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900"

  defp row_label_bg(%{kind: :subtotal}), do: "bg-gray-50 dark:bg-gray-800"
  defp row_label_bg(%{kind: :cumulative}), do: "bg-green-50 dark:bg-green-900"
  defp row_label_bg(_), do: "bg-white dark:bg-gray-900"

  defp cell(period, %{kind: :margin, key: key}), do: pct(Map.get(period, key))
  defp cell(period, %{key: key}), do: money(Map.get(period, key))

  defp total_cell(_totals, periods, %{kind: :cumulative}) do
    case List.last(periods) do
      nil -> money(Decimal.new(0))
      p -> money(p.cumulative_net)
    end
  end

  defp total_cell(totals, _periods, %{kind: :margin, key: key}), do: pct(Map.get(totals, key))
  defp total_cell(totals, _periods, %{key: key}), do: money(Map.get(totals, key))

  defp money(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp money(other), do: to_string(other)

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
