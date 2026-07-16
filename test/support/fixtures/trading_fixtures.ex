defmodule FullCircle.TradingFixtures do
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  alias FullCircle.Trading

  def trading_setup do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{admin: admin, company: company}
  end

  def location_fixture(company, user, attrs \\ %{}) do
    defaults = %{
      "name" => "loc-#{System.unique_integer([:positive])}",
      "kind" => "own_warehouse",
      "active" => true
    }

    {:ok, loc} = Trading.create_location(Map.merge(defaults, stringify_keys(attrs)), company, user)
    loc
  end

  def driver_fixture(company, user, attrs \\ %{}) do
    defaults = %{
      "name" => "driver-#{System.unique_integer([:positive])}",
      "active" => true
    }

    {:ok, driver} = Trading.create_driver(Map.merge(defaults, stringify_keys(attrs)), company, user)
    driver
  end

  def transport_agent_fixture(company, user, attrs \\ %{}) do
    defaults = %{
      "name" => "agent-#{System.unique_integer([:positive])}",
      "active" => true
    }

    {:ok, agent} =
      Trading.create_transport_agent(Map.merge(defaults, stringify_keys(attrs)), company, user)

    agent
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
