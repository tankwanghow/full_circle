defmodule FullCircleWeb.TradingDeskLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances
  alias FullCircle.Authorization

  @filter_fields %{
    "supply" => ~w(no supplier good status),
    "warehouse" => ~w(location good),
    "sales" => ~w(no customer good status need_by),
    "trips" => ~w(date ref vehicle agent good mode status)
  }

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
       |> assign(trips_expanded: false)
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
  def handle_event("open_modal", %{"kind" => kind, "action" => action} = params, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    if Authorization.can?(user, :manage_trading, company) do
      modal = %{
        kind: String.to_existing_atom(kind),
        action: String.to_existing_atom(action),
        id: params["id"]
      }

      {:noreply, assign(socket, modal: modal)}
    else
      {:noreply,
       put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal: nil)}
  end

  def handle_event("toggle_trips_panel", _, socket) do
    {:noreply, assign(socket, trips_expanded: !socket.assigns.trips_expanded)}
  end

  def handle_event("close_transit_list", _, socket) do
    {:noreply, assign(socket, transit_list: nil)}
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

      {:noreply, socket |> assign(:filters, filters) |> apply_filters()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_select", %{"kind" => kind, "id" => id} = params, socket) do
    if socket.assigns.can_manage do
      {:noreply, toggle_selection(socket, kind, id, params["good_id"])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_selection", _, socket) do
    {:noreply, socket |> assign_empty_selection() |> apply_filters()}
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

  @impl true
  def handle_info({:desk_modal_saved, kind}, socket),
    do: handle_info({:desk_modal_saved, kind, nil}, socket)

  def handle_info({:desk_modal_saved, kind, msg}, socket) do
    msg = msg || default_msg(kind)

    socket =
      socket
      |> put_flash(:info, msg)
      |> assign(modal: nil)
      |> then(fn s ->
        if kind == :trip, do: assign_empty_selection(s), else: s
      end)
      |> load_panels()

    {:noreply, socket}
  end

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

  defp warehouse_key(location_id, good_id) when is_binary(good_id), do: "#{location_id}:#{good_id}"
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
  end

  # Out and In are mutually exclusive per warehouse row (same location×good key).
  defp toggle_selection(socket, "warehouse_load", key, _good_id) do
    toggle_warehouse_exclusive(socket, :selected_warehouse_load_keys, :selected_warehouse_drop_keys, key)
  end

  defp toggle_selection(socket, "warehouse_drop", key, _good_id) do
    toggle_warehouse_exclusive(socket, :selected_warehouse_drop_keys, :selected_warehouse_load_keys, key)
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

    on_board? =
      is_binary(preferred_id) and
        Enum.any?(socket.assigns.supply_all, &(&1.supply.id == preferred_id))

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
      supply: %{no: "", supplier: "", good: "", status: ""},
      warehouse: %{location: "", good: ""},
      sales: %{no: "", customer: "", good: "", status: "", need_by: ""},
      trips: %{date: "", ref: "", vehicle: "", agent: "", good: "", mode: "", status: ""}
    }
  end

  defp load_panels(socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    sales_rows =
      company
      |> Trading.list_open_sales(user)
      |> Enum.map(fn s ->
        %{
          sales: s,
          ordered: s.quantity,
          delivered: Balances.sales_delivered(s),
          undelivered: Balances.sales_undelivered(s),
          in_transit: Balances.sales_in_transit(s)
        }
      end)

    trips =
      company
      |> Trading.list_trips(user)
      |> Enum.take(50)

    socket
    |> assign(:supply_all, Trading.position_board(company, user))
    |> assign(:sales_all, sales_rows)
    |> assign(:warehouse_all, Trading.warehouse_board(company, user))
    |> assign(:trips_all, trips)
    |> apply_filters()
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

    socket
    |> assign(:supply_rows, supply_rows)
    |> assign(:warehouse_rows, warehouse_rows)
    |> assign(:sales_rows, sales_rows)
    |> assign(:trips, trips)
    |> assign(:selection_ready, selection_ready?(socket))
    |> assign(:selection_summary, selection_summary(socket))
    |> assign(:selection_active, selection_active?(socket))
  end

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

  defp filter_rows(rows, filters, field_fn) do
    Enum.reduce(filters, rows, fn {field, query}, acc ->
      q = query |> as_text() |> String.trim() |> String.downcase()

      if q == "" do
        acc
      else
        Enum.filter(acc, fn row ->
          row
          |> field_fn.(field)
          |> as_text()
          |> String.downcase()
          |> String.contains?(q)
        end)
      end
    end)
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
  defp trip_field(t, :agent), do: t.transport_agent && t.transport_agent.name
  defp trip_field(t, :good), do: trip_goods_label(t)
  defp trip_field(t, :mode), do: t.transport_mode
  defp trip_field(t, :status), do: t.status
  defp trip_field(_, _), do: ""

  defp trip_goods_label(t) do
    t
    |> FullCircle.Trading.Trip.goods()
    |> Enum.map(& &1.name)
    |> Enum.join(", ")
  end

  defp nested_name(nil, _assoc), do: ""
  defp nested_name(parent, assoc) do
    case Map.get(parent, assoc) do
      nil -> ""
      %{name: name} -> name
      _ -> ""
    end
  end

  attr :table, :string, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :class, :string, default: ""
  attr :align, :string, default: "left"

  defp filter_col(assigns) do
    ~H"""
    <div class={[@class, "min-w-0 flex items-center"]}>
      <form
        id={"desk-filter-#{@table}-#{@field}"}
        phx-change="filter"
        phx-submit="filter"
        class="w-full m-0"
      >
        <input type="hidden" name="table" value={@table} />
        <input type="hidden" name="field" value={@field} />
        <input
          type="text"
          name="value"
          value={@value}
          phx-debounce="200"
          class={[
            "w-full font-bold text-xs md:text-sm px-1 py-0.5 rounded border border-black/20 bg-white/80 text-gray-900 placeholder:text-inherit placeholder:opacity-90 focus:outline-none focus:ring-1 focus:ring-black/30 focus:bg-white",
            @align == "right" && "text-right",
            @align == "center" && "text-center"
          ]}
          placeholder={@label}
          title={@label}
          aria-label={@label}
          autocomplete="off"
        />
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
      <%!-- Top: supply + warehouse | open sales --%>
      <div class="flex-1 min-h-0 flex flex-col lg:flex-row gap-2">
        <div class="lg:w-1/2 min-h-0 flex flex-col gap-2">
          <%!-- SUPPLY: header sticky inside scroll so cols share scrollbar width --%>
          <div
            id="desk_supply"
            class="flex-1 min-h-0 flex flex-col border-2 border-amber-500 rounded overflow-hidden bg-white dark:bg-zinc-900"
          >
            <div class="flex-1 min-h-0 overflow-y-scroll [scrollbar-gutter:stable]">
              <div class="sticky top-0 z-10 bg-amber-200 border-b-2 border-amber-500 font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm text-amber-950">
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
                  <.filter_col
                    class="w-3/24"
                    table="supply"
                    field="status"
                    label={gettext("Status")}
                    value={@filters.supply.status}
                  />
                  <.plain_col class="w-3/24" label={gettext("Remain")} align="right" />
                  <.plain_col class="w-2/24" label={gettext("Transit")} align="right" />
                  <.plain_col class="w-2/24" label={gettext("Soft")} align="right" />
                  <.plain_col class="w-2/24" label={gettext("Price")} align="right" />
                </div>
              </div>
              <div
                :for={row <- @supply_rows}
                id={"desk-supply-#{row.supply.id}"}
                class={[
                  "flex gap-1 border-b px-2 py-1 text-xs md:text-sm items-center hover:bg-gray-100 dark:hover:bg-zinc-800",
                  MapSet.member?(@selected_supply_ids, row.supply.id) && "bg-amber-50 dark:bg-amber-950/30"
                ]}
              >
                <div class="w-6 shrink-0 flex items-center justify-center">
                  <input
                    :if={@can_manage}
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
                  <div class="w-3/24 min-w-0 truncate">{row.supply.status}</div>
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
              <div class="sticky top-0 z-10 bg-sky-200 border-b-2 border-sky-500 font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm text-sky-950">
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
                  <div class="w-6/24 min-w-0 truncate">
                    <.link
                      navigate={
                        ~p"/companies/#{@current_company.id}/trading/locations/#{row.location.id}/edit"
                      }
                      class="text-blue-600 block truncate"
                      title={row.location.name}
                    >
                      {row.location.name}
                    </.link>
                  </div>
                  <div class="w-6/24 min-w-0 truncate" title={row.good && row.good.name}>
                    {(row.good && row.good.name) || "—"}
                  </div>
                  <div class={[
                    "w-4/24 min-w-0 text-right font-semibold",
                    on_hand_class(row.on_hand)
                  ]}>
                    {row.on_hand}
                    <span
                      :if={row.good && row.good.unit}
                      class="font-normal text-gray-600 ml-0.5"
                    >
                      {row.good.unit}
                    </span>
                  </div>
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
            <div class="sticky top-0 z-10 bg-emerald-200 border-b-2 border-emerald-500 font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm text-emerald-950">
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
                <.plain_col class="w-3/24" label={gettext("Undeliv")} align="right" />
                <.plain_col class="w-2/24" label={gettext("Transit")} align="right" />
                <.filter_col
                  class="w-2/24"
                  table="sales"
                  field="status"
                  label={gettext("Status")}
                  value={@filters.sales.status}
                />
                <.filter_col
                  class="w-3/24"
                  table="sales"
                  field="need_by"
                  label={gettext("Need by")}
                  value={@filters.sales.need_by}
                />
              </div>
            </div>
            <div
              :for={row <- @sales_rows}
              id={"desk-sales-#{row.sales.id}"}
              class={[
                "flex gap-1 border-b px-2 py-1 text-xs md:text-sm items-center hover:bg-gray-100 dark:hover:bg-zinc-800",
                MapSet.member?(@selected_sales_ids, row.sales.id) &&
                  "bg-emerald-50 dark:bg-emerald-950/30"
              ]}
            >
              <div class="w-6 shrink-0 flex items-center justify-center">
                <input
                  :if={@can_manage}
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
                  "w-3/24 min-w-0 text-right font-semibold",
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
                <div class="w-2/24 min-w-0 truncate">{row.sales.status}</div>
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

      <%!-- TRIPS (collapsible; transit drill-down is primary) --%>
      <div
        id="desk_trips"
        class={[
          "shrink-0 flex flex-col border-2 border-violet-500 rounded overflow-hidden bg-white dark:bg-zinc-900",
          @trips_expanded && "h-[28%] min-h-[8rem]"
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
          <button
            type="button"
            id="desk-trips-toggle"
            phx-click="toggle_trips_panel"
            class="flex-1 min-w-0 flex items-center justify-between hover:bg-violet-300 rounded px-1 py-0.5"
          >
            <span>
              {gettext("Trips")}
              <span class="font-normal text-violet-800">({length(@trips)})</span>
            </span>
            <span class="font-normal">
              {if(@trips_expanded, do: gettext("Hide"), else: gettext("Show"))}
            </span>
          </button>
        </div>
        <div
          :if={@trips_expanded}
          class="flex-1 min-h-0 overflow-y-scroll [scrollbar-gutter:stable]"
        >
          <div class="sticky top-0 z-10 bg-violet-100 border-b border-violet-400 font-bold px-2 py-1 flex gap-1 items-center text-xs md:text-sm text-violet-950">
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
                field="agent"
                label={gettext("Agent")}
                value={@filters.trips.agent}
              />
              <.filter_col
                class="w-5/24"
                table="trips"
                field="good"
                label={gettext("Good")}
                value={@filters.trips.good}
              />
              <.filter_col
                class="w-2/24"
                table="trips"
                field="mode"
                label={gettext("Mode")}
                value={@filters.trips.mode}
              />
              <.filter_col
                class="w-2/24"
                table="trips"
                field="status"
                label={gettext("Status")}
                value={@filters.trips.status}
              />
              <.plain_col class="w-2/24" label={gettext("Loads")} align="center" />
              <.plain_col class="w-2/24" label={gettext("Drops")} align="center" />
            </div>
          </div>
          <div
            :for={t <- @trips}
            id={"desk-trip-#{t.id}"}
            class="flex gap-1 border-b px-2 py-1 text-xs md:text-sm items-center hover:bg-gray-100 dark:hover:bg-zinc-800"
          >
            <div class="flex flex-1 min-w-0 gap-1 items-center">
              <div class="w-2/24 min-w-0 truncate">{t.date}</div>
              <div
                class={[
                  "w-2/24 min-w-0 truncate font-medium",
                  @can_manage && "text-blue-600 cursor-pointer hover:underline"
                ]}
                phx-click={if @can_manage, do: "open_modal"}
                phx-value-kind="trip"
                phx-value-action="edit"
                phx-value-id={t.id}
                title={t.reference_no}
              >
                {t.reference_no || "—"}
              </div>
              <div class="w-2/24 min-w-0 truncate" title={t.vehicle_number}>
                {t.vehicle_number || "—"}
              </div>
              <div
                class="w-5/24 min-w-0 truncate"
                title={t.transport_agent && t.transport_agent.name}
              >
                {(t.transport_agent && t.transport_agent.name) || "—"}
              </div>
              <div class="w-5/24 min-w-0 truncate" title={trip_goods_label(t)}>
                {trip_goods_label(t) |> then(fn s -> if s == "", do: "—", else: s end)}
              </div>
              <div class="w-2/24 min-w-0 truncate" title={t.transport_mode}>{t.transport_mode}</div>
              <div class="w-2/24 min-w-0 truncate">{t.status}</div>
              <div class="w-2/24 min-w-0 text-center">{length(t.loads || [])}</div>
              <div class="w-2/24 min-w-0 text-center">{length(t.drops || [])}</div>
            </div>
          </div>
          <p :if={@trips == []} class="text-center p-2 text-gray-500 text-sm">
            {gettext("No trips yet.")}
          </p>
        </div>
      </div>

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
            <div class="w-4/24">{gettext("Date")}</div>
            <div class="w-4/24">{gettext("Trip No")}</div>
            <div class="w-4/24">{gettext("Vehicle")}</div>
            <div class="w-4/24">{gettext("Agent")}</div>
            <div class="w-4/24">{gettext("Status")}</div>
            <div class="w-4/24 text-right">{gettext("Qty")}</div>
          </div>
          <button
            :for={t <- @transit_list.trips}
            type="button"
            id={"transit-trip-#{t.id}"}
            phx-click="open_transit_trip"
            phx-value-id={t.id}
            class="w-full flex gap-1 border-b p-2 text-sm text-left hover:bg-violet-50 dark:hover:bg-violet-950/40 cursor-pointer"
          >
            <div class="w-4/24 text-blue-600">{t.date}</div>
            <div class="w-4/24 min-w-0 truncate" title={t.reference_no}>{t.reference_no || "—"}</div>
            <div class="w-4/24 min-w-0 truncate">{t.vehicle_number || "—"}</div>
            <div class="w-4/24 min-w-0 truncate" title={t.agent_name}>{t.agent_name || "—"}</div>
            <div class="w-4/24">{t.status}</div>
            <div class="w-4/24 text-right font-semibold text-violet-700">{t.qty}</div>
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
        max_w={if @modal.kind == :trip, do: "max-w-7xl", else: "max-w-3xl"}
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
end
