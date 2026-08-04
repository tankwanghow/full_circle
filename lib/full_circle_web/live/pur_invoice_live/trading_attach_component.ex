defmodule FullCircleWeb.PurInvoiceLive.TradingAttachComponent do
  @moduledoc """
  Attach trading lines to a PurInvoice that already exists, or is about to.

  The settlement board's "Create PurInvoice" is the push direction. Most supplier
  and haulier bills instead arrive as received LHDN e-invoices and are keyed
  through `EInvMetas.Prefill`, which never sets the trading FKs. This panel is the
  pull direction: it lists that contact's still-unbilled loads and haul lines so
  the clerk can tick the ones this bill settles.

  The component owns the candidate queries and the tick state, and pushes the
  selection up to the form LiveView, which links it inside the save `Multi` via
  `Trading.attach_links_multi/6`.

  Renders no named inputs, so it is safe inside the parent's `<.form>` — the
  checkboxes carry `phx-click` only and never reach the form params.
  """
  use FullCircleWeb, :live_component

  alias FullCircle.Trading

  # Bills lag the trip. A month covers a normal billing cycle, plus slack either
  # side for a trip completed after the supplier cut their invoice.
  @days_before 45
  @days_after 7

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:show_all, fn -> false end)
      |> assign_new(:selected_loads, fn -> MapSet.new() end)
      |> assign_new(:selected_transport, fn -> MapSet.new() end)
      |> assign_new(:query_key, fn -> :none end)

    {:ok, maybe_load_candidates(socket)}
  end

  # The parent re-renders on every keystroke (phx-change="validate"). Re-query
  # only when something the query actually depends on moved.
  defp maybe_load_candidates(socket) do
    %{contact_id: contact_id, show_all: show_all} = socket.assigns
    {from_date, to_date} = window(bill_date(socket.assigns), show_all)
    key = {contact_id, from_date, to_date}

    if key == socket.assigns.query_key do
      socket
    else
      contact_changed? =
        match?({old, _, _} when old != contact_id, socket.assigns.query_key)

      socket
      |> assign(query_key: key)
      |> load_candidates(contact_id, from_date, to_date)
      |> reset_selection_if(contact_changed?)
      |> prune_selection()
    end
  end

  defp load_candidates(socket, nil, _from, _to) do
    assign(socket, load_rows: [], transport_rows: [])
  end

  defp load_candidates(socket, contact_id, from_date, to_date) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    opts = [from_date: from_date, to_date: to_date]

    assign(socket,
      load_rows: Trading.list_unbilled_loads(company, user, [{:supplier_id, contact_id} | opts]),
      transport_rows:
        Trading.list_unbilled_transport_lines(company, user, [{:agent_id, contact_id} | opts])
    )
  end

  defp reset_selection_if(socket, false), do: socket

  defp reset_selection_if(socket, true) do
    assign(socket, selected_loads: MapSet.new(), selected_transport: MapSet.new())
  end

  # Narrowing the window (or another clerk billing a line) can drop a ticked row
  # off the list. Keeping its id would link something the clerk can no longer see.
  defp prune_selection(socket) do
    visible_loads = billable_ids(socket.assigns.load_rows)
    visible_transport = billable_ids(socket.assigns.transport_rows)

    socket
    |> assign(
      selected_loads: MapSet.intersection(socket.assigns.selected_loads, visible_loads),
      selected_transport:
        MapSet.intersection(socket.assigns.selected_transport, visible_transport)
    )
    |> notify_parent()
  end

  defp billable_ids(rows) do
    rows |> Enum.filter(& &1.billable) |> Enum.map(&to_string(&1.id)) |> MapSet.new()
  end

  @impl true
  def handle_event("toggle_load", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(selected_loads: toggle(socket.assigns.selected_loads, id))
     |> notify_parent()}
  end

  def handle_event("toggle_transport", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(selected_transport: toggle(socket.assigns.selected_transport, id))
     |> notify_parent()}
  end

  def handle_event("toggle_show_all", _, socket) do
    {:noreply,
     socket
     |> assign(show_all: !socket.assigns.show_all)
     |> maybe_load_candidates()}
  end

  # Always store string ids — phx-value-id is a string; row.id may differ in type.
  defp toggle(set, id) do
    id = to_string(id)

    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp selected?(set, id), do: MapSet.member?(set, to_string(id))

  # The contact travels with the selection so the parent can discard it if the
  # clerk ticks lines and then switches supplier — the panel is unmounted at that
  # point and cannot retract the ids itself.
  defp notify_parent(socket) do
    send(
      self(),
      {:trading_attach_selection, socket.assigns.contact_id,
       MapSet.to_list(socket.assigns.selected_loads),
       MapSet.to_list(socket.assigns.selected_transport)}
    )

    socket
  end

  defp window(_date, true), do: {nil, nil}

  defp window(%Date{} = date, _show_all),
    do: {Date.add(date, -@days_before), Date.add(date, @days_after)}

  defp bill_date(%{bill_date: %Date{} = d}), do: d

  defp bill_date(%{bill_date: str}) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> Date.utc_today()
    end
  end

  defp bill_date(_), do: Date.utc_today()

  defp selected_sum(rows, selected) do
    rows
    |> Enum.filter(&selected?(selected, &1.id))
    |> Enum.reduce(Decimal.new(0), fn r, acc -> Decimal.add(acc, r.actual || Decimal.new(0)) end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        any_candidates?: assigns.load_rows != [] or assigns.transport_rows != []
      )

    ~H"""
    <div id={@id}>
      <div
        :if={@any_candidates?}
        class="mb-3 border rounded-lg border-violet-400 bg-violet-50 dark:bg-violet-950/40 dark:border-violet-700"
      >
        <div class="px-3 py-2 border-b border-violet-300 dark:border-violet-700 flex flex-wrap gap-2 items-center">
          <span class="font-bold text-violet-900 dark:text-violet-200">
            {gettext("Unbilled trading lines")}
          </span>
          <span class="text-xs text-violet-800 dark:text-violet-300">
            {gettext("Tick the lines this bill settles.")}
          </span>
          <button
            type="button"
            phx-click="toggle_show_all"
            phx-target={@myself}
            class="ml-auto gray button text-xs py-0.5"
          >
            {if @show_all,
              do: gettext("Near the bill date"),
              else: gettext("Show all unbilled")}
          </button>
        </div>

        <.attach_table
          :if={@load_rows != []}
          title={gettext("Supplier loads")}
          rows={@load_rows}
          selected={@selected_loads}
          event="toggle_load"
          myself={@myself}
          id_prefix="attach-load"
          bill_qty={@bill_qty}
        />

        <.attach_table
          :if={@transport_rows != []}
          title={gettext("Transport hauls")}
          rows={@transport_rows}
          selected={@selected_transport}
          event="toggle_transport"
          myself={@myself}
          id_prefix="attach-haul"
          bill_qty={@bill_qty}
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :selected, :any, required: true
  attr :event, :string, required: true
  attr :myself, :any, required: true
  attr :id_prefix, :string, required: true
  attr :bill_qty, :any, required: true

  defp attach_table(assigns) do
    # Include selected? in checkbox id so morphdom remounts after phx-click
    # (browser also toggles the box; rows 2+ otherwise stay visually wrong).
    rows =
      Enum.map(assigns.rows, fn row ->
        Map.put(row, :selected?, selected?(assigns.selected, row.id))
      end)

    assigns =
      assign(assigns,
        rows: rows,
        linked_qty: selected_sum(assigns.rows, assigns.selected),
        n_selected: MapSet.size(assigns.selected)
      )

    ~H"""
    <div class="px-3 py-1.5 bg-violet-100 dark:bg-violet-900/50 text-sm font-semibold border-b border-violet-200 dark:border-violet-700">
      {@title}
    </div>

    <div class="flex gap-1 px-3 py-1 text-xs font-semibold bg-gray-100 dark:bg-zinc-800 border-b dark:border-zinc-700">
      <div class="w-8"></div>
      <div class="w-2/12">{gettext("Date")}</div>
      <div class="w-2/12">{gettext("Trip")}</div>
      <div class="w-2/12">{gettext("Vehicle")}</div>
      <div class="w-2/12">{gettext("Good")}</div>
      <div class="w-3/12">{gettext("Location")}</div>
      <div class="w-1/12 text-right">{gettext("Qty")}</div>
    </div>

    <div
      :for={row <- @rows}
      id={"#{@id_prefix}-#{row.id}"}
      class={[
        "flex gap-1 px-3 py-1.5 text-sm items-center border-b dark:border-zinc-700",
        row.billable && "hover:bg-violet-100/60 dark:hover:bg-violet-900/40",
        !row.billable && "opacity-60 bg-gray-50/80 dark:bg-zinc-800/50"
      ]}
    >
      <div class="w-8">
        <input
          :if={row.billable}
          type="checkbox"
          phx-click={@event}
          phx-value-id={to_string(row.id)}
          phx-target={@myself}
          checked={row.selected?}
          id={"#{@id_prefix}-cb-#{row.id}-#{row.selected?}"}
        />
      </div>
      <div class="w-2/12">{row.trip_date}</div>
      <div class="w-2/12 font-mono text-xs">{row.trip_reference_no}</div>
      <div class="w-2/12">{row.vehicle_number}</div>
      <div class="w-2/12">{row.good_name}</div>
      <div class="w-3/12">{row.location_name}</div>
      <div class="w-1/12 text-right">
        {row.actual}
        <span :if={!row.billable} class="block text-[10px] text-amber-700 dark:text-amber-400">
          {row.trip_status}
        </span>
      </div>
    </div>

    <div class="flex gap-2 px-3 py-1.5 text-xs items-center bg-gray-50 dark:bg-zinc-800/60 border-b dark:border-zinc-700">
      <span class="font-semibold">
        {gettext("Linked")}: {@n_selected} {gettext("line(s)")} · {@linked_qty}
      </span>
      <span :if={@bill_qty}>
        {gettext("Bill qty")}: {@bill_qty}
      </span>
      <span :if={@bill_qty && @n_selected > 0} class={variance_class(@bill_qty, @linked_qty)}>
        Δ {Decimal.sub(@bill_qty, @linked_qty) |> Decimal.abs()}
      </span>
      <span class="ml-auto text-gray-500 dark:text-gray-400">
        {gettext("Advisory only — a difference never blocks saving.")}
      </span>
    </div>
    """
  end

  defp variance_class(bill_qty, linked_qty) do
    if Decimal.equal?(bill_qty, linked_qty) do
      "text-green-700 dark:text-green-400 font-semibold"
    else
      "text-red-600 dark:text-red-400 font-semibold"
    end
  end
end
