defmodule FullCircle.Trading do
  @moduledoc """
  Grain trading desk.

  Masters:
  - **Location** — new `trading_locations` table (physical load/drop sites)
  - **Driver** — existing `employees` (HR)
  - **Transport agent** — existing `contacts` (Accounting)
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Authorization
  alias FullCircle.Trading.{Location, SupplyPosition, SalesPosition, Balances, Trip}
  alias FullCircle.HR.Employee
  alias FullCircle.Accounting.Contact
  alias FullCircle.Sys

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
      %SupplyPosition{}
      |> SupplyPosition.changeset(put_company(attrs, company))
      |> Repo.insert()
    end
  end

  def update_supply_position(%SupplyPosition{} = position, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- position.company_id == company.id do
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
  Position board rows: active supplies (open/hold/collect) + loaded / remaining / soft_held.
  """
  def position_board(company, user) do
    company
    |> list_supply_positions(user, statuses: SupplyPosition.active_statuses())
    |> Enum.map(fn s ->
      %{
        supply: s,
        loaded: Balances.supply_loaded(s),
        remaining: Balances.supply_remaining(s),
        soft_held: Balances.soft_held_for_supply(s.id)
      }
    end)
  end

  # --- Sales positions ---

  def list_sales_positions(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      status = Keyword.get(opts, :status)

      q =
        from(s in SalesPosition,
          where: s.company_id == ^company.id,
          preload: [:customer, :good, :preferred_supply],
          order_by: [desc: s.inserted_at]
        )

      q =
        if status do
          from(s in q, where: s.status == ^status)
        else
          q
        end

      Repo.all(q)
    else
      []
    end
  end

  @doc """
  Open commitments board: draft + open + hold sales with undelivered / soft-hold info.
  """
  def list_open_sales(company, user) do
    if Authorization.can?(user, :view_trading, company) do
      active = SalesPosition.active_statuses()

      from(s in SalesPosition,
        where: s.company_id == ^company.id and s.status in ^active,
        preload: [:customer, :good, :preferred_supply],
        order_by: [desc: s.inserted_at]
      )
      |> Repo.all()
    else
      []
    end
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
      %SalesPosition{}
      |> SalesPosition.changeset(put_company(attrs, company))
      |> Repo.insert()
    end
  end

  def update_sales_position(%SalesPosition{} = position, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- position.company_id == company.id do
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
            :good,
            :transport_agent,
            loads: [:location, :supply_position],
            drops: [:location, :sales_position]
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

  def get_trip!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")

    from(t in Trip,
      where: t.id == ^id and t.company_id == ^company.id,
      preload: [
        :good,
        :transport_agent,
        loads: [:location, :supply_position, trip_load_employees: :employee],
        drops: [:location, :sales_position, :supply_position, trip_drop_employees: :employee]
      ]
    )
    |> Repo.one!()
  end

  def create_trip(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      %Trip{}
      |> Trip.changeset(put_company(attrs, company))
      |> validate_trip_goods()
      |> Repo.insert()
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

  defp preload_trip_result({:ok, trip}) do
    {:ok,
     Repo.preload(trip, [
       :good,
       :transport_agent,
       loads: [:location, :supply_position, trip_load_employees: :employee],
       drops: [:location, :sales_position, :supply_position, trip_drop_employees: :employee]
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
    good_id = Ecto.Changeset.get_field(cs, :good_id)
    loads = Ecto.Changeset.get_field(cs, :loads) || []
    drops = Ecto.Changeset.get_field(cs, :drops) || []

    if is_nil(good_id) do
      cs
    else
      supply_ids =
        loads
        |> Enum.map(& &1.supply_position_id)
        |> Enum.reject(&is_nil/1)

      sales_ids =
        drops
        |> Enum.map(& &1.sales_position_id)
        |> Enum.reject(&is_nil/1)

      bad_supply =
        if supply_ids == [] do
          false
        else
          from(s in SupplyPosition, where: s.id in ^supply_ids and s.good_id != ^good_id)
          |> Repo.exists?()
        end

      bad_sales =
        if sales_ids == [] do
          false
        else
          from(s in SalesPosition, where: s.id in ^sales_ids and s.good_id != ^good_id)
          |> Repo.exists?()
        end

      cond do
        bad_supply ->
          Ecto.Changeset.add_error(cs, :good_id, "does not match supply position product")

        bad_sales ->
          Ecto.Changeset.add_error(cs, :good_id, "does not match sales position product")

        true ->
          cs
      end
    end
  end

  defp missing_actuals?(%Trip{} = trip) do
    loads = trip.loads || []
    drops = trip.drops || []

    Enum.any?(loads, &is_nil(&1.actual_mt)) or Enum.any?(drops, &is_nil(&1.actual_mt)) or
      loads == [] or drops == []
  end

  defp goods_mismatch?(%Trip{} = trip) do
    good_id = trip.good_id

    Enum.any?(trip.loads || [], fn l ->
      l.supply_position && l.supply_position.good_id != good_id
    end) or
      Enum.any?(trip.drops || [], fn d ->
        d.sales_position && d.sales_position.good_id != good_id
      end)
  end

  defp ensure_trip_lines(%Trip{loads: loads, drops: drops} = trip)
       when is_list(loads) and is_list(drops),
       do: trip

  defp ensure_trip_lines(%Trip{} = trip) do
    Repo.preload(trip,
      loads: [:supply_position, trip_load_employees: :employee],
      drops: [:sales_position, trip_drop_employees: :employee]
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
