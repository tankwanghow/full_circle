defmodule FullCircleWeb.EggStockLive.Print do
  use FullCircleWeb, :live_view

  alias FullCircle.EggStock
  alias FullCircle.EggStock.EggStockDayDetail

  @impl true
  def mount(%{"date" => date_str}, _session, socket) do
    company = socket.assigns.current_company
    date = Date.from_iso8601!(date_str)
    grades = EggStock.list_grades(company.id)
    grade_names = Enum.map(grades, & &1.name)
    grade_labels = Map.new(grades, fn g -> {g.name, g.nickname || g.name} end)
    is_today = Date.compare(date, Date.utc_today()) == :eq

    day =
      EggStock.get_day(company.id, date) ||
        %{
          closing_bal: %{},
          expired: %{},
          ungraded_bal: 0,
          note: nil,
          egg_stock_day_details: []
        }

    opening = EggStock.get_previous_closing_bal(company.id, date)
    actual_sales = EggStock.actual_sales_for_date(company.id, date)
    actual_purchases = EggStock.actual_purchases_for_date(company.id, date)
    harvested = EggStock.harvest_total_for_date(company.id, date)
    yesterday_ug = EggStock.get_previous_ungraded_bal(company.id, date)

    {purchase_lines, sales_lines} =
      if is_today do
        day
        |> prepare_today_board(company.id, date, actual_sales, actual_purchases)
        |> board_lines_by_section()
      else
        {[], []}
      end

    {:ok,
     socket
     |> assign(
       page_title: gettext("Egg Stock Report"),
       date: date,
       is_today: is_today,
       day: day,
       opening: opening,
       grade_names: grade_names,
       grade_labels: grade_labels,
       actual_sales: actual_sales,
       actual_purchases: actual_purchases,
       purchase_lines: purchase_lines,
       sales_lines: sales_lines,
       harvested: harvested,
       yesterday_ug: yesterday_ug,
       company: FullCircle.Sys.get_company!(company.id)
     )}
  end

  # Seed from weekly book (if empty), mix in doc-only contacts, overlay actual qtys.
  defp prepare_today_board(day, company_id, date, actual_sales, actual_purchases) do
    day = seed_planned_from_book(day, company_id, date)
    {day, _} = EggStock.ensure_planned_lines_for_actuals(day, actual_sales, actual_purchases)
    {day, _} = EggStock.sync_day_details_from_actuals(day, actual_sales, actual_purchases)
    day
  end

  defp seed_planned_from_book(day, company_id, date) do
    details = day.egg_stock_day_details || []
    dow = Date.day_of_week(date)

    details =
      seed_section_from_book(
        details,
        company_id,
        dow,
        :sales,
        EggStock.planned_sales_section(),
        EggStock.planned_sales_sections()
      )

    details =
      seed_section_from_book(
        details,
        company_id,
        dow,
        :purchase,
        EggStock.planned_purchase_section(),
        EggStock.planned_purchase_sections()
      )

    %{day | egg_stock_day_details: details}
  end

  defp seed_section_from_book(details, company_id, dow, kind, section, sections) do
    if Enum.any?(details, &(&1.section in sections)) do
      details
    else
      book_details =
        EggStock.list_dow_lines(company_id, kind, dow)
        |> Enum.with_index()
        |> Enum.map(fn {line, idx} ->
          %EggStockDayDetail{
            section: section,
            contact_id: line.contact_id,
            contact_name: line.contact_name,
            quantities: line.quantities || %{},
            group_name: line.group_name || "",
            group_position: line.group_position || 0,
            is_separator: line.is_separator || false,
            position: line.position || idx,
            ignore: false
          }
        end)

      details ++ book_details
    end
  end

  defp board_lines_by_section(day) do
    details = day.egg_stock_day_details || []

    purchases =
      details
      |> Enum.filter(&(&1.section in EggStock.planned_purchase_sections()))
      |> Enum.sort_by(&{&1.position || 0, &1.id || ""})

    sales =
      details
      |> Enum.filter(&(&1.section in EggStock.planned_sales_sections()))
      |> Enum.sort_by(&{&1.position || 0, &1.id || ""})

    {purchases, sales}
  end

  @impl true
  def render(assigns) do
    closing = assigns.day.closing_bal || %{}
    expired = assigns.day.expired || %{}
    grades = assigns.grade_names

    productions =
      Map.new(grades, fn g ->
        o = to_int((assigns.opening || %{})[g])
        c = to_int(closing[g])
        b = actual_total(assigns.actual_purchases, g)
        s = actual_total(assigns.actual_sales, g)
        e = to_int(expired[g])
        {g, s + e + c - o - b}
      end)

    harvest_plus_ug = assigns.harvested + assigns.yesterday_ug

    yields =
      Map.new(grades, fn g ->
        p = to_int(productions[g])
        {g, if(harvest_plus_ug > 0, do: Float.round(p / harvest_plus_ug * 100, 2), else: 0.0)}
      end)

    closing_total =
      Enum.reduce(grades, 0, fn g, acc -> acc + to_int(closing[g]) end)

    opening_total =
      Enum.reduce(grades, 0, fn g, acc -> acc + to_int((assigns.opening || %{})[g]) end)

    sold_total =
      Enum.reduce(grades, 0, fn g, acc -> acc + actual_total(assigns.actual_sales, g) end)

    purchased_total =
      Enum.reduce(grades, 0, fn g, acc -> acc + actual_total(assigns.actual_purchases, g) end)

    expired_total =
      Enum.reduce(grades, 0, fn g, acc -> acc + to_int(expired[g]) end)

    ug_today = assigns.day.ungraded_bal || 0

    loss =
      assigns.harvested + opening_total + purchased_total + assigns.yesterday_ug - ug_today -
        sold_total - closing_total - expired_total

    assigns =
      assigns
      |> assign(
        closing: closing,
        expired: expired,
        productions: productions,
        yields: yields,
        loss: loss,
        closing_total: closing_total,
        harvest_plus_ug: harvest_plus_ug
      )

    ~H"""
    <div id="print-me" class="print-here">
      <style>
        .page {
          width: 210mm;
          min-height: 290mm;
          padding: 10mm;
          font-size: 11px;
        }
        @media print {
          .page { padding: 5mm; margin: 0; }
        }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #ccc; padding: 3px 5px; text-align: center; }
        th { background: #f3f4f6; font-weight: 600; }
        .label-col { text-align: left; font-weight: 800; width: 120px; }
        .section-title { font-weight: 700; text-align: left; padding: 4px 5px; background: #e5e7eb; }
        .total-row td { font-weight: 700; border-top: 2px solid #666; }
        .contact-name { text-align: left; padding-left: 10px; max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .num { text-align: center; }
        .separator-row td {
          border-left: none;
          border-right: none;
          border-top: 1px dashed #888;
          border-bottom: 1px dashed #888;
          background: #fafafa;
          text-align: center;
          font-style: italic;
          color: #555;
          font-weight: 600;
          padding: 2px 5px;
        }
        h1 { text-align: center; font-size: 18px; font-weight: 700; margin-bottom: 2px; }
        h2 { text-align: center; font-size: 14px; font-weight: 600; color: #555; margin-bottom: 10px; }
        .company-name { text-align: center; font-size: 14px; font-weight: 600; margin-bottom: 2px; }
        .harvest-row { margin-top: 8px; }
        .harvest-row table { width: auto; }
        .harvest-row td { border: 1px solid #ccc; padding: 3px 8px; }
        .harvest-label { text-align: left; font-weight: 600; }
        .bottom-section { position: absolute; bottom: 10mm; left: 10mm; right: 10mm; }
        @media print { .bottom-section { bottom: 5mm; left: 5mm; right: 5mm; } }
        .page { position: relative; }
      </style>

      <div class="page">
        <div class="company-name">{@company.name}</div>
        <h1>{gettext("Egg Stock Report")}</h1>
        <h2>{FullCircleWeb.Helpers.format_date(@date)}</h2>

        <table>
          <thead>
            <tr>
              <th class="label-col"></th>
              <th :for={g <- @grade_names}>{@grade_labels[g]}</th>
              <th>{gettext("Total")}</th>
            </tr>
          </thead>
          <tbody>
            <%!-- Opening --%>
            <tr>
              <td class="label-col">{gettext("Opening")}</td>
              <td :for={g <- @grade_names} class="num">{to_int((@opening || %{})[g])}</td>
              <td class="num">
                {Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int((@opening || %{})[g]) end)}
              </td>
            </tr>

            <%!-- Purchases: today = board order + separators; history = actual docs --%>
            <%= if @is_today do %>
              <.board_section
                title={gettext("Purchases")}
                lines={@purchase_lines}
                grades={@grade_names}
              />
            <% else %>
              <.actual_section
                title={gettext("Purchases")}
                total_label={gettext("Total Purchases")}
                rows={@actual_purchases}
                grades={@grade_names}
              />
            <% end %>

            <%!-- Sales --%>
            <%= if @is_today do %>
              <.board_section
                title={gettext("Sales")}
                lines={@sales_lines}
                grades={@grade_names}
              />
            <% else %>
              <.actual_section
                title={gettext("Sales")}
                total_label={gettext("Total Sales")}
                rows={@actual_sales}
                grades={@grade_names}
              />
            <% end %>

            <%!-- Expired --%>
            <tr>
              <td class="label-col">{gettext("Expired")}</td>
              <td :for={g <- @grade_names} class="num">{to_int(@expired[g])}</td>
              <td class="num">
                {Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int(@expired[g]) end)}
              </td>
            </tr>
          </tbody>
        </table>

        <%!-- Note --%>
        <div :if={@day.note && @day.note != ""} style="margin-top: 8px;">
          <strong>{gettext("Note")}:</strong> {@day.note}
        </div>

        <%!-- Bottom section --%>
        <div class="bottom-section">
          <table>
            <thead>
              <tr>
                <th class="label-col"></th>
                <th :for={g <- @grade_names}>{@grade_labels[g]}</th>
                <th>{gettext("Total")}</th>
              </tr>
            </thead>
            <tbody>
              <%!-- Closing --%>
              <tr style="background: #f0f0f0; font-weight: 700;">
                <td class="label-col">{gettext("Closing")}</td>
                <td :for={g <- @grade_names} class="num">{to_int(@closing[g])}</td>
                <td class="num">{@closing_total}</td>
              </tr>

              <%!-- Production --%>
              <tr style="background: #f0fdf4;">
                <td class="label-col">{gettext("Production")}</td>
                <td :for={g <- @grade_names} class="num">{to_int(@productions[g])}</td>
                <td class="num">
                  {Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int(@productions[g]) end)}
                </td>
              </tr>

              <%!-- Yield --%>
              <tr style="background: #fefce8;">
                <td class="label-col">{gettext("Yield %")}</td>
                <td :for={g <- @grade_names} class="num">{@yields[g]}%</td>
                <td class="num"></td>
              </tr>
            </tbody>
          </table>

          <%!-- Harvest / UG / Loss --%>
          <div class="harvest-row">
            <table>
              <tr>
                <td class="harvest-label">{gettext("Harvested")}</td>
                <td class="num">{@harvested}</td>
                <td class="harvest-label">{gettext("Ytd UG")}</td>
                <td class="num">{@yesterday_ug}</td>
                <td class="harvest-label">{gettext("UG")}</td>
                <td class="num">{@day.ungraded_bal || 0}</td>
                <td class="harvest-label">{gettext("Loss")}</td>
                <td class="num">{@loss}</td>
              </tr>
            </table>
          </div>

          <div style="text-align: right; margin-top: 4px; font-size: 10px; color: #888;">
            {FullCircleWeb.Helpers.format_date(@date)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Today: planned board order + separators (quantities from day details / docs overlay)
  defp board_section(assigns) do
    content_lines = Enum.reject(assigns.lines || [], &separator?/1)
    has_content? = content_lines != [] or Enum.any?(assigns.lines || [], &separator?/1)

    assigns =
      assigns
      |> assign(:content_lines, content_lines)
      |> assign(:has_content?, has_content?)

    ~H"""
    <tr :if={@has_content?}>
      <td colspan={length(@grades) + 2} class="section-title">{@title}</td>
    </tr>
    <tr :for={line <- @lines} class={if separator?(line), do: "separator-row"}>
      <%= if separator?(line) do %>
        <td colspan={length(@grades) + 2}>
          {separator_label(line)}
        </td>
      <% else %>
        <td class="contact-name">{line.contact_name}</td>
        <td :for={g <- @grades} class="num">{qty(line, g)}</td>
        <td class="num">
          {Enum.reduce(@grades, 0, fn g, acc -> acc + qty(line, g) end)}
        </td>
      <% end %>
    </tr>
    <tr :if={@content_lines != []} class="total-row">
      <td class="label-col">{gettext("Total")}</td>
      <td :for={g <- @grades} class="num">{lines_total(@content_lines, g)}</td>
      <td class="num">
        {Enum.reduce(@grades, 0, fn g, acc -> acc + lines_total(@content_lines, g) end)}
      </td>
    </tr>
    """
  end

  # History: flat document actuals (no board order / separators)
  defp actual_section(assigns) do
    ~H"""
    <tr :if={@rows != []}>
      <td colspan={length(@grades) + 2} class="section-title">{@title}</td>
    </tr>
    <tr :for={row <- @rows}>
      <td class="contact-name">{row.contact_name}</td>
      <td :for={g <- @grades} class="num">{(row.quantities || %{})[g] || 0}</td>
      <td class="num">
        {Enum.reduce(@grades, 0, fn g, acc -> acc + to_int((row.quantities || %{})[g]) end)}
      </td>
    </tr>
    <tr :if={@rows != []} class="total-row">
      <td class="label-col">{@total_label}</td>
      <td :for={g <- @grades} class="num">{actual_total(@rows, g)}</td>
      <td class="num">
        {Enum.reduce(@grades, 0, fn g, acc -> acc + actual_total(@rows, g) end)}
      </td>
    </tr>
    """
  end

  defp separator?(line), do: Map.get(line, :is_separator) == true

  defp separator_label(line) do
    label = line.group_name || ""
    if String.trim(to_string(label)) == "", do: "—", else: label
  end

  defp qty(line, grade), do: to_int((line.quantities || %{})[grade])

  defp lines_total(lines, grade) do
    Enum.reduce(lines, 0, fn line, acc -> acc + qty(line, grade) end)
  end

  defp to_int(nil), do: 0
  defp to_int(""), do: 0
  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_float(v), do: round(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp actual_total(rows, grade) do
    Enum.reduce(rows, 0, fn row, acc ->
      acc + to_int((row.quantities || %{})[grade])
    end)
  end
end
