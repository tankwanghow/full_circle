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
  alias FullCircle.Trading.Location
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
end
