defmodule FullCircleWeb.EggStockLive.Print do
  use FullCircleWeb, :live_view

  alias FullCircle.EggStock

  @impl true
  def mount(%{"date" => date_str}, _session, socket) do
    company = socket.assigns.current_company
    date = Date.from_iso8601!(date_str)
    grades = EggStock.list_grades(company.id)
    grade_names = Enum.map(grades, & &1.name)
    grade_labels = Map.new(grades, fn g -> {g.name, g.nickname || g.name} end)

    day = EggStock.get_day(company.id, date) || %{closing_bal: %{}, expired: %{}, ungraded_bal: 0, note: nil}
    opening = EggStock.get_previous_closing_bal(company.id, date)
    actual_sales = EggStock.actual_sales_for_date(company.id, date)
    actual_purchases = EggStock.actual_purchases_for_date(company.id, date)
    harvested = EggStock.harvest_total_for_date(company.id, date)
    yesterday_ug = EggStock.get_previous_ungraded_bal(company.id, date)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Egg Stock Report"),
       date: date,
       day: day,
       opening: opening,
       grade_names: grade_names,
       grade_labels: grade_labels,
       actual_sales: actual_sales,
       actual_purchases: actual_purchases,
       harvested: harvested,
       yesterday_ug: yesterday_ug,
       company: FullCircle.Sys.get_company!(company.id)
     )}
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
              <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int((@opening || %{})[g]) end)}</td>
            </tr>

            <%!-- Purchases --%>
            <tr :if={@actual_purchases != []}>
              <td colspan={length(@grade_names) + 2} class="section-title">{gettext("Purchases")}</td>
            </tr>
            <tr :for={row <- @actual_purchases}>
              <td class="contact-name">{row.contact_name}</td>
              <td :for={g <- @grade_names} class="num">{(row.quantities || %{})[g] || 0}</td>
              <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int((row.quantities || %{})[g]) end)}</td>
            </tr>
            <tr :if={@actual_purchases != []} class="total-row">
              <td class="label-col">{gettext("Total Purchases")}</td>
              <td :for={g <- @grade_names} class="num">{actual_total(@actual_purchases, g)}</td>
              <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + actual_total(@actual_purchases, g) end)}</td>
            </tr>

            <%!-- Sales --%>
            <tr :if={@actual_sales != []}>
              <td colspan={length(@grade_names) + 2} class="section-title">{gettext("Sales")}</td>
            </tr>
            <tr :for={row <- @actual_sales}>
              <td class="contact-name">{row.contact_name}</td>
              <td :for={g <- @grade_names} class="num">{(row.quantities || %{})[g] || 0}</td>
              <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int((row.quantities || %{})[g]) end)}</td>
            </tr>
            <tr :if={@actual_sales != []} class="total-row">
              <td class="label-col">{gettext("Total Sales")}</td>
              <td :for={g <- @grade_names} class="num">{actual_total(@actual_sales, g)}</td>
              <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + actual_total(@actual_sales, g) end)}</td>
            </tr>

            <%!-- Expired --%>
            <tr>
              <td class="label-col">{gettext("Expired")}</td>
              <td :for={g <- @grade_names} class="num">{to_int(@expired[g])}</td>
              <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int(@expired[g]) end)}</td>
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
                <td class="num">{Enum.reduce(@grade_names, 0, fn g, acc -> acc + to_int(@productions[g]) end)}</td>
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
