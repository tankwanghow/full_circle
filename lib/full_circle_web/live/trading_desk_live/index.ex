defmodule FullCircleWeb.TradingDeskLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Authorization

  @filter_fields %{
    "supply" => ~w(no supplier good status),
    "warehouse" => ~w(location good),
    "sales" => ~w(no customer good status need_by),
    "trips" => ~w(date ref vehicle from to good agent status)
  }

  # Default status text shown in filter boxes (comma = OR in filter_rows).
  @supply_active_status "open, hold, collect"
  @sales_active_status "draft, open, hold"
  # Ops-default trip status. Bill chips force "completed".
  @trip_ops_status "draft, planned"
  @trip_billing_status "completed"

  @impl true
  def mount(_params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :view_trading, company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Trading Desk"))
       |> assign(modal: nil)
       |> assign(transit_list: nil)
       |> assign(warehouse_history: nil)
       |> assign(trips_panel: :shown)
       |> assign(trip_detail_ids: MapSet.new())
       # Ops-first: no Bill chips on mount (billing only applies to completed trips)
       |> assign(trip_settle_filters: MapSet.new())
       |> assign(can_manage: Authorization.can?(user, :manage_trading, company))
       |> assign(filters: empty_filters())
       |> assign_empty_selection()
       |> load_panels()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_modal_from_live_action(socket, params)}
  end

  @impl true
  def handle_event("open_modal", %{"kind" => kind, "action" => action} = params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :manage_trading, company) do
      modal = %{
        kind: String.to_existing_atom(kind),
        action: String.to_existing_atom(action),
        id: params["id"],
        form_key: params["id"] || System.unique_integer([:positive])
      }

      {:noreply, assign(socket, modal: modal)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal_and_normalize_url(socket)}
  end

  def handle_event("set_trips_panel", %{"mode" => mode}, socket) do
    panel =
      case mode do
        "hidden" -> :hidden
        "shown" -> :shown
        "maximized" -> :maximized
        _ -> socket.assigns.trips_panel
      end

    {:noreply, assign(socket, trips_panel: panel)}
  end

  def handle_event("toggle_trip_settle_filter", %{"key" => key}, socket)
      when key in ["any", "customer", "supplier", "transport"] do
    set = socket.assigns.trip_settle_filters

    set =
      if MapSet.member?(set, key) do
        MapSet.delete(set, key)
      else
        MapSet.put(set, key)
      end

    # Bill chips only make sense for completed trips. Turning the last chip off
    # restores the ops default (draft + planned).
    status =
      if MapSet.size(set) > 0 do
        @trip_billing_status
      else
        @trip_ops_status
      end

    filters = put_in(socket.assigns.filters, [Access.key!(:trips), Access.key!(:status)], status)

    {:noreply,
     socket
     |> assign(trip_settle_filters: set, filters: filters)
     |> reload_trips()
     |> apply_filters()}
  end

  def handle_event("clear_trip_settle_filters", _, socket) do
    # Clear Bill chips and the status text box (does not restore ops default)
    filters = put_in(socket.assigns.filters, [Access.key!(:trips), Access.key!(:status)], "")

    {:noreply,
     socket
     |> assign(trip_settle_filters: MapSet.new(), filters: filters)
     |> reload_trips()
     |> apply_filters()}
  end

  def handle_event("toggle_trip_detail", %{"id" => id}, socket) do
    ids = socket.assigns.trip_detail_ids

    ids =
      if MapSet.member?(ids, id) do
        MapSet.delete(ids, id)
      else
        MapSet.put(ids, id)
      end

    {:noreply, assign(socket, trip_detail_ids: ids)}
  end

  def handle_event("close_transit_list", _, socket) do
    {:noreply, assign(socket, transit_list: nil)}
  end

  def handle_event("close_warehouse_history", _, socket) do
    {:noreply, assign(socket, warehouse_history: nil)}
  end

  def handle_event(
        "show_warehouse_history",
        %{
          "location_id" => location_id
        } = params,
        socket
      ) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    good_id = params["good_id"]
    good_id = if good_id in [nil, "", "any"], do: nil, else: good_id

    movements =
      Trading.list_warehouse_recent_movements(location_id, good_id, company, user, limit: 20)

    remaining = qty_dec(params["on_hand"])

    unit = params["unit"]
    location_name = params["location_name"] || gettext("Warehouse")
    good_name = params["good_name"]

    hist = %{
      location_id: location_id,
      good_id: good_id,
      location_name: location_name,
      good_name: good_name,
      unit: unit,
      remaining: remaining,
      movements: movements
    }

    {:noreply, assign(socket, warehouse_history: hist)}
  end

  def handle_event("open_warehouse_history_trip", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      modal = %{kind: :trip, action: :edit, id: id, form_key: id}

      {:noreply,
       socket
       |> assign(warehouse_history: nil)
       |> assign(modal: modal)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("show_transit_trips", %{"kind" => kind} = params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    {kind_atom, opts, title} = transit_list_query(kind, params)

    trips =
      if kind_atom do
        Trading.list_open_trips_for(company, user, kind_atom, opts)
      else
        []
      end

    list = %{
      kind: kind_atom,
      title: title,
      trips: trips
    }

    {:noreply, assign(socket, transit_list: list)}
  end

  def handle_event("open_transit_trip", %{"id" => id}, socket) do
    if socket.assigns.can_manage do
      modal = %{kind: :trip, action: :edit, id: id, form_key: id}
      {:noreply, assign(socket, modal: modal)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("filter", params, socket) do
    table = params["table"]
    field = params["field"]
    value = params["value"] || ""

    if is_binary(table) and is_binary(field) and
         field in Map.get(@filter_fields, table, []) do
      t = String.to_existing_atom(table)
      f = String.to_existing_atom(field)

      filters =
        put_in(socket.assigns.filters, [Access.key!(t), Access.key!(f)], value)

      socket =
        socket
        |> assign(:filters, filters)
        |> maybe_reload_for_status_filter(t, f)
        |> apply_filters()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Status chips write the same comma-OR string the status filter uses, so the
  # reload/expand/filter pipeline stays unchanged. All chips off = no status
  # restriction over the loaded (active) rows, same as an emptied status box.
  def handle_event("toggle_status_chip", %{"table" => table, "status" => status}, socket)
      when table in ["supply", "sales", "trips"] do
    t = String.to_existing_atom(table)
    vocab = panel_statuses(t)

    if status in vocab do
      tokens = filter_tokens(socket.assigns.filters[t].status)

      tokens =
        if status in tokens, do: List.delete(tokens, status), else: [status | tokens]

      value = vocab |> Enum.filter(&(&1 in tokens)) |> Enum.join(", ")

      filters = put_in(socket.assigns.filters, [Access.key!(t), Access.key!(:status)], value)

      {:noreply,
       socket
       |> assign(:filters, filters)
       |> maybe_reload_for_status_filter(t, :status)
       |> apply_filters()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_filter", %{"table" => table, "field" => field}, socket) do
    handle_event("filter", %{"table" => table, "field" => field, "value" => ""}, socket)
  end

  def handle_event("clear_panel_filters", %{"table" => table}, socket)
      when table in ["supply", "warehouse", "sales", "trips"] do
    t = String.to_existing_atom(table)
    filters = Map.put(socket.assigns.filters, t, empty_filters()[t])
    socket = assign(socket, :filters, filters)

    socket =
      case t do
        :supply -> maybe_reload_for_status_filter(socket, :supply, :status)
        :sales -> maybe_reload_for_status_filter(socket, :sales, :status)
        :trips -> socket |> assign(trip_settle_filters: MapSet.new()) |> reload_trips()
        :warehouse -> socket
      end

    {:noreply, apply_filters(socket)}
  end

  def handle_event("toggle_select", %{"kind" => kind, "id" => id} = params, socket) do
    if socket.assigns.can_manage do
      {:noreply, toggle_selection(socket, kind, id, params["good_id"])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_selection", _, socket) do
    had_sales = MapSet.size(socket.assigns.selected_sales_ids) > 0

    socket = assign_empty_selection(socket)

    socket =
      if had_sales do
        # Drop auto good filters that came from the selected sales
        sync_good_filters_from_selected_sales(socket)
      else
        apply_filters(socket)
      end

    {:noreply, socket}
  end

  def handle_event("create_trip_from_selection", _, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if socket.assigns.can_manage and selection_ready?(socket) do
      selection = selection_payload(socket)

      case Trading.build_trip_attrs_from_selection(selection, company, user) do
        {:ok, attrs} ->
          modal = %{
            kind: :trip,
            action: :new,
            id: nil,
            prefill: attrs,
            form_key: System.unique_integer([:positive])
          }

          {:noreply, assign(socket, modal: modal)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Could not build trip (%{reason})", reason: inspect(reason))
           )}

        :not_authorise ->
          {:noreply,
           put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "Select at least one load (supply or warehouse Out) and one drop (sales or warehouse In)."
         )
       )}
    end
  end

  defp transit_list_query("supply_transit", %{"id" => id}) do
    {:supply_transit, [supply_id: id], gettext("In-transit loads for supply")}
  end

  defp transit_list_query("sales_transit", %{"id" => id}) do
    {:sales_transit, [sales_id: id], gettext("In-transit drops for sales")}
  end

  defp transit_list_query("warehouse_incoming", %{"location_id" => loc, "good_id" => good}) do
    {:warehouse_incoming, [location_id: loc, good_id: good],
     gettext("Incoming trips to warehouse")}
  end

  defp transit_list_query("warehouse_outgoing", %{"location_id" => loc, "good_id" => good}) do
    {:warehouse_outgoing, [location_id: loc, good_id: good],
     gettext("Outgoing trips from warehouse")}
  end

  defp transit_list_query(_, _), do: {nil, [], gettext("Open trips")}

  @impl true
  def handle_info({:desk_modal_saved, kind}, socket),
    do: handle_info({:desk_modal_saved, kind, nil}, socket)

  def handle_info({:desk_modal_saved, kind, msg}, socket) do
    msg = msg || default_msg(kind)

    socket =
      socket
      |> put_flash(:info, msg)
      |> then(fn s ->
        if kind == :trip do
          s
          |> assign_empty_selection()
          # Clear auto good filters that came from the selected sales
          |> sync_good_filters_from_selected_sales()
        else
          s
        end
      end)
      |> load_panels()
      |> close_modal_and_normalize_url()

    {:noreply, socket}
  end

  # LiveComponents cannot put_flash on the parent layout; they send this instead.
  def handle_info({:desk_flash, kind, msg}, socket)
      when kind in [:info, :error, :warn] and is_binary(msg) do
    {:noreply, put_flash(socket, kind, msg)}
  end

  # Deep links: /supply_positions/:id/edit, /trips/new, etc. → desk + modal
  defp apply_modal_from_live_action(socket, params) do
    if socket.assigns.can_manage do
      case socket.assigns.live_action do
        :new_supply ->
          assign(socket, modal: %{kind: :supply, action: :new, id: nil})

        :edit_supply ->
          assign(socket,
            modal: %{kind: :supply, action: :edit, id: params["id"], form_key: params["id"]}
          )

        :new_sales ->
          assign(socket, modal: %{kind: :sales, action: :new, id: nil})

        :edit_sales ->
          assign(socket,
            modal: %{kind: :sales, action: :edit, id: params["id"], form_key: params["id"]}
          )

        :new_trip ->
          assign(socket,
            modal: %{
              kind: :trip,
              action: :new,
              id: nil,
              form_key: System.unique_integer([:positive])
            }
          )

        :edit_trip ->
          assign(socket,
            modal: %{kind: :trip, action: :edit, id: params["id"], form_key: params["id"]}
          )

        :index ->
          # Keep event-opened modal when already on desk; clear only if nothing open
          socket

        _ ->
          socket
      end
    else
      case socket.assigns.live_action do
        action
        when action in [:new_supply, :edit_supply, :new_sales, :edit_sales, :new_trip, :edit_trip] ->
          socket
          |> put_flash(:error, gettext("You are not authorised to perform this action"))
          |> push_patch(to: desk_path(socket))

        _ ->
          socket
      end
    end
  end

  defp close_modal_and_normalize_url(socket) do
    company = socket.assigns.current_company
    path = ~p"/companies/#{company.id}/trading/desk"

    socket = assign(socket, modal: nil)

    if socket.assigns.live_action != :index do
      push_patch(socket, to: path)
    else
      socket
    end
  end

  defp desk_path(socket),
    do: ~p"/companies/#{socket.assigns.current_company.id}/trading/desk"

  defp assign_empty_selection(socket) do
    socket
    |> assign(:selected_supply_ids, MapSet.new())
    |> assign(:selected_warehouse_load_keys, MapSet.new())
    |> assign(:selected_warehouse_drop_keys, MapSet.new())
    |> assign(:selected_sales_ids, MapSet.new())
  end

  # Need ≥1 load source (supply and/or warehouse Out) and ≥1 drop target
  # (sales and/or warehouse In). Supports delivery, stock-in, and mixed
  # (part to customer + part to own warehouse).
  defp selection_ready?(socket) do
    loads =
      MapSet.size(socket.assigns.selected_supply_ids) +
        MapSet.size(socket.assigns.selected_warehouse_load_keys)

    drops =
      MapSet.size(socket.assigns.selected_sales_ids) +
        MapSet.size(socket.assigns.selected_warehouse_drop_keys)

    loads > 0 and drops > 0
  end

  defp selection_payload(socket) do
    %{
      supply_ids: MapSet.to_list(socket.assigns.selected_supply_ids),
      warehouse_load_keys: parse_warehouse_keys(socket.assigns.selected_warehouse_load_keys),
      warehouse_drop_keys: parse_warehouse_keys(socket.assigns.selected_warehouse_drop_keys),
      sales_ids: MapSet.to_list(socket.assigns.selected_sales_ids)
    }
  end

  defp parse_warehouse_keys(set) do
    set
    |> MapSet.to_list()
    |> Enum.map(fn key ->
      [loc_id, good_id] = String.split(key, ":", parts: 2)
      good_id = if good_id in ["any", "nil", ""], do: nil, else: good_id
      %{location_id: loc_id, good_id: good_id}
    end)
  end

  defp warehouse_key(location_id, good_id) when is_binary(good_id),
    do: "#{location_id}:#{good_id}"

  defp warehouse_key(location_id, _), do: "#{location_id}:any"

  defp warehouse_row_selected?(load_keys, drop_keys, row) do
    key = warehouse_key(row.location.id, (row.good && row.good.id) || "any")
    MapSet.member?(load_keys, key) or MapSet.member?(drop_keys, key)
  end

  defp toggle_selection(socket, "supply", id, _good_id) do
    toggle_id_set(socket, :selected_supply_ids, id)
  end

  defp toggle_selection(socket, "sales", id, _good_id) do
    selecting? = not MapSet.member?(socket.assigns.selected_sales_ids, id)

    socket
    |> toggle_id_set(:selected_sales_ids, id)
    |> then(fn s ->
      if selecting?, do: maybe_auto_select_preferred_supply(s, id), else: s
    end)
    # Narrow supply + warehouse boards to the selected sale goods
    |> sync_good_filters_from_selected_sales()
  end

  # Out and In are mutually exclusive per warehouse row (same location×good key).
  defp toggle_selection(socket, "warehouse_load", key, _good_id) do
    toggle_warehouse_exclusive(
      socket,
      :selected_warehouse_load_keys,
      :selected_warehouse_drop_keys,
      key
    )
  end

  defp toggle_selection(socket, "warehouse_drop", key, _good_id) do
    toggle_warehouse_exclusive(
      socket,
      :selected_warehouse_drop_keys,
      :selected_warehouse_load_keys,
      key
    )
  end

  defp toggle_selection(socket, _, _, _), do: socket

  # When selecting open sales that soft-holds a supply, tick that supply too
  # (only if it is still on the open supply board).
  defp maybe_auto_select_preferred_supply(socket, sales_id) do
    preferred_id =
      socket.assigns.sales_all
      |> Enum.find_value(fn row ->
        if row.sales.id == sales_id, do: row.sales.preferred_supply_id
      end)

    # Being on the board is not enough — a status filter can pull closed rows in,
    # and those render no checkbox, so auto-ticking one would strand a selection
    # the user cannot see or clear from the supply panel.
    on_board? =
      is_binary(preferred_id) and
        Enum.any?(
          socket.assigns.supply_all,
          &(&1.supply.id == preferred_id and supply_selectable?(&1.supply.status))
        )

    if on_board? do
      socket
      |> assign(
        :selected_supply_ids,
        MapSet.put(socket.assigns.selected_supply_ids, preferred_id)
      )
      |> apply_filters()
    else
      socket
    end
  end

  # Set supply + warehouse "good" column filters from currently selected sales.
  # Multiple sales → comma-OR of unique good names. No selection → clear those
  # filters (caller only invokes this after a sales selection change).
  defp sync_good_filters_from_selected_sales(socket) do
    goods =
      socket.assigns.sales_all
      |> Enum.filter(&MapSet.member?(socket.assigns.selected_sales_ids, &1.sales.id))
      |> Enum.map(&nested_name(&1.sales, :good))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join(", ")

    filters =
      socket.assigns.filters
      |> put_in([Access.key!(:supply), Access.key!(:good)], goods)
      |> put_in([Access.key!(:warehouse), Access.key!(:good)], goods)

    socket
    |> assign(:filters, filters)
    |> apply_filters()
  end

  defp toggle_id_set(socket, set_key, id) do
    set = Map.get(socket.assigns, set_key)

    set =
      if MapSet.member?(set, id) do
        MapSet.delete(set, id)
      else
        MapSet.put(set, id)
      end

    socket
    |> assign(set_key, set)
    |> apply_filters()
  end

  defp toggle_warehouse_exclusive(socket, set_key, other_key, id) do
    set = Map.get(socket.assigns, set_key)
    other = Map.get(socket.assigns, other_key)

    if MapSet.member?(set, id) do
      socket
      |> assign(set_key, MapSet.delete(set, id))
      |> apply_filters()
    else
      socket
      |> assign(set_key, MapSet.put(set, id))
      |> assign(other_key, MapSet.delete(other, id))
      |> apply_filters()
    end
  end

  defp default_msg(:supply), do: gettext("Supply position saved successfully.")
  defp default_msg(:sales), do: gettext("Sales position saved successfully.")
  defp default_msg(:trip), do: gettext("Trip saved successfully.")
  defp default_msg(_), do: gettext("Saved successfully.")

  defp empty_filters do
    %{
      supply: %{no: "", supplier: "", good: "", status: @supply_active_status},
      warehouse: %{location: "", good: ""},
      sales: %{
        no: "",
        customer: "",
        good: "",
        status: @sales_active_status,
        need_by: ""
      },
      trips: %{
        date: "",
        ref: "",
        vehicle: "",
        from: "",
        to: "",
        good: "",
        agent: "",
        status: @trip_ops_status
      }
    }
  end

  defp load_panels(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    f = socket.assigns.filters

    trips = load_trips_for_panel(company, user, socket.assigns.trip_settle_filters)

    socket
    |> assign(
      :supply_all,
      Trading.position_board(company, user, statuses: supply_statuses_for_filter(f.supply.status))
    )
    |> assign(
      :sales_all,
      Trading.sales_board(company, user, statuses: sales_statuses_for_filter(f.sales.status))
    )
    |> assign(:warehouse_all, Trading.warehouse_board(company, user))
    |> assign(:trips_all, trips)
    |> apply_filters()
  end

  # Status filter may request inactive rows (closed / fulfilled / cancelled).
  # Reload those panels from the server when the status box changes.
  defp maybe_reload_for_status_filter(socket, :supply, :status) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    statuses = supply_statuses_for_filter(socket.assigns.filters.supply.status)

    assign(socket, :supply_all, Trading.position_board(company, user, statuses: statuses))
  end

  defp maybe_reload_for_status_filter(socket, :sales, :status) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user
    statuses = sales_statuses_for_filter(socket.assigns.filters.sales.status)

    assign(socket, :sales_all, Trading.sales_board(company, user, statuses: statuses))
  end

  defp maybe_reload_for_status_filter(socket, _, _), do: socket

  # Empty status → active only. Comma-OR tokens that match inactive statuses
  # (e.g. "closed" or "open, closed") are included so the client filter can show them.
  defp supply_statuses_for_filter(status_q) do
    expand_statuses_for_filter(
      status_q,
      FullCircle.Trading.SupplyPosition.active_statuses(),
      FullCircle.Trading.SupplyPosition.statuses()
    )
  end

  defp sales_statuses_for_filter(status_q) do
    expand_statuses_for_filter(
      status_q,
      FullCircle.Trading.SalesPosition.active_statuses(),
      FullCircle.Trading.SalesPosition.statuses()
    )
  end

  defp expand_statuses_for_filter(status_q, active, all) do
    tokens = filter_tokens(status_q)

    if tokens == [] do
      active
    else
      matched =
        Enum.filter(all, fn s ->
          Enum.any?(tokens, fn t ->
            String.starts_with?(s, t) or String.contains?(s, t)
          end)
        end)

      if matched == [] do
        active
      else
        # Keep active rows loaded so a partial token does not empty the board
        # before the client filter applies; inactive matches are added for typing.
        Enum.uniq(active ++ matched)
      end
    end
  end

  defp apply_filters(socket) do
    f = socket.assigns.filters

    supply_rows =
      socket.assigns.supply_all
      |> filter_rows(f.supply, &supply_field/2)

    warehouse_rows =
      socket.assigns.warehouse_all
      |> filter_rows(f.warehouse, &warehouse_field/2)

    sales_rows =
      socket.assigns.sales_all
      |> filter_rows(f.sales, &sales_field/2)

    trips =
      socket.assigns.trips_all
      |> filter_rows(f.trips, &trip_field/2)
      |> filter_trips_by_settlement(socket.assigns.trip_settle_filters)
      |> sort_trips_most_recent_first()

    socket
    |> assign(:supply_rows, supply_rows)
    |> assign(:warehouse_rows, warehouse_rows)
    |> assign(:sales_rows, sales_rows)
    |> assign(:trips, trips)
    |> assign(:selection_ready, selection_ready?(socket))
    |> assign(:selection_summary, selection_summary(socket))
    |> assign(:selection_active, selection_active?(socket))
  end

  # Ops view shows the newest trips only. Bill chips are about settlement, which
  # only exists on completed trips and stays open indefinitely — capping there
  # would hide older unbilled trips, so query that set from the DB instead.
  defp load_trips_for_panel(company, user, settle_filters) do
    if MapSet.size(settle_filters) > 0 do
      Trading.list_trips(company, user, status: "completed")
    else
      company
      |> Trading.list_trips(user)
      # list_trips is already most-recent-first; take newest 50 for the desk
      |> Enum.take(50)
    end
  end

  defp reload_trips(socket) do
    trips =
      load_trips_for_panel(
        socket.assigns.current_company,
        socket.assigns.current_user,
        socket.assigns.trip_settle_filters
      )

    assign(socket, :trips_all, trips)
  end

  # Settlement chips: multi-select OR. Empty = no settle filter.
  # "any" = any stream open/partial; stream keys match that stream only.
  defp filter_trips_by_settlement(trips, filters) do
    if MapSet.size(filters) == 0 do
      trips
    else
      Enum.filter(trips, fn t ->
        badges = Trading.trip_settlement_badges(t)
        Enum.any?(filters, &settlement_filter_match?(&1, badges))
      end)
    end
  end

  defp sort_trips_most_recent_first(trips) do
    Enum.sort_by(
      trips,
      fn t ->
        {
          t.date || ~D[0001-01-01],
          t.reference_no || "",
          t.inserted_at || ~U[0001-01-01 00:00:00Z]
        }
      end,
      :desc
    )
  end

  defp settlement_filter_match?("any", badges) do
    badges.show? and
      (badges.customer in [:open, :partial] or
         badges.supplier in [:open, :partial] or
         badges.transport in [:open, :partial])
  end

  defp settlement_filter_match?("customer", badges),
    do: badges.show? and badges.customer in [:open, :partial]

  defp settlement_filter_match?("supplier", badges),
    do: badges.show? and badges.supplier in [:open, :partial]

  defp settlement_filter_match?("transport", badges),
    do: badges.show? and badges.transport in [:open, :partial]

  defp settlement_filter_match?(_, _), do: false

  defp supply_selectable?(status),
    do: status in FullCircle.Trading.SupplyPosition.active_statuses()

  defp sales_selectable?(status),
    do: status in FullCircle.Trading.SalesPosition.active_statuses()

  defp selection_active?(socket) do
    MapSet.size(socket.assigns.selected_supply_ids) > 0 or
      MapSet.size(socket.assigns.selected_warehouse_load_keys) > 0 or
      MapSet.size(socket.assigns.selected_warehouse_drop_keys) > 0 or
      MapSet.size(socket.assigns.selected_sales_ids) > 0
  end

  defp selection_summary(socket) do
    supply_ids = socket.assigns.selected_supply_ids
    sales_ids = socket.assigns.selected_sales_ids
    wh_load = socket.assigns.selected_warehouse_load_keys
    wh_drop = socket.assigns.selected_warehouse_drop_keys

    demand =
      socket.assigns.sales_all
      |> Enum.filter(fn row -> MapSet.member?(sales_ids, row.sales.id) end)
      |> Enum.reduce(Decimal.new(0), fn row, acc -> Decimal.add(acc, row.undelivered || 0) end)

    supply_mt =
      socket.assigns.supply_all
      |> Enum.filter(fn row -> MapSet.member?(supply_ids, row.supply.id) end)
      |> Enum.reduce(Decimal.new(0), fn row, acc -> Decimal.add(acc, row.remaining || 0) end)

    wh_load_mt =
      socket.assigns.warehouse_all
      |> Enum.filter(fn row ->
        row.good &&
          MapSet.member?(wh_load, warehouse_key(row.location.id, row.good.id))
      end)
      |> Enum.reduce(Decimal.new(0), fn row, acc -> Decimal.add(acc, row.on_hand || 0) end)

    source = Decimal.add(supply_mt, wh_load_mt)

    good_names =
      (
        from_s =
          socket.assigns.sales_all
          |> Enum.filter(&MapSet.member?(sales_ids, &1.sales.id))
          |> Enum.map(&(&1.sales.good && &1.sales.good.name))

        from_p =
          socket.assigns.supply_all
          |> Enum.filter(&MapSet.member?(supply_ids, &1.supply.id))
          |> Enum.map(&(&1.supply.good && &1.supply.good.name))

        from_wl =
          socket.assigns.warehouse_all
          |> Enum.filter(fn row ->
            row.good && MapSet.member?(wh_load, warehouse_key(row.location.id, row.good.id))
          end)
          |> Enum.map(&(&1.good && &1.good.name))

        from_wd =
          socket.assigns.warehouse_all
          |> Enum.filter(fn row ->
            key = warehouse_key(row.location.id, (row.good && row.good.id) || "any")
            MapSet.member?(wh_drop, key)
          end)
          |> Enum.map(fn row -> (row.good && row.good.name) || gettext("warehouse") end)

        (from_s ++ from_p ++ from_wl ++ from_wd)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.join(", ")
      )

    has_sales = MapSet.size(sales_ids) > 0
    has_wh_in = MapSet.size(wh_drop) > 0

    mode =
      cond do
        has_sales and has_wh_in -> :mixed
        has_sales -> :delivery
        has_wh_in -> :stock_in
        true -> :partial
      end

    %{
      sales_n: MapSet.size(sales_ids),
      supply_n: MapSet.size(supply_ids),
      warehouse_load_n: MapSet.size(wh_load),
      warehouse_drop_n: MapSet.size(wh_drop),
      demand: demand,
      source: source,
      short: Decimal.compare(demand, source) == :gt,
      goods: good_names,
      mode: mode
    }
  end

  # Comma-delimited tokens are OR'd (trimmed, case-insensitive substring match).
  # Example: status "draft, planned" matches draft OR planned.
  defp filter_rows(rows, filters, field_fn) do
    Enum.reduce(filters, rows, fn {field, query}, acc ->
      tokens = filter_tokens(query)

      if tokens == [] do
        acc
      else
        Enum.filter(acc, fn row ->
          value =
            row
            |> field_fn.(field)
            |> as_text()
            |> String.downcase()

          Enum.any?(tokens, &String.contains?(value, &1))
        end)
      end
    end)
  end

  defp filter_tokens(query) do
    query
    |> as_text()
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp as_text(nil), do: ""
  defp as_text(v) when is_binary(v), do: v
  defp as_text(%Date{} = d), do: Date.to_iso8601(d)
  defp as_text(v), do: to_string(v)

  defp supply_field(row, :no), do: row.supply.title
  defp supply_field(row, :supplier), do: nested_name(row.supply, :supplier)
  defp supply_field(row, :good), do: nested_name(row.supply, :good)
  defp supply_field(row, :status), do: row.supply.status
  defp supply_field(_, _), do: ""

  defp warehouse_field(row, :location), do: row.location && row.location.name
  defp warehouse_field(row, :good), do: row.good && row.good.name
  defp warehouse_field(_, _), do: ""

  defp sales_field(row, :no), do: row.sales.title
  defp sales_field(row, :customer), do: nested_name(row.sales, :customer)
  defp sales_field(row, :good), do: nested_name(row.sales, :good)
  defp sales_field(row, :status), do: row.sales.status
  defp sales_field(row, :need_by), do: row.sales.available_from
  defp sales_field(_, _), do: ""

  defp trip_field(t, :date), do: t.date
  defp trip_field(t, :ref), do: t.reference_no
  defp trip_field(t, :vehicle), do: t.vehicle_number
  defp trip_field(t, :from), do: Enum.join(Trading.trip_from_names(t), ", ")
  defp trip_field(t, :to), do: Enum.join(Trading.trip_to_names(t), ", ")
  defp trip_field(t, :agent), do: t.transport_agent && t.transport_agent.name
  defp trip_field(t, :good), do: trip_goods_label(t)
  defp trip_field(t, :status), do: t.status
  defp trip_field(_, _), do: ""

  defp panel_statuses(:supply), do: FullCircle.Trading.SupplyPosition.statuses()
  defp panel_statuses(:sales), do: FullCircle.Trading.SalesPosition.statuses()
  defp panel_statuses(:trips), do: FullCircle.Trading.Trip.statuses()

  defp status_active?(status_q, status), do: status in filter_tokens(status_q)

  # A panel deviates when any of its filters differ from the mount defaults
  # (text typed, or status chips off the active set).
  defp filters_deviate?(filters, table), do: Map.get(filters, table) != empty_filters()[table]

  defp trip_goods_label(t) do
    t
    |> FullCircle.Trading.Trip.goods()
    |> Enum.map(& &1.name)
    |> Enum.join(", ")
  end

  defp trip_from_label(t), do: Trading.trip_parties_label(Trading.trip_from_names(t))
  defp trip_to_label(t), do: Trading.trip_parties_label(Trading.trip_to_names(t))
  defp trip_from_title(t), do: Enum.join(Trading.trip_from_names(t), ", ")
  defp trip_to_title(t), do: Enum.join(Trading.trip_to_names(t), ", ")

  defp nested_name(nil, _assoc), do: ""

  defp nested_name(parent, assoc) do
    case Map.get(parent, assoc) do
      nil -> ""
      %{name: name} -> name
      _ -> ""
    end
  end

  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :title, :string, default: nil
  attr :active?, :boolean, required: true

  defp trip_settle_chip(assigns) do
    ~H"""
    <button
      type="button"
      id={"desk-trip-settle-#{@key}"}
      phx-click="toggle_trip_settle_filter"
      phx-value-key={@key}
      title={@title}
      class={[
        "rounded-full px-2 py-0.5 border font-medium transition-colors",
        @active? && "bg-amber-200 border-amber-500 text-amber-950 ring-1 ring-amber-400",
        !@active? && "bg-white/80 border-violet-300 text-violet-900 hover:bg-violet-200/80"
      ]}
    >
      {@label}
    </button>
    """
  end

  # Status chip: toggles one status token in the panel's comma-OR status filter.
  attr :table, :string, required: true
  attr :status, :string, required: true
  attr :active?, :boolean, required: true
  attr :color, :string, required: true

  defp status_chip(assigns) do
    ~H"""
    <button
      type="button"
      id={"desk-#{@table}-status-chip-#{@status}"}
      phx-click="toggle_status_chip"
      phx-value-table={@table}
      phx-value-status={@status}
      data-active={to_string(@active?)}
      title={gettext("Show %{status} rows", status: @status)}
      class={[
        "rounded-full px-2 py-0 border font-medium transition-colors",
        chip_color_class(@color, @active?)
      ]}
    >
      {@status}
    </button>
    """
  end

  defp chip_color_class("amber", true),
    do: "bg-white border-amber-600 text-amber-950 ring-1 ring-amber-500 font-semibold"

  defp chip_color_class("amber", false),
    do: "bg-amber-100/60 border-amber-400 text-amber-800/70 hover:bg-amber-50"

  defp chip_color_class("emerald", true),
    do: "bg-white border-emerald-600 text-emerald-950 ring-1 ring-emerald-500 font-semibold"

  defp chip_color_class("emerald", false),
    do: "bg-emerald-100/60 border-emerald-400 text-emerald-800/70 hover:bg-emerald-50"

  defp chip_color_class("violet", true),
    do: "bg-white border-violet-600 text-violet-950 ring-1 ring-violet-500 font-semibold"

  defp chip_color_class("violet", false),
    do: "bg-violet-100/60 border-violet-400 text-violet-800/70 hover:bg-violet-50"

  attr :table, :string, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :class, :string, default: ""
  attr :align, :string, default: "left"
  attr :title, :string, default: nil

  defp filter_col(assigns) do
    tip = assigns.title || assigns.label
    assigns = assign(assigns, :tip, tip <> " · " <> gettext("comma = any of"))

    ~H"""
    <div class={[@class, "min-w-0 flex items-center"]}>
      <form
        id={"desk-filter-#{@table}-#{@field}"}
        phx-change="filter"
        phx-submit="filter"
        class="w-full m-0 relative"
      >
        <input type="hidden" name="table" value={@table} />
        <input type="hidden" name="field" value={@field} />
        <input
          type="text"
          name="value"
          value={@value}
          phx-debounce="200"
          class={[
            "w-full font-bold text-xs md:text-sm px-1 py-0.5 rounded border text-gray-900 placeholder:text-inherit placeholder:opacity-90 focus:outline-none focus:ring-1 focus:ring-black/30 focus:bg-white",
            if(@value != "",
              do: "bg-yellow-100 border-amber-500 ring-1 ring-amber-400 pr-5",
              else: "bg-white/80 border-black/20"
            ),
            @align == "right" && "text-right",
            @align == "center" && "text-center"
          ]}
          placeholder={@label}
          title={@tip}
          aria-label={@label}
          autocomplete="off"
        />
        <button
          :if={@value != ""}
          type="button"
          id={"desk-clear-#{@table}-#{@field}"}
          phx-click="clear_filter"
          phx-value-table={@table}
          phx-value-field={@field}
          class="absolute right-0.5 top-1/2 -translate-y-1/2 p-0 text-gray-500 hover:text-gray-900"
          title={gettext("Clear filter")}
          aria-label={gettext("Clear filter")}
        >
          <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
        </button>
      </form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :class, :string, default: ""
  attr :align, :string, default: "left"

  defp plain_col(assigns) do
    ~H"""
    <div class={[
      @class,
      "min-w-0 flex items-center leading-tight",
      @align == "right" && "text-right justify-end",
      @align == "center" && "text-center justify-center"
    ]}>
      {@label}
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- Fill viewport under app nav; tables scroll inside panels only --%>
    <div class="mx-auto w-11/12 h-[calc(100dvh-5.5rem)] flex flex-col overflow-hidden gap-1">
      <%!-- Top: supply + warehouse | open sales (hidden when trips maximized) --%>
      <div
        :if={@trips_panel != :maximized}
        class="flex-1 min-h-0 flex flex-col lg:flex-row gap-2"
      >
        <div class="lg:w-1/2 min-h-0 flex flex-col gap-2">
          <%!-- SUPPLY: header sticky inside scroll so cols share scrollbar width --%>
          <div
            id="desk_supply"
            class="flex-1 min-h-0 flex flex-col border-2 border-amber-500 rounded overflow-hidden bg-white dark:bg-zinc-900"
          >
            <div class="flex-1 min-h-0 overflow-y-scroll [scrollbar-gutter:stable]">
              <div class="sticky top-0 z-10 bg-amber-200 border-b-2 border-amber-500 text-amber-950">
                <div class="px-2 pt-0.5 flex flex-wrap items-center gap-1 text-[11px]">
                  <span class="font-bold">{gettext("Supply")}</span>
                  <span id="desk-supply-count" class="font-normal text-amber-800">
                    ({length(@supply_rows)}{if filters_deviate?(@filters, :supply),
                      do: "/#{length(@supply_all)}",
                      else: ""})
                  </span>
                  <span class="ml-1 font-semibold">{gettext("Status")}:</span>
                  <.status_chip
                    :for={s <- panel_statuses(:supply)}
                    table="supply"
                    status={s}
                    color="amber"
                    active?={status_active?(@filters.supply.status, s)}
                  />
                  <button
                    :if={filters_deviate?(@filters, :supply)}
                    type="button"
                    id="desk-supply-clear-filters"
                    phx-click="clear_panel_filters"
                    phx-value-table="supply"
                    class="ml-1 font-medium text-amber-800 underline hover:text-amber-950"
                  >
                    {gettext("Clear")}
                  </button>
                </div>
                <div class="font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm">
                  <div class="w-6 shrink-0 flex items-center justify-center">
                    <button
                      :if={@can_manage}
                      type="button"
                      id="desk-new-supply"
                      phx-click="open_modal"
                      phx-value-kind="supply"
                      phx-value-action="new"
                      class="p-0 rounded text-amber-900 hover:bg-amber-300/80 focus:outline-none focus:ring-1 focus:ring-amber-600"
                      title={gettext("New Supply")}
                      aria-label={gettext("New Supply")}
                    >
                      <.icon name="hero-plus-circle" class="w-5 h-5" />
                    </button>
                  </div>

                  <div class="flex flex-1 min-w-0 gap-1 items-center">
                    <.filter_col
                      class="w-3/24"
                      table="supply"
                      field="no"
                      label={gettext("Supply no")}
                      value={@filters.supply.no}
                    />
                    <.filter_col
                      class="w-5/24"
                      table="supply"
                      field="supplier"
                      label={gettext("Supplier")}
                      value={@filters.supply.supplier}
                    />
                    <.filter_col
                      class="w-4/24"
                      table="supply"
                      field="good"
                      label={gettext("Good")}
                      value={@filters.supply.good}
                    />
                    <.plain_col class="w-3/24" label={gettext("Status")} />
                    <.plain_col class="w-3/24" label={gettext("Remain")} align="right" />
                    <.plain_col class="w-2/24" label={gettext("Transit")} align="right" />
                    <.plain_col class="w-2/24" label={gettext("Soft")} align="right" />
                    <.plain_col class="w-2/24" label={gettext("Price")} align="right" />
                  </div>
                </div>
              </div>
              <div
                :for={row <- @supply_rows}
                id={"desk-supply-#{row.supply.id}"}
                class={[
                  "flex gap-1 border-b px-2 py-1 text-xs md:text-sm items-center hover:bg-gray-100 dark:hover:bg-zinc-800",
                  MapSet.member?(@selected_supply_ids, row.supply.id) &&
                    "bg-amber-50 dark:bg-amber-950/30",
                  row.supply.status == "closed" && "opacity-70"
                ]}
              >
                <div class="w-6 shrink-0 flex items-center justify-center">
                  <input
                    :if={@can_manage && supply_selectable?(row.supply.status)}
                    type="checkbox"
                    id={"sel-supply-#{row.supply.id}"}
                    phx-click="toggle_select"
                    phx-value-kind="supply"
                    phx-value-id={row.supply.id}
                    phx-value-good_id={row.supply.good_id}
                    checked={MapSet.member?(@selected_supply_ids, row.supply.id)}
                    class="cursor-pointer"
                  />
                </div>
                <div class="flex flex-1 min-w-0 gap-1 items-center">
                  <div
                    class={[
                      "w-3/24 min-w-0 truncate font-medium",
                      @can_manage && "text-blue-600 cursor-pointer hover:underline"
                    ]}
                    phx-click={if @can_manage, do: "open_modal"}
                    phx-value-kind="supply"
                    phx-value-action="edit"
                    phx-value-id={row.supply.id}
                    title={row.supply.title}
                  >
                    {row.supply.title}
                  </div>
                  <div
                    class="w-5/24 min-w-0 truncate"
                    title={row.supply.supplier && row.supply.supplier.name}
                  >
                    {row.supply.supplier && row.supply.supplier.name}
                  </div>
                  <div
                    class="w-4/24 min-w-0 truncate"
                    title={row.supply.good && row.supply.good.name}
                  >
                    {row.supply.good && row.supply.good.name}
                  </div>
                  <div class="w-3/24 min-w-0 truncate text-center">{row.supply.status}</div>
                  <div class={[
                    "w-3/24 min-w-0 text-right font-semibold",
                    remaining_class(row.remaining)
                  ]}>
                    {row.remaining}
                    <span
                      :if={row.supply.good && row.supply.good.unit}
                      class="font-normal text-gray-600 ml-0.5"
                    >
                      {row.supply.good.unit}
                    </span>
                  </div>
                  <div class="w-2/24 min-w-0 text-right">
                    <.transit_qty
                      qty={row.in_transit}
                      kind="supply_transit"
                      id={row.supply.id}
                    />
                  </div>
                  <div class="w-2/24 min-w-0 text-right">{row.soft_held}</div>
                  <div class="w-2/24 min-w-0 text-right">{row.supply.unit_price}</div>
                </div>
              </div>
              <p :if={@supply_rows == []} class="text-center p-2 text-gray-500 text-sm">
                {gettext("No open supply positions.")}
              </p>
            </div>
          </div>

          <%!-- WAREHOUSE --%>
          <div
            id="desk_warehouse"
            class="flex-1 min-h-0 flex flex-col border-2 border-sky-500 rounded overflow-hidden bg-white dark:bg-zinc-900"
          >
            <div class="flex-1 min-h-0 overflow-y-scroll [scrollbar-gutter:stable]">
              <div class="sticky top-0 z-10 bg-sky-200 border-b-2 border-sky-500 text-sky-950">
                <div class="px-2 pt-0.5 flex flex-wrap items-center gap-1 text-[11px]">
                  <span class="font-bold">{gettext("Warehouse")}</span>
                  <span id="desk-warehouse-count" class="font-normal text-sky-800">
                    ({length(@warehouse_rows)}{if filters_deviate?(@filters, :warehouse),
                      do: "/#{length(@warehouse_all)}",
                      else: ""})
                  </span>
                  <button
                    :if={filters_deviate?(@filters, :warehouse)}
                    type="button"
                    id="desk-warehouse-clear-filters"
                    phx-click="clear_panel_filters"
                    phx-value-table="warehouse"
                    class="ml-1 font-medium text-sky-800 underline hover:text-sky-950"
                  >
                    {gettext("Clear")}
                  </button>
                </div>
                <div class="font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm">
                  <.plain_col class="w-8 shrink-0 text-center" label={gettext("Out")} />
                  <.plain_col class="w-8 shrink-0 text-center" label={gettext("In")} />
                  <div class="flex flex-1 min-w-0 gap-1 items-center">
                    <.filter_col
                      class="w-6/24"
                      table="warehouse"
                      field="location"
                      label={gettext("Warehouse")}
                      value={@filters.warehouse.location}
                    />
                    <.filter_col
                      class="w-6/24"
                      table="warehouse"
                      field="good"
                      label={gettext("Good")}
                      value={@filters.warehouse.good}
                    />
                    <.plain_col class="w-4/24" label={gettext("On hand")} align="right" />
                    <.plain_col class="w-2/24" label={gettext("Inc")} align="right" />
                    <.plain_col class="w-2/24" label={gettext("Outg")} align="right" />
                  </div>
                </div>
              </div>
              <div
                :for={row <- @warehouse_rows}
                id={"desk-wh-#{row.location.id}-#{row.good && row.good.id || "none"}"}
                class={[
                  "flex gap-1 border-b px-2 py-1 text-xs md:text-sm items-center hover:bg-gray-100 dark:hover:bg-zinc-800",
                  warehouse_row_selected?(
                    @selected_warehouse_load_keys,
                    @selected_warehouse_drop_keys,
                    row
                  ) && "bg-sky-50 dark:bg-sky-950/30"
                ]}
              >
                <% wh_key = warehouse_key(row.location.id, (row.good && row.good.id) || "any") %>
                <%!-- Out = load from warehouse; In = drop into warehouse (stock-in) --%>
                <div class="w-8 shrink-0 flex items-center justify-center" title={gettext("Load out")}>
                  <input
                    :if={
                      @can_manage && row.good && row.on_hand &&
                        Decimal.compare(row.on_hand, Decimal.new(0)) == :gt
                    }
                    type="checkbox"
                    id={"sel-wh-out-#{row.location.id}-#{row.good.id}"}
                    phx-click="toggle_select"
                    phx-value-kind="warehouse_load"
                    phx-value-id={wh_key}
                    phx-value-good_id={row.good.id}
                    checked={MapSet.member?(@selected_warehouse_load_keys, wh_key)}
                    disabled={MapSet.member?(@selected_warehouse_drop_keys, wh_key)}
                    class={[
                      "cursor-pointer",
                      MapSet.member?(@selected_warehouse_drop_keys, wh_key) &&
                        "opacity-40 cursor-not-allowed"
                    ]}
                  />
                </div>
                <div class="w-8 shrink-0 flex items-center justify-center" title={gettext("Drop in")}>
                  <input
                    :if={@can_manage}
                    type="checkbox"
                    id={"sel-wh-in-#{row.location.id}-#{(row.good && row.good.id) || "any"}"}
                    phx-click="toggle_select"
                    phx-value-kind="warehouse_drop"
                    phx-value-id={wh_key}
                    phx-value-good_id={(row.good && row.good.id) || "any"}
                    checked={MapSet.member?(@selected_warehouse_drop_keys, wh_key)}
                    disabled={MapSet.member?(@selected_warehouse_load_keys, wh_key)}
                    class={[
                      "cursor-pointer",
                      MapSet.member?(@selected_warehouse_load_keys, wh_key) &&
                        "opacity-40 cursor-not-allowed"
                    ]}
                  />
                </div>
                <div class="flex flex-1 min-w-0 gap-1 items-center">
                  <button
                    type="button"
                    class="w-6/24 min-w-0 truncate text-left text-blue-600 hover:underline bg-transparent border-0 p-0 cursor-pointer"
                    title={gettext("Recent load/drop history")}
                    phx-click="show_warehouse_history"
                    phx-value-location_id={row.location.id}
                    phx-value-good_id={(row.good && row.good.id) || ""}
                    phx-value-location_name={row.location.name}
                    phx-value-good_name={(row.good && row.good.name) || ""}
                    phx-value-unit={(row.good && row.good.unit) || ""}
                    phx-value-on_hand={to_string(row.on_hand || 0)}
                  >
                    {row.location.name}
                  </button>
                  <div class="w-6/24 min-w-0 truncate" title={row.good && row.good.name}>
                    {(row.good && row.good.name) || "—"}
                  </div>
                  <button
                    type="button"
                    class={[
                      "w-4/24 min-w-0 text-right font-semibold bg-transparent border-0 p-0 cursor-pointer hover:underline",
                      on_hand_class(row.on_hand)
                    ]}
                    title={gettext("Recent load/drop history")}
                    phx-click="show_warehouse_history"
                    phx-value-location_id={row.location.id}
                    phx-value-good_id={(row.good && row.good.id) || ""}
                    phx-value-location_name={row.location.name}
                    phx-value-good_name={(row.good && row.good.name) || ""}
                    phx-value-unit={(row.good && row.good.unit) || ""}
                    phx-value-on_hand={to_string(row.on_hand || 0)}
                  >
                    {row.on_hand}
                    <span
                      :if={row.good && row.good.unit}
                      class="font-normal text-gray-600 ml-0.5"
                    >
                      {row.good.unit}
                    </span>
                  </button>
                  <div class="w-2/24 min-w-0 text-right">
                    <.transit_qty
                      :if={row.good}
                      qty={row.incoming || 0}
                      kind="warehouse_incoming"
                      location_id={row.location.id}
                      good_id={row.good.id}
                    />
                    <span :if={!row.good} class="text-gray-400">{row.incoming || 0}</span>
                  </div>
                  <div class="w-2/24 min-w-0 text-right">
                    <.transit_qty
                      :if={row.good}
                      qty={row.outgoing || 0}
                      kind="warehouse_outgoing"
                      location_id={row.location.id}
                      good_id={row.good.id}
                    />
                    <span :if={!row.good} class="text-gray-400">{row.outgoing || 0}</span>
                  </div>
                </div>
              </div>
              <p :if={@warehouse_rows == []} class="text-center p-2 text-gray-500 text-sm">
                {gettext("No own-warehouse locations yet.")}
              </p>
            </div>
          </div>
        </div>

        <%!-- OPEN SALES --%>
        <div
          id="desk_sales"
          class="lg:w-1/2 min-h-0 flex flex-col border-2 border-emerald-500 rounded overflow-hidden bg-white dark:bg-zinc-900"
        >
          <div class="flex-1 min-h-0 overflow-y-scroll [scrollbar-gutter:stable]">
            <div class="sticky top-0 z-10 bg-emerald-200 border-b-2 border-emerald-500 text-emerald-950">
              <div class="px-2 pt-0.5 flex flex-wrap items-center gap-1 text-[11px]">
                <span class="font-bold">{gettext("Sales")}</span>
                <span id="desk-sales-count" class="font-normal text-emerald-800">
                  ({length(@sales_rows)}{if filters_deviate?(@filters, :sales),
                    do: "/#{length(@sales_all)}",
                    else: ""})
                </span>
                <span class="ml-1 font-semibold">{gettext("Status")}:</span>
                <.status_chip
                  :for={s <- panel_statuses(:sales)}
                  table="sales"
                  status={s}
                  color="emerald"
                  active?={status_active?(@filters.sales.status, s)}
                />
                <button
                  :if={filters_deviate?(@filters, :sales)}
                  type="button"
                  id="desk-sales-clear-filters"
                  phx-click="clear_panel_filters"
                  phx-value-table="sales"
                  class="ml-1 font-medium text-emerald-800 underline hover:text-emerald-950"
                >
                  {gettext("Clear")}
                </button>
              </div>
              <div class="font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm">
                <div class="w-6 shrink-0 flex items-center justify-center">
                  <button
                    :if={@can_manage}
                    type="button"
                    id="desk-new-sales"
                    phx-click="open_modal"
                    phx-value-kind="sales"
                    phx-value-action="new"
                    class="p-0 rounded text-emerald-900 hover:bg-emerald-300/80 focus:outline-none focus:ring-1 focus:ring-emerald-600"
                    title={gettext("New Sales")}
                    aria-label={gettext("New Sales")}
                  >
                    <.icon name="hero-plus-circle" class="w-5 h-5" />
                  </button>
                </div>
                <div class="flex flex-1 min-w-0 gap-1 items-center">
                  <.filter_col
                    class="w-3/24"
                    table="sales"
                    field="no"
                    label={gettext("Sales no")}
                    value={@filters.sales.no}
                  />
                  <.filter_col
                    class="w-6/24"
                    table="sales"
                    field="customer"
                    label={gettext("Customer")}
                    value={@filters.sales.customer}
                  />
                  <.filter_col
                    class="w-5/24"
                    table="sales"
                    field="good"
                    label={gettext("Good")}
                    value={@filters.sales.good}
                  />
                  <.plain_col class="w-2/24" label={gettext("Undeliv")} align="right" />
                  <.plain_col class="w-2/24" label={gettext("Transit")} align="right" />
                  <.plain_col class="w-3/24" label={gettext("Status")} />
                  <.filter_col
                    class="w-3/24"
                    table="sales"
                    field="need_by"
                    label={gettext("Need by")}
                    value={@filters.sales.need_by}
                  />
                </div>
              </div>
            </div>
            <div
              :for={row <- @sales_rows}
              id={"desk-sales-#{row.sales.id}"}
              class={[
                "flex gap-1 border-b px-2 py-1 text-xs md:text-sm items-center hover:bg-gray-100 dark:hover:bg-zinc-800",
                MapSet.member?(@selected_sales_ids, row.sales.id) &&
                  "bg-emerald-50 dark:bg-emerald-950/30",
                row.sales.status in ["fulfilled", "cancelled"] && "opacity-70"
              ]}
            >
              <div class="w-6 shrink-0 flex items-center justify-center">
                <input
                  :if={@can_manage && sales_selectable?(row.sales.status)}
                  type="checkbox"
                  id={"sel-sales-#{row.sales.id}"}
                  phx-click="toggle_select"
                  phx-value-kind="sales"
                  phx-value-id={row.sales.id}
                  phx-value-good_id={row.sales.good_id}
                  checked={MapSet.member?(@selected_sales_ids, row.sales.id)}
                  class="cursor-pointer"
                />
              </div>
              <div class="flex flex-1 min-w-0 gap-1 items-center">
                <div
                  class={[
                    "w-3/24 min-w-0 truncate font-medium",
                    @can_manage && "text-blue-600 cursor-pointer hover:underline"
                  ]}
                  phx-click={if @can_manage, do: "open_modal"}
                  phx-value-kind="sales"
                  phx-value-action="edit"
                  phx-value-id={row.sales.id}
                  title={row.sales.title}
                >
                  {row.sales.title}
                </div>
                <div
                  class="w-6/24 min-w-0 truncate"
                  title={row.sales.customer && row.sales.customer.name}
                >
                  {row.sales.customer && row.sales.customer.name}
                </div>
                <div
                  class="w-5/24 min-w-0 truncate"
                  title={row.sales.good && row.sales.good.name}
                >
                  {row.sales.good && row.sales.good.name}
                </div>
                <div class={[
                  "w-2/24 min-w-0 text-right font-semibold",
                  undelivered_class(row.undelivered)
                ]}>
                  {row.undelivered}
                  <span
                    :if={row.sales.good && row.sales.good.unit}
                    class="font-normal text-gray-600 ml-0.5"
                  >
                    {row.sales.good.unit}
                  </span>
                </div>
                <div class="w-2/24 min-w-0 text-right">
                  <.transit_qty
                    qty={row.in_transit}
                    kind="sales_transit"
                    id={row.sales.id}
                  />
                </div>
                <div class="w-3/24 min-w-0 truncate text-center">{row.sales.status}</div>
                <div class="w-3/24 min-w-0 truncate">{row.sales.available_from || "—"}</div>
              </div>
            </div>
            <p :if={@sales_rows == []} class="text-center p-2 text-gray-500 text-sm">
              {gettext("No open sales commitments.")}
            </p>
          </div>
        </div>
      </div>

      <%!-- Selection tray --%>
      <div
        :if={@selection_active}
        id="desk-selection-tray"
        class="shrink-0 flex flex-wrap items-center gap-2 px-2 py-1.5 rounded border border-violet-400 bg-violet-50 dark:bg-violet-950/40 text-xs md:text-sm"
      >
        <span class="font-semibold">
          {gettext("Goods")}: {@selection_summary.goods || "—"}
        </span>
        <span class="text-gray-600">
          {@selection_summary.sales_n} {gettext("sales")} · {@selection_summary.supply_n} {gettext(
            "supply"
          )} · {@selection_summary.warehouse_load_n} {gettext("out")} · {@selection_summary.warehouse_drop_n} {gettext(
            "in"
          )}
        </span>
        <span
          :if={@selection_summary.mode == :delivery}
          class={[
            "font-medium",
            @selection_summary.short && "text-amber-700"
          ]}
        >
          {gettext("Demand")} {@selection_summary.demand} / {gettext("Source")} {@selection_summary.source}
        </span>
        <span :if={@selection_summary.mode == :stock_in} class="font-medium text-sky-800">
          {gettext("Stock-in")} · {gettext("Source")} {@selection_summary.source}
        </span>
        <span
          :if={@selection_summary.mode == :mixed}
          class={[
            "font-medium",
            @selection_summary.short && "text-amber-700"
          ]}
        >
          {gettext("Mixed")} · {gettext("Sales")} {@selection_summary.demand} + {gettext("WH in")} {@selection_summary.warehouse_drop_n} · {gettext(
            "Source"
          )} {@selection_summary.source}
        </span>
        <button
          :if={@can_manage}
          type="button"
          id="desk-create-trip-selection"
          phx-click="create_trip_from_selection"
          disabled={!@selection_ready}
          class={["blue button text-xs py-0.5", !@selection_ready && "opacity-50 cursor-not-allowed"]}
        >
          {gettext("Create Trip")}
        </button>
        <button
          type="button"
          id="desk-clear-selection"
          phx-click="clear_selection"
          class="teal button text-xs py-0.5"
        >
          {gettext("Clear")}
        </button>
      </div>

      <%!-- TRIPS: shown (~28%), maximized (fills desk), or hidden (header only) --%>
      <div
        id="desk_trips"
        data-trips-panel={@trips_panel}
        class={[
          "flex flex-col border-2 border-violet-500 rounded overflow-hidden bg-white dark:bg-zinc-900",
          @trips_panel == :hidden && "shrink-0",
          @trips_panel == :shown && "shrink-0 h-[28%] min-h-[8rem]",
          @trips_panel == :maximized && "flex-1 min-h-0"
        ]}
      >
        <div class="bg-violet-200 border-b border-violet-500 font-bold px-2 py-1 flex items-center gap-1 text-xs md:text-sm text-violet-950">
          <button
            :if={@can_manage}
            type="button"
            id="desk-new-trip"
            phx-click="open_modal"
            phx-value-kind="trip"
            phx-value-action="new"
            class="shrink-0 p-0.5 rounded text-violet-900 hover:bg-violet-300/80 focus:outline-none focus:ring-1 focus:ring-violet-600"
            title={gettext("New Trip")}
            aria-label={gettext("New Trip")}
          >
            <.icon name="hero-plus-circle" class="w-5 h-5" />
          </button>

          <div class="flex-1 min-w-0 flex items-center justify-between gap-2 px-1 py-0.5">
            <span>
              {gettext("Trips")}
              <span id="desk-trips-count" class="font-normal text-violet-800">
                ({length(@trips)}{if MapSet.size(@trip_settle_filters) > 0 or
                                       filters_deviate?(@filters, :trips),
                                     do: "/#{length(@trips_all)}",
                                     else: ""})
              </span>
            </span>
            <div
              id="desk-trip-settle-filters"
              class="px-2 py-1 flex flex-wrap items-center gap-1 text-[11px]"
            >
              <span class="font-semibold text-violet-900 mr-0.5">{gettext("Status")}:</span>
              <.status_chip
                :for={s <- panel_statuses(:trips)}
                table="trips"
                status={s}
                color="violet"
                active?={status_active?(@filters.trips.status, s)}
              />
              <button
                :if={filters_deviate?(@filters, :trips) or MapSet.size(@trip_settle_filters) > 0}
                type="button"
                id="desk-trips-clear-filters"
                phx-click="clear_panel_filters"
                phx-value-table="trips"
                class="mr-1 font-medium text-violet-800 underline hover:text-violet-950"
              >
                {gettext("Clear")}
              </button>
              <span class="font-semibold text-violet-900 mr-0.5 ml-2">{gettext("Bill")}:</span>
              <.trip_settle_chip
                key="any"
                label={gettext("Needs bill")}
                title={
                  gettext("Completed trips with any customer, supplier, or transport still unbilled")
                }
                active?={MapSet.member?(@trip_settle_filters, "any")}
              />
              <.trip_settle_chip
                key="customer"
                label={gettext("Cust unbilled")}
                title={gettext("Customer invoice open or partial")}
                active?={MapSet.member?(@trip_settle_filters, "customer")}
              />
              <.trip_settle_chip
                key="supplier"
                label={gettext("Supp unbilled")}
                title={gettext("Supplier bill open or partial")}
                active?={MapSet.member?(@trip_settle_filters, "supplier")}
              />
              <.trip_settle_chip
                key="transport"
                label={gettext("Haul unbilled")}
                title={gettext("Transport agent bill open or partial")}
                active?={MapSet.member?(@trip_settle_filters, "transport")}
              />
              <button
                :if={MapSet.size(@trip_settle_filters) > 0}
                type="button"
                id="desk-trip-settle-clear"
                phx-click="clear_trip_settle_filters"
                class="ml-1 text-violet-800 underline hover:text-violet-950"
              >
                {gettext("Clear")}
              </button>
              <.link
                navigate={~p"/companies/#{@current_company.id}/trading/settlement"}
                class="ml-5 border-1 rounded-xl px-2 py-0.5 bg-blue-200 text-blue-700 hover:bg-blue-300"
                id="desk-settlement-link"
              >
                {gettext("Invoice / Bill / Transport Bill")}
              </.link>
            </div>
            <span class="shrink-0 flex items-center gap-1 font-normal">
              <button
                :if={@trips_panel == :hidden}
                type="button"
                id="desk-trips-show"
                phx-click="set_trips_panel"
                phx-value-mode="shown"
                class="px-1.5 py-0.5 rounded hover:bg-violet-300 focus:outline-none focus:ring-1 focus:ring-violet-600"
              >
                {gettext("Show")}
              </button>
              <button
                :if={@trips_panel != :hidden}
                type="button"
                id="desk-trips-hide"
                phx-click="set_trips_panel"
                phx-value-mode="hidden"
                class="px-1.5 py-0.5 rounded hover:bg-violet-300 focus:outline-none focus:ring-1 focus:ring-violet-600"
              >
                {gettext("Hide")}
              </button>
              <button
                :if={@trips_panel != :maximized}
                type="button"
                id="desk-trips-maximize"
                phx-click="set_trips_panel"
                phx-value-mode="maximized"
                class="px-1.5 py-0.5 rounded hover:bg-violet-300 focus:outline-none focus:ring-1 focus:ring-violet-600"
              >
                {gettext("Maximize")}
              </button>
              <button
                :if={@trips_panel == :maximized}
                type="button"
                id="desk-trips-restore"
                phx-click="set_trips_panel"
                phx-value-mode="shown"
                class="px-1.5 py-0.5 rounded hover:bg-violet-300 focus:outline-none focus:ring-1 focus:ring-violet-600"
              >
                {gettext("Restore")}
              </button>
            </span>
          </div>
        </div>
        <div
          :if={@trips_panel != :hidden}
          class="flex-1 min-h-0 overflow-y-scroll [scrollbar-gutter:stable]"
        >
          <div class="sticky top-0 z-10 bg-violet-100 border-b border-violet-400">
            <div class="font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm text-violet-950">
              <div class="flex flex-1 min-w-0 gap-1 items-center">
                <.filter_col
                  class="w-2/24"
                  table="trips"
                  field="date"
                  label={gettext("Date")}
                  value={@filters.trips.date}
                />
                <.filter_col
                  class="w-2/24"
                  table="trips"
                  field="ref"
                  label={gettext("Trip No")}
                  value={@filters.trips.ref}
                />
                <.filter_col
                  class="w-2/24"
                  table="trips"
                  field="vehicle"
                  label={gettext("Vehicle")}
                  value={@filters.trips.vehicle}
                />
                <.filter_col
                  class="w-5/24"
                  table="trips"
                  field="from"
                  label={gettext("From")}
                  value={@filters.trips.from}
                  title={gettext("Suppliers / load locations")}
                />
                <.filter_col
                  class="w-5/24"
                  table="trips"
                  field="to"
                  label={gettext("To")}
                  value={@filters.trips.to}
                  title={gettext("Customers / drop locations")}
                />
                <.filter_col
                  class="w-3/24"
                  table="trips"
                  field="good"
                  label={gettext("Good")}
                  value={@filters.trips.good}
                />
                <.filter_col
                  class="w-3/24"
                  table="trips"
                  field="agent"
                  label={gettext("Agent")}
                  value={@filters.trips.agent}
                />
                <.plain_col class="w-2/24" label={gettext("Status")} />
              </div>
            </div>
          </div>
          <.desk_trip_row
            :for={t <- @trips}
            trip={t}
            settle={Trading.trip_settlement_badges(t)}
            detail_open?={MapSet.member?(@trip_detail_ids, t.id)}
            can_manage={@can_manage}
            company={@current_company}
          />
          <p :if={@trips == []} class="text-center p-2 text-gray-500 text-sm">
            {if MapSet.size(@trip_settle_filters) > 0 or filters_deviate?(@filters, :trips) do
              gettext("No trips match the current filters.")
            else
              gettext("No trips yet.")
            end}
          </p>
        </div>
      </div>

      <%!-- Own-warehouse recent load/drop history --%>
      <.modal
        :if={@warehouse_history}
        id="desk-warehouse-history-modal"
        show
        max_w="max-w-4xl"
        on_cancel={JS.push("close_warehouse_history")}
      >
        <div id="desk-warehouse-history">
          <p class="text-xl font-medium text-center mb-1">
            {@warehouse_history.location_name}
            <span :if={@warehouse_history.good_name} class="text-zinc-600">
              · {@warehouse_history.good_name}
            </span>
          </p>
          <p class="text-center text-sm mb-3">
            <span class="text-zinc-500">{gettext("Remaining")}</span>
            <span class={[
              "font-semibold tabular-nums ml-1",
              on_hand_class(@warehouse_history.remaining)
            ]}>
              {@warehouse_history.remaining}
            </span>
            <span
              :if={@warehouse_history.unit && @warehouse_history.unit != ""}
              class="text-zinc-500 text-xs ml-0.5"
            >
              {@warehouse_history.unit}
            </span>
            <span class="text-zinc-400 text-xs ml-2">
              ({gettext("last %{count}", count: length(@warehouse_history.movements))})
            </span>
          </p>

          <div class="bg-sky-200 border-y-2 border-sky-500 font-bold p-2 flex gap-1 text-sm text-sky-950">
            <div class="w-2/24">{gettext("Dir")}</div>
            <div class="w-3/24">{gettext("Date")}</div>
            <div class="w-3/24">{gettext("Trip")}</div>
            <div class="w-3/24">{gettext("Status")}</div>
            <div class="w-3/24">{gettext("Vehicle")}</div>
            <div class="w-4/24 text-right">{gettext("Qty")}</div>
            <div class="w-6/24">{gettext("Note")}</div>
          </div>
          <button
            :for={m <- @warehouse_history.movements}
            type="button"
            id={"wh-move-#{m.kind}-#{m.line_id}"}
            phx-click="open_warehouse_history_trip"
            phx-value-id={m.trip_id}
            class={[
              "w-full flex gap-1 border-b p-2 text-sm text-left hover:bg-sky-50 dark:hover:bg-sky-950/40 cursor-pointer",
              m.status == "cancelled" && "line-through opacity-70"
            ]}
          >
            <div class={[
              "w-2/24 font-semibold",
              m.kind == "in" && "text-teal-700",
              m.kind == "out" && "text-violet-700"
            ]}>
              {if m.kind == "in", do: gettext("In"), else: gettext("Out")}
            </div>
            <div class="w-3/24">{m.date}</div>
            <div class="w-3/24 min-w-0 truncate text-blue-600 font-medium" title={m.reference_no}>
              {m.reference_no || "—"}
            </div>
            <div class="w-3/24">{m.status}</div>
            <div class="w-3/24 min-w-0 truncate">{m.vehicle_number || "—"}</div>
            <div class={[
              "w-4/24 text-right font-semibold tabular-nums",
              m.kind == "in" && "text-teal-800",
              m.kind == "out" && "text-violet-800"
            ]}>
              {m.qty}
              <span :if={m.unit} class="font-normal text-xs text-zinc-500 ml-0.5">{m.unit}</span>
            </div>
            <div class="w-6/24 min-w-0 truncate text-zinc-500" title={m.notes}>{m.notes || ""}</div>
          </button>
          <p :if={@warehouse_history.movements == []} class="text-center p-4 text-gray-500 text-sm">
            {gettext("No recent loads or drops for this warehouse.")}
          </p>
          <div class="text-center mt-3">
            <button type="button" phx-click="close_warehouse_history" class="teal button">
              {gettext("Close")}
            </button>
          </div>
        </div>
      </.modal>

      <%!-- In-transit trip list (from Transit / Inc / Outg click) --%>
      <.modal
        :if={@transit_list}
        id="desk-transit-list-modal"
        show
        max_w="max-w-4xl"
        on_cancel={JS.push("close_transit_list")}
      >
        <div id="desk-transit-list">
          <p class="text-xl font-medium text-center mb-2">{@transit_list.title}</p>
          <div class="bg-violet-200 border-y-2 border-violet-500 font-bold p-2 flex gap-1 text-sm">
            <div class="w-3/24">{gettext("Date")}</div>
            <div class="w-3/24">{gettext("Trip No")}</div>
            <div class="w-3/24">{gettext("Vehicle")}</div>
            <div class="w-9/24">{gettext("Agent")}</div>
            <div class="w-3/24">{gettext("Status")}</div>
            <div class="w-3/24 text-right">{gettext("Qty")}</div>
          </div>
          <button
            :for={t <- @transit_list.trips}
            type="button"
            id={"transit-trip-#{t.id}"}
            phx-click="open_transit_trip"
            phx-value-id={t.id}
            class="w-full flex gap-1 border-b p-2 text-sm text-left hover:bg-violet-50 dark:hover:bg-violet-950/40 cursor-pointer"
          >
            <div class="w-3/24 text-blue-600">{t.date}</div>
            <div class="w-3/24 min-w-0 truncate" title={t.reference_no}>{t.reference_no || "—"}</div>
            <div class="w-3/24 min-w-0 truncate">{t.vehicle_number || "—"}</div>
            <div class="w-9/24 min-w-0 truncate" title={t.agent_name}>{t.agent_name || "—"}</div>
            <div class="w-3/24">{t.status}</div>
            <div class="w-3/24 text-right font-semibold text-violet-700">{t.qty}</div>
          </button>
          <p :if={@transit_list.trips == []} class="text-center p-4 text-gray-500 text-sm">
            {gettext("No open trips for this quantity.")}
          </p>
          <div class="text-center mt-3">
            <button type="button" phx-click="close_transit_list" class="teal button">
              {gettext("Close")}
            </button>
          </div>
        </div>
      </.modal>

      <.modal
        :if={@modal}
        id="desk-modal"
        show
        max_w={if @modal.kind == :trip, do: "max-w-7xl", else: "max-w-5xl"}
        on_cancel={JS.push("close_modal")}
      >
        <.live_component
          :if={@modal.kind == :supply}
          module={FullCircleWeb.TradingDeskLive.SupplyFormComponent}
          id="desk-supply-form-lc"
          company={@current_company}
          user={@current_user}
          action={@modal.action}
          supply_id={@modal.id}
        />
        <.live_component
          :if={@modal.kind == :sales}
          module={FullCircleWeb.TradingDeskLive.SalesFormComponent}
          id="desk-sales-form-lc"
          company={@current_company}
          user={@current_user}
          action={@modal.action}
          sales_id={@modal.id}
        />
        <.live_component
          :if={@modal.kind == :trip}
          module={FullCircleWeb.TradingDeskLive.TripFormComponent}
          id={"desk-trip-form-lc-#{@modal[:form_key] || @modal[:id] || "new"}"}
          company={@current_company}
          user={@current_user}
          action={@modal.action}
          trip_id={@modal.id}
          prefill={@modal[:prefill]}
        />
      </.modal>
    </div>
    """
  end

  defp remaining_class(remaining) do
    if Decimal.compare(remaining, 0) == :lt do
      "text-red-600"
    else
      ""
    end
  end

  defp on_hand_class(nil), do: "text-gray-500"

  defp on_hand_class(qty) do
    case Decimal.compare(qty, Decimal.new(0)) do
      :lt -> "text-red-600"
      :eq -> "text-gray-500"
      :gt -> ""
    end
  end

  defp undelivered_class(nil), do: ""

  defp undelivered_class(qty) do
    if Decimal.compare(qty, Decimal.new(0)) == :gt do
      "text-amber-700"
    else
      ""
    end
  end

  defp transit_class(nil), do: "text-gray-400"

  defp transit_class(qty) do
    case Decimal.compare(qty_dec(qty), Decimal.new(0)) do
      :gt -> "text-violet-700 font-medium underline decoration-dotted cursor-pointer"
      _ -> "text-gray-400"
    end
  end

  defp qty_dec(%Decimal{} = d), do: d
  defp qty_dec(n) when is_integer(n), do: Decimal.new(n)
  defp qty_dec(n) when is_float(n), do: Decimal.from_float(n)
  defp qty_dec(nil), do: Decimal.new(0)
  defp qty_dec(other), do: Decimal.new("#{other}")

  attr :qty, :any, required: true
  attr :kind, :string, required: true
  attr :id, :string, default: nil
  attr :location_id, :string, default: nil
  attr :good_id, :string, default: nil

  defp transit_qty(assigns) do
    clickable? = Decimal.compare(qty_dec(assigns.qty), Decimal.new(0)) == :gt
    assigns = assign(assigns, :clickable?, clickable?)

    ~H"""
    <button
      :if={@clickable?}
      type="button"
      phx-click="show_transit_trips"
      phx-value-kind={@kind}
      phx-value-id={@id}
      phx-value-location_id={@location_id}
      phx-value-good_id={@good_id}
      class={["bg-transparent border-0 p-0 text-right w-full", transit_class(@qty)]}
      title={gettext("Show open trips")}
    >
      {@qty}
    </button>
    <span :if={!@clickable?} class={transit_class(@qty)}>{@qty}</span>
    """
  end

  # --- Trip row: one trip + Option C badges + optional expand ---

  attr :trip, :any, required: true
  attr :settle, :map, required: true
  attr :detail_open?, :boolean, required: true
  attr :can_manage, :boolean, required: true
  attr :company, :any, required: true

  defp desk_trip_row(assigns) do
    ~H"""
    <div
      id={"desk-trip-#{@trip.id}"}
      class="border-b px-2 py-1 text-xs md:text-sm hover:bg-gray-100 dark:hover:bg-zinc-800"
    >
      <div class="flex gap-1 items-center">
        <button
          type="button"
          id={"desk-trip-expand-#{@trip.id}"}
          phx-click="toggle_trip_detail"
          phx-value-id={@trip.id}
          class="w-5 shrink-0 text-zinc-500 hover:text-zinc-800"
          title={if(@detail_open?, do: gettext("Hide lines"), else: gettext("Show loads/drops"))}
        >
          <span :if={@detail_open?} class="hero-chevron-down w-4 h-4 inline-block"></span>
          <span :if={!@detail_open?} class="hero-chevron-right w-4 h-4 inline-block"></span>
        </button>
        <div class="flex flex-1 min-w-0 gap-1 items-center">
          <div class="w-2/24 min-w-0 truncate">{@trip.date}</div>
          <div
            class={[
              "w-2/24 min-w-0 truncate font-medium",
              @can_manage && "text-blue-600 cursor-pointer hover:underline"
            ]}
            phx-click={if @can_manage, do: "open_modal"}
            phx-value-kind="trip"
            phx-value-action="edit"
            phx-value-id={@trip.id}
            title={@trip.reference_no}
          >
            {@trip.reference_no || "—"}
          </div>
          <div class="w-2/24 min-w-0 truncate" title={@trip.vehicle_number}>
            {@trip.vehicle_number || "—"}
          </div>
          <div class="w-5/24 min-w-0 truncate" title={trip_from_title(@trip)}>
            {trip_from_label(@trip) |> then(fn s -> if s == "", do: "—", else: s end)}
          </div>
          <div class="w-5/24 min-w-0 truncate" title={trip_to_title(@trip)}>
            {trip_to_label(@trip) |> then(fn s -> if s == "", do: "—", else: s end)}
          </div>
          <div class="w-3/24 min-w-0 truncate" title={trip_goods_label(@trip)}>
            {trip_goods_label(@trip) |> then(fn s -> if s == "", do: "—", else: s end)}
          </div>
          <div
            class="w-3/24 min-w-0 truncate"
            title={@trip.transport_agent && @trip.transport_agent.name}
          >
            {(@trip.transport_agent && @trip.transport_agent.name) || "—"}
          </div>
          <div class="w-2/24 min-w-0 truncate text-center">{@trip.status}</div>
        </div>
      </div>
      <div
        :if={@settle.show?}
        id={"desk-trip-settle-#{@trip.id}"}
        class="pl-5 mt-0.5 flex flex-wrap gap-1 items-center"
      >
        <.settlement_chip
          stream={:customer}
          state={@settle.customer}
          done={@settle.customer_done}
          exempt={@settle.customer_exempt}
          total={@settle.customer_total}
        />
        <.settlement_chip
          stream={:supplier}
          state={@settle.supplier}
          done={@settle.supplier_done}
          exempt={@settle.supplier_exempt}
          total={@settle.supplier_total}
        />
        <.settlement_chip
          stream={:transport}
          state={@settle.transport}
          done={@settle.transport_done}
          exempt={@settle.transport_exempt}
          total={@settle.transport_total}
        />
        <.link
          id={"desk-trip-settlement-#{@trip.id}"}
          navigate={~p"/companies/#{@company.id}/trading/settlement?#{%{trip_id: @trip.id}}"}
          class="text-[10px] text-blue-600 hover:underline ml-1"
        >
          {gettext("Settlement")}
        </.link>
      </div>
      <div
        :if={@detail_open?}
        id={"desk-trip-lines-#{@trip.id}"}
        class="pl-5 mt-1 mb-0.5 text-[11px] space-y-0.5 border-l-2 border-violet-200 ml-1"
      >
        <div class="font-semibold text-zinc-600">{gettext("Loads")}</div>
        <div
          :for={l <- List.wrap(@trip.loads)}
          class="flex flex-wrap gap-x-2 text-zinc-700 dark:text-zinc-300"
        >
          <span class="text-zinc-400">L{l.seq || "·"}</span>
          <span>{(l.location && l.location.name) || "—"}</span>
          <span class="text-zinc-500">{(l.good && l.good.name) || ""}</span>
          <span class="tabular-nums">
            {l.actual || l.planned || "—"}
            <span :if={l.good && l.good.unit} class="text-zinc-500 font-normal">
              {l.good.unit}
            </span>
          </span>

          <span :if={l.supply_position} class="font-mono text-zinc-500">
            {l.supply_position.title}
          </span>
          <span :if={l.supply_position_id} class={["rounded px-1", load_bill_class(l)]}>
            {load_bill_label(l)}
          </span>
        </div>
        <div :if={List.wrap(@trip.loads) == []} class="text-zinc-400">—</div>
        <div class="font-semibold text-zinc-600 pt-0.5">{gettext("Drops")}</div>
        <div
          :for={d <- List.wrap(@trip.drops)}
          class="flex flex-wrap gap-x-2 text-zinc-700 dark:text-zinc-300"
        >
          <span class="text-zinc-400">D{d.seq || "·"}</span>
          <span>{(d.location && d.location.name) || "—"}</span>
          <span class="text-zinc-500">{(d.good && d.good.name) || ""}</span>
          <span class="tabular-nums">
            {d.actual || d.planned || "—"}
            <span :if={d.good && d.good.unit} class="text-zinc-500 font-normal">
              {d.good.unit}
            </span>
          </span>

          <span :if={d.sales_position} class="font-mono text-zinc-500">
            {d.sales_position.title}
          </span>
          <span :if={d.sales_position_id} class={["rounded px-1", drop_invoice_class(d)]}>
            {drop_invoice_label(d)}
          </span>
          <span
            :if={@trip.transport_mode == "agent"}
            class={["rounded px-1", drop_haul_class(d)]}
          >
            {drop_haul_label(d)}
          </span>
        </div>
        <div :if={List.wrap(@trip.drops) == []} class="text-zinc-400">—</div>
      </div>
    </div>
    """
  end

  # --- Settlement badges (Option C) ---

  attr :stream, :atom, required: true
  attr :state, :atom, required: true
  attr :done, :integer, default: 0
  attr :exempt, :integer, default: 0
  attr :total, :integer, default: 0

  defp settlement_chip(assigns) do
    label = settlement_chip_label(assigns.stream, assigns.state)
    title = settlement_chip_title(assigns.stream, assigns.state, assigns.done, assigns.total)

    title =
      if assigns.exempt > 0 do
        title <> " · " <> gettext("%{count} waived", count: assigns.exempt)
      else
        title
      end

    assigns = assign(assigns, label: label, title: title)

    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-full border px-1.5 py-0.5 text-[10px] font-semibold leading-none",
        settlement_chip_class(@state)
      ]}
      title={@title}
    >
      {@label}
    </span>
    """
  end

  defp settlement_chip_label(:customer, :open), do: gettext("Customer uninvoiced")
  defp settlement_chip_label(:customer, :partial), do: gettext("Customer partial")
  defp settlement_chip_label(:customer, :done), do: gettext("Customer invoiced")
  defp settlement_chip_label(:customer, :waived), do: gettext("Customer waived")
  defp settlement_chip_label(:customer, :n_a), do: gettext("Customer n/a")

  defp settlement_chip_label(:supplier, :open), do: gettext("Supplier unbilled")
  defp settlement_chip_label(:supplier, :partial), do: gettext("Supplier partial")
  defp settlement_chip_label(:supplier, :done), do: gettext("Supplier billed")
  defp settlement_chip_label(:supplier, :waived), do: gettext("Supplier waived")
  defp settlement_chip_label(:supplier, :n_a), do: gettext("Supplier n/a")

  defp settlement_chip_label(:transport, :open), do: gettext("Transport unbilled")
  defp settlement_chip_label(:transport, :partial), do: gettext("Transport partial")
  defp settlement_chip_label(:transport, :done), do: gettext("Transport billed")
  defp settlement_chip_label(:transport, :waived), do: gettext("Transport waived")
  defp settlement_chip_label(:transport, :n_a), do: gettext("Transport n/a")

  defp settlement_chip_label(_, _), do: "—"

  defp settlement_chip_title(:customer, :n_a, _, _),
    do: gettext("No sales drops on this trip")

  defp settlement_chip_title(:customer, _, done, total),
    do: gettext("Customer: %{done} of %{total} sales drops invoiced", done: done, total: total)

  defp settlement_chip_title(:supplier, :n_a, _, _),
    do: gettext("No commercial supply loads on this trip")

  defp settlement_chip_title(:supplier, _, done, total),
    do: gettext("Supplier: %{done} of %{total} commercial loads billed", done: done, total: total)

  defp settlement_chip_title(:transport, :n_a, _, _),
    do: gettext("Not an agent trip")

  defp settlement_chip_title(:transport, _, done, total),
    do: gettext("Transport: %{done} of %{total} haul lines billed", done: done, total: total)

  defp settlement_chip_title(_, _, _, _), do: ""

  defp settlement_chip_class(:open), do: "bg-amber-100 text-amber-900 border-amber-300"
  defp settlement_chip_class(:partial), do: "bg-sky-100 text-sky-900 border-sky-300"
  defp settlement_chip_class(:done), do: "bg-emerald-100 text-emerald-900 border-emerald-300"
  defp settlement_chip_class(:waived), do: "bg-zinc-200 text-zinc-600 border-zinc-400"
  defp settlement_chip_class(:n_a), do: "bg-zinc-100 text-zinc-500 border-zinc-300"
  defp settlement_chip_class(_), do: "bg-zinc-100 text-zinc-500 border-zinc-300"

  defp load_bill_label(%{pur_invoice_id: id}) when not is_nil(id), do: gettext("billed")
  defp load_bill_label(%{pur_invoice_exempt_at: at}) when not is_nil(at), do: gettext("waived")
  defp load_bill_label(%{supply_position_id: id}) when not is_nil(id), do: gettext("unbilled")
  defp load_bill_label(_), do: ""

  defp load_bill_class(%{pur_invoice_id: id}) when not is_nil(id),
    do: "bg-emerald-50 text-emerald-800"

  defp load_bill_class(%{pur_invoice_exempt_at: at}) when not is_nil(at),
    do: "bg-zinc-100 text-zinc-600"

  defp load_bill_class(%{supply_position_id: id}) when not is_nil(id),
    do: "bg-amber-50 text-amber-800"

  defp load_bill_class(_), do: ""

  defp drop_invoice_label(%{invoice_id: id}) when not is_nil(id), do: gettext("invoiced")
  defp drop_invoice_label(%{invoice_exempt_at: at}) when not is_nil(at), do: gettext("waived")
  defp drop_invoice_label(%{sales_position_id: id}) when not is_nil(id), do: gettext("uninvoiced")
  defp drop_invoice_label(_), do: ""

  defp drop_invoice_class(%{invoice_id: id}) when not is_nil(id),
    do: "bg-emerald-50 text-emerald-800"

  defp drop_invoice_class(%{invoice_exempt_at: at}) when not is_nil(at),
    do: "bg-zinc-100 text-zinc-600"

  defp drop_invoice_class(%{sales_position_id: id}) when not is_nil(id),
    do: "bg-amber-50 text-amber-800"

  defp drop_invoice_class(_), do: ""

  defp drop_haul_label(%{transport_pur_invoice_id: id}) when not is_nil(id),
    do: gettext("haul billed")

  defp drop_haul_label(%{transport_exempt_at: at}) when not is_nil(at),
    do: gettext("haul waived")

  defp drop_haul_label(_), do: gettext("haul open")

  defp drop_haul_class(%{transport_pur_invoice_id: id}) when not is_nil(id),
    do: "bg-emerald-50 text-emerald-800"

  defp drop_haul_class(%{transport_exempt_at: at}) when not is_nil(at),
    do: "bg-zinc-100 text-zinc-600"

  defp drop_haul_class(_), do: "bg-amber-50 text-amber-800"
end
