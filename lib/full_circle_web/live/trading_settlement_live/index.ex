defmodule FullCircleWeb.TradingSettlementLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Authorization

  @streams ~w(customer supplier transport)

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_trading, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Trading Settlement"))
       |> assign(tab: "customer")
       |> assign(selected: MapSet.new())
       |> assign(selected_by_stream: empty_selected_by_stream())
       |> assign(modal: nil)
       |> assign(trip_filter: nil)
       |> assign(can_manage: Authorization.can?(user, :manage_trading, company))
       |> assign(can_invoice: Authorization.can?(user, :create_invoice, company))
       |> assign(can_pur_invoice: Authorization.can?(user, :create_pur_invoice, company))
       |> assign(can_exempt: Authorization.can?(user, :exempt_trading_settlement, company))
       |> assign(waive: nil)
       |> assign(filters: %{"party_id" => "", "from_date" => "", "to_date" => ""})
       |> assign(rows: [])
       |> assign(groups: %{})
       |> assign(customer_rows: [])
       |> assign(supplier_rows: [])
       |> assign(transport_rows: [])}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> apply_trip_filter(params["trip_id"]) |> load_rows()}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket)
      when tab in @streams do
    if socket.assigns.trip_filter do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(tab: tab)
       |> assign(selected: MapSet.new())
       |> assign(filters: %{"party_id" => "", "from_date" => "", "to_date" => ""})
       |> load_rows()}
    end
  end

  def handle_event("open_trip", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      {:noreply,
       assign(socket,
         modal: %{kind: :trip, action: :edit, id: id, form_key: id}
       )}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal: nil)}
  end

  def handle_event("toggle", %{"id" => id, "stream" => stream}, socket)
      when stream in @streams do
    rows = rows_for_stream(socket, stream)
    row = Enum.find(rows, &(&1.id == id))

    if row && selectable?(row, stream) do
      selected_set = Map.get(socket.assigns.selected_by_stream, stream, MapSet.new())

      selected_set =
        if MapSet.member?(selected_set, id) do
          MapSet.delete(selected_set, id)
        else
          MapSet.put(selected_set, id)
        end

      {:noreply,
       assign(socket,
         selected_by_stream: Map.put(socket.assigns.selected_by_stream, stream, selected_set)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1.id == id))
    selectable? = row && selectable?(row, socket.assigns.tab)

    if selectable? do
      selected =
        if MapSet.member?(socket.assigns.selected, id) do
          MapSet.delete(socket.assigns.selected, id)
        else
          MapSet.put(socket.assigns.selected, id)
        end

      {:noreply, assign(socket, selected: selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_party", %{"party_id" => party_id, "stream" => stream}, socket)
      when stream in @streams do
    rows = rows_for_stream(socket, stream)

    ids =
      rows
      |> Enum.filter(&(party_id_of(&1, stream) == party_id and selectable?(&1, stream)))
      |> Enum.map(& &1.id)

    selected_set = Map.get(socket.assigns.selected_by_stream, stream, MapSet.new())
    all_selected? = ids != [] and Enum.all?(ids, &MapSet.member?(selected_set, &1))

    selected_set =
      if all_selected? do
        Enum.reduce(ids, selected_set, &MapSet.delete(&2, &1))
      else
        Enum.reduce(ids, selected_set, &MapSet.put(&2, &1))
      end

    {:noreply,
     assign(socket,
       selected_by_stream: Map.put(socket.assigns.selected_by_stream, stream, selected_set)
     )}
  end

  def handle_event("toggle_party", %{"party_id" => party_id}, socket) do
    tab = socket.assigns.tab

    ids =
      socket.assigns.rows
      |> Enum.filter(&(party_id_of(&1, tab) == party_id and selectable?(&1, tab)))
      |> Enum.map(& &1.id)

    all_selected? = ids != [] and Enum.all?(ids, &MapSet.member?(socket.assigns.selected, &1))

    selected =
      if all_selected? do
        Enum.reduce(ids, socket.assigns.selected, &MapSet.delete(&2, &1))
      else
        Enum.reduce(ids, socket.assigns.selected, &MapSet.put(&2, &1))
      end

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    if socket.assigns.trip_filter do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(filters: filters)
       |> assign(selected: MapSet.new())
       |> load_rows()}
    end
  end

  def handle_event("create_doc", %{"stream" => stream}, socket) when stream in @streams do
    ids =
      socket.assigns.selected_by_stream
      |> Map.get(stream, MapSet.new())
      |> MapSet.to_list()

    case stream do
      "customer" -> create_customer_invoice(socket, ids, stream)
      "supplier" -> create_supplier_pur_invoice(socket, ids, stream)
      "transport" -> create_transport_pur_invoice(socket, ids, stream)
    end
  end

  def handle_event("create_doc", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    case socket.assigns.tab do
      "customer" -> create_customer_invoice(socket, ids, nil)
      "supplier" -> create_supplier_pur_invoice(socket, ids, nil)
      "transport" -> create_transport_pur_invoice(socket, ids, nil)
    end
  end

  # --- Admin-only settlement waivers ---

  def handle_event("open_waive", %{"id" => id, "stream" => stream}, socket)
      when stream in @streams do
    if socket.assigns.can_exempt do
      {:noreply, assign(socket, waive: %{id: id, stream: stream})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_waive", _params, socket) do
    {:noreply, assign(socket, waive: nil)}
  end

  def handle_event("confirm_waive", %{"reason" => reason}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case socket.assigns.waive do
      %{id: id, stream: stream} ->
        case Trading.exempt_settlement_lines(stream_atom(stream), [id], reason, company, user) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(waive: nil)
             |> put_flash(:info, gettext("Billing waived for this line."))
             |> load_rows()}

          {:error, :reason_required} ->
            {:noreply, put_flash(socket, :error, gettext("A reason is required to waive."))}

          {:error, :not_authorise} ->
            {:noreply,
             socket
             |> assign(waive: nil)
             |> put_flash(:error, gettext("You are not authorised to perform this action"))}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(waive: nil)
             |> put_flash(:error, gettext("Line can no longer be waived (billed or changed)."))
             |> load_rows()}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("unwaive", %{"id" => id, "stream" => stream}, socket)
      when stream in @streams do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    case Trading.unexempt_settlement_lines(stream_atom(stream), [id], company, user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Waiver removed; line is billable again."))
         |> load_rows()}

      {:error, :not_authorise} ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      {:error, _} ->
        {:noreply,
         socket |> put_flash(:error, gettext("Could not remove waiver.")) |> load_rows()}
    end
  end

  @impl true
  def handle_info({:desk_modal_saved, kind}, socket),
    do: handle_info({:desk_modal_saved, kind, nil}, socket)

  def handle_info({:desk_modal_saved, :trip, msg}, socket) do
    msg = msg || gettext("Trip saved.")

    {:noreply,
     socket
     |> put_flash(:info, msg)
     |> assign(modal: nil)
     |> load_rows()}
  end

  def handle_info({:desk_modal_saved, _kind, msg}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, msg || gettext("Saved."))
     |> assign(modal: nil)
     |> load_rows()}
  end

  defp create_customer_invoice(socket, ids, stream) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    cond do
      not socket.assigns.can_invoice ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      ids == [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one drop"))}

      true ->
        case Trading.build_invoice_attrs_from_drop_ids(ids, company, user) do
          {:ok, _attrs} ->
            {:noreply,
             push_navigate(socket,
               to:
                 ~p"/companies/#{company.id}/Invoice/new?#{%{trading_drops: Enum.join(ids, ",")}}"
             )}

          {:error, :mixed_customers} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Selected drops must belong to the same customer")
             )}

          {:error, :ineligible_drops} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Some drops are no longer eligible for invoicing"))
             |> clear_selection(stream)
             |> load_rows()}

          :not_authorise ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Cannot create invoice from selection"))}
        end
    end
  end

  defp create_supplier_pur_invoice(socket, ids, stream) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    cond do
      not socket.assigns.can_pur_invoice ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      ids == [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one load"))}

      true ->
        case Trading.build_pur_invoice_attrs_from_load_ids(ids, company, user) do
          {:ok, _attrs} ->
            {:noreply,
             push_navigate(socket,
               to:
                 ~p"/companies/#{company.id}/PurInvoice/new?#{%{trading_loads: Enum.join(ids, ",")}}"
             )}

          {:error, :mixed_suppliers} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Selected loads must belong to the same supplier")
             )}

          {:error, :ineligible_loads} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Some loads are no longer eligible for billing"))
             |> clear_selection(stream)
             |> load_rows()}

          :not_authorise ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot create purchase invoice from selection"))}
        end
    end
  end

  defp create_transport_pur_invoice(socket, ids, stream) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    cond do
      not socket.assigns.can_pur_invoice ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

      ids == [] ->
        {:noreply, put_flash(socket, :error, gettext("Select at least one haul line"))}

      true ->
        case Trading.build_pur_invoice_attrs_from_transport_drop_ids(ids, company, user) do
          {:ok, _attrs} ->
            {:noreply,
             push_navigate(socket,
               to:
                 ~p"/companies/#{company.id}/PurInvoice/new?#{%{trading_transport_drops: Enum.join(ids, ",")}}"
             )}

          {:error, :mixed_agents} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Selected haul lines must belong to the same transport agent")
             )}

          {:error, :ineligible_transport} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Some haul lines are no longer eligible for billing"))
             |> clear_selection(stream)
             |> load_rows()}

          :not_authorise ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not authorised to perform this action"))}

          {:error, _} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot create purchase invoice from selection"))}
        end
    end
  end

  defp apply_trip_filter(socket, trip_id) when trip_id in [nil, ""] do
    assign(socket, trip_filter: nil)
  end

  defp apply_trip_filter(socket, trip_id) when is_binary(trip_id) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    try do
      trip = Trading.get_trip!(trip_id, company, user)

      assign(socket,
        trip_filter: %{id: trip.id, reference_no: trip.reference_no},
        selected_by_stream: empty_selected_by_stream()
      )
    rescue
      Ecto.NoResultsError ->
        socket
        |> put_flash(:error, gettext("Trip not found for settlement filter"))
        |> assign(trip_filter: nil)
    end
  end

  defp load_rows(socket) do
    if socket.assigns.trip_filter do
      load_trip_page(socket)
    else
      load_board_tab(socket)
    end
  end

  defp load_trip_page(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    trip_id = socket.assigns.trip_filter.id
    opts = [trip_id: trip_id]

    customer_rows = Trading.list_uninvoiced_drops(company, user, opts)
    supplier_rows = Trading.list_unbilled_loads(company, user, opts)
    transport_rows = Trading.list_unbilled_transport_lines(company, user, opts)

    by =
      socket.assigns.selected_by_stream
      |> prune_selected("customer", customer_rows)
      |> prune_selected("supplier", supplier_rows)
      |> prune_selected("transport", transport_rows)

    socket
    |> assign(customer_rows: customer_rows)
    |> assign(supplier_rows: supplier_rows)
    |> assign(transport_rows: transport_rows)
    |> assign(selected_by_stream: by)
    |> assign(rows: [])
    |> assign(groups: %{})
    |> assign(selected: MapSet.new())
  end

  defp load_board_tab(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    filters = socket.assigns.filters
    tab = socket.assigns.tab

    opts =
      []
      |> maybe_opt(party_opt_key(tab), blank_to_nil(filters["party_id"]))
      |> maybe_opt(:from_date, parse_date(filters["from_date"]))
      |> maybe_opt(:to_date, parse_date(filters["to_date"]))

    rows =
      case tab do
        "customer" -> Trading.list_uninvoiced_drops(company, user, opts)
        "supplier" -> Trading.list_unbilled_loads(company, user, opts)
        "transport" -> Trading.list_unbilled_transport_lines(company, user, opts)
      end

    selectable_ids =
      rows
      |> Enum.filter(&selectable?(&1, tab))
      |> MapSet.new(& &1.id)

    selected = MapSet.intersection(socket.assigns.selected || MapSet.new(), selectable_ids)
    groups = Enum.group_by(rows, &party_key(&1, tab))

    socket
    |> assign(rows: rows)
    |> assign(selected: selected)
    |> assign(groups: groups)
    |> assign(customer_rows: [])
    |> assign(supplier_rows: [])
    |> assign(transport_rows: [])
  end

  defp empty_selected_by_stream do
    %{"customer" => MapSet.new(), "supplier" => MapSet.new(), "transport" => MapSet.new()}
  end

  defp prune_selected(by, stream, rows) do
    ids =
      rows
      |> Enum.filter(&selectable?(&1, stream))
      |> MapSet.new(& &1.id)

    Map.put(by, stream, MapSet.intersection(Map.get(by, stream, MapSet.new()), ids))
  end

  defp clear_selection(socket, nil), do: assign(socket, selected: MapSet.new())

  defp clear_selection(socket, stream) when stream in @streams do
    by = Map.put(socket.assigns.selected_by_stream, stream, MapSet.new())
    assign(socket, selected_by_stream: by, selected: MapSet.new())
  end

  defp rows_for_stream(socket, "customer"), do: socket.assigns.customer_rows
  defp rows_for_stream(socket, "supplier"), do: socket.assigns.supplier_rows
  defp rows_for_stream(socket, "transport"), do: socket.assigns.transport_rows
  defp rows_for_stream(_, _), do: []

  defp party_opt_key("customer"), do: :customer_id
  defp party_opt_key("supplier"), do: :supplier_id
  defp party_opt_key("transport"), do: :agent_id

  defp party_key(row, "customer"), do: {row.customer_id, row.customer_name}
  defp party_key(row, "supplier"), do: {row.supplier_id, row.supplier_name}
  defp party_key(row, "transport"), do: {row.agent_id, row.agent_name}

  defp party_id_of(row, "customer"), do: row.customer_id
  defp party_id_of(row, "supplier"), do: row.supplier_id
  defp party_id_of(row, "transport"), do: row.agent_id

  defp stream_atom("customer"), do: :customer
  defp stream_atom("supplier"), do: :supplier
  defp stream_atom("transport"), do: :transport

  defp waived?(row), do: not is_nil(Map.get(row, :exempt_at))

  defp selectable?(row, "customer"), do: row.invoiceable
  defp selectable?(row, "supplier"), do: row.billable
  defp selectable?(row, "transport"), do: row.billable

  defp settled?(%{doc_id: id}) when not is_nil(id), do: true
  defp settled?(_), do: false

  defp settlement_doc_path(company, %{doc_id: id, doc_kind: "invoice"}) when not is_nil(id) do
    ~p"/companies/#{company.id}/Invoice/#{id}/edit"
  end

  defp settlement_doc_path(company, %{doc_id: id, doc_kind: "pur_invoice"}) when not is_nil(id) do
    ~p"/companies/#{company.id}/PurInvoice/#{id}/edit"
  end

  defp settlement_doc_path(company, %{doc_id: id}) when not is_nil(id) do
    ~p"/companies/#{company.id}/Invoice/#{id}/edit"
  end

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp display_mt(%{actual: %Decimal{} = a}), do: a
  defp display_mt(%{actual: a}) when not is_nil(a), do: a
  defp display_mt(%{planned: p}), do: p
  defp display_mt(_), do: Decimal.new(0)

  defp selected_total_mt(rows, selected) do
    rows
    |> Enum.filter(&MapSet.member?(selected, &1.id))
    |> Enum.reduce(Decimal.new(0), fn r, acc -> Decimal.add(acc, display_mt(r) || 0) end)
  end

  defp party_options(rows, tab) do
    rows
    |> Enum.map(fn r ->
      case tab do
        "customer" -> {r.customer_name, r.customer_id}
        "supplier" -> {r.supplier_name, r.supplier_id}
        "transport" -> {r.agent_name, r.agent_id}
      end
    end)
    |> Enum.uniq_by(fn {_n, id} -> id end)
    |> Enum.sort_by(fn {n, _} -> n end)
  end

  defp status_label("completed"), do: gettext("completed")
  defp status_label("planned"), do: gettext("planned")
  defp status_label("draft"), do: gettext("draft")
  defp status_label(other), do: other

  defp status_class("completed"), do: "bg-emerald-100 text-emerald-800"
  defp status_class("planned"), do: "bg-sky-100 text-sky-800"
  defp status_class("draft"), do: "bg-gray-100 text-gray-600"
  defp status_class(_), do: "bg-gray-100 text-gray-600"

  defp group_selectable_count(rows, stream), do: Enum.count(rows, &selectable?(&1, stream))

  defp group_mt(rows) do
    Enum.reduce(rows, Decimal.new(0), fn r, a -> Decimal.add(a, display_mt(r) || 0) end)
  end

  defp position_title(row, "customer"), do: row.sales_title
  defp position_title(row, "supplier"), do: row.supply_title
  defp position_title(row, "transport"), do: row.from_location_name || "—"

  defp location_display(row, "transport"), do: row.to_location_name || row.location_name
  defp location_display(row, _), do: row.location_name

  defp action_label("customer"), do: gettext("Create Invoice")
  defp action_label("supplier"), do: gettext("Create Purchase Invoice")
  defp action_label("transport"), do: gettext("Create Transport Bill")

  defp can_create?(%{tab: "customer", can_invoice: true}), do: true
  defp can_create?(%{tab: "supplier", can_pur_invoice: true}), do: true
  defp can_create?(%{tab: "transport", can_pur_invoice: true}), do: true
  defp can_create?(_), do: false

  defp help_text("customer") do
    gettext(
      "Sales drops on draft, planned, and completed trips (not yet invoiced). Only completed drops with actual MT can be selected for invoicing."
    )
  end

  defp help_text("supplier") do
    gettext(
      "Commercial loads (with supply position) on draft, planned, and completed trips not yet billed. Only completed loads with actual MT can be selected."
    )
  end

  defp help_text("transport") do
    gettext(
      "Agent haul lines (one per drop with origin→destination). Only completed agent trips with actual MT can be selected. Enter haulage RM on the purchase invoice."
    )
  end

  defp empty_text("customer"), do: gettext("No sales deliveries for this trip.")
  defp empty_text("supplier"), do: gettext("No commercial loads for this trip.")
  defp empty_text("transport"), do: gettext("No transport haul lines for this trip.")

  defp board_empty_text("customer"), do: gettext("No sales deliveries to show.")
  defp board_empty_text("supplier"), do: gettext("No commercial loads to show.")
  defp board_empty_text("transport"), do: gettext("No transport haul lines to show.")

  defp party_filter_label("customer"), do: gettext("Customer")
  defp party_filter_label("supplier"), do: gettext("Supplier")
  defp party_filter_label("transport"), do: gettext("Transport agent")

  defp all_parties_label("customer"), do: gettext("All customers")
  defp all_parties_label("supplier"), do: gettext("All suppliers")
  defp all_parties_label("transport"), do: gettext("All agents")

  defp position_col_label("customer"), do: gettext("Sales")
  defp position_col_label("supplier"), do: gettext("Supply")
  defp position_col_label("transport"), do: gettext("From")

  defp location_col_label("transport"), do: gettext("To")
  defp location_col_label(_), do: gettext("Location")

  defp stream_title("customer"), do: gettext("Customer Invoice")
  defp stream_title("supplier"), do: gettext("Supplier Bill")
  defp stream_title("transport"), do: gettext("Transport Bill")

  defp stream_header_class("customer"), do: "bg-emerald-200 border-emerald-500 text-emerald-950"
  defp stream_header_class("supplier"), do: "bg-amber-200 border-amber-500 text-amber-950"
  defp stream_header_class("transport"), do: "bg-sky-200 border-sky-500 text-sky-950"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-11/12 max-w-6xl">
      <%= if @trip_filter do %>
        <.trip_settlement_page
          trip_filter={@trip_filter}
          current_company={@current_company}
          can_manage={@can_manage}
          can_invoice={@can_invoice}
          can_pur_invoice={@can_pur_invoice}
          customer_rows={@customer_rows}
          supplier_rows={@supplier_rows}
          transport_rows={@transport_rows}
          selected_by_stream={@selected_by_stream}
          modal={@modal}
          current_user={@current_user}
          can_exempt={@can_exempt}
        />
      <% else %>
        <.board_settlement_page
          page_title={@page_title}
          tab={@tab}
          filters={@filters}
          rows={@rows}
          groups={@groups}
          selected={@selected}
          current_company={@current_company}
          can_manage={@can_manage}
          can_invoice={@can_invoice}
          can_pur_invoice={@can_pur_invoice}
          modal={@modal}
          current_user={@current_user}
          can_exempt={@can_exempt}
        />
      <% end %>
      <.waive_modal waive={@waive} />
    </div>
    """
  end

  attr :waive, :any, required: true

  defp waive_modal(assigns) do
    ~H"""
    <.modal
      :if={@waive}
      id="settlement-waive-modal"
      show
      max_w="max-w-md"
      on_cancel={JS.push("close_waive")}
    >
      <p class="text-lg font-medium mb-1">{gettext("Waive billing for this line")}</p>
      <p class="text-sm text-zinc-500 mb-3">
        {gettext(
          "The line leaves the billing queues and the trip settles without this bill. Only an admin can undo it (Un-waive)."
        )}
      </p>
      <form id="settlement-waive-form" phx-submit="confirm_waive" class="m-0">
        <input
          type="text"
          name="reason"
          autocomplete="off"
          placeholder={gettext("Reason (required)")}
          class="w-full rounded border border-zinc-300 px-2 py-1 text-sm"
        />
        <div class="flex gap-2 mt-3 justify-end">
          <button type="button" phx-click="close_waive" class="gray button text-sm py-0.5">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="blue button text-sm py-0.5">
            {gettext("Waive billing")}
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  # --- Trip-only page: all three bill streams, no tabs/filters ---

  attr :trip_filter, :map, required: true
  attr :current_company, :any, required: true
  attr :current_user, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :can_invoice, :boolean, required: true
  attr :can_pur_invoice, :boolean, required: true
  attr :customer_rows, :list, required: true
  attr :supplier_rows, :list, required: true
  attr :transport_rows, :list, required: true
  attr :selected_by_stream, :map, required: true
  attr :modal, :any, required: true
  attr :can_exempt, :boolean, default: false

  defp trip_settlement_page(assigns) do
    ~H"""
    <div id="settlement-trip-page">
      <p class="w-full text-3xl text-center font-medium">
        {gettext("Trip Settlement")}
        <span class="font-mono text-2xl text-violet-800">{@trip_filter.reference_no}</span>
      </p>
      <div class="text-center mb-4">
        <.link
          id="settlement-back-desk"
          navigate={~p"/companies/#{@current_company.id}/trading/desk"}
          class="gray button"
        >
          {gettext("Back to Trading Desk")}
        </.link>
      </div>
      <p class="text-sm text-center text-gray-600 mb-6">
        {gettext(
          "Customer invoice, supplier bill, and transport bill for this trip. Select unbilled lines and create a document; billed lines link to the existing Invoice or PurInvoice."
        )}
      </p>

      <.stream_panel
        stream="customer"
        title={stream_title("customer")}
        header_class={stream_header_class("customer")}
        rows={@customer_rows}
        selected={Map.get(@selected_by_stream, "customer", MapSet.new())}
        current_company={@current_company}
        can_manage={@can_manage}
        can_create={@can_invoice}
        create_id="create-trading-doc-customer"
        can_exempt={@can_exempt}
      />
      <.stream_panel
        stream="supplier"
        title={stream_title("supplier")}
        header_class={stream_header_class("supplier")}
        rows={@supplier_rows}
        selected={Map.get(@selected_by_stream, "supplier", MapSet.new())}
        current_company={@current_company}
        can_manage={@can_manage}
        can_create={@can_pur_invoice}
        create_id="create-trading-doc-supplier"
        can_exempt={@can_exempt}
      />
      <.stream_panel
        stream="transport"
        title={stream_title("transport")}
        header_class={stream_header_class("transport")}
        rows={@transport_rows}
        selected={Map.get(@selected_by_stream, "transport", MapSet.new())}
        current_company={@current_company}
        can_manage={@can_manage}
        can_create={@can_pur_invoice}
        create_id="create-trading-doc-transport"
        can_exempt={@can_exempt}
      />

      <.settlement_trip_modal
        modal={@modal}
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :stream, :string, required: true
  attr :title, :string, required: true
  attr :header_class, :string, required: true
  attr :rows, :list, required: true
  attr :selected, :any, required: true
  attr :current_company, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :can_create, :boolean, required: true
  attr :create_id, :string, required: true
  attr :can_exempt, :boolean, default: false

  defp stream_panel(assigns) do
    groups = Enum.group_by(assigns.rows, &party_key(&1, assigns.stream))
    selected_count = MapSet.size(assigns.selected)
    selected_mt = selected_total_mt(assigns.rows, assigns.selected)

    assigns =
      assign(assigns,
        groups: groups,
        selected_count: selected_count,
        selected_mt: selected_mt
      )

    ~H"""
    <section
      id={"settlement-stream-#{@stream}"}
      class="mb-8 border-2 rounded-lg overflow-hidden border-zinc-300 bg-white dark:bg-zinc-900"
    >
      <div class={["px-3 py-2 border-b font-bold flex flex-wrap gap-2 items-center", @header_class]}>
        <span class="text-base">{@title}</span>
        <span class="font-normal text-xs ml-auto">
          {group_selectable_count(@rows, @stream)}/{length(@rows)} {gettext("billable")} · {group_mt(
            @rows
          )} {gettext("MT")}
        </span>
      </div>

      <div class="flex flex-wrap gap-3 items-center px-3 py-2 border-b bg-zinc-50 text-sm">
        <span>
          {gettext("Selected")}: <strong>{@selected_count}</strong>
          · {gettext("MT")}: <strong>{@selected_mt}</strong>
        </span>
        <button
          :if={@can_create}
          type="button"
          phx-click="create_doc"
          phx-value-stream={@stream}
          id={@create_id}
          class="blue button text-sm py-0.5"
          disabled={@selected_count == 0}
        >
          {action_label(@stream)}
        </button>
        <span :if={!@can_create} class="text-amber-700 text-xs">
          {case @stream do
            "customer" -> gettext("You need invoice permission to settle drops.")
            _ -> gettext("You need purchase-invoice permission to bill.")
          end}
        </span>
      </div>

      <div :if={@rows == []} class="text-center text-gray-500 py-6 text-sm">
        {empty_text(@stream)}
      </div>

      <div
        :for={{{party_id, party_name}, group_rows} <- @groups}
        class="border-t border-zinc-200"
      >
        <div class="bg-zinc-100 px-3 py-1.5 flex gap-2 items-center text-sm font-semibold">
          <button
            :if={group_selectable_count(group_rows, @stream) > 0}
            type="button"
            phx-click="toggle_party"
            phx-value-party_id={party_id}
            phx-value-stream={@stream}
            class="underline text-blue-800 font-normal text-xs"
            id={"toggle-party-#{@stream}-#{party_id}"}
          >
            {gettext("Toggle all billable")}
          </button>
          <span class="flex-1">{party_name}</span>
          <span class="font-normal text-xs text-zinc-600">
            {group_selectable_count(group_rows, @stream)}/{length(group_rows)} {gettext("billable")}
          </span>
        </div>
        <.settlement_table
          stream={@stream}
          group_rows={group_rows}
          selected={@selected}
          current_company={@current_company}
          can_manage={@can_manage}
          compact_trip={true}
          can_exempt={@can_exempt}
        />
      </div>
    </section>
    """
  end

  # --- Full settlement board (unfiltered) ---

  attr :page_title, :string, required: true
  attr :tab, :string, required: true
  attr :filters, :map, required: true
  attr :rows, :list, required: true
  attr :groups, :map, required: true
  attr :selected, :any, required: true
  attr :current_company, :any, required: true
  attr :current_user, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :can_invoice, :boolean, required: true
  attr :can_pur_invoice, :boolean, required: true
  attr :modal, :any, required: true
  attr :can_exempt, :boolean, default: false

  defp board_settlement_page(assigns) do
    assigns =
      assign(assigns,
        selected_count: MapSet.size(assigns.selected),
        selected_mt: selected_total_mt(assigns.rows, assigns.selected)
      )

    ~H"""
    <div id="settlement-board-page">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-3 flex flex-wrap gap-2 justify-center">
        <.link navigate={~p"/companies/#{@current_company.id}/trading/desk"} class="gray button">
          {gettext("Trading Desk")}
        </.link>
        <button
          type="button"
          id="tab-customer"
          phx-click="set_tab"
          phx-value-tab="customer"
          class={[
            "button",
            @tab == "customer" && "blue",
            @tab != "customer" && "gray"
          ]}
        >
          {gettext("Customer invoices")}
        </button>
        <button
          type="button"
          id="tab-supplier"
          phx-click="set_tab"
          phx-value-tab="supplier"
          class={[
            "button",
            @tab == "supplier" && "blue",
            @tab != "supplier" && "gray"
          ]}
        >
          {gettext("Supplier bills")}
        </button>
        <button
          type="button"
          id="tab-transport"
          phx-click="set_tab"
          phx-value-tab="transport"
          class={[
            "button",
            @tab == "transport" && "blue",
            @tab != "transport" && "gray"
          ]}
        >
          {gettext("Transport bills")}
        </button>
      </div>

      <p class="text-sm text-center text-gray-600 mb-4">
        {help_text(@tab)}
      </p>

      <.form
        for={%{}}
        as={:filters}
        id="settlement-filters"
        phx-change="filter"
        class="mb-4 flex flex-wrap gap-2 items-end justify-center text-sm"
      >
        <div>
          <label class="block text-xs font-medium">{party_filter_label(@tab)}</label>
          <select name="filters[party_id]" class="border rounded px-2 py-1 min-w-[12rem]">
            <option value="">{all_parties_label(@tab)}</option>
            <option
              :for={{name, id} <- party_options(@rows, @tab)}
              value={id}
              selected={@filters["party_id"] == id}
            >
              {name}
            </option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium">{gettext("From")}</label>
          <input
            type="date"
            name="filters[from_date]"
            value={@filters["from_date"]}
            class="border rounded px-2 py-1"
          />
        </div>
        <div>
          <label class="block text-xs font-medium">{gettext("To")}</label>
          <input
            type="date"
            name="filters[to_date]"
            value={@filters["to_date"]}
            class="border rounded px-2 py-1"
          />
        </div>
      </.form>

      <div class="flex flex-wrap gap-3 justify-center items-center mb-4">
        <span class="text-sm">
          {gettext("Selected")}: <strong>{@selected_count}</strong>
          · {gettext("MT")}: <strong>{@selected_mt}</strong>
        </span>
        <button
          :if={can_create?(assigns)}
          type="button"
          phx-click="create_doc"
          id="create-trading-doc"
          class="blue button"
          disabled={@selected_count == 0}
        >
          {action_label(@tab)}
        </button>
        <span :if={!can_create?(assigns)} class="text-sm text-amber-700">
          {case @tab do
            "customer" -> gettext("You need invoice permission to settle drops.")
            _ -> gettext("You need purchase-invoice permission to bill.")
          end}
        </span>
      </div>

      <div :if={@rows == []} class="text-center text-gray-500 py-8 border rounded">
        {board_empty_text(@tab)}
      </div>

      <div
        :for={{{party_id, party_name}, group_rows} <- @groups}
        class="mb-6 border rounded overflow-hidden"
      >
        <div class="bg-amber-200 border-b border-amber-500 font-bold p-2 flex gap-2 items-center text-sm">
          <button
            :if={group_selectable_count(group_rows, @tab) > 0}
            type="button"
            phx-click="toggle_party"
            phx-value-party_id={party_id}
            class="underline text-blue-800"
            id={"toggle-party-#{party_id}"}
          >
            {gettext("Toggle all billable")}
          </button>
          <span
            :if={group_selectable_count(group_rows, @tab) == 0}
            class="text-xs font-normal text-gray-600"
          >
            {gettext("None billable yet")}
          </span>
          <span class="flex-1">{party_name}</span>
          <span class="font-normal text-xs">
            {group_selectable_count(group_rows, @tab)}/{length(group_rows)} {gettext("billable")} · {group_mt(
              group_rows
            )} {gettext("MT")}
          </span>
        </div>
        <.settlement_table
          stream={@tab}
          group_rows={group_rows}
          selected={@selected}
          current_company={@current_company}
          can_manage={@can_manage}
          compact_trip={false}
          can_exempt={@can_exempt}
        />
      </div>

      <.settlement_trip_modal
        modal={@modal}
        current_company={@current_company}
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :stream, :string, required: true
  attr :group_rows, :list, required: true
  attr :selected, :any, required: true
  attr :current_company, :any, required: true
  attr :can_manage, :boolean, required: true
  attr :compact_trip, :boolean, default: false
  attr :can_exempt, :boolean, default: false

  defp settlement_table(assigns) do
    ~H"""
    <div class="bg-gray-100 font-semibold p-2 flex gap-1 text-xs border-b">
      <div class="w-8"></div>
      <div :if={!@compact_trip} class="w-2/12">{gettext("Date")}</div>
      <div :if={!@compact_trip} class="w-2/12">{gettext("Trip")}</div>
      <div :if={!@compact_trip} class="w-1/12">{gettext("Status")}</div>
      <div class={if(@compact_trip, do: "w-3/12", else: "w-2/12")}>
        {position_col_label(@stream)}
      </div>
      <div class="w-2/12">{gettext("Good")}</div>
      <div class={if(@compact_trip, do: "w-3/12", else: "w-2/12")}>
        {location_col_label(@stream)}
      </div>
      <div class="w-1/12 text-right">{gettext("MT")}</div>
      <div class="w-1/12 text-right">{gettext("Price")}</div>
      <div class="w-2/12">{gettext("Bill")}</div>
    </div>
    <div
      :for={row <- @group_rows}
      id={"settlement-row-#{row.id}"}
      class={[
        "flex gap-1 border-b p-2 text-sm items-center",
        selectable?(row, @stream) && "hover:bg-gray-50",
        settled?(row) && "bg-emerald-50/50",
        waived?(row) && "opacity-70 bg-zinc-100/80 dark:bg-zinc-800/60",
        (!selectable?(row, @stream) and not settled?(row) and not waived?(row)) &&
          "opacity-60 bg-gray-50/80"
      ]}
    >
      <div class="w-8">
        <input
          :if={selectable?(row, @stream) and @compact_trip}
          type="checkbox"
          phx-click="toggle"
          phx-value-id={row.id}
          phx-value-stream={@stream}
          checked={MapSet.member?(@selected, row.id)}
          id={"select-row-#{row.id}"}
        />
        <input
          :if={selectable?(row, @stream) and not @compact_trip}
          type="checkbox"
          phx-click="toggle"
          phx-value-id={row.id}
          checked={MapSet.member?(@selected, row.id)}
          id={"select-row-#{row.id}"}
        />
        <span
          :if={settled?(row)}
          class="inline-block w-4 text-center text-emerald-600"
          title={gettext("Already billed")}
        >
          ✓
        </span>
        <span
          :if={waived?(row)}
          class="inline-block w-4 text-center text-zinc-500"
          title={gettext("Billing waived")}
        >
          ⊘
        </span>
        <span
          :if={!selectable?(row, @stream) and not settled?(row) and not waived?(row)}
          class="inline-block w-4 text-center text-gray-400"
          title={gettext("Complete the trip before billing")}
        >
          —
        </span>
      </div>
      <div :if={!@compact_trip} class="w-2/12">{row.trip_date}</div>
      <div :if={!@compact_trip} class="w-2/12 font-mono text-xs">
        <button
          :if={@can_manage}
          type="button"
          id={"open-trip-#{row.trip_id}-#{row.id}"}
          phx-click="open_trip"
          phx-value-id={row.trip_id}
          class="text-blue-600 hover:underline font-medium text-left"
          title={gettext("Edit trip")}
        >
          {row.trip_reference_no}
        </button>
        <span :if={!@can_manage}>{row.trip_reference_no}</span>
      </div>
      <div :if={!@compact_trip} class="w-1/12">
        <span class={["px-1.5 py-0.5 rounded text-xs font-medium", status_class(row.trip_status)]}>
          {status_label(row.trip_status)}
        </span>
      </div>
      <div class={[
        "font-mono text-xs",
        if(@compact_trip, do: "w-3/12", else: "w-2/12")
      ]}>
        {position_title(row, @stream)}
      </div>
      <div class="w-2/12">{row.good_name}</div>
      <div class={if(@compact_trip, do: "w-3/12", else: "w-2/12")}>
        {location_display(row, @stream)}
      </div>
      <div class="w-1/12 text-right tabular-nums">
        {display_mt(row)}
        <span
          :if={is_nil(row.actual) and not is_nil(row.planned)}
          class="text-xs text-gray-400"
          title={gettext("Planned (no actual yet)")}
        >
          *
        </span>
      </div>
      <div class="w-1/12 text-right tabular-nums">{row.unit_price || "—"}</div>
      <div class="w-2/12 min-w-0 flex items-center gap-1">
        <.link
          :if={settled?(row)}
          id={"settlement-doc-#{row.id}"}
          navigate={settlement_doc_path(@current_company, row)}
          class="text-xs font-medium text-emerald-800 hover:underline truncate block"
          title={gettext("Open billed document")}
        >
          {row.doc_no || gettext("Open bill")}
        </.link>
        <span
          :if={waived?(row)}
          id={"settlement-waived-#{row.id}"}
          class="text-xs font-medium text-zinc-600 dark:text-zinc-400 truncate"
          title={waived_title(row)}
        >
          {gettext("Waived")} · {row.exempt_reason}
        </span>
        <button
          :if={waived?(row) and @can_exempt}
          type="button"
          id={"unwaive-row-#{row.id}"}
          phx-click="unwaive"
          phx-value-id={row.id}
          phx-value-stream={@stream}
          class="text-xs text-blue-700 underline hover:text-blue-900 shrink-0"
          title={gettext("Remove waiver; line becomes billable again")}
        >
          {gettext("Un-waive")}
        </button>
        <span :if={not settled?(row) and not waived?(row)} class="text-xs text-gray-400">
          —
        </span>
        <button
          :if={selectable?(row, @stream) and @can_exempt}
          type="button"
          id={"waive-row-#{row.id}"}
          phx-click="open_waive"
          phx-value-id={row.id}
          phx-value-stream={@stream}
          class="text-xs text-zinc-500 underline hover:text-zinc-800 shrink-0"
          title={gettext("Admin: waive billing for this line (no bill will exist)")}
        >
          {gettext("Waive…")}
        </button>
      </div>
    </div>
    """
  end

  defp waived_title(row) do
    who = Map.get(row, :exempt_by_email)
    at = Map.get(row, :exempt_at)

    [row.exempt_reason, who, at && Calendar.strftime(at, "%Y-%m-%d")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  attr :modal, :any, required: true
  attr :current_company, :any, required: true
  attr :current_user, :any, required: true

  defp settlement_trip_modal(assigns) do
    ~H"""
    <.modal
      :if={@modal}
      id="settlement-trip-modal"
      show
      max_w="max-w-7xl"
      on_cancel={JS.push("close_modal")}
    >
      <.live_component
        :if={@modal.kind == :trip}
        module={FullCircleWeb.TradingDeskLive.TripFormComponent}
        id={"settlement-trip-form-lc-#{@modal[:form_key] || @modal[:id] || "new"}"}
        company={@current_company}
        user={@current_user}
        action={@modal.action}
        trip_id={@modal.id}
        prefill={@modal[:prefill]}
      />
    </.modal>
    """
  end
end
