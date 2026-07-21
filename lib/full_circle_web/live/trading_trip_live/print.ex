defmodule FullCircleWeb.TradingTripLive.Print do
  @moduledoc "Printable trip document — loads page + drops page."
  use FullCircleWeb, :live_view

  import FullCircleWeb.Helpers
  alias FullCircle.Trading
  alias FullCircle.Authorization

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    pre_print = Map.get(params, "pre_print", "false")

    if Authorization.can?(user, :view_trading, company) do
      trip = Trading.get_trip!(id, company, user)

      {:ok,
       socket
       |> assign(page_title: gettext("Print Trip") <> " " <> (trip.reference_no || ""))
       |> assign(:pre_print, pre_print)
       |> assign(:company, FullCircle.Sys.get_company!(company.id))
       |> assign(:trip, trip)
       |> assign(:loads, List.wrap(trip.loads))
       |> assign(:drops, List.wrap(trip.drops))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {pre_print_style(assigns)}
      {if(@pre_print == "false", do: full_style(assigns))}

      <%!-- Page 1: Loads --%>
      <div class="page">
        <div class="letter-head">
          {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
        </div>
        <div class="doctype is-size-4 has-text-weight-semibold">{gettext("TRIP — LOADS")}</div>
        {trip_header(assigns)}
        <div class="section-title is-size-5 has-text-weight-semibold">{gettext("Loads")}</div>
        <table class="line-table is-size-6">
          <thead>
            <tr>
              <th class="c">#</th>
              <th>{gettext("Supply")}</th>
              <th>{gettext("Supplier")}</th>
              <th>{gettext("Good")}</th>
              <th>{gettext("Location")}</th>
              <th class="num">{gettext("Plan MT")}</th>
              <th class="num">{gettext("Actual MT")}</th>
              <th>{gettext("Note")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{load, i} <- Enum.with_index(@loads, 1)}>
              <td class="c">{load.seq || i}</td>
              <td>{load.supply_position && load.supply_position.title}</td>
              <td>{supplier_name(load)}</td>
              <td>{load.good && load.good.name}</td>
              <td>{load.location && load.location.name}</td>
              <td class="num">{format_qty(load.planned_mt)}</td>
              <td class="num">{format_qty(load.actual_mt)}</td>
              <td>{load.location_note}</td>
            </tr>
            <tr :if={@loads == []}>
              <td colspan="8" class="c muted">{gettext("No loads")}</td>
            </tr>
          </tbody>
        </table>
        {if(@pre_print == "true", do: "", else: loads_foot(assigns))}
      </div>

      <%!-- Page 2: Drops --%>
      <div class="page">
        <div class="letter-head">
          {if(@pre_print == "true", do: "", else: letter_head_data(assigns))}
        </div>
        <div class="doctype is-size-4 has-text-weight-semibold">{gettext("TRIP - Deliver")}</div>
        {trip_header(assigns)}
        <div class="section-title is-size-5 has-text-weight-semibold">{gettext("Drops")}</div>
        <table class="line-table is-size-6">
          <thead>
            <tr>
              <th class="c">#</th>
              <th>{gettext("Sales")}</th>
              <th>{gettext("Customer")}</th>
              <th>{gettext("Good")}</th>
              <th>{gettext("Location")}</th>
              <th>{gettext("Supply")}</th>
              <th class="num">{gettext("Plan MT")}</th>
              <th class="num">{gettext("Actual MT")}</th>
              <th>{gettext("Variance")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{drop, i} <- Enum.with_index(@drops, 1)}>
              <td class="c">{drop.seq || i}</td>
              <td>{drop.sales_position && drop.sales_position.title}</td>
              <td>{customer_name(drop)}</td>
              <td>{drop.good && drop.good.name}</td>
              <td>{drop.location && drop.location.name}</td>
              <td>{drop.supply_position && drop.supply_position.title}</td>
              <td class="num">{format_qty(drop.planned_mt)}</td>
              <td class="num">{format_qty(drop.actual_mt)}</td>
              <td>{drop.variance_note}</td>
            </tr>
            <tr :if={@drops == []}>
              <td colspan="9" class="c muted">{gettext("No drops")}</td>
            </tr>
          </tbody>
        </table>
        {if(@pre_print == "true", do: "", else: drops_foot(assigns))}
      </div>
    </div>
    """
  end

  defp trip_header(assigns) do
    ~H"""
    <div class="doc-header">
      <div class="left is-size-5">
        <div>
          {gettext("Date")}:
          <span class="has-text-weight-semibold">{format_date(@trip.date)}</span>
        </div>
        <div>
          {gettext("Vehicle")}:
          <span class="has-text-weight-semibold">{@trip.vehicle_number || "—"}</span>
        </div>
        <div>
          {gettext("Transport")}:
          <span class="has-text-weight-semibold">{@trip.transport_mode}</span>
          <span :if={@trip.transport_agent}>
            — {@trip.transport_agent.name}
          </span>
        </div>
      </div>
      <div class="right is-size-5">
        <div>
          {gettext("Trip no")}:
          <span class="has-text-weight-semibold">{@trip.reference_no}</span>
        </div>
        <div>
          {gettext("Status")}:
          <span class="has-text-weight-semibold">{@trip.status}</span>
        </div>
      </div>
    </div>
    <div :if={@trip.notes && @trip.notes != ""} class="notes is-size-6">
      <span class="has-text-weight-semibold">{gettext("Notes")}:</span>
      {@trip.notes}
    </div>
    """
  end

  defp supplier_name(%{supply_position: %{supplier: %{name: name}}}), do: name
  defp supplier_name(_), do: "—"

  defp customer_name(%{sales_position: %{customer: %{name: name}}}), do: name
  defp customer_name(_), do: "—"

  defp format_qty(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_qty(nil), do: "—"
  defp format_qty(v), do: to_string(v)

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

  def loads_foot(assigns) do
    ~H"""
    <div class="letter-foot">
      <div class="sign">{gettext("Driver")}</div>
      <div class="sign">{gettext("Warehouse / Load")}</div>
      <div class="sign">{gettext("Checked by")}</div>
    </div>
    """
  end

  def drops_foot(assigns) do
    ~H"""
    <div class="letter-foot">
      <div class="sign">{gettext("Driver")}</div>
      <div class="sign">{gettext("Delivered by")}</div>
      <div class="sign">{gettext("Received by")}</div>
    </div>
    """
  end

  def full_style(assigns) do
    ~H"""
    <style>
      .letter-head { border-bottom: 0.5mm solid black; }
      .letter-foot { border-top: 0.5mm solid black; margin-top: 10mm; overflow: auto; }
      .sign { padding: 3mm; border-top: 2px dotted black; width: 28%; text-align: center; float: right; margin-left: 3mm; margin-top: 16mm; }
    </style>
    """
  end

  def pre_print_style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; min-height: 297mm; padding: 8mm; }
      @media print {
        @page { size: A4; margin: 8mm; }
        body { margin: 0; }
        .page { padding: 0; page-break-after: always; }
      }
      .letter-head { padding-bottom: 2mm; margin-bottom: 3mm; height: 28mm; }
      .doctype { float: right; margin-top: -18mm; margin-right: 0; }
      .doc-header { width: 100%; min-height: 20mm; border-bottom: 0.5mm solid black; margin-bottom: 3mm; overflow: auto; }
      .doc-header .left { float: left; width: 58%; }
      .doc-header .right { float: right; text-align: right; }
      .doc-header .left div, .doc-header .right div { margin-bottom: 1.2mm; }
      .notes { margin: 2mm 0 3mm; white-space: pre-wrap; }
      .section-title { margin: 4mm 0 1.5mm; clear: both; }
      .line-table { width: 100%; border-collapse: collapse; margin-bottom: 3mm; }
      .line-table th, .line-table td { border: 0.3mm solid #333; padding: 1.5mm 2mm; vertical-align: top; }
      .line-table th { background: #eee; font-weight: 600; text-align: left; }
      .line-table .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
      .line-table .c { text-align: center; width: 8mm; }
      .line-table .muted { color: #666; font-style: italic; }
    </style>
    """
  end
end
