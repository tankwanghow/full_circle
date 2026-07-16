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

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
