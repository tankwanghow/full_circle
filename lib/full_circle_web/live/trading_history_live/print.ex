defmodule FullCircleWeb.TradingHistoryLive.Print do
  @moduledoc """
  Printable load/drop movement history for a supply or sales position.
  """
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Trading
  alias FullCircle.Authorization

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    pre_print = Map.get(params, "pre_print", "false")
    kind = socket.assigns.live_action

    if Authorization.can?(user, :view_trading, company) do
      case load_history(kind, id, company, user) do
        {:ok, data} ->
          {:ok,
           socket
           |> assign(page_title: data.page_title)
           |> assign(:pre_print, pre_print)
           |> assign(:company, FullCircle.Sys.get_company!(company.id))
           |> assign(:kind, kind)
           |> assign(data)}

        {:error, :not_found} ->
          {:ok,
           socket
           |> put_flash(:error, gettext("Not found"))
           |> push_navigate(to: ~p"/companies/#{company.id}/trading/desk")}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  defp load_history(:supply, id, company, user) do
    try do
      supply = Trading.get_supply_position!(id, company, user)
      rows = Trading.list_supply_line_history(supply.id, company, user)
      unit = (supply.good && supply.good.unit) || default_unit(rows)
      totals = sum_history(rows)
      remaining = Decimal.sub(to_dec(supply.quantity), totals.load)

      {:ok,
       %{
         page_title: gettext("Print Supply History") <> " " <> (supply.title || ""),
         doc_label: gettext("SUPPLY — LOAD & DROP HISTORY"),
         party_label: gettext("Supplier"),
         party_name: supply.supplier && supply.supplier.name,
         doc_no: supply.title,
         status: supply.status,
         good_name: supply.good && supply.good.name,
         unit: unit,
         base_qty: supply.quantity,
         remaining_from: :load,
         show_loads: true,
         rows: rows,
         total_load: totals.load,
         total_drop: totals.drop,
         remaining: remaining
       }}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  defp load_history(:sales, id, company, user) do
    try do
      sales = Trading.get_sales_position!(id, company, user)
      rows = Trading.list_sales_line_history(sales.id, company, user)
      unit = (sales.good && sales.good.unit) || default_unit(rows)
      totals = sum_history(rows)
      remaining = Decimal.sub(to_dec(sales.quantity), totals.drop)

      {:ok,
       %{
         page_title: gettext("Print Sales History") <> " " <> (sales.title || ""),
         doc_label: gettext("SALES — DELIVERY HISTORY"),
         party_label: gettext("Customer"),
         party_name: sales.customer && sales.customer.name,
         doc_no: sales.title,
         status: sales.status,
         good_name: sales.good && sales.good.name,
         unit: unit,
         base_qty: sales.quantity,
         remaining_from: :drop,
         show_loads: false,
         rows: rows,
         total_load: totals.load,
         total_drop: totals.drop,
         remaining: remaining
       }}
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  defp load_history(_, _, _, _), do: {:error, :not_found}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}
      <div class="page">
        <div class="letter-head">
          {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
        </div>
        <div class="doctype is-size-6 has-text-weight-semibold">{@doc_label}</div>

        <div class="doc-header">
          <div class="left">
            <div class="is-size-6">{@party_label}</div>
            <div class="is-size-4 has-text-weight-semibold">{@party_name || "—"}</div>
            <div class="is-size-6 mt-2">
              {gettext("Good")}:
              <span class="has-text-weight-semibold">{@good_name || "—"}</span>
              <span :if={@unit}> ({@unit})</span>
            </div>
          </div>
          <div class="right is-size-5">
            <div>
              {if @kind == :supply, do: gettext("Supply no"), else: gettext("Sales no")}:
              <span class="has-text-weight-semibold">{@doc_no}</span>
            </div>
            <div>
              {gettext("Status")}:
              <span class="has-text-weight-semibold">{@status}</span>
            </div>
            <div>
              {gettext("Position qty")}:
              <span class="has-text-weight-semibold">{fmt_dec(@base_qty)}</span>
              <span :if={@unit}> {@unit}</span>
            </div>
          </div>
        </div>

        <div class="summary-bar is-size-5">
          <span :if={@show_loads}>
            <span class="lbl">{gettext("Load")}</span>
            <span class="val load">{fmt_dec(@total_load)}</span>
            <span :if={@unit} class="unit">{@unit}</span>
          </span>
          <span :if={@show_loads} class="sep">|</span>
          <span>
            <span class="lbl">
              {if @show_loads, do: gettext("Drop"), else: gettext("Delivered")}
            </span>
            <span class="val drop">{fmt_dec(@total_drop)}</span>
            <span :if={@unit} class="unit">{@unit}</span>
          </span>
          <span class="sep">|</span>
          <span>
            <span class="lbl">{gettext("Remaining")}</span>
            <span class="val rem">{fmt_dec(@remaining)}</span>
            <span :if={@unit} class="unit">{@unit}</span>
            <span class="hint">
              ({if @remaining_from == :drop,
                do: gettext("position − delivered"),
                else: gettext("position − load")})
            </span>
          </span>
        </div>

        <div class="section-title is-size-5 has-text-weight-semibold">
          {if @show_loads, do: gettext("Loads & drops"), else: gettext("Delivery history")}
          ({length(@rows)})
        </div>

        <table class="line-table is-size-6">
          <thead>
            <tr>
              <th class="c">#</th>
              <th>{gettext("Date")}</th>
              <th>{gettext("Trip")}</th>
              <th>{gettext("Vehicle")}</th>
              <th :if={@show_loads}>{gettext("Load")}</th>
              <th>{if @show_loads, do: gettext("Drop"), else: gettext("Delivery")}</th>
              <th>{gettext("Note")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{row, i} <- Enum.with_index(@rows, 1)}
              class={if(row.status == "cancelled", do: "cancelled")}
            >
              <td class="c">{i}</td>
              <td>{if row.date, do: format_date(row.date), else: "—"}</td>
              <td>{row.reference_no || "—"}</td>
              <td>{row.vehicle_number || "—"}</td>
              <td :if={@show_loads} class="load">
                {format_side(row.loads, row.unit || @unit)}
              </td>
              <td class="drop">{format_side(row.drops, row.unit || @unit)}</td>
              <td class="note">{row.notes || ""}</td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan={if(@show_loads, do: 7, else: 6)} class="c muted">
                {if @show_loads,
                  do: gettext("No loads or drops yet."),
                  else: gettext("No deliveries yet.")}
              </td>
            </tr>
          </tbody>
        </table>

        {if(@pre_print == "true", do: "", else: letter_foot(assigns))}
      </div>
    </div>
    """
  end

  defp format_side([], _unit), do: "—"

  defp format_side(parts, unit) when is_list(parts) do
    parts
    |> Enum.map(fn p ->
      qty = p.qty
      u = if unit && qty, do: " #{unit}", else: ""
      if qty, do: "#{p.place} #{qty}#{u}", else: p.place
    end)
    |> Enum.join(" + ")
  end

  defp format_side(_, _), do: "—"

  defp sum_history(rows) when is_list(rows) do
    Enum.reduce(rows, %{load: Decimal.new(0), drop: Decimal.new(0)}, fn row, acc ->
      if row.status == "cancelled" do
        acc
      else
        %{
          load: Decimal.add(acc.load, sum_parts(row.loads)),
          drop: Decimal.add(acc.drop, sum_parts(row.drops))
        }
      end
    end)
  end

  defp sum_history(_), do: %{load: Decimal.new(0), drop: Decimal.new(0)}

  defp sum_parts(parts) when is_list(parts) do
    Enum.reduce(parts, Decimal.new(0), fn part, acc ->
      case parse_qty(part.qty) do
        nil -> acc
        d -> Decimal.add(acc, d)
      end
    end)
  end

  defp sum_parts(_), do: Decimal.new(0)

  defp parse_qty(nil), do: nil
  defp parse_qty(%Decimal{} = d), do: d

  defp parse_qty(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp parse_qty(n) when is_integer(n), do: Decimal.new(n)
  defp parse_qty(n) when is_float(n), do: Decimal.from_float(n)
  defp parse_qty(_), do: nil

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n) when is_integer(n), do: Decimal.new(n)
  defp to_dec(n) when is_float(n), do: Decimal.from_float(n)

  defp to_dec(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  defp to_dec(_), do: Decimal.new(0)

  defp fmt_dec(%Decimal{} = d), do: Decimal.to_string(d)
  defp fmt_dec(nil), do: "—"
  defp fmt_dec(other), do: to_string(other)

  defp default_unit(rows) when is_list(rows) do
    Enum.find_value(rows, fn r ->
      if is_binary(r.unit) and r.unit != "", do: r.unit
    end)
  end

  defp default_unit(_), do: nil

  def letter_head_data(assigns) do
    ~H"""
    <div class="is-size-3 has-text-weight-bold">{@company.name}</div>
    <div>{@company.address1}, {@company.address2}</div>
    <div>
      {Enum.join(
        Enum.reject(
          [@company.zipcode, @company.city, @company.state, @company.country],
          &(&1 in [nil, ""])
        ),
        ", "
      )}
    </div>
    <div>
      Tel: {@company.tel} RegNo: {@company.reg_no} Email: {@company.email}
    </div>
    """
  end

  def letter_foot(assigns) do
    ~H"""
    <div class="letter-foot">
      <div class="sign">{gettext("Prepared by")}</div>
      <div class="sign">{gettext("Approved by")}</div>
    </div>
    """
  end

  def full_style(assigns) do
    ~H"""
    <style>
      .letter-head { border-bottom: 0.5mm solid black; }
      .letter-foot { border-top: 0.5mm solid black; margin-top: 12mm; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 35%; text-align: center; float: right; margin-left: 3mm; margin-top: 18mm; }
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; min-height: 148mm; padding: 8mm; }
      @media print {
        @page { size: A4; margin: 8mm; }
        body { margin: 0; }
        .page { padding: 0; page-break-after: always; }
      }
      .letter-head { padding-bottom: 2mm; margin-bottom: 3mm; height: 28mm; }
      .doctype { float: right; margin-top: -18mm; margin-right: 0; }
      .doc-header { width: 100%; min-height: 22mm; border-bottom: 0.5mm solid black; margin-bottom: 3mm; overflow: auto; }
      .doc-header .left { float: left; width: 55%; }
      .doc-header .right { float: right; text-align: right; }
      .doc-header .right div { margin-bottom: 1.5mm; }
      .summary-bar {
        width: 100%; border: 0.4mm solid #333; padding: 2.5mm 3mm; margin-bottom: 4mm;
        background: #f7f7f7; overflow: auto;
      }
      .summary-bar .lbl { font-weight: 600; margin-right: 1.5mm; }
      .summary-bar .val { font-weight: 700; font-variant-numeric: tabular-nums; }
      .summary-bar .val.load { color: #0f766e; }
      .summary-bar .val.drop { color: #6d28d9; }
      .summary-bar .val.rem { color: #047857; }
      .summary-bar .unit { font-size: 0.85em; margin-left: 0.5mm; }
      .summary-bar .sep { margin: 0 3mm; color: #999; }
      .summary-bar .hint { font-size: 0.75em; color: #666; margin-left: 1.5mm; font-weight: 400; }
      .section-title { margin: 2mm 0 2mm; }
      .line-table { width: 100%; border-collapse: collapse; }
      .line-table th, .line-table td {
        border: 0.3mm solid #333; padding: 1.5mm 2mm; vertical-align: top;
      }
      .line-table th { background: #eee; font-weight: 600; text-align: left; }
      .line-table td.c, .line-table th.c { text-align: center; width: 8mm; }
      .line-table td.load { color: #0f766e; }
      .line-table td.drop { color: #6d28d9; }
      .line-table td.note { font-size: 0.9em; color: #555; }
      .line-table tr.cancelled td { text-decoration: line-through; color: #999; }
      .muted { color: #888; }
    </style>
    """
  end
end
