defmodule FullCircleWeb.EggStockLive.LoadingList do
  use FullCircleWeb, :live_view

  alias FullCircle.EggStock

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    grades = EggStock.list_grades(company.id)
    grade_names = Enum.map(grades, & &1.name)
    grade_labels = Map.new(grades, fn g -> {g.name, g.nickname || g.name} end)

    ids = params |> Map.get("ids", "") |> String.split(",", trim: true)
    {source, date_label} = parse_source(params)
    groups = EggStock.loading_list_groups(company.id, source, ids)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Loading List"),
       date_label: date_label,
       sheet_title: sheet_title(source),
       groups: groups,
       grade_names: grade_names,
       grade_labels: grade_labels,
       # numbered/1 only adds a :no key per row, so totalling before it is safe
       grand_total: total_of(groups, grade_names),
       company: FullCircle.Sys.get_company!(company.id)
     )}
  end

  # The weekly href carries an explicit board-anchored `date`, so the sheet shows
  # the same date as the DOW button that was clicked. URLs copied before that
  # param existed still work: fall back to anchoring the weekday on today.
  defp parse_source(%{"src" => "dow", "kind" => kind, "dow" => dow_str} = params)
       when kind in ["sales", "purchase"] do
    dow = String.to_integer(dow_str)

    date =
      case params["date"] do
        d when is_binary(d) and d != "" -> Date.from_iso8601!(d)
        _ -> EggStock.dow_date(Date.utc_today(), dow)
      end

    {{:dow, kind, dow}, "#{dow_label(dow)} #{FullCircleWeb.Helpers.format_date(date)}"}
  end

  defp parse_source(%{"src" => "day", "date" => date_str}) do
    date = Date.from_iso8601!(date_str)
    {{:day, date}, FullCircleWeb.Helpers.format_date(date)}
  end

  # Only the weekly purchase book prints purchases; `src=day` is always sales
  # (the Stock tab renders planned purchases with `selectable={false}`).
  defp sheet_title({:dow, "purchase", _dow}), do: gettext("Planned purchases — loading list")
  defp sheet_title(_source), do: gettext("Planned sales — loading list")

  defp dow_label(1), do: gettext("Mon")
  defp dow_label(2), do: gettext("Tue")
  defp dow_label(3), do: gettext("Wed")
  defp dow_label(4), do: gettext("Thu")
  defp dow_label(5), do: gettext("Fri")
  defp dow_label(6), do: gettext("Sat")
  defp dow_label(7), do: gettext("Sun")

  defp qty(row, grade), do: EggStock.to_int(row.quantities[grade])

  defp row_total(row, grade_names),
    do: Enum.reduce(grade_names, 0, fn g, acc -> acc + qty(row, g) end)

  defp group_subtotal(rows, grade), do: Enum.reduce(rows, 0, fn r, acc -> acc + qty(r, grade) end)

  defp group_total(rows, grade_names),
    do: Enum.reduce(rows, 0, fn r, acc -> acc + row_total(r, grade_names) end)

  defp total_of(groups, grade_names),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + group_total(g.rows, grade_names) end)

  defp grand_subtotal(groups, grade),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + group_subtotal(g.rows, grade) end)

  # Running row number across all groups, so the sheet numbers 1..n end to end.
  defp numbered(groups) do
    {numbered, _} =
      Enum.map_reduce(groups, 1, fn group, start ->
        {rows, next} =
          Enum.map_reduce(group.rows, start, fn row, n -> {Map.put(row, :no, n), n + 1} end)

        {%{group | rows: rows}, next}
      end)

    numbered
  end

  defp render_group(assigns) do
    ~H"""
    <tr :if={@group.group_name != ""} class="group-row">
      <td colspan={length(@grade_names) + 4}>{@group.group_name}</td>
    </tr>
    <tr :for={row <- @group.rows}>
      <td class="no-col">{row.no}</td>
      <td class="contact-name">{row.contact_name}</td>
      <td :for={g <- @grade_names}>{qty(row, g)}</td>
      <td>{row_total(row, @grade_names)}</td>
      <td class="tick-col"></td>
    </tr>
    <tr :if={@show_subtotal} class="subtotal-row">
      <td class="no-col"></td>
      <td class="contact-name">{gettext("Subtotal")}</td>
      <td :for={g <- @grade_names}>{group_subtotal(@group.rows, g)}</td>
      <td>{group_total(@group.rows, @grade_names)}</td>
      <td class="tick-col"></td>
    </tr>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, numbered(assigns.groups))

    ~H"""
    <div id="print-me" class="print-here">
      <style>
        .page {
          width: 210mm;
          min-height: 290mm;
          padding: 10mm;
          font-size: 12px;
          position: relative;
        }
        @media print {
          .page { padding: 5mm; margin: 0; }
        }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #ccc; padding: 4px 5px; text-align: center; }
        th { background: #f3f4f6; font-weight: 600; }
        .no-col { width: 26px; }
        .contact-name { text-align: left; }
        .tick-col { width: 34px; }
        .group-row td {
          text-align: left;
          background: #e5e7eb;
          font-weight: 700;
          padding: 4px 5px;
        }
        .subtotal-row td { font-weight: 700; background: #fafafa; }
        .total-row td { font-weight: 700; border-top: 2px solid #666; }
        h1 { text-align: center; font-size: 18px; font-weight: 700; margin-bottom: 2px; }
        h2 { text-align: center; font-size: 14px; font-weight: 600; color: #555; margin-bottom: 10px; }
        .company-name { text-align: center; font-size: 14px; font-weight: 600; margin-bottom: 2px; }
        .sign-row { display: flex; gap: 40px; margin-top: 30px; }
        .sign-box { flex: 1; border-top: 1px solid #666; padding-top: 4px; text-align: center; }
      </style>

      <div class="page">
        <div class="company-name">{@company.name}</div>
        <h1>{@sheet_title}</h1>
        <h2>{@date_label}</h2>

        <table>
          <thead>
            <tr>
              <th class="no-col">#</th>
              <th class="contact-name">{gettext("Contact")}</th>
              <th :for={g <- @grade_names}>{@grade_labels[g]}</th>
              <th>{gettext("Total")}</th>
              <th class="tick-col">✓</th>
            </tr>
          </thead>
          <tbody>
            <%!-- A lone group's subtotal just repeats the grand total, so skip it. --%>
            <.render_group
              :for={group <- @groups}
              group={group}
              grade_names={@grade_names}
              show_subtotal={length(@groups) > 1}
            />
            <tr class="total-row">
              <td class="no-col"></td>
              <td class="contact-name">{gettext("Total")}</td>
              <td :for={g <- @grade_names}>{grand_subtotal(@groups, g)}</td>
              <td>{@grand_total}</td>
              <td class="tick-col"></td>
            </tr>
          </tbody>
        </table>

        <div class="sign-row">
          <div class="sign-box">{gettext("Loaded by")}</div>
          <div class="sign-box">{gettext("Checked by")}</div>
        </div>
      </div>
    </div>
    """
  end
end
