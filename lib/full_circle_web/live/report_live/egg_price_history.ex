defmodule FullCircleWeb.ReportLive.EggPriceHistory do
  use FullCircleWeb, :live_view

  alias FullCircle.Product

  # Distinct colours per egg grade (continuous layout)
  @grade_colors %{
    "Egg Grade AA" => "#7c3aed",
    "Egg Grade A" => "#2563eb",
    "Egg Grade B" => "#0891b2",
    "Egg Grade C" => "#16a34a",
    "Egg Grade D" => "#ca8a04",
    "Egg Grade E" => "#ea580c",
    "Egg Grade F" => "#dc2626",
    "Egg Grade White" => "#64748b",
    "Egg Grade Crack" => "#db2777",
    "Egg Grade Dirty" => "#78716c",
    "Egg Grade Broken" => "#a16207",
    "Egg Grade G" => "#4f46e5"
  }

  # Year overlay palette (cycled; latest years get stronger stroke in build)
  @year_colors [
    "#0f766e",
    "#1d4ed8",
    "#7c3aed",
    "#be123c",
    "#c2410c",
    "#a16207",
    "#15803d",
    "#0369a1",
    "#4c1d95",
    "#9f1239",
    "#365314",
    "#0e7490"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_role] != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Not authorized."))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    else
      {:ok, assign(socket, page_title: gettext("Egg Price History"))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = params["search"] || %{}
    today = Timex.today()

    side = search["side"] || "sale"
    f_date = search["f_date"] || "#{Date.new!(today.year - 5, 1, 1)}"
    t_date = search["t_date"] || "#{today}"
    layout = parse_layout(search["layout"])
    grades = parse_grades(search["grades"])

    {:noreply,
     socket
     |> assign(
       search: %{side: side, f_date: f_date, t_date: t_date, layout: layout, grades: grades}
     )
     |> load_chart(side, f_date, t_date, grades, layout)}
  end

  @impl true
  def handle_event("query", %{"search" => search}, socket) do
    grades =
      Product.default_egg_grade_names()
      |> Enum.filter(fn name -> search[grade_param(name)] == "true" end)

    qry = %{
      "search[side]" => search["side"] || "sale",
      "search[f_date]" => search["f_date"] || "",
      "search[t_date]" => search["t_date"] || "",
      "search[layout]" => search["layout"] || "continuous",
      "search[grades]" => Enum.join(grades, ",")
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/egg_price_history?#{URI.encode_query(qry)}"

    {:noreply, push_navigate(socket, to: url)}
  end

  defp load_chart(socket, side, f_date, t_date, grades, layout) do
    company_id = socket.assigns.current_company.id

    with {:ok, from} <- Date.from_iso8601(f_date),
         {:ok, to} <- Date.from_iso8601(t_date),
         true <- Date.compare(from, to) != :gt,
         true <- grades != [] do
      rows =
        Product.egg_price_history_monthly(company_id,
          side: side,
          from: from,
          to: to,
          names: grades
        )

      {chart, trend_stats} =
        case layout do
          "by_year" -> {build_year_overlay(rows), nil}
          "trend" -> build_price_trend(rows)
          _ -> {build_grade_timeline(rows, grades), nil}
        end

      year_summary =
        if layout == "by_year", do: year_month_table(rows), else: []

      socket
      |> assign(
        rows: rows,
        chart: chart,
        year_summary: year_summary,
        trend_stats: trend_stats,
        error: nil
      )
    else
      :error ->
        assign(socket,
          rows: [],
          chart: empty_chart(),
          year_summary: [],
          trend_stats: nil,
          error: gettext("Invalid date range")
        )

      false ->
        assign(socket,
          rows: [],
          chart: empty_chart(),
          year_summary: [],
          trend_stats: nil,
          error: gettext("Check dates and grades")
        )

      _ ->
        assign(socket,
          rows: [],
          chart: empty_chart(),
          year_summary: [],
          trend_stats: nil,
          error: gettext("Unable to load chart")
        )
    end
  end

  defp parse_layout("by_year"), do: "by_year"
  defp parse_layout("trend"), do: "trend"
  defp parse_layout(_), do: "continuous"

  defp parse_grades(nil), do: Product.default_egg_grade_names()
  defp parse_grades(""), do: Product.default_egg_grade_names()

  defp parse_grades(csv) when is_binary(csv) do
    names =
      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if names == [], do: Product.default_egg_grade_names(), else: names
  end

  defp grade_param(name), do: "g_" <> (name |> String.replace(" ", "_") |> String.downcase())

  defp grade_color(name), do: Map.get(@grade_colors, name, "#334155")

  defp year_color(year, years) do
    # Newest year first in palette so recent years stand out
    sorted = Enum.sort(years, :desc)
    idx = Enum.find_index(sorted, &(&1 == year)) || 0
    Enum.at(@year_colors, rem(idx, length(@year_colors)))
  end

  defp empty_chart do
    %{
      title: nil,
      subtitle: nil,
      width: 960,
      height: 420,
      pad_l: 56,
      pad_r: 16,
      pad_t: 24,
      pad_b: 48,
      series: [],
      x_ticks: [],
      y_ticks: [],
      min_price: 0,
      max_price: 1
    }
  end

  # Continuous: one line per egg grade over calendar time.
  defp build_grade_timeline([], _grades), do: empty_chart()

  defp build_grade_timeline(rows, grades) do
    months =
      rows
      |> Enum.map(& &1.month)
      |> Enum.uniq()
      |> Enum.sort(Date)

    {min_p, max_p} = price_range_from_floats(Enum.map(rows, &decimal_to_float(&1.avg_price)))

    dims = chart_dims(height: 420, pad_t: 20)
    x_at = x_scaler(months, dims, :timeline)
    y_at = y_scaler(min_p, max_p, dims)

    series =
      grades
      |> Enum.map(fn name ->
        points =
          rows
          |> Enum.filter(&(&1.good_name == name))
          |> Enum.sort_by(& &1.month, Date)
          |> Enum.map(fn r ->
            price = decimal_to_float(r.avg_price)

            %{
              month: r.month,
              price: price,
              x: x_at.(r.month),
              y: y_at.(price),
              lines: r.lines,
              label: Calendar.strftime(r.month, "%b %Y")
            }
          end)

        %{
          name: short_grade(name),
          full_name: name,
          color: grade_color(name),
          stroke_width: 2.2,
          stroke_dasharray: nil,
          show_dots: true,
          points: points,
          path: polyline_path(points)
        }
      end)
      |> Enum.reject(&(&1.points == []))

    Map.merge(dims, %{
      title: nil,
      subtitle: nil,
      series: series,
      x_ticks: x_tick_labels_timeline(months, x_at),
      y_ticks: y_tick_values(min_p, max_p, y_at),
      min_price: min_p,
      max_price: max_p
    })
  end

  # Timeline of weighted avg price + 12-month MA + linear regression trend.
  defp build_price_trend([]), do: {empty_chart(), nil}

  defp build_price_trend(rows) do
    avg_rows = monthly_weighted_avg_series(rows)

    if avg_rows == [] do
      {empty_chart(), nil}
    else
      months = Enum.map(avg_rows, & &1.month)
      prices = Enum.map(avg_rows, & &1.price)
      ma = moving_average(prices, 12)
      {slope, intercept} = linear_regression(prices)

      trend_prices =
        prices
        |> Enum.with_index()
        |> Enum.map(fn {_p, i} -> intercept + slope * i end)

      all_for_scale = prices ++ Enum.reject(ma, &is_nil/1) ++ trend_prices
      {min_p, max_p} = price_range_from_floats(all_for_scale)

      dims = chart_dims(height: 460, pad_t: 48)
      x_at = x_scaler(months, dims, :timeline)
      y_at = y_scaler(min_p, max_p, dims)

      actual_points =
        Enum.map(avg_rows, fn r ->
          %{
            month: r.month,
            price: r.price,
            x: x_at.(r.month),
            y: y_at.(r.price),
            lines: r.lines,
            label: Calendar.strftime(r.month, "%b %Y")
          }
        end)

      ma_points =
        avg_rows
        |> Enum.zip(ma)
        |> Enum.reject(fn {_r, m} -> is_nil(m) end)
        |> Enum.map(fn {r, m} ->
          %{
            month: r.month,
            price: m,
            x: x_at.(r.month),
            y: y_at.(m),
            lines: r.lines,
            label: Calendar.strftime(r.month, "%b %Y")
          }
        end)

      trend_points =
        avg_rows
        |> Enum.with_index()
        |> Enum.map(fn {r, i} ->
          p = intercept + slope * i

          %{
            month: r.month,
            price: p,
            x: x_at.(r.month),
            y: y_at.(p),
            lines: r.lines,
            label: Calendar.strftime(r.month, "%b %Y")
          }
        end)

      series = [
        %{
          name: gettext("Monthly avg"),
          full_name: gettext("Monthly avg"),
          color: "#2563eb",
          stroke_width: 1.8,
          stroke_dasharray: nil,
          show_dots: true,
          points: actual_points,
          path: polyline_path(actual_points)
        },
        %{
          name: gettext("12-mo moving avg"),
          full_name: gettext("12-mo moving avg"),
          color: "#16a34a",
          stroke_width: 2.6,
          stroke_dasharray: nil,
          show_dots: false,
          points: ma_points,
          path: polyline_path(ma_points)
        },
        %{
          name: gettext("Linear trend"),
          full_name: gettext("Linear trend"),
          color: "#dc2626",
          stroke_width: 2.2,
          stroke_dasharray: "8 5",
          show_dots: false,
          points: trend_points,
          path: polyline_path(trend_points)
        }
      ]

      n = length(prices)
      per_year = slope * 12
      first = List.first(prices)
      last = List.last(prices)
      total_chg = if first && first != 0, do: (last - first) / first * 100, else: 0.0

      direction =
        cond do
          abs(per_year) < 0.0005 -> gettext("flat")
          per_year > 0 -> gettext("rising")
          true -> gettext("falling")
        end

      stats = %{
        months: n,
        slope_per_month: slope,
        slope_per_year: per_year,
        direction: direction,
        first_price: first,
        last_price: last,
        total_change_pct: total_chg,
        start_month: List.first(months),
        end_month: List.last(months)
      }

      chart =
        Map.merge(dims, %{
          title: gettext("Average egg price trend"),
          subtitle:
            gettext(
              "Weighted avg of selected grades · blue = monthly · green = 12-mo MA · red dashed = linear trend"
            ),
          series: series,
          x_ticks: x_tick_labels_timeline(months, x_at),
          y_ticks: y_tick_values(min_p, max_p, y_at),
          min_price: min_p,
          max_price: max_p
        })

      {chart, stats}
    end
  end

  # Overlay by year: one line per year on a shared Jan–Dec axis.
  # Y = line-weighted average unit price across the selected grades.
  # Also draws multi-year seasonal average as a dashed baseline.
  defp build_year_overlay([]), do: empty_chart()

  defp build_year_overlay(rows) do
    avg_rows = monthly_weighted_avg_series(rows)

    years =
      avg_rows
      |> Enum.map(& &1.year)
      |> Enum.uniq()
      |> Enum.sort()

    months_axis = Enum.map(1..12, fn m -> Date.new!(2000, m, 1) end)

    seasonal =
      1..12
      |> Enum.map(fn mon ->
        group = Enum.filter(avg_rows, &(&1.month_num == mon))
        prices = Enum.map(group, & &1.price)

        avg =
          if prices == [], do: nil, else: Enum.sum(prices) / length(prices)

        %{
          month: Date.new!(2000, mon, 1),
          month_num: mon,
          price: avg,
          lines: Enum.sum(Enum.map(group, & &1.lines))
        }
      end)
      |> Enum.reject(fn r -> is_nil(r.price) end)

    {min_p, max_p} =
      price_range_from_floats(
        Enum.map(avg_rows, & &1.price) ++ Enum.map(seasonal, & &1.price)
      )

    dims = chart_dims(height: 460, pad_t: 48)
    x_at = x_scaler(months_axis, dims, :month_of_year)
    y_at = y_scaler(min_p, max_p, dims)
    newest = List.last(years)

    year_series =
      years
      |> Enum.map(fn year ->
        points =
          avg_rows
          |> Enum.filter(&(&1.year == year))
          |> Enum.sort_by(& &1.month_num)
          |> Enum.map(fn r ->
            %{
              month: r.month,
              price: r.price,
              x: x_at.(r.month),
              y: y_at.(r.price),
              lines: r.lines,
              label: Calendar.strftime(r.month, "%b %Y")
            }
          end)

        %{
          name: Integer.to_string(year),
          full_name: Integer.to_string(year),
          color: year_color(year, years),
          stroke_width: if(year == newest, do: 3.0, else: 1.8),
          stroke_dasharray: nil,
          show_dots: year == newest,
          points: points,
          path: polyline_path(points)
        }
      end)
      |> Enum.reject(&(&1.points == []))

    seasonal_points =
      Enum.map(seasonal, fn r ->
        %{
          month: r.month,
          price: r.price,
          x: x_at.(r.month),
          y: y_at.(r.price),
          lines: r.lines,
          label: Calendar.strftime(r.month, "%b")
        }
      end)

    seasonal_series = %{
      name: gettext("Seasonal avg"),
      full_name: gettext("Multi-year seasonal average"),
      color: "#0f172a",
      stroke_width: 2.8,
      stroke_dasharray: "6 4",
      show_dots: false,
      points: seasonal_points,
      path: polyline_path(seasonal_points)
    }

    series = year_series ++ [seasonal_series]

    x_ticks =
      Enum.map(months_axis, fn m ->
        %{x: x_at.(m), label: Calendar.strftime(m, "%b")}
      end)

    Map.merge(dims, %{
      title: gettext("Average egg price by year"),
      subtitle:
        gettext(
          "Weighted avg of selected grades · years overlaid · black dashed = multi-year seasonal avg"
        ),
      series: series,
      x_ticks: x_ticks,
      y_ticks: y_tick_values(min_p, max_p, y_at),
      min_price: min_p,
      max_price: max_p
    })
  end

  # One point per calendar month: weighted avg across selected grades.
  defp monthly_weighted_avg_series(rows) do
    rows
    |> Enum.group_by(fn r -> {r.month.year, r.month.month} end)
    |> Enum.map(fn {{year, mon}, group} ->
      {price, lines} = weighted_avg(group)

      %{
        year: year,
        month_num: mon,
        month: Date.new!(year, mon, 1),
        price: price,
        lines: lines
      }
    end)
    |> Enum.reject(fn r -> is_nil(r.price) end)
    |> Enum.sort_by(& &1.month, Date)
  end

  # Weighted average of grade monthly avgs by line count.
  defp weighted_avg(group) do
    {sum_px, sum_n} =
      Enum.reduce(group, {0.0, 0}, fn r, {acc_p, acc_n} ->
        p = decimal_to_float(r.avg_price)
        n = r.lines || 0

        if is_nil(p) or n <= 0 do
          {acc_p, acc_n}
        else
          {acc_p + p * n, acc_n + n}
        end
      end)

    if sum_n > 0, do: {sum_px / sum_n, sum_n}, else: {nil, 0}
  end

  # Trailing moving average; first window-1 points are nil.
  defp moving_average(values, window) when window > 1 do
    values
    |> Enum.with_index()
    |> Enum.map(fn {_v, i} ->
      if i + 1 < window do
        nil
      else
        slice = Enum.slice(values, i - window + 1, window)
        Enum.sum(slice) / window
      end
    end)
  end

  defp moving_average(values, _), do: values

  # Ordinary least squares: y = intercept + slope * x, x = 0..n-1
  defp linear_regression([]), do: {0.0, 0.0}
  defp linear_regression([y]), do: {0.0, y}

  defp linear_regression(ys) when is_list(ys) do
    n = length(ys)
    xs = Enum.to_list(0..(n - 1))

    sum_x = Enum.sum(xs)
    sum_y = Enum.sum(ys)
    sum_xy = Enum.zip(xs, ys) |> Enum.reduce(0.0, fn {x, y}, a -> a + x * y end)
    sum_x2 = Enum.reduce(xs, 0.0, fn x, a -> a + x * x end)

    denom = n * sum_x2 - sum_x * sum_x

    if denom == 0 do
      {0.0, sum_y / n}
    else
      slope = (n * sum_xy - sum_x * sum_y) / denom
      intercept = (sum_y - slope * sum_x) / n
      {slope, intercept}
    end
  end

  # Pivot table: rows = years, cols = months, cell = avg price
  defp year_month_table(rows) do
    avg_rows = monthly_weighted_avg_series(rows)

    years =
      avg_rows
      |> Enum.map(& &1.year)
      |> Enum.uniq()
      |> Enum.sort(:desc)

    by_ym = Map.new(avg_rows, fn r -> {{r.year, r.month_num}, r} end)

    Enum.map(years, fn year ->
      months =
        Enum.map(1..12, fn mon ->
          case Map.get(by_ym, {year, mon}) do
            nil -> nil
            r -> r
          end
        end)

      prices = for m <- months, m, do: m.price
      year_avg = if prices == [], do: nil, else: Enum.sum(prices) / length(prices)

      %{year: year, months: months, year_avg: year_avg}
    end)
  end

  defp chart_dims(opts) do
    height = Keyword.get(opts, :height, 420)
    pad_t = Keyword.get(opts, :pad_t, 24)
    pad_b = Keyword.get(opts, :pad_b, 48)
    pad_l = 56
    pad_r = 16
    width = 960

    %{
      width: width,
      height: height,
      pad_l: pad_l,
      pad_r: pad_r,
      pad_t: pad_t,
      pad_b: pad_b,
      plot_w: width - pad_l - pad_r,
      plot_h: height - pad_t - pad_b
    }
  end

  defp x_scaler(months, dims, :timeline) do
    month_index = months |> Enum.with_index() |> Map.new()
    n = max(length(months) - 1, 1)

    fn month ->
      i = Map.get(month_index, month, 0)
      dims.pad_l + dims.plot_w * i / n
    end
  end

  defp x_scaler(_months, dims, :month_of_year) do
    # Jan=0 … Dec=11
    n = 11

    fn month ->
      i = month.month - 1
      dims.pad_l + dims.plot_w * i / n
    end
  end

  defp y_scaler(min_p, max_p, dims) do
    span = max(max_p - min_p, 0.0001)

    fn price ->
      dims.pad_t + dims.plot_h * (1 - (price - min_p) / span)
    end
  end

  defp price_range_from_floats(prices) do
    prices = Enum.reject(prices, &is_nil/1)
    min_p = Enum.min(prices, fn -> 0.0 end)
    max_p = Enum.max(prices, fn -> 1.0 end)
    span = max(max_p - min_p, 0.05)
    min_p = max(min_p - span * 0.1, 0.0)
    max_p = max_p + span * 0.1
    {min_p, max_p}
  end

  defp polyline_path([]), do: ""

  defp polyline_path([first | rest]) do
    Enum.reduce(rest, "M #{fmt(first.x)} #{fmt(first.y)}", fn p, acc ->
      acc <> " L #{fmt(p.x)} #{fmt(p.y)}"
    end)
  end

  defp x_tick_labels_timeline(months, x_at) do
    count = length(months)

    step =
      cond do
        count <= 12 -> 1
        count <= 36 -> 3
        count <= 72 -> 6
        true -> 12
      end

    months
    |> Enum.with_index()
    |> Enum.filter(fn {_m, i} -> rem(i, step) == 0 or i == count - 1 end)
    |> Enum.map(fn {m, _} ->
      %{x: x_at.(m), label: Calendar.strftime(m, "%b %y")}
    end)
  end

  defp y_tick_values(min_p, max_p, y_at) do
    steps = 5
    span = max_p - min_p

    0..steps
    |> Enum.map(fn i ->
      v = min_p + span * i / steps
      %{y: y_at.(v), label: :erlang.float_to_binary(v, decimals: 3)}
    end)
  end

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_float(n), do: n
  defp decimal_to_float(n) when is_integer(n), do: n * 1.0
  defp decimal_to_float(_), do: nil

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp fmt_price(nil), do: "—"
  defp fmt_price(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt_price(%Decimal{} = d), do: FullCircleWeb.Helpers.format_unit_price(d)
  defp fmt_price(n), do: to_string(n)

  defp fmt_signed(n) when is_float(n) do
    sign = if n > 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(n, decimals: 4)
  end

  defp fmt_signed(n), do: to_string(n)

  defp short_grade("Egg Grade " <> rest), do: rest
  defp short_grade(name), do: name

  defp latest_by_grade(rows) do
    rows
    |> Enum.group_by(& &1.good_name)
    |> Enum.map(fn {name, rs} ->
      last = Enum.max_by(rs, & &1.month, Date)
      {name, last}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp month_labels, do: ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto mb-8">
      <p class="text-2xl text-center font-medium mb-2">{@page_title}</p>
      <p class="text-center text-sm text-gray-600 mb-3">
        {gettext(
          "Monthly average unit price (RM/pcs). Archive history plus live invoices after cutover."
        )}
      </p>

      <div class="border rounded bg-purple-200 p-3 mb-4">
        <.form for={%{}} id="egg-price-form" phx-submit="query" autocomplete="off">
          <div class="flex flex-wrap items-end gap-3 justify-center">
            <div class="w-36">
              <.input
                type="select"
                label={gettext("Side")}
                name="search[side]"
                id="search_side"
                value={@search.side}
                options={[{gettext("Sale"), "sale"}, {gettext("Purchase"), "purchase"}]}
              />
            </div>
            <div class="w-64">
              <.input
                type="select"
                label={gettext("Layout")}
                name="search[layout]"
                id="search_layout"
                value={@search.layout}
                options={[
                  {gettext("By grade (timeline)"), "continuous"},
                  {gettext("Avg price overlay by year"), "by_year"},
                  {gettext("Avg price trend (+ MA)"), "trend"}
                ]}
              />
            </div>
            <div class="w-40">
              <.input
                type="date"
                label={gettext("From")}
                name="search[f_date]"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="w-40">
              <.input
                type="date"
                label={gettext("To")}
                name="search[t_date]"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="mt-5">
              <.button>{gettext("Query")}</.button>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 justify-center text-sm">
            <%= for name <- Product.default_egg_grade_names() do %>
              <label class="inline-flex items-center gap-1 cursor-pointer">
                <input
                  type="checkbox"
                  name={"search[#{grade_param(name)}]"}
                  value="true"
                  checked={name in @search.grades}
                  class="rounded"
                />
                <span style={"color: #{grade_color(name)}"} class="font-medium">
                  {short_grade(name)}
                </span>
              </label>
            <% end %>
          </div>
        </.form>
      </div>

      <div :if={@error} class="text-center text-red-700 mb-3">{@error}</div>

      <div :if={@chart.series != []} class="bg-white border rounded shadow-sm p-3 overflow-x-auto">
        <.price_chart chart={@chart} />

        <div class="flex flex-wrap gap-3 justify-center mt-3 text-sm">
          <%= for s <- @chart.series do %>
            <span class="inline-flex items-center gap-1">
              <span
                class="inline-block w-6 h-0 border-t-2"
                style={"border-color: #{s.color}; border-style: #{if s[:stroke_dasharray], do: "dashed", else: "solid"};"}
              >
              </span>
              <span class={if (s.stroke_width || 0) >= 3.0, do: "font-semibold", else: ""}>
                {s.name}
              </span>
            </span>
          <% end %>
        </div>

        <div
          :if={@trend_stats}
          class="mt-3 text-center text-sm text-slate-700 bg-slate-50 border rounded p-2"
        >
          <span class="font-medium capitalize">{@trend_stats.direction}</span>
          · {gettext("linear ≈")}
          <span class="font-semibold tabular-nums">
            {fmt_signed(@trend_stats.slope_per_year)}
          </span>
          {gettext("RM/pcs per year")}
          · {Calendar.strftime(@trend_stats.start_month, "%b %Y")}
          {fmt_price(@trend_stats.first_price)}
          → {Calendar.strftime(@trend_stats.end_month, "%b %Y")}
          {fmt_price(@trend_stats.last_price)}
          ({fmt_signed(@trend_stats.total_change_pct)}%)
        </div>
      </div>

      <div :if={@chart.series == [] and is_nil(@error)} class="text-center text-gray-500 py-10">
        {gettext("No price data for the selected filters.")}
      </div>

      <%!-- Year overlay: matrix of avg prices --%>
      <div :if={@search.layout == "by_year" and @year_summary != []} class="mt-6 overflow-x-auto">
        <p class="font-medium text-center mb-2">
          {gettext("Average egg price by month (selected grades)")}
        </p>
        <table class="mx-auto text-xs border-collapse">
          <thead>
            <tr class="bg-gray-200">
              <th class="border px-2 py-1 text-left">{gettext("Year")}</th>
              <%= for lab <- month_labels() do %>
                <th class="border px-2 py-1">{lab}</th>
              <% end %>
              <th class="border px-2 py-1">{gettext("Avg")}</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @year_summary do %>
              <tr>
                <td
                  class="border px-2 py-1 font-semibold"
                  style={"color: #{year_color(row.year, Enum.map(@year_summary, & &1.year))}"}
                >
                  {row.year}
                </td>
                <%= for cell <- row.months do %>
                  <td class="border px-2 py-1 text-right tabular-nums" title={if cell, do: "#{cell.lines} lines"}>
                    {if cell, do: fmt_price(cell.price), else: "—"}
                  </td>
                <% end %>
                <td class="border px-2 py-1 text-right font-medium tabular-nums">
                  {fmt_price(row.year_avg)}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Continuous: latest grade snapshot --%>
      <div :if={@search.layout == "continuous" and @rows != []} class="mt-6">
        <p class="font-medium text-center mb-2">{gettext("Latest month in range")}</p>
        <div class="overflow-x-auto">
          <table class="mx-auto text-sm border-collapse">
            <thead>
              <tr class="bg-gray-200">
                <th class="border px-3 py-1 text-left">{gettext("Grade")}</th>
                <th class="border px-3 py-1">{gettext("Month")}</th>
                <th class="border px-3 py-1">{gettext("Avg price")}</th>
                <th class="border px-3 py-1">{gettext("Min")}</th>
                <th class="border px-3 py-1">{gettext("Max")}</th>
                <th class="border px-3 py-1">{gettext("Lines")}</th>
              </tr>
            </thead>
            <tbody>
              <%= for {name, r} <- latest_by_grade(@rows) do %>
                <tr>
                  <td class="border px-3 py-1 font-medium" style={"color: #{grade_color(name)}"}>
                    {name}
                  </td>
                  <td class="border px-3 py-1 text-center">
                    {Calendar.strftime(r.month, "%b %Y")}
                  </td>
                  <td class="border px-3 py-1 text-right">
                    {FullCircleWeb.Helpers.format_unit_price(r.avg_price)}
                  </td>
                  <td class="border px-3 py-1 text-right">
                    {FullCircleWeb.Helpers.format_unit_price(r.min_price)}
                  </td>
                  <td class="border px-3 py-1 text-right">
                    {FullCircleWeb.Helpers.format_unit_price(r.max_price)}
                  </td>
                  <td class="border px-3 py-1 text-right">{r.lines}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :chart, :map, required: true

  defp price_chart(assigns) do
    ~H"""
    <svg
      viewBox={"0 0 #{@chart.width} #{@chart.height}"}
      class="w-full min-w-[720px] h-auto"
      role="img"
      aria-label={@chart.title || gettext("Egg price line chart")}
    >
      <text
        :if={@chart.title}
        x={@chart.width / 2}
        y="16"
        text-anchor="middle"
        font-size="15"
        font-weight="600"
        fill="#1e293b"
      >
        {@chart.title}
      </text>
      <text
        :if={@chart.subtitle}
        x={@chart.width / 2}
        y="32"
        text-anchor="middle"
        font-size="11"
        fill="#64748b"
      >
        {@chart.subtitle}
      </text>

      <rect
        x={@chart.pad_l}
        y={@chart.pad_t}
        width={@chart.width - @chart.pad_l - @chart.pad_r}
        height={@chart.height - @chart.pad_t - @chart.pad_b}
        fill="#f8fafc"
        stroke="#e2e8f0"
      />

      <%= for tick <- @chart.y_ticks do %>
        <line
          x1={@chart.pad_l}
          y1={tick.y}
          x2={@chart.width - @chart.pad_r}
          y2={tick.y}
          stroke="#e2e8f0"
          stroke-width="1"
        />
        <text x={@chart.pad_l - 8} y={tick.y + 4} text-anchor="end" font-size="11" fill="#475569">
          {tick.label}
        </text>
      <% end %>

      <%= for tick <- @chart.x_ticks do %>
        <text
          x={tick.x}
          y={@chart.height - 14}
          text-anchor="middle"
          font-size="11"
          fill="#475569"
        >
          {tick.label}
        </text>
      <% end %>

      <text
        x="16"
        y={@chart.height / 2}
        transform={"rotate(-90 16 #{@chart.height / 2})"}
        text-anchor="middle"
        font-size="12"
        fill="#334155"
      >
        {gettext("Unit price (RM)")}
      </text>

      <%= for s <- @chart.series do %>
        <path
          d={s.path}
          fill="none"
          stroke={s.color}
          stroke-width={s.stroke_width || 2.2}
          stroke-dasharray={s[:stroke_dasharray]}
          stroke-linejoin="round"
          stroke-linecap="round"
        />
        <%= if s[:show_dots] != false do %>
          <%= for p <- s.points do %>
            <circle cx={p.x} cy={p.y} r="2.6" fill={s.color}>
              <title>
                {s.name} · {p.label} · {fmt(p.price)} ({p.lines} lines)
              </title>
            </circle>
          <% end %>
        <% end %>
      <% end %>
    </svg>
    """
  end
end

