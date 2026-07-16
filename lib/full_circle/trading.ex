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
  alias FullCircle.Trading.{Location, SupplyPosition, SalesPosition, Balances}
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

      q =
        from(s in SupplyPosition,
          where: s.company_id == ^company.id,
          preload: [:supplier, :good],
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

  def close_supply_position(%SupplyPosition{} = position, company, user) do
    update_supply_position(position, %{"status" => "closed"}, company, user)
  end

  @doc """
  Position board rows: supply + loaded / remaining / soft_held.
  """
  def position_board(company, user) do
    company
    |> list_supply_positions(user, status: "open")
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
  Open commitments board: draft + open sales with undelivered / soft-hold info.
  """
  def list_open_sales(company, user) do
    if Authorization.can?(user, :view_trading, company) do
      from(s in SalesPosition,
        where: s.company_id == ^company.id and s.status in ["draft", "open"],
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
end
