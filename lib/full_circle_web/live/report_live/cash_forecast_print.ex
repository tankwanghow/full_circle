defmodule FullCircleWeb.ReportLive.CashForecastPrint do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company

    forecast =
      case Date.from_iso8601(to_string(params["s_date"])) do
        {:ok, date} ->
          Reporting.cash_forecast(
            %{
              start_date: date,
              period_days: safe_int(params["period_days"], 30),
              periods_count: safe_int(params["periods_count"], 12),
              buffer_periods: safe_int(params["buffer_periods"], 1),
              trailing_days: safe_int(params["trailing_days"], 365),
              account_ids: :all
            },
            com
          )

        _ ->
          nil
      end

    {:ok,
     socket
     |> assign(page_title: gettext("Cash Forecast"))
     |> assign(:forecast, forecast)}
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
        <h1 class="text-center text-xl font-bold">
          {gettext("Cash Forecast & Free Cash Flow")}
        </h1>
        <p class="text-center">
          {Date.to_iso8601(@forecast.start_date)} — {@forecast.periods_count} × {@forecast.period_days} {gettext("day periods")}
          · {gettext("base/timing from last %{t} days", t: @forecast.trailing_days)}
        </p>

        <div class="ladder">
          <p class="font-bold">{gettext("Fixed Deposit Tenure Ladder")}</p>
          <div class="ladder-row">
            <div>~1 mo: {fmt(@forecast.ladder.place_1mo)}</div>
            <div>~3 mo: {fmt(@forecast.ladder.place_3mo)}</div>
            <div>~6 mo: {fmt(@forecast.ladder.place_6mo)}</div>
            <div>~12 mo: {fmt(@forecast.ladder.place_12mo)}</div>
          </div>
          <div class="ladder-row muted">
            <div>{gettext("Lockable")} 1mo: {fmt(@forecast.ladder.lockable_1mo)}</div>
            <div>{gettext("Lockable")} 3mo: {fmt(@forecast.ladder.lockable_3mo)}</div>
            <div>{gettext("Lockable")} 6mo: {fmt(@forecast.ladder.lockable_6mo)}</div>
            <div>{gettext("Lockable")} 12mo: {fmt(@forecast.ladder.lockable_12mo)}</div>
          </div>
        </div>

        <table class="forecast">
          <thead>
            <tr>
              <th>#</th>
              <th>{gettext("From")}</th>
              <th>{gettext("To")}</th>
              <th>{gettext("Opening")}</th>
              <th>{gettext("Known In")}</th>
              <th>{gettext("Run-rate In")}</th>
              <th>{gettext("Known Out")}</th>
              <th>{gettext("Run-rate Out")}</th>
              <th>{gettext("Closing")}</th>
              <th>{gettext("Buffer")}</th>
              <th>{gettext("Free Cash")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @forecast.periods}>
              <td class="ctr">{p.n}</td>
              <td class="ctr">{Date.to_iso8601(p.period_start)}</td>
              <td class="ctr">{Date.to_iso8601(p.period_end)}</td>
              <td>{fmt(p.opening)}</td>
              <td>{fmt(p.known_in)}</td>
              <td>{fmt(p.baseline_in)}</td>
              <td>{fmt(p.known_out)}</td>
              <td>{fmt(p.baseline_out)}</td>
              <td class="bold">{fmt(p.closing)}</td>
              <td>{fmt(p.buffer)}</td>
              <td class="bold">{fmt(p.free_cash)}</td>
            </tr>
          </tbody>
        </table>

        <p class="bold" style="margin-top:4mm;">{gettext("Recent actual cash flow")} ({gettext("real data")})</p>
        <table class="forecast">
          <thead>
            <tr>
              <th>{gettext("From")}</th>
              <th>{gettext("To")}</th>
              <th>{gettext("Actual In")}</th>
              <th>{gettext("Actual Out")}</th>
              <th>{gettext("Net")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={h <- @forecast.history}>
              <td class="ctr">{Date.to_iso8601(h.period_start)}</td>
              <td class="ctr">{Date.to_iso8601(h.period_end)}</td>
              <td>{fmt(h.in)}</td>
              <td>{fmt(h.out)}</td>
              <td class="bold">{fmt(h.net)}</td>
            </tr>
          </tbody>
        </table>

        <div class="legend">
          <p class="bold">{gettext("How to read this report")}</p>
          <p>
            <b>{gettext("Opening")}</b>: {gettext("cash & bank balance at the start of the period (previous period's Closing")}).
            <b>{gettext("Closing")}</b>: {gettext("Opening + all inflows − all outflows")}.
            <b>{gettext("Run-rate In")}</b> / <b>{gettext("Run-rate Out")}</b>: {gettext("the backbone — this company's actual average cash & bank throughput per period from the trailing window (captures the whole ongoing business)")}.
            <b>{gettext("Known In")}</b> / <b>{gettext("Known Out")}</b>: {gettext("specific dated cash already certain and on top of the run-rate — in-hand post-dated cheques and already-posted future-dated transactions")}.
            <b>{gettext("Buffer")}</b>: {gettext("cash that must stay liquid — projected net cash drain (outflow − inflow, floored at 0) over the next %{n} period(s)", n: @forecast.buffer_periods)}.
            <b>{gettext("Free Cash")}</b>: {gettext("Closing − Buffer (never below 0) — surplus safe to put to work")}.
          </p>
          <p>
            <b>{gettext("Fixed Deposit Tenure Ladder")}</b>: {gettext("the most you can lock away for ~1/3/6/12 months without any period dropping below its Buffer")}.
            {gettext("The run-rate projects the recent past forward; Known items are certain")}.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 290mm; min-height: 200mm; padding: 5mm; }
      @media print {
        @page { size: A4 landscape; margin: 0mm; }
        body { width: 290mm; height: 210mm; margin: 0mm; }
        html { margin: 0mm; }
      }
      .ladder { margin: 4mm 0; padding: 2mm; border: 1px solid gray; text-align: center; }
      .ladder-row { display: flex; justify-content: space-around; }
      .ladder .muted { color: #555; font-size: 12px; }
      table.forecast { width: 100%; border-collapse: collapse; font-size: 12px; text-align: right; }
      table.forecast th, table.forecast td { border: 1px solid gray; padding: 1px 3px; }
      table.forecast .ctr { text-align: center; }
      table.forecast .bold { font-weight: bold; }
      .legend { margin-top: 4mm; font-size: 11px; text-align: left; }
      .legend .bold { font-weight: bold; }
    </style>
    """
  end

  defp fmt(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp fmt(other), do: to_string(other)
end
