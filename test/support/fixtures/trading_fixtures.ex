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

    {:ok, loc} =
      Trading.create_location(Map.merge(defaults, stringify_keys(attrs)), company, user)

    loc
  end

  def supply_position_fixture(company, user, attrs \\ %{}) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)

    defaults = %{
      "quantity" => "100",
      "unit_price" => "1200",
      "status" => "open",
      "supplier_id" => contact.id,
      "good_id" => good.id
    }

    # title is system-generated (SUP-######); drop if passed so create assigns it
    attrs = stringify_keys(attrs) |> Map.drop(["title"])

    {:ok, supply} =
      Trading.create_supply_position(Map.merge(defaults, attrs), company, user)

    supply
  end

  def sales_position_fixture(company, user, attrs \\ %{}) do
    attrs = stringify_keys(attrs) |> Map.drop(["title"])

    contact =
      if attrs["customer_id"] do
        nil
      else
        contact_fixture(company, user)
      end

    good =
      if attrs["good_id"] do
        nil
      else
        good_fixture(company, user)
      end

    defaults = %{
      "quantity" => "35",
      "unit_price" => "1400",
      "status" => "draft",
      "customer_id" => (contact && contact.id) || attrs["customer_id"],
      "good_id" => (good && good.id) || attrs["good_id"]
    }

    {:ok, sales} =
      Trading.create_sales_position(Map.merge(defaults, attrs), company, user)

    sales
  end

  def trip_fixture(company, user, attrs \\ %{}) do
    # reference_no is system-generated (TRP-######)
    attrs = stringify_keys(attrs) |> Map.drop(["reference_no"])

    good_id =
      attrs["good_id"] ||
        good_fixture(company, user).id

    defaults = %{
      "date" => Date.utc_today() |> Date.to_iso8601(),
      "transport_mode" => "company_own",
      "vehicle_number" => "ABC1234",
      "status" => "draft"
    }

    attrs =
      attrs
      |> Map.put_new("loads", [
        %{
          "planned_mt" => "1",
          "actual_mt" => "1",
          "good_id" => good_id,
          "location_id" =>
            attrs["load_location_id"] || location_fixture(company, user, %{"kind" => "port"}).id
        }
      ])
      |> Map.put_new("drops", [
        %{
          "planned_mt" => "1",
          "actual_mt" => "1",
          "good_id" => good_id,
          "location_id" =>
            attrs["drop_location_id"] ||
              location_fixture(company, user, %{"kind" => "customer_site"}).id
        }
      ])
      |> Map.drop(["good_id", "load_location_id", "drop_location_id"])

    {:ok, trip} =
      Trading.create_trip(Map.merge(defaults, attrs), company, user)

    trip
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
