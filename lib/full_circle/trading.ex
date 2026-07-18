defmodule FullCircle.Trading do
  @moduledoc """
  Grain trading desk.

  Masters:
  - **Location** — new `trading_locations` table (physical load/drop sites)
  - **Driver** — existing `employees` (HR)
  - **Transport agent** — existing `contacts` (Accounting)
  """

  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.Repo
  alias FullCircle.Authorization
  alias FullCircle.Trading.{
    Location,
    SupplyPosition,
    SalesPosition,
    Balances,
    Trip,
    TripLoad,
    TripDrop
  }
  alias FullCircle.HR.Employee
  alias FullCircle.Accounting.Contact
  alias FullCircle.Sys
  alias Ecto.Multi

  # --- Locations (new table) ---

  def list_locations(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      active_only? = Keyword.get(opts, :active_only, false)

      from(l in Location,
        where: l.company_id == ^company.id,
        order_by: [asc: l.name]
      )
      |> maybe_active_only(active_only?)
      |> Repo.all()
    else
      []
    end
  end

  def get_location!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")
    Repo.get_by!(Location, id: id, company_id: company.id)
  end

  def create_location(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      %Location{}
      |> Location.changeset(put_company(attrs, company))
      |> Repo.insert()
    end
  end

  def update_location(%Location{} = location, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- location.company_id == company.id do
      location
      |> Location.changeset(attrs)
      |> Repo.update()
    else
      false -> :not_authorise
      other -> other
    end
  end

  # --- Drivers = Employees ---

  @doc """
  Employees usable as trip load/drop drivers.
  Active employees only when `active_only: true` (status == \"Active\").
  """
  def list_drivers(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      active_only? = Keyword.get(opts, :active_only, false)

      from(e in Employee,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == e.company_id,
        order_by: [asc: e.name]
      )
      |> maybe_employee_active_only(active_only?)
      |> Repo.all()
    else
      []
    end
  end

  def get_driver!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")

    from(e in Employee,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == e.company_id,
      where: e.id == ^id
    )
    |> Repo.one!()
  end

  # --- Transport agents = Contacts ---

  @doc """
  Contacts usable as transport agents (haulage companies).
  Optional `category` filter (e.g. \"Transporter\") when you tag contacts that way.
  """
  def list_transport_agents(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      category = Keyword.get(opts, :category)

      q =
        from(c in Contact,
          join: com in subquery(Sys.user_company(company, user)),
          on: com.id == c.company_id,
          order_by: [asc: c.name]
        )

      q =
        if category do
          from(c in q, where: c.category == ^category)
        else
          q
        end

      Repo.all(q)
    else
      []
    end
  end

  def get_transport_agent!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")

    from(c in Contact,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == c.company_id,
      where: c.id == ^id
    )
    |> Repo.one!()
  end

  # --- Supply positions ---

  def list_supply_positions(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      status = Keyword.get(opts, :status)
      statuses = Keyword.get(opts, :statuses)

      q =
        from(s in SupplyPosition,
          where: s.company_id == ^company.id,
          preload: [:supplier, :good],
          order_by: [desc: s.inserted_at]
        )

      q =
        cond do
          is_list(statuses) and statuses != [] ->
            from(s in q, where: s.status in ^statuses)

          is_binary(status) ->
            from(s in q, where: s.status == ^status)

          true ->
            q
        end

      Repo.all(q)
    else
      []
    end
  end

  def get_supply_position!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")

    from(s in SupplyPosition,
      where: s.id == ^id and s.company_id == ^company.id,
      preload: [:supplier, :good]
    )
    |> Repo.one!()
  end

  def create_supply_position(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())

      Multi.new()
      |> get_gapless_doc_id(gapless_name, "TradingSupply", "SUP", company)
      |> Multi.insert(:create_supply, fn %{^gapless_name => doc} ->
        attrs
        |> stringify_attr_keys()
        |> put_company(company)
        |> Map.put("title", doc)
        |> then(&SupplyPosition.changeset(%SupplyPosition{}, &1))
      end)
      |> Repo.transaction()
      |> unwrap_multi(:create_supply)
    end
  end

  def update_supply_position(%SupplyPosition{} = position, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- position.company_id == company.id do
      attrs =
        attrs
        |> stringify_attr_keys()
        # System-generated supply no — never change after create
        |> Map.drop(["title"])
        |> Map.put("title", position.title)

      position
      |> SupplyPosition.changeset(attrs)
      |> Repo.update()
    else
      false -> :not_authorise
      other -> other
    end
  end

  @doc """
  Supplier holding collection (stock still exists).
  """
  def hold_supply_position(%SupplyPosition{} = position, company, user) do
    update_supply_position(position, %{"status" => "hold"}, company, user)
  end

  @doc """
  Supplier allows collection / lift.
  """
  def collect_supply_position(%SupplyPosition{} = position, company, user) do
    update_supply_position(position, %{"status" => "collect"}, company, user)
  end

  @doc """
  Stock ended / collection finished.
  """
  def close_supply_position(%SupplyPosition{} = position, company, user) do
    update_supply_position(position, %{"status" => "closed"}, company, user)
  end

  @doc """
  Autocomplete: active supplies (open/hold/collect) by title for soft-hold targets.
  """
  def open_supply_position_names(terms, company, user) do
    if Authorization.can?(user, :view_trading, company) do
      active = SupplyPosition.active_statuses()

      from(s in SupplyPosition,
        where: s.company_id == ^company.id,
        where: s.status in ^active,
        where: not is_nil(s.title) and s.title != "",
        where: ilike(s.title, ^"%#{terms}%"),
        select: %{id: s.id, value: s.title},
        order_by: [asc: s.title]
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Resolve active supply (open/hold/collect) by exact title (soft-hold typeahead).
  """
  def get_open_supply_position_by_title(title, company, user) do
    title = title |> to_string() |> String.trim()
    active = SupplyPosition.active_statuses()

    if title == "" or not Authorization.can?(user, :view_trading, company) do
      nil
    else
      from(s in SupplyPosition,
        where: s.company_id == ^company.id,
        where: s.status in ^active,
        where: s.title == ^title,
        preload: [:supplier, :good]
      )
      |> Repo.one()
    end
  end

  @doc """
  Position board rows: supplies + loaded / remaining / soft_held / in_transit.

  By default only **active** statuses (`open` / `hold` / `collect`).
  Pass `statuses:` to include inactive (e.g. `closed`) when the desk status filter asks for them.
  """
  def position_board(company, user, opts \\ []) do
    statuses = Keyword.get(opts, :statuses) || SupplyPosition.active_statuses()

    company
    |> list_supply_positions(user, statuses: statuses)
    |> Enum.map(fn s ->
      %{
        supply: s,
        loaded: Balances.supply_loaded(s),
        remaining: Balances.supply_remaining(s),
        soft_held: Balances.soft_held_for_supply(s.id),
        in_transit: Balances.supply_in_transit(s)
      }
    end)
  end

  @doc """
  Small warehouse board: own_warehouse locations with on-hand stock from
  completed trip drops in − loads out, one row per location × good.
  Also shows **incoming** from draft/planned drops.
  Empty warehouses (no movements and no incoming) appear as a single row with `good: nil`.
  """
  def warehouse_board(company, user) do
    if Authorization.can?(user, :view_trading, company) do
      locations =
        company
        |> list_locations(user)
        |> Enum.filter(&(&1.kind == "own_warehouse"))
        |> Enum.sort_by(& &1.name)

      per_loc =
        Enum.map(locations, fn loc ->
          {loc, Balances.own_warehouse_inbound_by_good(loc.id),
           Balances.own_warehouse_outbound_by_good(loc.id),
           Balances.own_warehouse_incoming_by_good(loc.id),
           Balances.own_warehouse_outgoing_by_good(loc.id)}
        end)

      good_ids =
        per_loc
        |> Enum.flat_map(fn {_loc, in_map, out_map, inc_map, og_map} ->
          Map.keys(in_map) ++ Map.keys(out_map) ++ Map.keys(inc_map) ++ Map.keys(og_map)
        end)
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1)

      goods =
        if good_ids == [] do
          %{}
        else
          from(g in FullCircle.Product.Good, where: g.id in ^good_ids)
          |> Repo.all()
          |> Map.new(&{&1.id, &1})
        end

      Enum.flat_map(per_loc, fn {loc, in_map, out_map, inc_map, og_map} ->
        gids =
          (Map.keys(in_map) ++ Map.keys(out_map) ++ Map.keys(inc_map) ++ Map.keys(og_map))
          |> Enum.uniq()
          |> Enum.reject(&is_nil/1)

        if gids == [] do
          [
            %{
              location: loc,
              good: nil,
              inbound: Decimal.new(0),
              outbound: Decimal.new(0),
              on_hand: Decimal.new(0),
              incoming: Decimal.new(0),
              outgoing: Decimal.new(0)
            }
          ]
        else
          gids
          |> Enum.sort_by(fn gid -> (goods[gid] && goods[gid].name) || "" end)
          |> Enum.map(fn gid ->
            inbound = Map.get(in_map, gid, Decimal.new(0))
            outbound = Map.get(out_map, gid, Decimal.new(0))
            incoming = Map.get(inc_map, gid, Decimal.new(0))
            outgoing = Map.get(og_map, gid, Decimal.new(0))

            %{
              location: loc,
              good: Map.get(goods, gid),
              inbound: inbound,
              outbound: outbound,
              on_hand: Decimal.sub(inbound, outbound),
              incoming: incoming,
              outgoing: outgoing
            }
          end)
        end
      end)
    else
      []
    end
  end

  # --- Sales positions ---

  def list_sales_positions(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      status = Keyword.get(opts, :status)
      statuses = Keyword.get(opts, :statuses)

      q =
        from(s in SalesPosition,
          where: s.company_id == ^company.id,
          preload: [:customer, :good, :preferred_supply],
          order_by: [desc: s.inserted_at]
        )

      q =
        cond do
          is_list(statuses) and statuses != [] ->
            from(s in q, where: s.status in ^statuses)

          is_binary(status) ->
            from(s in q, where: s.status == ^status)

          true ->
            q
        end

      Repo.all(q)
    else
      []
    end
  end

  @doc """
  Open commitments board: draft + open + hold sales by default.
  Pass `statuses:` to include fulfilled / cancelled when the desk status filter asks for them.
  """
  def list_open_sales(company, user, opts \\ []) do
    statuses = Keyword.get(opts, :statuses) || SalesPosition.active_statuses()
    list_sales_positions(company, user, statuses: statuses)
  end

  @doc """
  Desk sales rows with undelivered / in-transit balances.
  """
  def sales_board(company, user, opts \\ []) do
    company
    |> list_open_sales(user, opts)
    |> Enum.map(fn s ->
      %{
        sales: s,
        ordered: s.quantity,
        delivered: Balances.sales_delivered(s),
        undelivered: Balances.sales_undelivered(s),
        in_transit: Balances.sales_in_transit(s)
      }
    end)
  end

  def get_sales_position!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")

    from(s in SalesPosition,
      where: s.id == ^id and s.company_id == ^company.id,
      preload: [:customer, :good, :preferred_supply]
    )
    |> Repo.one!()
  end

  def create_sales_position(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())

      Multi.new()
      |> get_gapless_doc_id(gapless_name, "TradingSales", "SAL", company)
      |> Multi.insert(:create_sales, fn %{^gapless_name => doc} ->
        attrs
        |> stringify_attr_keys()
        |> put_company(company)
        |> Map.put("title", doc)
        |> then(&SalesPosition.changeset(%SalesPosition{}, &1))
      end)
      |> Repo.transaction()
      |> unwrap_multi(:create_sales)
    end
  end

  def update_sales_position(%SalesPosition{} = position, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- position.company_id == company.id do
      attrs =
        attrs
        |> stringify_attr_keys()
        # System-generated sales no — never change after create
        |> Map.drop(["title"])
        |> Map.put("title", position.title)

      position
      |> SalesPosition.changeset(attrs)
      |> Repo.update()
    else
      false -> :not_authorise
      other -> other
    end
  end

  def open_sales_position(%SalesPosition{} = position, company, user) do
    update_sales_position(position, %{"status" => "open"}, company, user)
  end

  def hold_sales_position(%SalesPosition{} = position, company, user) do
    update_sales_position(position, %{"status" => "hold"}, company, user)
  end

  @doc """
  Manual fulfill — allowed even when undelivered > 0 (short deliveries).
  Optional attrs: `fulfilled_note`.
  """
  def fulfill_sales_position(%SalesPosition{} = position, attrs, company, user) do
    attrs =
      attrs
      |> stringify_attr_keys()
      |> Map.put("status", "fulfilled")

    update_sales_position(position, attrs, company, user)
  end

  def cancel_sales_position(%SalesPosition{} = position, company, user) do
    cancel_sales_position(position, %{}, company, user)
  end

  def cancel_sales_position(%SalesPosition{} = position, attrs, company, user)
      when is_map(attrs) do
    attrs =
      attrs
      |> stringify_attr_keys()
      |> Map.put("status", "cancelled")

    update_sales_position(position, attrs, company, user)
  end

  # --- Trips ---

  def list_trips(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      status = Keyword.get(opts, :status)

      q =
        from(t in Trip,
          where: t.company_id == ^company.id,
          preload: [
            :transport_agent,
            loads: [:location, :good, supply_position: :supplier],
            drops: [:location, :good, :supply_position, sales_position: :customer]
          ],
          order_by: [desc: t.date, desc: t.inserted_at]
        )

      q =
        if status do
          from(t in q, where: t.status == ^status)
        else
          q
        end

      Repo.all(q)
    else
      []
    end
  end

  @doc """
  Unique source labels for a trip's loads (supplier name, else load location).
  """
  def trip_from_names(%Trip{} = trip) do
    trip
    |> trip_lines(:loads)
    |> Enum.map(fn load ->
      supplier_name =
        case load.supply_position do
          %{supplier: %{name: name}} when is_binary(name) and name != "" -> name
          _ -> nil
        end

      location_name =
        case load.location do
          %{name: name} when is_binary(name) and name != "" -> name
          _ -> nil
        end

      supplier_name || location_name
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def trip_from_names(_), do: []

  @doc """
  Unique destination labels for a trip's drops (customer name, else drop location).
  """
  def trip_to_names(%Trip{} = trip) do
    trip
    |> trip_lines(:drops)
    |> Enum.map(fn drop ->
      customer_name =
        case drop.sales_position do
          %{customer: %{name: name}} when is_binary(name) and name != "" -> name
          _ -> nil
        end

      location_name =
        case drop.location do
          %{name: name} when is_binary(name) and name != "" -> name
          _ -> nil
        end

      customer_name || location_name
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def trip_to_names(_), do: []

  @doc """
  Compact label for multi-party columns: `A`, `A, B`, or `A, B +N`.
  """
  def trip_parties_label(names, max_show \\ 2)
  def trip_parties_label([], _), do: ""
  def trip_parties_label(names, max_show) when is_list(names) do
    case names do
      [one] ->
        one

      many when length(many) <= max_show ->
        Enum.join(many, ", ")

      many ->
        shown = Enum.take(many, max_show)
        rest = length(many) - max_show
        Enum.join(shown, ", ") <> " +#{rest}"
    end
  end

  def trip_parties_label(_, _), do: ""

  defp trip_lines(trip, field) do
    case Map.get(trip, field) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Open trips (draft/planned) contributing to an in-transit quantity.

  `kind` is one of:
  - `:supply_transit` — requires `:supply_id`
  - `:sales_transit` — requires `:sales_id`
  - `:warehouse_incoming` — requires `:location_id`, `:good_id`
  - `:warehouse_outgoing` — requires `:location_id`, `:good_id`

  Returns list of maps:
  `%{id, date, reference_no, status, vehicle_number, agent_name, qty}`.
  """
  def list_open_trips_for(company, user, kind, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      open = Balances.open_trip_statuses()

      rows =
        case kind do
          :supply_transit ->
            supply_id = Keyword.fetch!(opts, :supply_id)

            from(t in Trip,
              join: l in TripLoad,
              on: l.trip_id == t.id,
              left_join: a in Contact,
              on: a.id == t.transport_agent_id,
              where:
                t.company_id == ^company.id and t.status in ^open and
                  l.supply_position_id == ^supply_id,
              group_by: [
                t.id,
                t.date,
                t.reference_no,
                t.status,
                t.vehicle_number,
                t.inserted_at,
                a.name
              ],
              order_by: [desc: t.date, desc: t.inserted_at],
              select: %{
                id: t.id,
                date: t.date,
                reference_no: t.reference_no,
                status: t.status,
                vehicle_number: t.vehicle_number,
                agent_name: a.name,
                qty:
                  coalesce(sum(fragment("coalesce(?, ?)", l.actual_mt, l.planned_mt)), 0)
              }
            )
            |> Repo.all()

          :sales_transit ->
            sales_id = Keyword.fetch!(opts, :sales_id)

            from(t in Trip,
              join: d in TripDrop,
              on: d.trip_id == t.id,
              left_join: a in Contact,
              on: a.id == t.transport_agent_id,
              where:
                t.company_id == ^company.id and t.status in ^open and
                  d.sales_position_id == ^sales_id,
              group_by: [
                t.id,
                t.date,
                t.reference_no,
                t.status,
                t.vehicle_number,
                t.inserted_at,
                a.name
              ],
              order_by: [desc: t.date, desc: t.inserted_at],
              select: %{
                id: t.id,
                date: t.date,
                reference_no: t.reference_no,
                status: t.status,
                vehicle_number: t.vehicle_number,
                agent_name: a.name,
                qty:
                  coalesce(sum(fragment("coalesce(?, ?)", d.actual_mt, d.planned_mt)), 0)
              }
            )
            |> Repo.all()

          :warehouse_incoming ->
            location_id = Keyword.fetch!(opts, :location_id)
            good_id = Keyword.fetch!(opts, :good_id)

            from(t in Trip,
              join: d in TripDrop,
              on: d.trip_id == t.id,
              left_join: a in Contact,
              on: a.id == t.transport_agent_id,
              where:
                t.company_id == ^company.id and t.status in ^open and
                  d.location_id == ^location_id and d.good_id == ^good_id,
              group_by: [
                t.id,
                t.date,
                t.reference_no,
                t.status,
                t.vehicle_number,
                t.inserted_at,
                a.name
              ],
              order_by: [desc: t.date, desc: t.inserted_at],
              select: %{
                id: t.id,
                date: t.date,
                reference_no: t.reference_no,
                status: t.status,
                vehicle_number: t.vehicle_number,
                agent_name: a.name,
                qty:
                  coalesce(sum(fragment("coalesce(?, ?)", d.actual_mt, d.planned_mt)), 0)
              }
            )
            |> Repo.all()

          :warehouse_outgoing ->
            location_id = Keyword.fetch!(opts, :location_id)
            good_id = Keyword.fetch!(opts, :good_id)

            from(t in Trip,
              join: l in TripLoad,
              on: l.trip_id == t.id,
              left_join: a in Contact,
              on: a.id == t.transport_agent_id,
              where:
                t.company_id == ^company.id and t.status in ^open and
                  l.location_id == ^location_id and l.good_id == ^good_id,
              group_by: [
                t.id,
                t.date,
                t.reference_no,
                t.status,
                t.vehicle_number,
                t.inserted_at,
                a.name
              ],
              order_by: [desc: t.date, desc: t.inserted_at],
              select: %{
                id: t.id,
                date: t.date,
                reference_no: t.reference_no,
                status: t.status,
                vehicle_number: t.vehicle_number,
                agent_name: a.name,
                qty:
                  coalesce(sum(fragment("coalesce(?, ?)", l.actual_mt, l.planned_mt)), 0)
              }
            )
            |> Repo.all()

          _ ->
            []
        end

      Enum.map(rows, fn row ->
        Map.update!(row, :qty, &open_trip_qty_to_dec/1)
      end)
    else
      []
    end
  end

  defp open_trip_qty_to_dec(%Decimal{} = d), do: d
  defp open_trip_qty_to_dec(n) when is_integer(n), do: Decimal.new(n)
  defp open_trip_qty_to_dec(n) when is_float(n), do: Decimal.from_float(n)
  defp open_trip_qty_to_dec(nil), do: Decimal.new(0)
  defp open_trip_qty_to_dec(other), do: Decimal.new("#{other}")

  def get_trip!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")

    from(t in Trip,
      where: t.id == ^id and t.company_id == ^company.id,
      preload: [
        :transport_agent,
        loads: [
          :location,
          :good,
          supply_position: :supplier,
          trip_load_employees: :employee
        ],
        drops: [
          :location,
          :good,
          :supply_position,
          sales_position: :customer,
          trip_drop_employees: :employee
        ]
      ]
    )
    |> Repo.one!()
  end

  @doc """
  Build string-key attrs for a new multi-good trip from desk selection.

  `selection` map:
  - `:supply_ids` — commercial supplies to load
  - `:warehouse_load_keys` — own warehouses to load **out** of (`%{location_id, good_id}`)
  - `:warehouse_drop_keys` — own warehouses to drop **into** (`%{location_id, good_id | nil}`)
  - `:sales_ids` — customer sales drops

  Unified assembly:
  - **Loads** = selected supplies + warehouse **Out**
  - **Drops** = selected sales + warehouse **In** (can combine customer + own-warehouse drops)

  Requires ≥1 load line and ≥1 drop line.
  MT on warehouse In drops defaults to matching supply remaining (edit to split half/half).
  """
  def build_trip_attrs_from_selection(selection, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      supply_ids = List.wrap(selection[:supply_ids] || selection["supply_ids"])
      sales_ids = List.wrap(selection[:sales_ids] || selection["sales_ids"])

      legacy_wh = List.wrap(selection[:warehouse_keys] || selection["warehouse_keys"])

      warehouse_load_keys =
        case List.wrap(selection[:warehouse_load_keys] || selection["warehouse_load_keys"]) do
          [] when sales_ids != [] and legacy_wh != [] -> legacy_wh
          keys -> keys
        end

      warehouse_drop_keys =
        case List.wrap(selection[:warehouse_drop_keys] || selection["warehouse_drop_keys"]) do
          [] when sales_ids == [] and legacy_wh != [] -> legacy_wh
          keys -> keys
        end

      supplies = Enum.map(supply_ids, fn id -> get_supply_position!(id, company, user) end)
      sales = Enum.map(sales_ids, fn id -> get_sales_position!(id, company, user) end)

      load_loc_id = default_load_location_id(company, user)

      loads =
        Enum.map(supplies, fn s ->
          s
          |> supply_load_attrs()
          |> then(fn attrs ->
            if is_nil(attrs["location_id"]),
              do: Map.put(attrs, "location_id", load_loc_id),
              else: attrs
          end)
        end) ++ warehouse_load_lines(warehouse_load_keys)

      sales_drops = sales_drop_lines(sales, supplies, company, user)

      warehouse_drops =
        warehouse_drop_keys
        |> Enum.flat_map(fn key -> stock_in_drops_for_key(key, supplies) end)
        |> case do
          [] when warehouse_drop_keys != [] and supplies != [] ->
            Enum.flat_map(warehouse_drop_keys, fn key ->
              loc_id = key[:location_id] || key["location_id"]

              case supplies do
                [s | _] -> [stock_in_drop_line(s, loc_id)]
                [] -> []
              end
            end)

          list ->
            list
        end

      drops = sales_drops ++ warehouse_drops

      if loads == [] or drops == [] do
        {:error, :incomplete_selection}
      else
        {:ok, base_trip_attrs(loads, drops)}
      end
    end
  end

  defp warehouse_load_lines(warehouse_load_keys) do
    Enum.flat_map(warehouse_load_keys, fn key ->
      loc_id = key[:location_id] || key["location_id"]
      g_id = key[:good_id] || key["good_id"]

      if is_binary(g_id) and g_id not in ["", "any"] do
        case Repo.get(FullCircle.Product.Good, g_id) do
          nil ->
            []

          good ->
            on_hand = warehouse_on_hand(loc_id, g_id)
            mt = decimal_str(on_hand)

            [
              %{
                "planned_mt" => mt,
                "actual_mt" => mt,
                "good_id" => g_id,
                "good_name" => good.name,
                "location_id" => loc_id,
                "supply_position_id" => nil
              }
            ]
        end
      else
        []
      end
    end)
  end

  defp sales_drop_lines(sales, supplies, company, user) do
    Enum.map(sales, fn s ->
      mt = Balances.sales_undelivered(s) |> decimal_str()
      good = s.good || Repo.get!(FullCircle.Product.Good, s.good_id)

      same_good_supplies = Enum.filter(supplies, &(&1.good_id == s.good_id))

      supply_pos_id =
        cond do
          s.preferred_supply_id &&
              Enum.any?(same_good_supplies, &(&1.id == s.preferred_supply_id)) ->
            s.preferred_supply_id

          match?([_], same_good_supplies) ->
            hd(same_good_supplies).id

          true ->
            nil
        end

      loc_id = customer_site_location_id(company, user, s.customer_id)

      %{
        "planned_mt" => mt,
        "actual_mt" => mt,
        "good_id" => s.good_id,
        "good_name" => good && good.name,
        "sales_position_id" => s.id,
        "supply_position_id" => supply_pos_id,
        "location_id" => loc_id
      }
    end)
  end

  defp stock_in_drops_for_key(key, supplies) do
    loc_id = key[:location_id] || key["location_id"]
    g_id = key[:good_id] || key["good_id"]
    g_id = if g_id in [nil, "", "any"], do: nil, else: to_string(g_id)

    target_supplies =
      if is_nil(g_id) do
        supplies
      else
        Enum.filter(supplies, fn s -> to_string(s.good_id) == g_id end)
      end

    case target_supplies do
      [] when not is_nil(g_id) ->
        # Warehouse row good with no matching supply still gets a drop line
        good = Repo.get(FullCircle.Product.Good, g_id)

        if good do
          [
            %{
              "planned_mt" => "0",
              "actual_mt" => "0",
              "good_id" => g_id,
              "good_name" => good.name,
              "location_id" => loc_id,
              "sales_position_id" => nil,
              "supply_position_id" => nil
            }
          ]
        else
          []
        end

      [] ->
        []

      list ->
        Enum.map(list, &stock_in_drop_line(&1, loc_id))
    end
  end

  defp stock_in_drop_line(s, loc_id) do
    good = s.good || Repo.get!(FullCircle.Product.Good, s.good_id)
    mt = Balances.supply_remaining(s) |> decimal_str()

    %{
      "planned_mt" => mt,
      "actual_mt" => mt,
      "good_id" => s.good_id,
      "good_name" => good && good.name,
      "location_id" => loc_id,
      "sales_position_id" => nil,
      "supply_position_id" => s.id
    }
  end

  defp supply_load_attrs(s) do
    mt = Balances.supply_remaining(s) |> decimal_str()
    good = s.good || Repo.get!(FullCircle.Product.Good, s.good_id)

    %{
      "planned_mt" => mt,
      "actual_mt" => mt,
      "good_id" => s.good_id,
      "good_name" => good && good.name,
      "supply_position_id" => s.id,
      "location_id" => nil
    }
  end

  defp default_load_location_id(company, user) do
    company
    |> list_locations(user, active_only: true)
    |> Enum.find(&(&1.kind in ~w(port supplier_site)))
    |> case do
      nil -> nil
      loc -> loc.id
    end
  end

  defp base_trip_attrs(loads, drops) do
    %{
      "date" => Date.utc_today() |> Date.to_iso8601(),
      "status" => "draft",
      "transport_mode" => "company_own",
      "loads" => loads,
      "drops" => drops
    }
  end

  defp warehouse_on_hand(location_id, good_id)
       when is_binary(location_id) and is_binary(good_id) do
    inbound = Map.get(Balances.own_warehouse_inbound_by_good(location_id), good_id, Decimal.new(0))
    outbound = Map.get(Balances.own_warehouse_outbound_by_good(location_id), good_id, Decimal.new(0))
    Decimal.sub(inbound, outbound)
  end

  defp warehouse_on_hand(_, _), do: Decimal.new(0)

  defp customer_site_location_id(company, user, customer_id)
       when is_binary(customer_id) do
    company
    |> list_locations(user, active_only: true)
    |> Enum.find(fn l -> l.kind == "customer_site" and l.contact_id == customer_id end)
    |> case do
      nil -> nil
      loc -> loc.id
    end
  end

  defp customer_site_location_id(_, _, _), do: nil

  defp decimal_str(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_str(n) when is_integer(n), do: Integer.to_string(n)
  defp decimal_str(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp decimal_str(nil), do: "0"
  defp decimal_str(other), do: to_string(other)

  def create_trip(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())

      Multi.new()
      |> get_gapless_doc_id(gapless_name, "TradingTrip", "TRP", company)
      |> Multi.insert(:create_trip, fn %{^gapless_name => doc} ->
        attrs
        |> stringify_attr_keys()
        |> put_company(company)
        |> Map.put("reference_no", doc)
        |> then(&Trip.changeset(%Trip{}, &1))
        |> validate_trip_goods()
      end)
      |> Repo.transaction()
      |> unwrap_multi(:create_trip)
      |> maybe_promote_open_supplies_to_collect()
      |> preload_trip_result()
    end
  end

  def update_trip(%Trip{} = trip, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- trip.company_id == company.id do
      if trip.status in ["completed", "cancelled"] do
        {:error, :trip_locked}
      else
        attrs =
          attrs
          |> stringify_attr_keys()
          # System-generated trip no — never change after create
          |> Map.drop(["reference_no"])
          |> Map.put("reference_no", trip.reference_no)

        trip
        |> Repo.preload([:loads, :drops])
        |> Trip.changeset(attrs)
        |> validate_trip_goods()
        |> Repo.update()
        |> maybe_promote_open_supplies_to_collect()
        |> preload_trip_result()
      end
    else
      false -> :not_authorise
      other -> other
    end
  end

  @doc """
  Mark trip completed. Requires actual_mt on every load and drop.
  Returns `{:ok, trip, warnings}` — warnings never block completion.
  """
  def complete_trip(%Trip{} = trip, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- trip.company_id == company.id do
      trip = get_trip!(trip.id, company, user)

      cond do
        trip.status == "completed" ->
          {:error, :already_completed}

        trip.status == "cancelled" ->
          {:error, :cancelled}

        missing_actuals?(trip) ->
          {:error, :missing_actuals}

        goods_mismatch?(trip) ->
          {:error, :good_mismatch}

        true ->
          case trip
               |> Ecto.Changeset.change(%{status: "completed"})
               |> Repo.update() do
            {:ok, _} ->
              trip = get_trip!(trip.id, company, user)
              {:ok, trip, trip_warnings(trip)}

            error ->
              error
          end
      end
    else
      false -> :not_authorise
      other -> other
    end
  end

  @doc """
  Cancel a trip. Completed trips can be cancelled only if no drop is invoiced.
  """
  def cancel_trip(%Trip{} = trip, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- trip.company_id == company.id do
      trip = get_trip!(trip.id, company, user)

      cond do
        trip.status == "cancelled" ->
          {:error, :already_cancelled}

        trip.status == "completed" and Enum.any?(trip.drops, & &1.invoice_id) ->
          {:error, :has_invoices}

        true ->
          case trip
               |> Ecto.Changeset.change(%{status: "cancelled"})
               |> Repo.update() do
            {:ok, _} -> {:ok, get_trip!(trip.id, company, user)}
            error -> error
          end
      end
    else
      false -> :not_authorise
      other -> other
    end
  end

  @doc """
  Non-blocking warnings for a trip (used on complete and form display).
  """
  def trip_warnings(%Trip{} = trip) do
    trip = ensure_trip_lines(trip)

    []
    |> warn_load_drop_mismatch(trip)
    |> warn_negative_remaining(trip)
    |> warn_missing_agent(trip)
    |> warn_empty_crews(trip)
  end

  # --- helpers ---

  defp authorize(user, action, company) do
    if Authorization.can?(user, action, company), do: :ok, else: :not_authorise
  end

  defp put_company(attrs, company) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "company_id") or Map.has_key?(attrs, :company_id) ->
        attrs

      match?([k | _] when is_binary(k), Map.keys(attrs)) ->
        Map.put(attrs, "company_id", company.id)

      true ->
        Map.put(attrs, :company_id, company.id)
    end
  end

  defp maybe_active_only(query, true), do: from(r in query, where: r.active == true)
  defp maybe_active_only(query, _), do: query

  defp maybe_employee_active_only(query, true) do
    from(e in query, where: e.status == "Active" or is_nil(e.status))
  end

  defp maybe_employee_active_only(query, _), do: query

  defp stringify_attr_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp unwrap_multi({:ok, map}, key), do: {:ok, Map.fetch!(map, key)}

  defp unwrap_multi({:error, key, %Ecto.Changeset{} = cs, _}, key), do: {:error, cs}

  defp unwrap_multi({:error, _step, reason, _}, _key), do: {:error, reason}

  defp preload_trip_result({:ok, trip}) do
    {:ok,
     Repo.preload(trip, [
       :transport_agent,
       loads: [:location, :supply_position, :good, trip_load_employees: :employee],
       drops: [
         :location,
         :sales_position,
         :supply_position,
         :good,
         trip_drop_employees: :employee
       ]
     ])}
  end

  defp preload_trip_result(other), do: other

  # When a load is saved against an open supply, mark that supply as collect
  # (supplier is effectively allowing collection via the trip plan).
  defp maybe_promote_open_supplies_to_collect({:ok, trip}) do
    trip = Repo.preload(trip, :loads)

    supply_ids =
      (trip.loads || [])
      |> Enum.map(& &1.supply_position_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if supply_ids != [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(s in SupplyPosition,
        where: s.id in ^supply_ids and s.status == "open"
      )
      |> Repo.update_all(set: [status: "collect", updated_at: now])
    end

    {:ok, trip}
  end

  defp maybe_promote_open_supplies_to_collect(other), do: other

  defp validate_trip_goods(%Ecto.Changeset{valid?: false} = cs), do: cs

  defp validate_trip_goods(%Ecto.Changeset{} = cs) do
    loads = Ecto.Changeset.get_field(cs, :loads) || []
    drops = Ecto.Changeset.get_field(cs, :drops) || []

    cond do
      Enum.any?(loads, &is_nil(&1.good_id)) ->
        Ecto.Changeset.add_error(cs, :loads, "each load requires a good")

      Enum.any?(drops, &is_nil(&1.good_id)) ->
        Ecto.Changeset.add_error(cs, :drops, "each drop requires a good")

      line_goods_mismatch?(loads, drops) ->
        Ecto.Changeset.add_error(cs, :loads, "good does not match linked supply/sales position")

      true ->
        cs
    end
  end

  defp line_goods_mismatch?(loads, drops) do
    supply_ids =
      (Enum.map(loads, & &1.supply_position_id) ++ Enum.map(drops, & &1.supply_position_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    sales_ids =
      drops
      |> Enum.map(& &1.sales_position_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    supply_goods =
      if supply_ids == [] do
        %{}
      else
        from(s in SupplyPosition, where: s.id in ^supply_ids, select: {s.id, s.good_id})
        |> Repo.all()
        |> Map.new()
      end

    sales_goods =
      if sales_ids == [] do
        %{}
      else
        from(s in SalesPosition, where: s.id in ^sales_ids, select: {s.id, s.good_id})
        |> Repo.all()
        |> Map.new()
      end

    Enum.any?(loads, fn l ->
      is_binary(l.supply_position_id) and
        Map.get(supply_goods, l.supply_position_id) != l.good_id
    end) or
      Enum.any?(drops, fn d ->
        (is_binary(d.sales_position_id) and
           Map.get(sales_goods, d.sales_position_id) != d.good_id) or
          (is_binary(d.supply_position_id) and
             Map.get(supply_goods, d.supply_position_id) != d.good_id)
      end)
  end

  defp missing_actuals?(%Trip{} = trip) do
    loads = trip.loads || []
    drops = trip.drops || []

    Enum.any?(loads, &is_nil(&1.actual_mt)) or Enum.any?(drops, &is_nil(&1.actual_mt)) or
      loads == [] or drops == []
  end

  defp goods_mismatch?(%Trip{} = trip) do
    Enum.any?(trip.loads || [], fn l ->
      is_nil(l.good_id) or
        (match?(%{good_id: _}, l.supply_position) and l.supply_position.good_id != l.good_id)
    end) or
      Enum.any?(trip.drops || [], fn d ->
        is_nil(d.good_id) or
          (match?(%{good_id: _}, d.sales_position) and d.sales_position.good_id != d.good_id) or
          (match?(%{good_id: _}, d.supply_position) and d.supply_position.good_id != d.good_id)
      end)
  end

  defp ensure_trip_lines(%Trip{loads: loads, drops: drops} = trip)
       when is_list(loads) and is_list(drops),
       do: trip

  defp ensure_trip_lines(%Trip{} = trip) do
    Repo.preload(trip,
      loads: [:supply_position, :good, trip_load_employees: :employee],
      drops: [:sales_position, :supply_position, :good, trip_drop_employees: :employee]
    )
  end

  defp warn_load_drop_mismatch(warnings, trip) do
    load_sum = sum_actuals(trip.loads)
    drop_sum = sum_actuals(trip.drops)

    if Decimal.eq?(load_sum, drop_sum) do
      warnings
    else
      ["Load actuals (#{load_sum}) do not equal drop actuals (#{drop_sum})" | warnings]
    end
  end

  defp warn_negative_remaining(warnings, trip) do
    supply_ids =
      (trip.loads || [])
      |> Enum.map(& &1.supply_position_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    negative =
      Enum.any?(supply_ids, fn id ->
        case Repo.get(SupplyPosition, id) do
          nil -> false
          s -> Decimal.compare(Balances.supply_remaining(s), 0) == :lt
        end
      end)

    if negative do
      ["Supply remaining is negative after this trip" | warnings]
    else
      warnings
    end
  end

  defp warn_missing_agent(warnings, trip) do
    if trip.transport_mode == "agent" and is_nil(trip.transport_agent_id) do
      ["Agent transport mode without transport agent" | warnings]
    else
      warnings
    end
  end

  defp warn_empty_crews(warnings, trip) do
    if trip.transport_mode == "company_own" do
      empty_load =
        Enum.any?(trip.loads || [], fn l ->
          employees = Map.get(l, :trip_load_employees) || []
          employees == []
        end)

      empty_drop =
        Enum.any?(trip.drops || [], fn d ->
          employees = Map.get(d, :trip_drop_employees) || []
          employees == []
        end)

      cond do
        empty_load or empty_drop ->
          ["Company-own trip has load/drop lines without employees" | warnings]

        true ->
          warnings
      end
    else
      warnings
    end
  end

  defp sum_actuals(lines) do
    (lines || [])
    |> Enum.reduce(Decimal.new(0), fn line, acc ->
      Decimal.add(acc, line.actual_mt || Decimal.new(0))
    end)
  end
end
