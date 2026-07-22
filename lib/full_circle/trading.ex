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

    Location
    |> Repo.get_by!(id: id, company_id: company.id)
    |> Repo.preload(:contact)
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
      |> Multi.run(:ensure_supplier_location, fn _, %{create_supply: supply} ->
        ensure_supplier_site_location(supply.supplier_id, company, user)
      end)
      |> Repo.transaction()
      |> unwrap_multi(:create_supply)
    end
  end

  @doc """
  If the supplier has no linked `supplier_site` location, create a default one
  named with the first 20 characters of the supplier name (no suffix), using the
  contact mailing address as `address_note`.
  """
  def ensure_supplier_site_location(supplier_id, company, user)
      when is_binary(supplier_id) and supplier_id != "" do
    with :ok <- authorize(user, :manage_trading, company) do
      existing =
        list_locations_for_contact(supplier_id, company, user)
        |> Enum.filter(&(&1.kind == "supplier_site"))

      if existing != [] do
        {:ok, :already_present}
      else
        case Repo.get_by(Contact, id: supplier_id, company_id: company.id) do
          nil ->
            {:ok, :no_supplier}

          supplier ->
            attrs = %{
              "name" => contact_site_location_name(supplier),
              "kind" => "supplier_site",
              "contact_id" => supplier.id,
              "address_note" => contact_mailing_address(supplier),
              "active" => true,
              "company_id" => company.id
            }

            case create_location(attrs, company, user) do
              {:ok, loc} -> {:ok, loc}
              {:error, cs} -> {:error, cs}
              :not_authorise -> {:error, :not_authorise}
            end
        end
      end
    end
  end

  def ensure_supplier_site_location(_, _, _), do: {:ok, :skipped}

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
  Autocomplete: active supplies (open/hold/collect) by title or supplier name.
  Value is unique supply title (system no); list shows \"title · supplier\".
  """
  def open_supply_position_names(terms, company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      active = SupplyPosition.active_statuses()
      good_ids = typeahead_good_ids(opts)

      q =
        from(s in SupplyPosition,
          join: c in assoc(s, :supplier),
          where: s.company_id == ^company.id,
          where: s.status in ^active,
          where: not is_nil(s.title) and s.title != "",
          where: ilike(s.title, ^"%#{terms}%") or ilike(c.name, ^"%#{terms}%"),
          select: %{
            id: s.id,
            value: fragment("? || ' · ' || ?", s.title, c.name)
          },
          order_by: [asc: s.title]
        )

      q =
        case good_ids do
          [] -> q
          ids -> from(s in q, where: s.good_id in ^ids)
        end

      Repo.all(q)
    else
      []
    end
  end

  @doc """
  Resolve loadable/active supply by typeahead label or exact title.
  Accepts \"SUP-000001 · Supplier\" or \"SUP-000001\".
  """
  def get_open_supply_position_by_title(label, company, user) do
    title = typeahead_key(label)
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

  @doc "Autocomplete: open sales by title or customer name. Optional `good_id:` filter."
  def open_sales_position_names(terms, company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      active = SalesPosition.active_statuses()
      good_id = Keyword.get(opts, :good_id) |> blank_to_nil()

      q =
        from(s in SalesPosition,
          join: c in assoc(s, :customer),
          where: s.company_id == ^company.id,
          where: s.status in ^active,
          where: not is_nil(s.title) and s.title != "",
          where: ilike(s.title, ^"%#{terms}%") or ilike(c.name, ^"%#{terms}%"),
          select: %{
            id: s.id,
            value: fragment("? || ' · ' || ?", s.title, c.name)
          },
          order_by: [asc: s.title]
        )

      q =
        if good_id do
          from(s in q, where: s.good_id == ^good_id)
        else
          q
        end

      Repo.all(q)
    else
      []
    end
  end

  @doc "Resolve open sales by typeahead label or exact title."
  def get_open_sales_position_by_title(label, company, user) do
    title = typeahead_key(label)
    active = SalesPosition.active_statuses()

    if title == "" or not Authorization.can?(user, :view_trading, company) do
      nil
    else
      from(s in SalesPosition,
        where: s.company_id == ^company.id,
        where: s.status in ^active,
        where: s.title == ^title,
        preload: [:customer, :good]
      )
      |> Repo.one()
    end
  end

  @doc """
  Autocomplete: active trading locations by name or kind.

  Optional `contact_id:` filters to sites linked to that supplier/customer.
  """
  def location_names(terms, company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      contact_id = Keyword.get(opts, :contact_id) |> blank_to_nil()

      q =
        from(l in Location,
          where: l.company_id == ^company.id,
          where: l.active == true,
          where: ilike(l.name, ^"%#{terms}%") or ilike(l.kind, ^"%#{terms}%"),
          select: %{
            id: l.id,
            value: fragment("? || ' (' || ? || ')'", l.name, l.kind)
          },
          order_by: [asc: l.name],
          limit: 40
        )

      q =
        if contact_id do
          from(l in q, where: l.contact_id == ^contact_id)
        else
          q
        end

      Repo.all(q)
    else
      []
    end
  end

  @doc """
  Active locations linked to a contact (supplier/customer sites).
  """
  def list_locations_for_contact(contact_id, company, user)
      when is_binary(contact_id) and contact_id != "" do
    if Authorization.can?(user, :view_trading, company) do
      from(l in Location,
        where: l.company_id == ^company.id,
        where: l.contact_id == ^contact_id,
        where: l.active == true,
        order_by: [asc: l.name]
      )
      |> Repo.all()
    else
      []
    end
  end

  def list_locations_for_contact(_, _, _), do: []

  @doc """
  When the contact has exactly one active location, return it (for auto-select on trip form).
  """
  def sole_location_for_contact(contact_id, company, user) do
    case list_locations_for_contact(contact_id, company, user) do
      [one] -> one
      _ -> nil
    end
  end

  @doc "Resolve location by typeahead label \"Name (kind)\" or exact name."
  def get_location_by_name(label, company, user, opts \\ []) do
    label = label |> to_string() |> String.trim()

    if label == "" or not Authorization.can?(user, :view_trading, company) do
      nil
    else
      {name, kind} = parse_location_label(label)
      contact_id = Keyword.get(opts, :contact_id) |> blank_to_nil()

      q =
        from(l in Location,
          where: l.company_id == ^company.id,
          where: l.active == true,
          where: l.name == ^name
        )

      q =
        if kind do
          from(l in q, where: l.kind == ^kind)
        else
          q
        end

      q =
        if contact_id do
          from(l in q, where: l.contact_id == ^contact_id)
        else
          q
        end

      Repo.one(from(l in q, order_by: [asc: l.name], limit: 1))
    end
  end

  defp typeahead_key(label) do
    label
    |> to_string()
    |> String.trim()
    |> String.split(" · ")
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp parse_location_label(label) do
    case Regex.run(~r/^(.*)\s+\(([^)]+)\)\s*$/, label) do
      [_, name, kind] -> {String.trim(name), String.trim(kind)}
      _ -> {label, nil}
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
      |> Multi.run(:ensure_customer_location, fn _, %{create_sales: sales} ->
        ensure_customer_delivery_location(sales.customer_id, company, user)
      end)
      |> Repo.transaction()
      |> unwrap_multi(:create_sales)
    end
  end

  @doc """
  If the customer has no linked delivery location, create a default `customer_site`
  named with the first 20 characters of the customer name (no suffix), using the
  contact mailing address as `address_note`.
  """
  def ensure_customer_delivery_location(customer_id, company, user)
      when is_binary(customer_id) and customer_id != "" do
    with :ok <- authorize(user, :manage_trading, company) do
      existing =
        list_locations_for_contact(customer_id, company, user)
        |> Enum.filter(&(&1.kind == "customer_site"))

      if existing != [] do
        {:ok, :already_present}
      else
        case Repo.get_by(Contact, id: customer_id, company_id: company.id) do
          nil ->
            {:ok, :no_customer}

          customer ->
            attrs = %{
              "name" => contact_site_location_name(customer),
              "kind" => "customer_site",
              "contact_id" => customer.id,
              "address_note" => contact_mailing_address(customer),
              "active" => true,
              "company_id" => company.id
            }

            case create_location(attrs, company, user) do
              {:ok, loc} -> {:ok, loc}
              {:error, cs} -> {:error, cs}
              :not_authorise -> {:error, :not_authorise}
            end
        end
      end
    end
  end

  def ensure_customer_delivery_location(_, _, _), do: {:ok, :skipped}

  defp contact_site_location_name(%{name: name}) do
    name
    |> to_string()
    |> String.trim()
    |> String.slice(0, 20)
  end

  defp contact_mailing_address(%Contact{} = c) do
    [c.address1, c.address2, c.city, c.state, c.zipcode, c.country]
    |> Enum.map(fn
      nil -> ""
      v -> v |> to_string() |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      addr -> addr
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

  @doc """
  Trip-level movement history for a supply (one row per trip).

  Each row pairs loads **from** this supply with drops **drawing** this supply:
  `%{trip_id, date, reference_no, status, vehicle_number, unit,
    loads: [%{place, qty}], drops: [%{place, qty}], notes}`.
  """
  def list_supply_line_history(supply_id, company, user)
      when is_binary(supply_id) do
    if Authorization.can?(user, :view_trading, company) do
      loads =
        from(l in TripLoad,
          join: t in Trip,
          on: t.id == l.trip_id,
          left_join: loc in Location,
          on: loc.id == l.location_id,
          left_join: g in FullCircle.Product.Good,
          on: g.id == l.good_id,
          where: t.company_id == ^company.id and l.supply_position_id == ^supply_id,
          order_by: [asc: l.seq],
          select: %{
            trip_id: t.id,
            date: t.date,
            reference_no: t.reference_no,
            status: t.status,
            vehicle_number: t.vehicle_number,
            inserted_at: t.inserted_at,
            location_name: loc.name,
            unit: g.unit,
            planned_mt: l.planned_mt,
            actual_mt: l.actual_mt,
            notes: l.location_note
          }
        )
        |> Repo.all()

      drops =
        from(d in TripDrop,
          join: t in Trip,
          on: t.id == d.trip_id,
          left_join: loc in Location,
          on: loc.id == d.location_id,
          left_join: g in FullCircle.Product.Good,
          on: g.id == d.good_id,
          left_join: s in SalesPosition,
          on: s.id == d.sales_position_id,
          left_join: c in Contact,
          on: c.id == s.customer_id,
          where: t.company_id == ^company.id and d.supply_position_id == ^supply_id,
          order_by: [asc: d.seq],
          select: %{
            trip_id: t.id,
            date: t.date,
            reference_no: t.reference_no,
            status: t.status,
            vehicle_number: t.vehicle_number,
            inserted_at: t.inserted_at,
            location_name: loc.name,
            unit: g.unit,
            party_name: fragment("coalesce(?, ?)", c.name, s.title),
            planned_mt: d.planned_mt,
            actual_mt: d.actual_mt,
            notes: fragment("coalesce(?, ?)", d.variance_note, d.location_note)
          }
        )
        |> Repo.all()

      merge_trip_movements(loads, drops)
    else
      []
    end
  end

  def list_supply_line_history(_, _, _), do: []

  @doc """
  Trip-level movement history for a sales position (one row per trip).

  Each row pairs the trip’s load locations with drops **to** this sales:
  `%{trip_id, date, reference_no, status, vehicle_number, unit,
    loads: [%{place, qty}], drops: [%{place, qty}], notes}`.
  """
  def list_sales_line_history(sales_id, company, user) when is_binary(sales_id) do
    if Authorization.can?(user, :view_trading, company) do
      drops =
        from(d in TripDrop,
          join: t in Trip,
          on: t.id == d.trip_id,
          left_join: loc in Location,
          on: loc.id == d.location_id,
          left_join: g in FullCircle.Product.Good,
          on: g.id == d.good_id,
          left_join: sp in SupplyPosition,
          on: sp.id == d.supply_position_id,
          where: t.company_id == ^company.id and d.sales_position_id == ^sales_id,
          order_by: [asc: d.seq],
          select: %{
            trip_id: t.id,
            date: t.date,
            reference_no: t.reference_no,
            status: t.status,
            vehicle_number: t.vehicle_number,
            inserted_at: t.inserted_at,
            location_name: loc.name,
            unit: g.unit,
            party_name: sp.title,
            planned_mt: d.planned_mt,
            actual_mt: d.actual_mt,
            notes: fragment("coalesce(?, ?)", d.variance_note, d.location_note)
          }
        )
        |> Repo.all()

      trip_ids = drops |> Enum.map(& &1.trip_id) |> Enum.uniq()

      loads =
        if trip_ids == [] do
          []
        else
          from(l in TripLoad,
            join: t in Trip,
            on: t.id == l.trip_id,
            left_join: loc in Location,
            on: loc.id == l.location_id,
            left_join: g in FullCircle.Product.Good,
            on: g.id == l.good_id,
            where: t.id in ^trip_ids,
            order_by: [asc: l.seq],
            select: %{
              trip_id: t.id,
              date: t.date,
              reference_no: t.reference_no,
              status: t.status,
              vehicle_number: t.vehicle_number,
              inserted_at: t.inserted_at,
              location_name: loc.name,
              unit: g.unit,
              planned_mt: l.planned_mt,
              actual_mt: l.actual_mt,
              notes: l.location_note
            }
          )
          |> Repo.all()
        end

      merge_trip_movements(loads, drops)
    else
      []
    end
  end

  def list_sales_line_history(_, _, _), do: []

  @doc """
  Recent load/drop movements for an own-warehouse location (optionally × good).

  Returns at most `limit` rows (default 20), newest first. Each row:
  `%{kind: "in" | "out", line_id, trip_id, date, reference_no, status,
    vehicle_number, qty, unit, good_name, notes}`.

  - **in**  — drop into this warehouse (stock-in)
  - **out** — load out of this warehouse

  Designed for large tables: each side is queried with SQL `LIMIT`, then merged.
  """
  def list_warehouse_recent_movements(location_id, good_id, company, user, opts \\ [])

  def list_warehouse_recent_movements(location_id, good_id, company, user, opts)
      when is_binary(location_id) do
    if Authorization.can?(user, :view_trading, company) do
      limit = Keyword.get(opts, :limit, 20) |> max(1) |> min(50)
      # Fetch recent of each direction, then keep the newest `limit` overall.
      per_side = limit

      outs =
        warehouse_movement_query(
          :out,
          location_id,
          good_id,
          company.id,
          per_side
        )

      ins =
        warehouse_movement_query(
          :in,
          location_id,
          good_id,
          company.id,
          per_side
        )

      (outs ++ ins)
      |> Enum.sort_by(
        &{&1.date || ~D[1970-01-01], &1.inserted_at || ~U[1970-01-01 00:00:00Z]},
        :desc
      )
      |> Enum.take(limit)
    else
      []
    end
  end

  def list_warehouse_recent_movements(_, _, _, _, _), do: []

  defp warehouse_movement_query(:out, location_id, good_id, company_id, limit) do
    q =
      from(l in TripLoad,
        join: t in Trip,
        on: t.id == l.trip_id,
        left_join: g in FullCircle.Product.Good,
        on: g.id == l.good_id,
        where: t.company_id == ^company_id and l.location_id == ^location_id,
        order_by: [desc: t.date, desc: t.inserted_at],
        limit: ^limit,
        select: %{
          kind: "out",
          line_id: l.id,
          trip_id: t.id,
          date: t.date,
          reference_no: t.reference_no,
          status: t.status,
          vehicle_number: t.vehicle_number,
          inserted_at: t.inserted_at,
          qty: fragment("coalesce(?, ?)", l.actual_mt, l.planned_mt),
          unit: g.unit,
          good_name: g.name,
          notes: l.location_note
        }
      )

    q =
      if warehouse_good_filter?(good_id) do
        from([l, t, g] in q, where: l.good_id == ^good_id)
      else
        q
      end

    q
    |> Repo.all()
    |> Enum.map(&Map.update!(&1, :qty, fn qty -> open_trip_qty_to_dec(qty) end))
  end

  defp warehouse_movement_query(:in, location_id, good_id, company_id, limit) do
    q =
      from(d in TripDrop,
        join: t in Trip,
        on: t.id == d.trip_id,
        left_join: g in FullCircle.Product.Good,
        on: g.id == d.good_id,
        where: t.company_id == ^company_id and d.location_id == ^location_id,
        order_by: [desc: t.date, desc: t.inserted_at],
        limit: ^limit,
        select: %{
          kind: "in",
          line_id: d.id,
          trip_id: t.id,
          date: t.date,
          reference_no: t.reference_no,
          status: t.status,
          vehicle_number: t.vehicle_number,
          inserted_at: t.inserted_at,
          qty: fragment("coalesce(?, ?)", d.actual_mt, d.planned_mt),
          unit: g.unit,
          good_name: g.name,
          notes: fragment("coalesce(?, ?)", d.variance_note, d.location_note)
        }
      )

    q =
      if warehouse_good_filter?(good_id) do
        from([d, t, g] in q, where: d.good_id == ^good_id)
      else
        q
      end

    q
    |> Repo.all()
    |> Enum.map(&Map.update!(&1, :qty, fn qty -> open_trip_qty_to_dec(qty) end))
  end

  defp warehouse_good_filter?(good_id)
       when is_binary(good_id) and good_id != "" and good_id != "any",
       do: true

  defp warehouse_good_filter?(_), do: false

  # Pair load/drop lines by trip_id into one display row each.
  defp merge_trip_movements(loads, drops) do
    load_by_trip = Enum.group_by(loads, & &1.trip_id)
    drop_by_trip = Enum.group_by(drops, & &1.trip_id)

    (Map.keys(load_by_trip) ++ Map.keys(drop_by_trip))
    |> Enum.uniq()
    |> Enum.map(fn trip_id ->
      trip_loads = Map.get(load_by_trip, trip_id, [])
      trip_drops = Map.get(drop_by_trip, trip_id, [])
      head = List.first(trip_loads) || List.first(trip_drops)

      unit =
        (trip_loads ++ trip_drops)
        |> Enum.map(& &1.unit)
        |> Enum.find(&(is_binary(&1) and &1 != ""))

      %{
        trip_id: trip_id,
        date: head.date,
        reference_no: head.reference_no,
        status: head.status,
        vehicle_number: head.vehicle_number,
        inserted_at: head.inserted_at,
        unit: unit,
        loads: format_side_parts(trip_loads, :load),
        drops: format_side_parts(trip_drops, :drop),
        notes: combine_notes(trip_loads ++ trip_drops)
      }
    end)
    |> Enum.sort_by(&{&1.date || ~D[1970-01-01], &1.inserted_at}, :desc)
  end

  defp format_side_parts([], _), do: []

  defp format_side_parts(lines, :load) do
    Enum.map(lines, fn l ->
      %{place: l.location_name || "?", qty: effective_mt(l)}
    end)
  end

  defp format_side_parts(lines, :drop) do
    Enum.map(lines, fn d ->
      # Drop destination: location name only (not customer/sales title)
      %{place: d.location_name || "?", qty: effective_mt(d)}
    end)
  end

  defp effective_mt(%{actual_mt: %Decimal{} = a}), do: Decimal.to_string(a)
  defp effective_mt(%{planned_mt: %Decimal{} = p}), do: Decimal.to_string(p)
  defp effective_mt(%{actual_mt: a}) when not is_nil(a), do: to_string(a)
  defp effective_mt(%{planned_mt: p}) when not is_nil(p), do: to_string(p)
  defp effective_mt(_), do: nil

  defp combine_notes(lines) do
    lines
    |> Enum.map(& &1.notes)
    |> Enum.filter(&present_str?/1)
    |> Enum.uniq()
    |> Enum.join("; ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp present_str?(nil), do: false
  defp present_str?(""), do: false
  defp present_str?(_), do: true

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
          supply_position: :supplier,
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

      load_loc = default_load_location(company, user)
      load_loc_id = load_loc && load_loc.id

      loads =
        Enum.map(supplies, fn s ->
          s
          |> supply_load_attrs(company, user)
          |> then(fn attrs ->
            if is_nil(attrs["location_id"]) and load_loc_id do
              attrs
              |> Map.put("location_id", load_loc_id)
              |> Map.put("location_name", location_typeahead_label(load_loc))
            else
              put_location_typeahead_name(attrs)
            end
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

      drops =
        (sales_drops ++ warehouse_drops)
        |> Enum.map(&put_location_typeahead_name/1)
        |> Enum.map(&put_supply_typeahead_title(&1, supplies))

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
                "location_name" => location_name_by_id(loc_id),
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

      preferred =
        s.preferred_supply_id &&
          Enum.find(same_good_supplies, &(&1.id == s.preferred_supply_id))

      supply =
        cond do
          preferred -> preferred
          match?([_], same_good_supplies) -> hd(same_good_supplies)
          true -> nil
        end

      loc = customer_site_location(company, user, s.customer_id)

      %{
        "planned_mt" => mt,
        "actual_mt" => mt,
        "good_id" => s.good_id,
        "good_name" => good && good.name,
        "sales_position_id" => s.id,
        "sales_title" => sales_typeahead_label(s),
        "supply_position_id" => supply && supply.id,
        "supply_title" => supply && supply_typeahead_label(supply),
        "party_contact_id" => s.customer_id,
        "location_id" => loc && loc.id,
        "location_name" => loc && location_typeahead_label(loc)
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
              "location_name" => location_name_by_id(loc_id),
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
      "location_name" => location_name_by_id(loc_id),
      "sales_position_id" => nil,
      "supply_position_id" => s.id,
      "supply_title" => supply_typeahead_label(s)
    }
  end

  defp supply_load_attrs(s, company, user) do
    mt = Balances.supply_remaining(s) |> decimal_str()
    good = s.good || Repo.get!(FullCircle.Product.Good, s.good_id)
    supplier_id = s.supplier_id
    loc = supplier_site_location(company, user, supplier_id)

    %{
      "planned_mt" => mt,
      "actual_mt" => mt,
      "good_id" => s.good_id,
      "good_name" => good && good.name,
      "supply_position_id" => s.id,
      "supply_title" => supply_typeahead_label(s),
      "party_contact_id" => supplier_id,
      "location_id" => loc && loc.id,
      "location_name" => loc && location_typeahead_label(loc)
    }
  end

  defp default_load_location(company, user) do
    company
    |> list_locations(user, active_only: true)
    |> Enum.find(&(&1.kind in ~w(port supplier_site)))
  end

  defp location_typeahead_label(%{name: name, kind: kind}) when is_binary(name),
    do: if(kind && kind != "", do: "#{name} (#{kind})", else: name)

  defp location_typeahead_label(_), do: nil

  defp supply_typeahead_label(%{title: title, supplier: %{name: sn}}) when is_binary(title),
    do: "#{title} · #{sn}"

  defp supply_typeahead_label(%{title: title}) when is_binary(title), do: title
  defp supply_typeahead_label(_), do: nil

  defp sales_typeahead_label(%{title: title, customer: %{name: cn}}) when is_binary(title),
    do: "#{title} · #{cn}"

  defp sales_typeahead_label(%{title: title}) when is_binary(title), do: title
  defp sales_typeahead_label(_), do: nil

  defp location_name_by_id(nil), do: nil

  defp location_name_by_id(id) do
    case Repo.get(Location, id) do
      nil -> nil
      loc -> location_typeahead_label(loc)
    end
  end

  defp put_location_typeahead_name(%{"location_name" => name} = attrs)
       when is_binary(name) and name != "",
       do: attrs

  defp put_location_typeahead_name(%{"location_id" => id} = attrs)
       when is_binary(id) and id != "" do
    Map.put(attrs, "location_name", location_name_by_id(id))
  end

  defp put_location_typeahead_name(attrs), do: attrs

  defp put_supply_typeahead_title(%{"supply_title" => t} = attrs, _supplies)
       when is_binary(t) and t != "",
       do: attrs

  defp put_supply_typeahead_title(%{"supply_position_id" => id} = attrs, supplies)
       when is_binary(id) and id != "" do
    case Enum.find(supplies, &(&1.id == id)) do
      nil -> attrs
      s -> Map.put(attrs, "supply_title", supply_typeahead_label(s))
    end
  end

  defp put_supply_typeahead_title(attrs, _supplies), do: attrs

  defp base_trip_attrs(loads, drops) do
    %{
      "date" => Date.utc_today() |> Date.to_iso8601(),
      "status" => "draft",
      "transport_mode" => "company_own",
      "loads" => stamp_line_seq(loads),
      "drops" => stamp_line_seq(drops)
    }
  end

  defp stamp_line_seq(lines) when is_list(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, i} ->
      line
      |> stringify_attr_keys()
      |> Map.put("seq", i)
    end)
  end

  defp stamp_line_seq(lines), do: lines

  defp warehouse_on_hand(location_id, good_id)
       when is_binary(location_id) and is_binary(good_id) do
    inbound = Map.get(Balances.own_warehouse_inbound_by_good(location_id), good_id, Decimal.new(0))
    outbound = Map.get(Balances.own_warehouse_outbound_by_good(location_id), good_id, Decimal.new(0))
    Decimal.sub(inbound, outbound)
  end

  defp warehouse_on_hand(_, _), do: Decimal.new(0)

  defp customer_site_location(company, user, customer_id)
       when is_binary(customer_id) do
    linked = list_locations_for_contact(customer_id, company, user)

    case linked do
      [one] ->
        one

      many when is_list(many) and many != [] ->
        Enum.find(many, &(&1.kind == "customer_site")) || hd(many)

      _ ->
        # Fallback: match location name to customer name (legacy rows without contact_id)
        locs = list_locations(company, user, active_only: true)

        case Repo.get(Contact, customer_id) do
          %{name: name} when is_binary(name) and name != "" ->
            down = String.downcase(name)

            Enum.find(locs, fn l ->
              l.kind == "customer_site" and is_binary(l.name) and
                String.contains?(String.downcase(l.name), down)
            end)

          _ ->
            nil
        end
    end
  end

  defp customer_site_location(_, _, _), do: nil

  defp supplier_site_location(company, user, supplier_id)
       when is_binary(supplier_id) do
    linked = list_locations_for_contact(supplier_id, company, user)

    case linked do
      [one] ->
        one

      many when is_list(many) and many != [] ->
        Enum.find(many, &(&1.kind == "supplier_site")) ||
          Enum.find(many, &(&1.kind == "port")) || hd(many)

      _ ->
        nil
    end
  end

  defp supplier_site_location(_, _, _), do: nil

  defp decimal_str(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_str(n) when is_integer(n), do: Integer.to_string(n)
  defp decimal_str(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp decimal_str(nil), do: "0"
  defp decimal_str(other), do: to_string(other)

  def create_trip(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
      attrs = stringify_attr_keys(attrs)

      Multi.new()
      |> get_gapless_doc_id(gapless_name, "TradingTrip", "TRP", company)
      |> Multi.insert(:create_trip, fn %{^gapless_name => doc} ->
        attrs
        |> put_company(company)
        |> Map.put("reference_no", doc)
        |> then(&Trip.changeset(%Trip{}, &1))
        |> validate_trip_goods()
      end)
      |> Multi.insert(:create_trip_log, fn %{create_trip: entity} ->
        Sys.log_changeset(
          :create_trip,
          entity,
          trip_log_attrs(
            attrs
            |> put_company(company)
            |> Map.put("reference_no", entity.reference_no)
          ),
          company,
          user
        )
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

        cs =
          trip
          |> Repo.preload([:loads, :drops])
          |> Trip.changeset(attrs)
          |> validate_trip_goods()

        Multi.new()
        |> Multi.update(:update_trip, cs)
        |> Multi.insert(:update_trip_log, fn %{update_trip: entity} ->
          Sys.log_changeset(:update_trip, entity, trip_log_attrs(attrs), company, user)
        end)
        |> Repo.transaction()
        |> unwrap_multi(:update_trip)
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
          Multi.new()
          |> Multi.update(:complete_trip, Ecto.Changeset.change(trip, %{status: "completed"}))
          |> Multi.insert(:complete_trip_log, fn %{complete_trip: entity} ->
            Sys.log_changeset(
              :complete_trip,
              entity,
              trip_lifecycle_log_attrs(trip, "completed"),
              company,
              user
            )
          end)
          |> Repo.transaction()
          |> case do
            {:ok, _} ->
              trip = get_trip!(trip.id, company, user)
              {:ok, trip, trip_warnings(trip)}

            {:error, :complete_trip, %Ecto.Changeset{} = cs, _} ->
              {:error, cs}

            {:error, _step, reason, _} ->
              {:error, reason}
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
          Multi.new()
          |> Multi.update(:cancel_trip, Ecto.Changeset.change(trip, %{status: "cancelled"}))
          |> Multi.insert(:cancel_trip_log, fn %{cancel_trip: entity} ->
            Sys.log_changeset(
              :cancel_trip,
              entity,
              trip_lifecycle_log_attrs(trip, "cancelled"),
              company,
              user
            )
          end)
          |> Repo.transaction()
          |> case do
            {:ok, _} ->
              {:ok, get_trip!(trip.id, company, user)}

            {:error, :cancel_trip, %Ecto.Changeset{} = cs, _} ->
              {:error, cs}

            {:error, _step, reason, _} ->
              {:error, reason}
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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(_), do: nil

  # Accept `good_id:` and/or `good_ids:` (list or comma-separated string).
  defp typeahead_good_ids(opts) when is_list(opts) do
    from_list =
      case Keyword.get(opts, :good_ids) do
        ids when is_list(ids) -> ids
        s when is_binary(s) and s != "" -> String.split(s, ",", trim: true)
        _ -> []
      end

    single = Keyword.get(opts, :good_id) |> blank_to_nil()

    ([single] ++ from_list)
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp typeahead_good_ids(_), do: []

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

  # Snapshot attrs for Sys.Log (readable names + MT; `_id` keys stripped by Sys.attr_to_string).
  defp trip_log_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.take([
      "date",
      "transport_mode",
      "status",
      "notes",
      "reference_no",
      "vehicle_number",
      "transport_agent_name",
      "loads",
      "drops"
    ])
    |> Map.update("loads", %{}, &normalize_log_lines/1)
    |> Map.update("drops", %{}, &normalize_log_lines/1)
  end

  defp trip_lifecycle_log_attrs(%Trip{} = trip, status) do
    %{
      "status" => status,
      "reference_no" => trip.reference_no,
      "date" => trip.date && Date.to_iso8601(trip.date),
      "transport_mode" => trip.transport_mode,
      "vehicle_number" => trip.vehicle_number,
      "transport_agent_name" => trip.transport_agent && trip.transport_agent.name,
      "notes" => trip.notes,
      "loads" => snapshot_lines(trip.loads || [], :load),
      "drops" => snapshot_lines(trip.drops || [], :drop)
    }
  end

  defp normalize_log_lines(lines) when is_map(lines) do
    Map.new(lines, fn {k, line} ->
      {to_string(k), take_line_log_fields(stringify_attr_keys(line))}
    end)
  end

  defp normalize_log_lines(lines) when is_list(lines) do
    lines
    |> Enum.with_index()
    |> Map.new(fn {line, i} ->
      {"#{i}", take_line_log_fields(stringify_attr_keys(line))}
    end)
  end

  defp normalize_log_lines(_), do: %{}

  defp take_line_log_fields(line) when is_map(line) do
    Map.take(line, [
      "seq",
      "planned_mt",
      "actual_mt",
      "location_note",
      "variance_note",
      "good_name",
      "location_name",
      "supply_title",
      "sales_title"
    ])
  end

  defp take_line_log_fields(_), do: %{}

  defp snapshot_lines(lines, kind) do
    lines
    |> Enum.with_index()
    |> Map.new(fn {line, i} ->
      base = %{
        "seq" => line.seq && to_string(line.seq),
        "planned_mt" => decimal_str(line.planned_mt),
        "actual_mt" => decimal_str(line.actual_mt),
        "location_note" => line.location_note,
        "good_name" => assoc_name(line, :good),
        "location_name" => assoc_name(line, :location),
        "supply_title" => assoc_title(line, :supply_position)
      }

      fields =
        if kind == :drop do
          base
          |> Map.put("variance_note", line.variance_note)
          |> Map.put("sales_title", assoc_title(line, :sales_position))
        else
          base
        end

      {"#{i}", fields}
    end)
  end

  defp assoc_name(line, key) do
    case Map.get(line, key) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp assoc_title(line, key) do
    case Map.get(line, key) do
      %{title: title} -> title
      _ -> nil
    end
  end

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
