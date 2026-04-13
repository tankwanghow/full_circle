defmodule FullCircleWeb.EggStockLive.ProductionReport do
  use FullCircleWeb, :live_view

  alias FullCircle.EggStock

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Egg Production Report"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}
    today = Date.utc_today()
    default_from = Date.add(today, -29) |> Date.to_iso8601()
    default_to = Date.to_iso8601(today)

    from_date = params["from_date"] || default_from
    to_date = params["to_date"] || default_to
    group_by = parse_group_by(params["group_by"])

    company = socket.assigns.current_company
    grades = EggStock.list_grades(company.id)

    {:noreply,
     socket
     |> assign(grades: grades)
     |> assign(search: %{from_date: from_date, to_date: to_date, group_by: group_by})
     |> load_rows(from_date, to_date, group_by)}
  end

  @impl true
  def handle_event(
        "query",
        %{"search" => %{"from_date" => from_date, "to_date" => to_date} = params},
        socket
      ) do
    qry =
      URI.encode_query(%{
        "search[from_date]" => from_date,
        "search[to_date]" => to_date,
        "search[group_by]" => params["group_by"] || "1"
      })

    url =
      "/companies/#{socket.assigns.current_company.id}/egg_stock/production_report?#{qry}"

    {:noreply, push_patch(socket, to: url)}
  end

  defp parse_group_by(nil), do: 1
  defp parse_group_by(""), do: 1

  defp parse_group_by(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp load_rows(socket, from_str, to_str, group_by) do
    with {:ok, from_date} <- Date.from_iso8601(from_str),
         {:ok, to_date} <- Date.from_iso8601(to_str),
         true <- Date.compare(from_date, to_date) != :gt do
      rows =
        EggStock.production_report(socket.assigns.current_company.id, from_date, to_date)
        |> group_rows(group_by, socket.assigns.grades)

      assign(socket, rows: rows, averages: compute_averages(rows, socket.assigns.grades))
    else
      _ -> assign(socket, rows: [], averages: nil)
    end
  end

  defp group_rows(rows, 1, _grades), do: Enum.map(rows, &Map.put(&1, :label, Date.to_iso8601(&1.date)))

  defp group_rows(rows, n, grades) do
    grade_names = Enum.map(grades, & &1.name)

    rows
    |> Enum.chunk_every(n)
    |> Enum.map(fn chunk ->
      sum_by_grade =
        Enum.reduce(chunk, Map.new(grade_names, &{&1, 0}), fn row, acc ->
          Map.merge(acc, row.quantities, fn _k, v1, v2 -> v1 + v2 end)
        end)

      total = Enum.reduce(chunk, 0, fn r, acc -> acc + r.total end)
      first = List.first(chunk).date
      last = List.last(chunk).date

      label =
        if first == last,
          do: Date.to_iso8601(first),
          else: "#{Date.to_iso8601(first)} ~ #{Date.to_iso8601(last)}"

      %{date: first, quantities: sum_by_grade, total: total, label: label}
    end)
  end

  defp compute_averages([], _grades), do: nil

  defp compute_averages(rows, grades) do
    count = length(rows)
    grade_names = Enum.map(grades, & &1.name)

    sum_by_grade =
      Enum.reduce(rows, Map.new(grade_names, &{&1, 0}), fn row, acc ->
        Map.merge(acc, row.quantities, fn _k, v1, v2 -> v1 + v2 end)
      end)

    total_sum = Enum.reduce(rows, 0, fn r, acc -> acc + r.total end)
    avg_by_grade = Map.new(sum_by_grade, fn {k, v} -> {k, div(v, count)} end)
    avg_total = div(total_sum, count)

    %{quantities: avg_by_grade, total: avg_total, overall_total: total_sum}
  end

  defp pct(_v, 0), do: "0.00%"

  defp pct(v, total) do
    (v / total * 100) |> Number.Percentage.number_to_percentage(precision: 2)
  end

  defp fmt(v), do: Number.Delimit.number_to_delimited(v, precision: 0)

  defp label_of(grade), do: grade.nickname || grade.name

  defp short_date(%Date{} = d), do: "#{pad2(d.month)}/#{pad2(d.day)}"
  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp short_label(%{date: date, label: label}) do
    case String.split(label, " ~ ") do
      [_one] ->
        short_date(date)

      [_first, last_str] ->
        case Date.from_iso8601(last_str) do
          {:ok, last} -> "#{short_date(date)}~#{short_date(last)}"
          _ -> short_date(date)
        end
    end
  end

  @chart_colors ~w(#ef4444 #3b82f6 #10b981 #f59e0b #8b5cf6 #ec4899 #14b8a6 #f97316 #84cc16 #6366f1)

  defp color_for(idx), do: Enum.at(@chart_colors, rem(idx, length(@chart_colors)))

  defp chart_data(rows, grades) do
    n = length(rows)

    series =
      grades
      |> Enum.with_index()
      |> Enum.map(fn {g, gi} ->
        points =
          rows
          |> Enum.with_index()
          |> Enum.map(fn {row, ri} ->
            x = if n <= 1, do: 0.0, else: ri / (n - 1)
            qty = Map.get(row.quantities, g.name, 0)
            pct = if row.total > 0, do: qty / row.total * 100, else: 0.0
            {x, pct, row.label, qty}
          end)

        %{name: label_of(g), color: color_for(gi), points: points}
      end)

    step = if n <= 8, do: 1, else: max(div(n - 1, 6), 1)

    x_labels =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {_, i} -> rem(i, step) == 0 or i == n - 1 end)
      |> Enum.map(fn {r, i} ->
        {if(n <= 1, do: 0.0, else: i / (n - 1)), short_label(r)}
      end)

    %{series: series, x_labels: x_labels}
  end

  defp sx(x_frac, width, pad_l, pad_r) do
    inner = width - pad_l - pad_r
    pad_l + x_frac * inner
  end

  @y_max 40.0

  defp sy(pct, height, pad_t, pad_b) do
    inner = height - pad_t - pad_b
    clamped = pct |> min(@y_max) |> max(0.0)
    pad_t + (@y_max - clamped) / @y_max * inner
  end

  defp path_d(points, width, height, pad_l, pad_r, pad_t, pad_b) do
    points
    |> Enum.with_index()
    |> Enum.map(fn {{x, y, _, _}, i} ->
      cmd = if i == 0, do: "M", else: "L"
      "#{cmd}#{Float.round(sx(x, width, pad_l, pad_r), 2)},#{Float.round(sy(y, height, pad_t, pad_b), 2)}"
    end)
    |> Enum.join(" ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-10/12 mx-auto">
      <p class="text-2xl text-center font-medium">{@page_title}</p>

      <div class="border rounded bg-purple-200 text-center p-2 mb-3">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2 tracking-tighter">
            <div class="col-span-3">
              <.input
                label={gettext("From")}
                name="search[from_date]"
                type="date"
                id="search_from_date"
                value={@search.from_date}
              />
            </div>
            <div class="col-span-3">
              <.input
                label={gettext("To")}
                name="search[to_date]"
                type="date"
                id="search_to_date"
                value={@search.to_date}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("Group by (days)")}
                name="search[group_by]"
                type="number"
                min="1"
                id="search_group_by"
                value={@search.group_by}
              />
            </div>
            <div class="col-span-2 mt-6 text-left">
              <.button>{gettext("Query")}</.button>
            </div>
          </div>
        </.form>
      </div>

      <div :if={@rows != []} class="mb-4 border rounded bg-white p-2">
        <% chart = chart_data(@rows, @grades) %>
        <% width = 1000 %>
        <% height = 320 %>
        <% pad_l = 40 %>
        <% pad_r = 20 %>
        <% pad_t = 20 %>
        <% pad_b = 50 %>
        <svg viewBox={"0 0 #{width} #{height}"} class="w-full h-80" preserveAspectRatio="none">
          <%= for pct <- [0, 10, 20, 30, 40] do %>
            <line
              x1={pad_l}
              x2={width - pad_r}
              y1={sy(pct, height, pad_t, pad_b)}
              y2={sy(pct, height, pad_t, pad_b)}
              stroke="#e5e7eb"
              stroke-width="1"
            />
            <text
              x={pad_l - 5}
              y={sy(pct, height, pad_t, pad_b) + 4}
              text-anchor="end"
              font-size="11"
              fill="#6b7280"
            >
              {pct}%
            </text>
          <% end %>
          <%= for {x_frac, lbl} <- chart.x_labels do %>
            <text
              x={sx(x_frac, width, pad_l, pad_r)}
              y={height - pad_b + 15}
              text-anchor="end"
              font-size="10"
              fill="#6b7280"
              transform={"rotate(-35, #{sx(x_frac, width, pad_l, pad_r)}, #{height - pad_b + 15})"}
            >
              {lbl}
            </text>
          <% end %>
          <%= for s <- chart.series do %>
            <path
              d={path_d(s.points, width, height, pad_l, pad_r, pad_t, pad_b)}
              fill="none"
              stroke={s.color}
              stroke-width="2"
            />
            <%= for {x, y, lbl, qty} <- s.points do %>
              <circle
                cx={sx(x, width, pad_l, pad_r)}
                cy={sy(y, height, pad_t, pad_b)}
                r="3"
                fill={s.color}
              >
                <title>{"#{s.name} @ #{lbl}: #{fmt(qty)} (#{Float.round(y, 2)}%)"}</title>
              </circle>
            <% end %>
          <% end %>
        </svg>
        <div class="flex flex-wrap justify-center gap-4 mt-2 text-sm">
          <%= for s <- chart.series do %>
            <div class="flex items-center gap-1">
              <span class="inline-block w-4 h-1" style={"background-color: #{s.color}"}></span>
              <span>{s.name}</span>
            </div>
          <% end %>
        </div>
      </div>

      <div class="flex flex-row font-medium text-center tracking-tighter mb-1">
        <div class="w-[18%] border rounded bg-gray-200 border-gray-400 px-1 py-1">
          {gettext("Date")}
        </div>
        <%= for g <- @grades do %>
          <div class="flex-1 border rounded bg-gray-200 border-gray-400 px-1 py-1">
            {label_of(g)}
          </div>
        <% end %>
        <div class="flex-1 border rounded bg-gray-300 border-gray-500 px-1 py-1">
          {gettext("Total")}
        </div>
      </div>

      <%= for row <- @rows do %>
        <div class="flex flex-row text-center tracking-tighter">
          <div class="w-[18%] border rounded bg-blue-100 border-blue-300 px-1 py-1">
            {row.label}
          </div>
          <%= for g <- @grades do %>
            <div class="flex-1 border rounded bg-blue-100 border-blue-300 px-1 py-1">
              {fmt(Map.get(row.quantities, g.name, 0))} / {pct(Map.get(row.quantities, g.name, 0), row.total)}
            </div>
          <% end %>
          <div class="flex-1 border rounded bg-blue-200 border-blue-400 px-1 py-1">
            {fmt(row.total)}
          </div>
        </div>
      <% end %>

      <div :if={@averages} class="flex flex-row text-center font-bold tracking-tighter mt-1">
        <div class="w-[18%] border rounded bg-amber-200 border-amber-400 px-1 py-1">
          {gettext("Average")}
        </div>
        <%= for g <- @grades do %>
          <div class="flex-1 border rounded bg-amber-200 border-amber-400 px-1 py-1">
            {fmt(Map.get(@averages.quantities, g.name, 0))} / {pct(Map.get(@averages.quantities, g.name, 0), @averages.total)}
          </div>
        <% end %>
        <div class="flex-1 border rounded bg-amber-300 border-amber-500 px-1 py-1">
          {fmt(@averages.total)}
        </div>
      </div>

      <div :if={@rows == []} class="text-center text-gray-500 mt-6">
        {gettext("No data for the selected date range.")}
      </div>
    </div>
    """
  end
end
