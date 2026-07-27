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
        <table class="line-table is-size-6">
          <thead>
            <tr>
              <th class="c">#</th>
              <th>{gettext("Supply")}</th>
              <th>{gettext("Supplier")}</th>
              <th>{gettext("Good")}</th>
              <th>{gettext("Location")}</th>
              <th class="num">{gettext("Plan")}</th>
              <th class="num">{gettext("Actual")}</th>
            </tr>
          </thead>
          <tbody>
            <%= for {load, i} <- Enum.with_index(@loads, 1) do %>
              <% note? = present_text?(load.location_note)
              crew = crew_names(load.trip_load_employees)
              crew? = crew != ""
              rowspan = 1 + if(note?, do: 1, else: 0) + if(crew?, do: 1, else: 0) %>
              <tr>
                <td class="c" rowspan={rowspan}>{load.seq || i}</td>
                <td>{load.supply_position && load.supply_position.title}</td>
                <td>{supplier_name(load)}</td>
                <td>
                  {load.good && load.good.name}
                  <%= if load.good && load.good.unit do %>
                    <span class="muted"> ({load.good.unit})</span>
                  <% end %>
                </td>
                <td>{load.location && load.location.name}</td>
                <td class="num">{format_qty(load.planned)}</td>
                <td class="num">{format_qty(load.actual)}</td>
              </tr>
              <%= if note? do %>
                <tr class="sub-row">
                  <td colspan="6">
                    <span class="sub-label">{gettext("Note")}:</span>
                    {load.location_note}
                  </td>
                </tr>
              <% end %>
              <%= if crew? do %>
                <tr class="sub-row">
                  <td colspan="6">
                    <span class="sub-label">{gettext("Crew")}:</span>
                    {crew}
                  </td>
                </tr>
              <% end %>
            <% end %>
            <%= if @loads == [] do %>
              <tr>
                <td colspan="7" class="c muted">{gettext("No loads")}</td>
              </tr>
            <% end %>
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
        <table class="line-table is-size-6">
          <thead>
            <tr>
              <th class="c">#</th>
              <th>{gettext("Sales")}</th>
              <th>{gettext("Customer")}</th>
              <th>{gettext("Good")}</th>
              <th>{gettext("Location")}</th>
              <th>{gettext("Supply")}</th>
              <th class="num">{gettext("Plan")}</th>
              <th class="num">{gettext("Actual")}</th>
            </tr>
          </thead>
          <tbody>
            <%= for {drop, i} <- Enum.with_index(@drops, 1) do %>
              <% note? = present_text?(drop.variance_note) or present_text?(drop.location_note)
              note_text = drop_note_text(drop)
              crew = crew_names(drop.trip_drop_employees)
              crew? = crew != ""
              rowspan = 1 + if(note?, do: 1, else: 0) + if(crew?, do: 1, else: 0) %>
              <tr>
                <td class="c" rowspan={rowspan}>{drop.seq || i}</td>
                <td>{drop.sales_position && drop.sales_position.title}</td>
                <td>{customer_name(drop)}</td>
                <td>
                  {drop.good && drop.good.name}
                  <%= if drop.good && drop.good.unit do %>
                    <span class="muted"> ({drop.good.unit})</span>
                  <% end %>
                </td>
                <td>{drop.location && drop.location.name}</td>
                <td>{drop.supply_position && drop.supply_position.title}</td>
                <td class="num">{format_qty(drop.planned)}</td>
                <td class="num">{format_qty(drop.actual)}</td>
              </tr>
              <%= if note? do %>
                <tr class="sub-row">
                  <td colspan="7">
                    <span class="sub-label">{gettext("Note")}:</span>
                    {note_text}
                  </td>
                </tr>
              <% end %>
              <%= if crew? do %>
                <tr class="sub-row">
                  <td colspan="7">
                    <span class="sub-label">{gettext("Crew")}:</span>
                    {crew}
                  </td>
                </tr>
              <% end %>
            <% end %>
            <%= if @drops == [] do %>
              <tr>
                <td colspan="8" class="c muted">{gettext("No drops")}</td>
              </tr>
            <% end %>
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
          {gettext("Date")}: <span class="has-text-weight-semibold">{format_date(@trip.date)}</span>
        </div>
        <div>
          {gettext("Vehicle")}:
          <span class="has-text-weight-semibold">{@trip.vehicle_number || "—"}</span>
        </div>
        <div>
          {gettext("Transport")}: <span class="has-text-weight-semibold">{@trip.transport_mode}</span>
          <span :if={@trip.transport_agent}>
            — {@trip.transport_agent.name}
          </span>
        </div>
      </div>
      <div class="right is-size-5">
        <div>
          {gettext("Trip no")}: <span class="has-text-weight-semibold">{@trip.reference_no}</span>
        </div>
        <div>
          {gettext("Status")}: <span class="has-text-weight-semibold">{@trip.status}</span>
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

  defp present_text?(nil), do: false
  defp present_text?(""), do: false
  defp present_text?(s) when is_binary(s), do: String.trim(s) != ""
  defp present_text?(_), do: false

  defp crew_names(nil), do: ""

  defp crew_names(rows) do
    rows
    |> List.wrap()
    |> Enum.map(fn
      %{employee: %{name: name}} when is_binary(name) -> String.trim(name)
      %{employee_name: name} when is_binary(name) -> String.trim(name)
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp drop_note_text(drop) do
    [drop.variance_note, drop.location_note]
    |> Enum.filter(&present_text?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.join(" · ")
  end

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
      .letter-foot {  margin-top: 10mm; overflow: auto; }
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
      .notes { margin: 1mm 0 2mm; }
      .line-table { width: 100%; border-collapse: collapse; margin-bottom: 3mm; }
      .line-table th, .line-table td { border: 0.3mm solid #333; padding: 1.5mm 2mm; vertical-align: top; font-size: 0.85em; }
      .line-table th { background: #eee; font-weight: 600; text-align: left; }
      .line-table .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
      .line-table .c { text-align: center; width: 8mm; }
      .line-table .muted { color: #666; font-style: italic; }
      .line-table tr.sub-row td { border-top: none; background: #fafafa; font-size: 0.75em; min-height: 6mm; }
      .line-table .sub-label { font-weight: 600; margin-right: 1.5mm; }
    </style>
    """
  end
end
