defmodule FullCircleWeb.ReportLive.CashForecast do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Cash Forecast"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    p = params["search"] || %{}

    search = %{
      s_date: p["s_date"] || "",
      period_days: p["period_days"] || "30",
      periods_count: p["periods_count"] || "12",
      buffer_periods: p["buffer_periods"] || "1",
      trailing_days: p["trailing_days"] || "365"
    }

    {:noreply,
     socket
     |> assign(search: search)
     |> run_forecast(search)}
  end

  @impl true
  def handle_event("query", %{"search" => s}, socket) do
    qry = %{
      "search[s_date]" => s["s_date"],
      "search[period_days]" => s["period_days"],
      "search[periods_count]" => s["periods_count"],
      "search[buffer_periods]" => s["buffer_periods"],
      "search[trailing_days]" => s["trailing_days"]
    }

    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/cash_forecast?#{URI.encode_query(qry)}"
     )}
  end

  defp run_forecast(socket, search) do
    current_company = socket.assigns.current_company

    parsed =
      case Date.from_iso8601(search.s_date) do
        {:ok, date} ->
          %{
            start_date: date,
            period_days: safe_int(search.period_days, 30),
            periods_count: safe_int(search.periods_count, 12),
            buffer_periods: safe_int(search.buffer_periods, 1),
            trailing_days: safe_int(search.trailing_days, 365),
            account_ids: :all
          }

        _ ->
          nil
      end

    socket
    |> assign_async(:result, fn ->
      {:ok,
       %{
         result:
           if(parsed, do: Reporting.cash_forecast(parsed, current_company), else: [])
       }}
    end)
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
    <div class="w-11/12 mx-auto mb-10">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>

      <div class="border rounded bg-amber-200 dark:bg-amber-900 dark:border-amber-700 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2 tracking-tighter">
            <div class="col-span-2">
              <.input
                label={gettext("Start Date")}
                name="search[s_date]"
                type="date"
                id="search_s_date"
                value={@search.s_date}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Period (days)")}
                name="search[period_days]"
                type="number"
                id="search_period_days"
                value={@search.period_days}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("No. of Periods")}
                name="search[periods_count]"
                type="number"
                id="search_periods_count"
                value={@search.periods_count}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Buffer (periods)")}
                name="search[buffer_periods]"
                type="number"
                id="search_buffer_periods"
                value={@search.buffer_periods}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Trailing (days)")}
                name="search[trailing_days]"
                type="number"
                id="search_trailing_days"
                value={@search.trailing_days}
              />
            </div>
            <div class="col-span-2 mt-6 flex items-center gap-2">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? && is_map(@result.result)}
                navigate={
                  ~p"/companies/#{@current_company.id}/cash_forecast/print?#{[s_date: @search.s_date, period_days: @search.period_days, periods_count: @search.periods_count, buffer_periods: @search.buffer_periods, trailing_days: @search.trailing_days]}"
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
          <div :if={is_map(f)}>
            <.ladder_box ladder={f.ladder} />
            <.period_table periods={f.periods} />
            <.legend
              period_days={f.period_days}
              buffer_periods={f.buffer_periods}
              trailing_days={f.trailing_days}
            />
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end

  attr :ladder, :map, required: true

  defp ladder_box(assigns) do
    ~H"""
    <div class="my-4 p-3 border rounded bg-green-100 dark:bg-green-900 dark:border-green-700">
      <p class="font-bold text-center">{gettext("Fixed Deposit Tenure Ladder")}</p>
      <div class="grid grid-cols-4 text-center mt-2 text-sm">
        <div>~1 mo: <span class="font-mono">{fmt(@ladder.place_1mo)}</span></div>
        <div>~3 mo: <span class="font-mono">{fmt(@ladder.place_3mo)}</span></div>
        <div>~6 mo: <span class="font-mono">{fmt(@ladder.place_6mo)}</span></div>
        <div>~12 mo: <span class="font-mono">{fmt(@ladder.place_12mo)}</span></div>
      </div>
      <div class="grid grid-cols-4 text-center mt-1 text-sm text-gray-500 dark:text-gray-400">
        <div>{gettext("Lockable")} 1mo: <span class="font-mono">{fmt(@ladder.lockable_1mo)}</span></div>
        <div>{gettext("Lockable")} 3mo: <span class="font-mono">{fmt(@ladder.lockable_3mo)}</span></div>
        <div>{gettext("Lockable")} 6mo: <span class="font-mono">{fmt(@ladder.lockable_6mo)}</span></div>
        <div>{gettext("Lockable")} 12mo: <span class="font-mono">{fmt(@ladder.lockable_12mo)}</span></div>
      </div>
    </div>
    """
  end

  attr :periods, :list, required: true

  defp period_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm text-right border dark:border-gray-700">
        <thead class="bg-gray-200 dark:bg-gray-700 dark:text-gray-100">
          <tr>
            <th class="text-center px-1">#</th>
            <th class="text-center px-1">{gettext("From")}</th>
            <th class="text-center px-1">{gettext("To")}</th>
            <th class="text-center px-1">{gettext("Type")}</th>
            <th class="px-1">{gettext("Opening")}</th>
            <th class="px-1 text-gray-500 dark:text-gray-400">{gettext("Base In")}</th>
            <th class="px-1">{gettext("Known In")}</th>
            <th class="px-1 text-gray-500 dark:text-gray-400">{gettext("Base Out")}</th>
            <th class="px-1">{gettext("Known Out")}</th>
            <th class="px-1">{gettext("Closing")}</th>
            <th class="px-1">{gettext("Buffer")}</th>
            <th class="px-1 text-green-700 dark:text-green-400">{gettext("Free Cash")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @periods}
            class={[
              "border-b dark:border-gray-700 dark:text-gray-200",
              if(p.source == :actual,
                do: "bg-sky-50 dark:bg-sky-950",
                else: "odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900"
              )
            ]}
          >
            <td class="text-center px-1">{p.n}</td>
            <td class="text-center px-1">{Date.to_iso8601(p.period_start)}</td>
            <td class="text-center px-1">{Date.to_iso8601(p.period_end)}</td>
            <td class={[
              "text-center px-1 font-medium",
              if(p.source == :actual,
                do: "text-sky-700 dark:text-sky-300",
                else: "text-gray-500 dark:text-gray-400"
              )
            ]}>
              {if p.source == :actual, do: gettext("Actual"), else: gettext("Forecast")}
            </td>
            <td class="font-mono px-1">{fmt(p.opening)}</td>
            <td class="font-mono px-1 text-gray-500 dark:text-gray-400">{fmt(p.baseline_in)}</td>
            <td class="font-mono px-1">{fmt(p.known_in)}</td>
            <td class="font-mono px-1 text-gray-500 dark:text-gray-400">{fmt(p.baseline_out)}</td>
            <td class="font-mono px-1">{fmt(p.known_out)}</td>
            <td class="font-mono px-1 font-bold">{fmt(p.closing)}</td>
            <td class="font-mono px-1">{fmt(p.buffer)}</td>
            <td class="font-mono px-1 font-bold text-green-700 dark:text-green-400">
              {fmt(p.free_cash)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :period_days, :integer, required: true
  attr :buffer_periods, :integer, required: true
  attr :trailing_days, :integer, required: true

  defp legend(assigns) do
    ~H"""
    <div class="my-4 p-3 border rounded bg-gray-50 dark:bg-gray-800 dark:border-gray-700 text-sm">
      <p class="font-bold mb-2">
        {gettext("How to read this report")}
        <span class="font-normal text-gray-500 dark:text-gray-400">
          ({gettext("each period is %{d} days; the run-rate is sampled from the last %{t} days", d: @period_days, t: @trailing_days)})
        </span>
      </p>
      <dl class="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-1">
        <div>
          <dt class="inline font-semibold">{gettext("Type")}:</dt>
          <dd class="inline">
            {gettext(
              "Actual = the period has already fully passed, so its figures are this company's REAL cash in/out for those dates (shaded). Forecast = the period is still open or in the future, so it is projected."
            )}
          </dd>
        </div>
        <div>
          <dt class="inline font-semibold">{gettext("Opening")} / {gettext("Closing")}:</dt>
          <dd class="inline">
            {gettext("Balance at the start / end of the period (Opening + all inflows − all outflows). One continuous line across actual and forecast.")}
          </dd>
        </div>
        <div>
          <dt class="inline font-semibold">{gettext("Base In")} / {gettext("Base Out")}:</dt>
          <dd class="inline">
            {gettext(
              "The period's underlying cash flow. For an Actual period it is the REAL total throughput. For a Forecast period it is the run-rate — this company's average operating throughput per period from the trailing window (treasury transfers excluded)."
            )}
          </dd>
        </div>
        <div>
          <dt class="inline font-semibold">{gettext("Known In")} / {gettext("Known Out")}:</dt>
          <dd class="inline">
            {gettext(
              "Forecast periods only — specific dated cash already certain and on top of the run-rate: in-hand post-dated cheques and transactions already entered with a future date."
            )}
          </dd>
        </div>
        <div>
          <dt class="inline font-semibold">{gettext("Buffer")}:</dt>
          <dd class="inline">
            {gettext("Cash that must stay liquid — the projected net cash drain (outflow − inflow, floored at 0) over the next %{n} period(s).",
              n: @buffer_periods
            )}
          </dd>
        </div>
        <div>
          <dt class="inline font-semibold">{gettext("Free Cash")}:</dt>
          <dd class="inline">
            {gettext("Closing − Buffer (never below 0) — surplus safe to put to work.")}
          </dd>
        </div>
      </dl>
      <p class="mt-2">
        <span class="font-semibold">{gettext("Fixed Deposit Tenure Ladder")}:</span>
        {gettext(
          "the most you can lock away for ~1/3/6/12 months without any period dropping below its Buffer. \"Place\" is how much to put at each tenure; \"Lockable\" is the sustainable amount across that whole window."
        )}
      </p>
      <p class="mt-1 italic text-gray-500 dark:text-gray-400">
        {gettext("Set the Start Date in the past to see real actuals for the elapsed periods alongside the forecast for the rest. The run-rate (used for forecast periods) is always taken from the most recent days; a longer trailing window smooths seasonality, a shorter one tracks recent changes.")}
      </p>
    </div>
    """
  end

  defp fmt(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp fmt(other), do: to_string(other)
end
