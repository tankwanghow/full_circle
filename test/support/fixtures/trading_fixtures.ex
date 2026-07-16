defmodule FullCircle.TradingFixtures do
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.BillingFixtures

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

  def supply_position_fixture(company, user, attrs \\ %{}) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)

    defaults = %{
      "title" => "supply-#{System.unique_integer([:positive])}",
      "quantity" => "100",
      "unit_price" => "1200",
      "status" => "open",
      "supplier_id" => contact.id,
      "good_id" => good.id
    }

    {:ok, supply} =
      Trading.create_supply_position(Map.merge(defaults, stringify_keys(attrs)), company, user)

    supply
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end

