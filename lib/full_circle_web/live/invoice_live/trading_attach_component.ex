defmodule FullCircleWeb.InvoiceLive.TradingAttachComponent do
  @moduledoc """
  Attach trading sales drops to an Invoice that already exists, or is about to.

  Settlement board "Create Invoice" is the **push** direction. Manual / e-invoice
  sales invoices often arrive without trading FKs. This panel is the **pull**
  direction: lists that **customer's** still-uninvoiced drops so the clerk can
  tick the ones this invoice settles.

  Multi-customer trips are fine: each drop carries its own `sales_position` /
  customer. Candidates are filtered by `contact_id` (invoice customer), so only
  that customer's lines appear — never other customers' drops on the same TRP.

  No named form inputs; checkboxes use `phx-click` only.
  """
  use FullCircleWeb, :live_component

  alias FullCircle.Trading

  # Invoices lag trips. Window covers a normal cycle plus slack either side.
  @days_before 45
  @days_after 7

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:show_all, fn -> false end)
      |> assign_new(:selected_drops, fn -> MapSet.new() end)
      |> assign_new(:query_key, fn -> :none end)

    {:ok, maybe_load_candidates(socket)}
  end

  # Parent re-renders on every keystroke. Re-query only when query inputs move.
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
    assign(socket, drop_rows: [])
  end

  defp load_candidates(socket, contact_id, from_date, to_date) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    rows =
      Trading.list_uninvoiced_drops(company, user,
        customer_id: contact_id,
        from_date: from_date,
        to_date: to_date
      )

    assign(socket, drop_rows: rows)
  end

  defp reset_selection_if(socket, false), do: socket

  defp reset_selection_if(socket, true) do
    assign(socket, selected_drops: MapSet.new())
  end

  defp prune_selection(socket) do
    visible = billable_ids(socket.assigns.drop_rows)

    socket
    |> assign(selected_drops: MapSet.intersection(socket.assigns.selected_drops, visible))
    |> notify_parent()
  end

  defp billable_ids(rows) do
    rows |> Enum.filter(& &1.billable) |> Enum.map(&to_string(&1.id)) |> MapSet.new()
  end

  @impl true
  def handle_event("toggle_drop", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(selected_drops: toggle(socket.assigns.selected_drops, id))
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

  # Contact travels with selection so parent can discard if customer changes.
  defp notify_parent(socket) do
    send(
      self(),
      {:trading_invoice_attach_selection, socket.assigns.contact_id,
       MapSet.to_list(socket.assigns.selected_drops)}
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
    # Precompute selected? so checkbox id can include it (forces morphdom refresh —
    # browser also toggles checkbox on click, which desyncs rows 2+ otherwise).
    drop_rows =
      Enum.map(assigns.drop_rows, fn row ->
        Map.put(row, :selected?, selected?(assigns.selected_drops, row.id))
      end)

    assigns =
      assign(assigns,
        drop_rows: drop_rows,
        linked_qty: selected_sum(assigns.drop_rows, assigns.selected_drops),
        n_selected: MapSet.size(assigns.selected_drops)
      )

    ~H"""
    <div id={@id}>
      <div
        :if={@drop_rows != []}
        class="mb-3 border rounded-lg border-violet-400 bg-violet-50 dark:bg-violet-950/40 dark:border-violet-700"
      >
        <div class="px-3 py-2 border-b border-violet-300 dark:border-violet-700 flex flex-wrap gap-2 items-center">
          <span class="font-bold text-violet-900 dark:text-violet-200">
            {gettext("Uninvoiced trading drops")}
          </span>
          <span class="text-xs text-violet-800 dark:text-violet-300">
            {gettext(
              "Tick drops this invoice settles for this customer only (multi-customer trips show only their lines)."
            )}
          </span>
          <button
            type="button"
            phx-click="toggle_show_all"
            phx-target={@myself}
            class="ml-auto gray button text-xs py-0.5"
          >
            {if @show_all,
              do: gettext("Near the invoice date"),
              else: gettext("Show all uninvoiced")}
          </button>
        </div>

        <div class="flex gap-1 px-3 py-1 text-xs font-semibold bg-gray-100 dark:bg-zinc-800 border-b dark:border-zinc-700">
          <div class="w-8"></div>
          <div class="w-2/12">{gettext("Date")}</div>
          <div class="w-2/12">{gettext("Trip")}</div>
          <div class="w-2/12">{gettext("Sales")}</div>
          <div class="w-2/12">{gettext("Good")}</div>
          <div class="w-2/12">{gettext("Location")}</div>
          <div class="w-1/12 text-right">{gettext("Qty")}</div>
        </div>

        <div
          :for={row <- @drop_rows}
          id={"attach-drop-#{row.id}"}
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
              phx-click="toggle_drop"
              phx-value-id={to_string(row.id)}
              phx-target={@myself}
              checked={row.selected?}
              id={"attach-drop-cb-#{row.id}-#{row.selected?}"}
            />
          </div>
          <div class="w-2/12">{row.trip_date}</div>
          <div class="w-2/12 font-mono text-xs" title={row.vehicle_number}>
            {row.trip_reference_no}
          </div>
          <div class="w-2/12 font-mono text-xs">{row.sales_title}</div>
          <div class="w-2/12">{row.good_name}</div>
          <div class="w-2/12">{row.location_name}</div>
          <div class="w-1/12 text-right">
            {row.actual}
            <span :if={!row.billable} class="block text-[10px] text-amber-700 dark:text-amber-400">
              {row.trip_status}
            </span>
          </div>
        </div>

        <div class="flex gap-2 px-3 py-1.5 text-xs items-center bg-gray-50 dark:bg-zinc-800/60">
          <span class="font-semibold">
            {gettext("Linked")}: {@n_selected} {gettext("line(s)")} · {@linked_qty}
          </span>
          <span :if={@bill_qty}>
            {gettext("Invoice qty")}: {@bill_qty}
          </span>
          <span :if={@bill_qty && @n_selected > 0} class={variance_class(@bill_qty, @linked_qty)}>
            Δ {Decimal.sub(@bill_qty, @linked_qty) |> Decimal.abs()}
          </span>
          <span class="ml-auto text-gray-500 dark:text-gray-400">
            {gettext("Advisory only — a difference never blocks saving.")}
          </span>
        </div>
      </div>
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
