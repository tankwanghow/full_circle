defmodule FullCircleWeb.ReportLive.CashForecast do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: gettext("Cash Forecast"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    p = params["search"] || %{}
    s_date = p["s_date"] || ""
    buffer_weeks = p["buffer_weeks"] || "2"
    trailing_weeks = p["trailing_weeks"] || "52"

    {:noreply,
     socket
     |> assign(search: %{s_date: s_date, buffer_weeks: buffer_weeks, trailing_weeks: trailing_weeks})
     |> run_forecast(s_date, buffer_weeks, trailing_weeks)}
  end

  @impl true
  def handle_event("query", %{"search" => s}, socket) do
    qry = %{
      "search[s_date]" => s["s_date"],
      "search[buffer_weeks]" => s["buffer_weeks"],
      "search[trailing_weeks]" => s["trailing_weeks"]
    }

    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/cash_forecast?#{URI.encode_query(qry)}"
     )}
  end

  defp run_forecast(socket, s_date, buffer_weeks, trailing_weeks) do
    current_company = socket.assigns.current_company

    parsed =
      case Date.from_iso8601(s_date) do
        {:ok, date} ->
          %{
            start_date: date,
            weeks_count: 13,
            buffer_weeks: safe_int(buffer_weeks, 2),
            trailing_weeks: safe_int(trailing_weeks, 52),
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
           if parsed do
             Reporting.cash_forecast(parsed, current_company)
           else
             []
           end
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
    <div class="w-10/12 mx-auto mb-10">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>

      <div class="border rounded bg-amber-200 dark:bg-amber-900 dark:border-amber-700 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2 tracking-tighter">
            <div class="col-span-3">
              <.input
                label={gettext("Start Date")}
                name="search[s_date]"
                type="date"
                id="search_s_date"
                value={@search.s_date}
              />
            </div>
            <div class="col-span-3">
              <.input
                label={gettext("Buffer Weeks")}
                name="search[buffer_weeks]"
                type="number"
                id="search_buffer_weeks"
                value={@search.buffer_weeks}
              />
            </div>
            <div class="col-span-3">
              <.input
                label={gettext("Trailing Weeks")}
                name="search[trailing_weeks]"
                type="number"
                id="search_trailing_weeks"
                value={@search.trailing_weeks}
              />
            </div>
            <div class="col-span-3 mt-6">
              <.button>
                {gettext("Query")}
              </.button>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% f = @result.result %>
          <div :if={is_map(f)}>
            <div class="text-center my-2">
              <.link
                navigate={
                  ~p"/companies/#{@current_company.id}/cash_forecast/print?#{[s_date: @search.s_date, buffer_weeks: @search.buffer_weeks, trailing_weeks: @search.trailing_weeks]}"
                }
                target="_blank"
                class="blue button"
              >
                {gettext("Print")}
              </.link>
            </div>
            <.ladder_box ladder={f.ladder} />
            <.week_table weeks={f.weeks} />
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
      <div class="grid grid-cols-3 text-center mt-2 text-sm">
        <div>
          {gettext("~1 mo (4 wk)")}: <span class="font-mono">{fmt(@ladder.place_1mo)}</span>
        </div>
        <div>
          {gettext("~2 mo (8 wk)")}: <span class="font-mono">{fmt(@ladder.place_2mo)}</span>
        </div>
        <div>
          {gettext("~3 mo (13 wk)")}: <span class="font-mono">{fmt(@ladder.place_3mo)}</span>
        </div>
      </div>
      <div class="grid grid-cols-3 text-center mt-1 text-sm text-gray-500 dark:text-gray-400">
        <div>
          {gettext("Lockable 1mo")}: <span class="font-mono">{fmt(@ladder.lockable_1mo)}</span>
        </div>
        <div>
          {gettext("Lockable 2mo")}: <span class="font-mono">{fmt(@ladder.lockable_2mo)}</span>
        </div>
        <div>
          {gettext("Lockable 3mo")}: <span class="font-mono">{fmt(@ladder.lockable_3mo)}</span>
        </div>
      </div>
      <div class="text-center mt-1 text-sm">
        {gettext("On-call")}: <span class="font-mono">{fmt(@ladder.on_call)}</span>
      </div>
    </div>
    """
  end

  attr :weeks, :list, required: true

  defp week_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm text-right border dark:border-gray-700">
        <thead class="bg-gray-200 dark:bg-gray-700 dark:text-gray-100">
          <tr>
            <th class="text-center px-1">{gettext("Wk")}</th>
            <th class="text-center px-1">{gettext("Start")}</th>
            <th class="px-1">{gettext("Opening")}</th>
            <th class="px-1">{gettext("Known In")}</th>
            <th class="px-1 text-gray-500 dark:text-gray-400">{gettext("Base In")}</th>
            <th class="px-1">{gettext("Known Out")}</th>
            <th class="px-1 text-gray-500 dark:text-gray-400">{gettext("Base Out")}</th>
            <th class="px-1">{gettext("Closing")}</th>
            <th class="px-1">{gettext("Buffer")}</th>
            <th class="px-1 text-green-700 dark:text-green-400">{gettext("Free Cash")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={w <- @weeks}
            class="border-b dark:border-gray-700 odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900 dark:text-gray-200"
          >
            <td class="text-center px-1">{w.n}</td>
            <td class="text-center px-1">{Date.to_iso8601(w.week_start)}</td>
            <td class="font-mono px-1">{fmt(w.opening)}</td>
            <td class="font-mono px-1">{fmt(w.known_in)}</td>
            <td class="font-mono px-1 text-gray-500 dark:text-gray-400">{fmt(w.baseline_in)}</td>
            <td class="font-mono px-1">{fmt(w.known_out)}</td>
            <td class="font-mono px-1 text-gray-500 dark:text-gray-400">{fmt(w.baseline_out)}</td>
            <td class="font-mono px-1 font-bold">{fmt(w.closing)}</td>
            <td class="font-mono px-1">{fmt(w.buffer)}</td>
            <td class="font-mono px-1 font-bold text-green-700 dark:text-green-400">
              {fmt(w.free_cash)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp fmt(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp fmt(other), do: to_string(other)
end
