defmodule FullCircleWeb.LayerLive.HarvestReport do
  use FullCircleWeb, :live_view

  alias FullCircle.{Layer}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, drill: nil, sort_by: :house_no, sort_dir: :asc)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    t_date = params["t_date"] || Timex.today() |> Timex.format!("%Y-%m-%d", :strftime)

    {:noreply,
     socket
     |> assign(page_title: "Harvest Report")
     |> assign(search: %{t_date: t_date})
     |> filter_transactions(t_date)}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "t_date" => t_date
          }
        },
        socket
      ) do
    {:noreply, push_navigate(socket, to: report_url(socket, t_date))}
  end

  def handle_event("shift_date", %{"days" => days}, socket) do
    new_date =
      socket.assigns.search.t_date
      |> Date.from_iso8601!()
      |> Date.add(String.to_integer(days))
      |> Date.to_iso8601()

    {:noreply, push_navigate(socket, to: report_url(socket, new_date))}
  end

  def handle_event("today", _params, socket) do
    {:noreply, push_navigate(socket, to: report_url(socket, Date.to_iso8601(Date.utc_today())))}
  end

  def handle_event(
        "drill",
        %{
          "house-id" => house_id,
          "flock-id" => flock_id,
          "house-no" => house_no,
          "flock-no" => flock_no
        },
        socket
      ) do
    rows =
      Layer.harvest_detail_for(
        house_id,
        flock_id,
        socket.assigns.search.t_date,
        socket.assigns.current_company.id
      )

    {:noreply,
     assign(socket,
       drill: %{house_no: house_no, flock_no: flock_no, rows: rows}
     )}
  end

  def handle_event("close_drill", _params, socket) do
    {:noreply, assign(socket, drill: nil)}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == field do
        {field, if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc)}
      else
        {field, :asc}
      end

    {:noreply, assign(socket, sort_by: sort_by, sort_dir: sort_dir)}
  end

  defp report_url(socket, t_date) do
    qry = URI.encode_query(%{"search[t_date]" => t_date})
    "/companies/#{socket.assigns.current_company.id}/harvest_report?#{qry}"
  end

  defp filter_transactions(socket, t_date) do
    current_company = socket.assigns.current_company

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if t_date == "" do
               []
             else
               [y, m, d] =
                 t_date |> String.split("-") |> Enum.map(fn x -> String.to_integer(x) end)

               Layer.harvest_report(
                 Date.new!(y, m, d),
                 current_company.id
               )
             end
         }}
      end
    )
  end

  defp yield_color(y1, y2) do
    cond do
      y1 - y2 >= 0.02 -> "yield-strong-up"
      y1 - y2 >= 0.0 -> "yield-slight-up"
      y1 - y2 > -0.01 -> "yield-flat"
      y1 - y2 > -0.02 -> "yield-slight-down"
      true -> "yield-strong-down"
    end
  end

  defp yield_header(dt, days) do
    try do
      dt
      |> Timex.parse!("{YYYY}-{0M}-{0D}")
      |> Timex.shift(days: days)
      |> Timex.format!("%d/%m", :strftime)
    rescue
      Timex.Parse.ParseError ->
        "error"
    end
  end

  defp average_yield(results, yield_n) do
    (avg_yield_value(results.result, yield_n) * 100)
    |> Number.Percentage.number_to_percentage(precision: 1)
  end

  defp avg_yield_value(rows, yield_n) do
    sum = rows |> Enum.reduce(0.0, fn e, acc -> acc + e[yield_n] end)
    count = rows |> Enum.count(fn x -> x[yield_n] > 0 end)
    count = if count == 0, do: 1, else: count
    sum / count
  end

  defp avg_sparkline_values(rows) do
    Enum.map(
      [:yield_7, :yield_6, :yield_5, :yield_4, :yield_3, :yield_2, :yield_1, :yield_0],
      &avg_yield_value(rows, &1)
    )
  end

  defp summary_stats(results) do
    rows = results.result
    count = length(rows)
    total_prod = rows |> Enum.reduce(0, fn r, acc -> acc + r.prod end)
    total_dea = rows |> Enum.reduce(0, fn r, acc -> acc + r.dea end)
    declining = rows |> Enum.count(fn r -> r.yield_0 - r.yield_1 <= -0.02 end)

    %{
      count: count,
      prod_trays: trunc(total_prod / 30),
      dea: total_dea,
      declining: declining
    }
  end

  # Builds an SVG polyline string from a list of yield values (0..1),
  # ordered oldest-to-newest (left-to-right on screen). Clamps values
  # into a fixed display window so sparklines are comparable across rows.
  defp sparkline_points(values) do
    w = 100.0
    h = 20.0
    y_min = 0.5
    y_max = 1.0
    step = w / max(length(values) - 1, 1)

    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      x = i * step
      clamped = v |> max(y_min) |> min(y_max)
      norm = (clamped - y_min) / (y_max - y_min)
      y = h - norm * h
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp sort_rows(rows, sort_by, sort_dir) do
    Layer.sort_harvest_report(rows, sort_by, sort_dir)
  end

  defp sort_arrow(sort_by, sort_dir, field) do
    cond do
      sort_by == field and sort_dir == :asc -> " ▲"
      sort_by == field and sort_dir == :desc -> " ▼"
      true -> ""
    end
  end

  defp sparkline_values(obj) do
    [
      obj.yield_7,
      obj.yield_6,
      obj.yield_5,
      obj.yield_4,
      obj.yield_3,
      obj.yield_2,
      obj.yield_1,
      obj.yield_0
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="text-2xl text-center font-medium">{"#{@page_title}"}</p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-1 text-right">
              <button
                type="button"
                phx-click="shift_date"
                phx-value-days="-1"
                class="blue button"
                title={gettext("Previous day")}
              >
                ◀
              </button>
            </div>
            <div class="col-span-2">
              <.input
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-2 text-left">
              <button
                type="button"
                phx-click="shift_date"
                phx-value-days="1"
                class="blue button mr-1"
                title={gettext("Next day")}
              >
                ▶
              </button>
              <button type="button" phx-click="today" class="blue button">
                {gettext("Today")}
              </button>
            </div>
            <div class="col-span-2">
              <.button>
                {gettext("Query")}
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/harvrepo?tdate=#{@search.t_date}&sort_by=#{@sort_by}&sort_dir=#{@sort_dir}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=harvrepo&tdate=#{@search.t_date}&sort_by=#{@sort_by}&sort_dir=#{@sort_dir}"
                }
                target="_blank"
                class="blue button"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <%= if @drill do %>
        <div class="mt-3">
          <div class="flex flex-row justify-between items-center border rounded bg-purple-200 border-purple-400 px-3 py-2 mb-2">
            <div class="font-medium tracking-tighter">
              {gettext("House")} <span class="font-bold">{@drill.house_no}</span>
              · {gettext("Flock")} <span class="font-bold">{@drill.flock_no}</span>
              · {gettext("Last 14 days up to")} <span class="font-bold">{@search.t_date}</span>
            </div>
            <button type="button" phx-click="close_drill" class="blue button">
              {gettext("Close")}
            </button>
          </div>
          <%= if Enum.empty?(@drill.rows) do %>
            <div class="text-center text-gray-600 py-6">
              {gettext("No harvest records in this period.")}
            </div>
          <% else %>
            <div class="flex flex-row text-center font-medium tracking-tighter mb-1">
              <div class="w-[12%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Date")}
              </div>
              <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Doc")}
              </div>
              <div class="w-[18%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Collector")}
              </div>
              <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Har 1")}
              </div>
              <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Har 2")}
              </div>
              <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Har 3")}
              </div>
              <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Total Eggs")}
              </div>
              <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Dea 1")}
              </div>
              <div class="w-[8%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Dea 2")}
              </div>
              <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
                {gettext("Total Dea")}
              </div>
            </div>
            <%= for r <- @drill.rows do %>
              <div class="flex flex-row text-center tracking-tighter">
                <div class="w-[12%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.har_date}
                </div>
                <div class="w-[10%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.harvest_no}
                </div>
                <div
                  class="w-[18%] border rounded bg-blue-100 border-blue-300 px-2 py-1 truncate"
                  title={r.employee}
                >
                  {r.employee}
                </div>
                <div class="w-[8%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.har_1}
                </div>
                <div class="w-[8%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.har_2}
                </div>
                <div class="w-[8%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.har_3}
                </div>
                <div class="w-[10%] border rounded bg-green-100 border-green-300 px-2 py-1 font-medium">
                  {r.total_har}
                </div>
                <div class="w-[8%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.dea_1}
                </div>
                <div class="w-[8%] border rounded bg-blue-100 border-blue-300 px-2 py-1">
                  {r.dea_2}
                </div>
                <div class="w-[10%] border rounded bg-amber-100 border-amber-300 px-2 py-1 font-medium">
                  {r.total_dea}
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      <% else %>
      <.async_html result={@result}>
        <:result_html>
          <%= if Enum.count(@result.result) > 0 do %>
            <% s = summary_stats(@result) %>
            <div class="grid grid-cols-4 gap-2 mt-2 mb-2 tracking-tighter">
              <div class="border rounded bg-blue-100 border-blue-300 p-2 text-center">
                <div class="text-xs text-gray-600">{gettext("Active Houses")}</div>
                <div class="text-xl font-bold">{s.count}</div>
              </div>
              <div class="border rounded bg-green-100 border-green-300 p-2 text-center">
                <div class="text-xs text-gray-600">{gettext("Production (trays)")}</div>
                <div class="text-xl font-bold">{s.prod_trays}</div>
              </div>
              <div class="border rounded bg-amber-100 border-amber-300 p-2 text-center">
                <div class="text-xs text-gray-600">{gettext("Deaths")}</div>
                <div class="text-xl font-bold">{s.dea}</div>
              </div>
              <div class={[
                "border rounded p-2 text-center",
                if(s.declining > 0,
                  do: "bg-rose-200 border-rose-400",
                  else: "bg-gray-100 border-gray-300"
                )
              ]}>
                <div class="text-xs text-gray-600">{gettext("Declining (≥2%)")}</div>
                <div class="text-xl font-bold">{s.declining}</div>
              </div>
            </div>
          <% end %>

          <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="house_no"
            >
              {gettext("Hou")}{sort_arrow(@sort_by, @sort_dir, :house_no)}
            </div>
            <div
              class="w-[17%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="employee"
            >
              {gettext("Collector")}{sort_arrow(@sort_by, @sort_dir, :employee)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="age"
            >
              {gettext("Age")}{sort_arrow(@sort_by, @sort_dir, :age)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="prod"
            >
              {gettext("Prod")}{sort_arrow(@sort_by, @sort_dir, :prod)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="dea"
            >
              {gettext("Dea")}{sort_arrow(@sort_by, @sort_dir, :dea)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_0"
            >
              {yield_header(@search.t_date, 0)}{sort_arrow(@sort_by, @sort_dir, :yield_0)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_1"
            >
              {yield_header(@search.t_date, -1)}{sort_arrow(@sort_by, @sort_dir, :yield_1)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_2"
            >
              {yield_header(@search.t_date, -2)}{sort_arrow(@sort_by, @sort_dir, :yield_2)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_3"
            >
              {yield_header(@search.t_date, -3)}{sort_arrow(@sort_by, @sort_dir, :yield_3)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_4"
            >
              {yield_header(@search.t_date, -4)}{sort_arrow(@sort_by, @sort_dir, :yield_4)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_5"
            >
              {yield_header(@search.t_date, -5)}{sort_arrow(@sort_by, @sort_dir, :yield_5)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_6"
            >
              {yield_header(@search.t_date, -6)}{sort_arrow(@sort_by, @sort_dir, :yield_6)}
            </div>
            <div
              class="w-[6%] border rounded bg-gray-200 border-gray-400 px-2 py-1 cursor-pointer hover:bg-gray-300"
              phx-click="sort"
              phx-value-field="yield_7"
            >
              {yield_header(@search.t_date, -7)}{sort_arrow(@sort_by, @sort_dir, :yield_7)}
            </div>
            <div class="w-[12%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              {gettext("Trend")}
            </div>
          </div>

          <div id="lists">
            <%= for obj <- sort_rows(@result.result, @sort_by, @sort_dir) do %>
              <div
                class="flex flex-row text-center tracking-tighter max-h-20 cursor-pointer hover:opacity-80"
                phx-click="drill"
                phx-value-house-id={obj.house_id}
                phx-value-flock-id={obj.flock_id}
                phx-value-house-no={obj.house_no}
                phx-value-flock-no={obj.flock_no}
                title={gettext("Click for 14-day detail")}
              >
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.house_no}
                </div>
                <div
                  class="w-[17%] border rounded bg-blue-200 border-blue-400 px-2 py-1 truncate"
                  title={obj.employee}
                >
                  {obj.employee}
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.age}
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {(obj.prod / 30) |> trunc}
                </div>
                <div class="w-[6%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                  {obj.dea}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_0, obj.yield_1)
                ]}>
                  {(obj.yield_0 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_1, obj.yield_2)
                ]}>
                  {(obj.yield_1 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_2, obj.yield_3)
                ]}>
                  {(obj.yield_2 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_3, obj.yield_4)
                ]}>
                  {(obj.yield_3 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_4, obj.yield_5)
                ]}>
                  {(obj.yield_4 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_5, obj.yield_6)
                ]}>
                  {(obj.yield_5 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class={[
                  "w-[6%] border rounded px-2 py-1",
                  yield_color(obj.yield_6, obj.yield_7)
                ]}>
                  {(obj.yield_6 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class="w-[6%] border rounded bg-green-200 border-green-400 px-2 py-1">
                  {(obj.yield_7 * 100) |> Number.Percentage.number_to_percentage(precision: 1)}
                </div>
                <div class="w-[12%] border rounded bg-blue-50 border-blue-300 px-1 py-1 flex items-center justify-center">
                  <svg viewBox="0 0 100 20" class="w-full h-5" preserveAspectRatio="none">
                    <polyline
                      points={sparkline_points(sparkline_values(obj))}
                      fill="none"
                      stroke="#1d4ed8"
                      stroke-width="1.5"
                      vector-effect="non-scaling-stroke"
                    />
                  </svg>
                </div>
              </div>
            <% end %>
          </div>
          <div :if={Enum.count(@result.result) > 0} id="footer">
            <div class="flex flex-row text-center font-bold tracking-tighter mb-5 mt-1">
              <div class="w-[23%] border rounded bg-amber-200 border-amber-400 px-2 py-1 overflow-clip">
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {((@result.result |> Enum.reduce(0, fn e, acc -> acc + e.age end)) /
                    Enum.count(@result.result))
                |> trunc}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {((@result.result |> Enum.reduce(0, fn e, acc -> acc + e.prod end)) / 30) |> trunc}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {@result.result |> Enum.reduce(0, fn e, acc -> acc + e.dea end)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_0)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_1)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_2)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_3)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_4)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_5)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_6)}
              </div>
              <div class="w-[6%] border rounded bg-amber-200 border-amber-400 px-2 py-1">
                {average_yield(@result, :yield_7)}
              </div>
              <div class="w-[12%] border rounded bg-amber-200 border-amber-400 px-1 py-1 flex items-center justify-center">
                <svg viewBox="0 0 100 20" class="w-full h-5" preserveAspectRatio="none">
                  <polyline
                    points={sparkline_points(avg_sparkline_values(@result.result))}
                    fill="none"
                    stroke="#b45309"
                    stroke-width="2"
                    vector-effect="non-scaling-stroke"
                  />
                </svg>
              </div>
            </div>
          </div>
        </:result_html>
      </.async_html>
      <% end %>
    </div>
    """
  end
end
