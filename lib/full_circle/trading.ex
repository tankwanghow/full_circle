defmodule FullCircle.Trading do
  @moduledoc """
  Grain trading desk: masters, supply/sales positions, trips, and settlement helpers.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Authorization
  alias FullCircle.Trading.{Location, Driver, TransportAgent}

  # --- Locations ---

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

  # --- Drivers ---

  def list_drivers(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      active_only? = Keyword.get(opts, :active_only, false)

      from(d in Driver,
        where: d.company_id == ^company.id,
        order_by: [asc: d.name]
      )
      |> maybe_active_only(active_only?)
      |> Repo.all()
    else
      []
    end
  end

  def get_driver!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")
    Repo.get_by!(Driver, id: id, company_id: company.id)
  end

  def create_driver(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      %Driver{}
      |> Driver.changeset(put_company(attrs, company))
      |> Repo.insert()
    end
  end

  def update_driver(%Driver{} = driver, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- driver.company_id == company.id do
      driver
      |> Driver.changeset(attrs)
      |> Repo.update()
    else
      false -> :not_authorise
      other -> other
    end
  end

  # --- Transport agents ---

  def list_transport_agents(company, user, opts \\ []) do
    if Authorization.can?(user, :view_trading, company) do
      active_only? = Keyword.get(opts, :active_only, false)

      from(a in TransportAgent,
        where: a.company_id == ^company.id,
        order_by: [asc: a.name]
      )
      |> maybe_active_only(active_only?)
      |> Repo.all()
    else
      []
    end
  end

  def get_transport_agent!(id, company, user) do
    unless Authorization.can?(user, :view_trading, company), do: raise("not authorised")
    Repo.get_by!(TransportAgent, id: id, company_id: company.id)
  end

  def create_transport_agent(attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company) do
      %TransportAgent{}
      |> TransportAgent.changeset(put_company(attrs, company))
      |> Repo.insert()
    end
  end

  def update_transport_agent(%TransportAgent{} = agent, attrs, company, user) do
    with :ok <- authorize(user, :manage_trading, company),
         true <- agent.company_id == company.id do
      agent
      |> TransportAgent.changeset(attrs)
      |> Repo.update()
    else
      false -> :not_authorise
      other -> other
    end
  end

  # --- helpers ---

  defp authorize(user, action, company) do
    if Authorization.can?(user, action, company), do: :ok, else: :not_authorise
  end

  defp put_company(attrs, company) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "company_id") or Map.has_key?(attrs, :company_id) ->
        attrs

      is_map_key_string_map?(attrs) ->
        Map.put(attrs, "company_id", company.id)

      true ->
        Map.put(attrs, :company_id, company.id)
    end
  end

  defp is_map_key_string_map?(attrs) do
    case Enum.at(Map.keys(attrs), 0) do
      key when is_binary(key) -> true
      _ -> false
    end
  end

  defp maybe_active_only(query, true), do: from(r in query, where: r.active == true)
  defp maybe_active_only(query, _), do: query
end
