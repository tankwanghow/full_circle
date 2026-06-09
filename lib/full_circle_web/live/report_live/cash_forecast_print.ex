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
              weeks_count: 13,
              buffer_weeks: safe_int(params["buffer_weeks"], 2),
              trailing_weeks: safe_int(params["trailing_weeks"], 52),
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
          {Date.to_iso8601(@forecast.start_date)} — {@forecast.weeks_count} {gettext("weeks")}
        </p>

        <div class="ladder">
          <p class="font-bold">{gettext("Fixed Deposit Tenure Ladder")}</p>
          <div class="ladder-row">
            <div>{gettext("~1 mo (4 wk)")}: {fmt(@forecast.ladder.place_1mo)}</div>
            <div>{gettext("~2 mo (8 wk)")}: {fmt(@forecast.ladder.place_2mo)}</div>
            <div>{gettext("~3 mo (13 wk)")}: {fmt(@forecast.ladder.place_3mo)}</div>
          </div>
          <div class="ladder-row muted">
            <div>{gettext("Lockable 1mo")}: {fmt(@forecast.ladder.lockable_1mo)}</div>
            <div>{gettext("Lockable 2mo")}: {fmt(@forecast.ladder.lockable_2mo)}</div>
            <div>{gettext("Lockable 3mo")}: {fmt(@forecast.ladder.lockable_3mo)}</div>
          </div>
          <p class="muted">{gettext("On-call")}: {fmt(@forecast.ladder.on_call)}</p>
        </div>

        <table class="forecast">
          <thead>
            <tr>
              <th>{gettext("Wk")}</th>
              <th>{gettext("Start")}</th>
              <th>{gettext("Opening")}</th>
              <th>{gettext("Known In")}</th>
              <th>{gettext("Base In")}</th>
              <th>{gettext("Known Out")}</th>
              <th>{gettext("Base Out")}</th>
              <th>{gettext("Closing")}</th>
              <th>{gettext("Buffer")}</th>
              <th>{gettext("Free Cash")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={w <- @forecast.weeks}>
              <td class="ctr">{w.n}</td>
              <td class="ctr">{Date.to_iso8601(w.week_start)}</td>
              <td>{fmt(w.opening)}</td>
              <td>{fmt(w.known_in)}</td>
              <td>{fmt(w.baseline_in)}</td>
              <td>{fmt(w.known_out)}</td>
              <td>{fmt(w.baseline_out)}</td>
              <td class="bold">{fmt(w.closing)}</td>
              <td>{fmt(w.buffer)}</td>
              <td class="bold">{fmt(w.free_cash)}</td>
            </tr>
          </tbody>
        </table>
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
    </style>
    """
  end

  defp fmt(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp fmt(other), do: to_string(other)
end
