defmodule FullCircleWeb.ReportLive.ProfitLossForecastPrint do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

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
  def mount(params, _session, socket) do
    com = PLF.company_with_settings(socket.assigns.current_company)
    gran = if params["granularity"] == "quarterly", do: :quarterly, else: :monthly
    year = safe_int(params["fy_year"], Date.utc_today().year)

    as_of =
      case Date.from_iso8601(to_string(params["as_of"])) do
        {:ok, date} -> date
        _ -> Date.utc_today()
      end

    forecast = PLF.pl_forecast(%{fy_year: year, granularity: gran, as_of: as_of}, com)

    {:ok,
     socket
     |> assign(page_title: gettext("Profit & Loss Forecast"), rows: @rows, forecast: forecast)}
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
    <div id="print-me" class="print-here">
      {style(assigns)}
      <div :if={is_nil(@forecast)} class="page">
        <p class="text-center">{gettext("Invalid or missing start date.")}</p>
      </div>
      <div :if={@forecast} class="page">
        <h1 class="text-center text-xl font-bold">{gettext("Profit & Loss Forecast")}</h1>
        <p class="text-center">
          {gettext("Financial year")} {Date.to_iso8601(@forecast.start_date)} → {Date.to_iso8601(@forecast.fy_end)}
          · {if @forecast.granularity == :quarterly, do: gettext("Quarterly"), else: gettext("Monthly")}
        </p>

        <table class="pl">
          <thead>
            <tr>
              <th class="lbl">{gettext("Category")}</th>
              <th :for={p <- @forecast.periods} class={if p.source == :actual, do: "actual", else: ""}>
                {Date.to_iso8601(p.period_start)}<br />
                <span class="sub">{if p.source == :actual, do: gettext("Actual"), else: gettext("Forecast")}</span>
              </th>
              <th>{gettext("Total")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class={row.kind}>
              <td class="lbl">{row.label}{if Map.get(row, :type) in @forecast.estimated_types, do: "*", else: ""}</td>
              <td :for={p <- @forecast.periods} class={if p.source == :actual, do: "actual", else: ""}>
                {cell(p, row)}
              </td>
              <td class="tot">{total_cell(@forecast.totals, @forecast.periods, row)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp cell(period, %{kind: :margin, key: key}), do: pct(Map.get(period, key))
  defp cell(period, %{key: key}), do: money(Map.get(period, key))

  defp total_cell(_t, periods, %{kind: :cumulative}) do
    case List.last(periods) do
      nil -> money(Decimal.new(0))
      p -> money(p.cumulative_net)
    end
  end

  defp total_cell(totals, _p, %{kind: :margin, key: key}), do: pct(Map.get(totals, key))
  defp total_cell(totals, _p, %{key: key}), do: money(Map.get(totals, key))

  defp money(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp money(other), do: to_string(other)

  defp pct(%Decimal{} = d), do: "#{Decimal.round(d, 1)}%"
  defp pct(other), do: to_string(other)

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 290mm; min-height: 200mm; padding: 5mm; }
      @media print {
        @page { size: A4 landscape; margin: 0mm; }
        body { width: 290mm; height: 210mm; margin: 0mm; }
        html { margin: 0mm; }
      }
      table.pl { width: 100%; border-collapse: collapse; font-size: 11px; text-align: right; margin-top: 3mm; }
      table.pl th, table.pl td { border: 1px solid gray; padding: 1px 3px; }
      table.pl .lbl { text-align: left; }
      table.pl .sub { font-weight: normal; font-size: 9px; }
      table.pl tr.subtotal td { font-weight: bold; background: #f0f0f0; }
      table.pl tr.margin td { font-style: italic; color: #555; }
      table.pl tr.cumulative td { font-weight: bold; background: #eefaf0; }
      table.pl td.actual, table.pl th.actual { background: #eef6ff; }
      table.pl td.tot { font-weight: bold; }
    </style>
    """
  end
end
