defmodule FullCircle.Trading.TripAssemblyTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances

  setup do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{user: user, company: company}
  end

  test "build_trip_attrs_from_selection prefills loads and drops", %{
    user: user,
    company: company
  } do
    good = good_fixture(company, user)
    supplier = contact_fixture(company, user)
    customer = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "quantity" => "100",
        "status" => "collect"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "25",
        "status" => "open"
      })

    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Asm silo"})

    # Stock into warehouse so on-hand > 0
    port = location_fixture(company, user, %{"kind" => "port"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-01",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    assert {:ok, _, _} = Trading.complete_trip(trip, company, user)

    remaining = Balances.supply_remaining(supply)
    assert Decimal.eq?(remaining, Decimal.new("60"))

    selection = %{
      supply_ids: [supply.id],
      warehouse_load_keys: [%{location_id: wh.id, good_id: good.id}],
      warehouse_drop_keys: [],
      sales_ids: [sales.id]
    }

    assert {:ok, attrs} = Trading.build_trip_attrs_from_selection(selection, company, user)
    # Delivery: supply load + warehouse load-out + sales drop
    assert length(attrs["loads"]) == 2
    assert length(attrs["drops"]) == 1
    assert Enum.all?(attrs["loads"], &(&1["good_id"] == good.id))
    assert Enum.all?(attrs["drops"], &(&1["good_id"] == good.id))

    supply_load = Enum.find(attrs["loads"], &(&1["supply_position_id"] == supply.id))
    assert supply_load["planned_mt"] == Decimal.to_string(remaining)

    wh_load = Enum.find(attrs["loads"], &(&1["location_id"] == wh.id))
    assert wh_load["planned_mt"] == "40"
    assert wh_load["supply_position_id"] == nil

    [drop] = attrs["drops"]
    assert drop["sales_position_id"] == sales.id
    assert drop["planned_mt"] == "25"
  end

  test "incomplete selection errors", %{user: user, company: company} do
    assert {:error, :incomplete_selection} =
             Trading.build_trip_attrs_from_selection(
               %{supply_ids: [], warehouse_keys: [], sales_ids: []},
               company,
               user
             )
  end

  test "mixed: sales drop + warehouse In drop with supply load", %{
    user: user,
    company: company
  } do
    good = good_fixture(company, user)
    customer = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "100",
        "status" => "collect"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "40",
        "status" => "open"
      })

    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Mixed silo"})

    selection = %{
      supply_ids: [supply.id],
      warehouse_load_keys: [],
      warehouse_drop_keys: [%{location_id: wh.id, good_id: good.id}],
      sales_ids: [sales.id]
    }

    assert {:ok, attrs} = Trading.build_trip_attrs_from_selection(selection, company, user)
    assert length(attrs["loads"]) == 1
    assert length(attrs["drops"]) == 2

    assert Enum.any?(attrs["drops"], &(&1["sales_position_id"] == sales.id))
    assert Enum.any?(attrs["drops"], &(&1["location_id"] == wh.id and is_nil(&1["sales_position_id"])))
  end

  test "stock-in selection: supply + warehouse, no sales", %{user: user, company: company} do
    good = good_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "80",
        "status" => "collect"
      })

    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Empty silo"})

    selection = %{
      supply_ids: [supply.id],
      warehouse_load_keys: [],
      warehouse_drop_keys: [%{location_id: wh.id, good_id: nil}],
      sales_ids: []
    }

    assert {:ok, attrs} = Trading.build_trip_attrs_from_selection(selection, company, user)
    assert length(attrs["loads"]) == 1
    assert length(attrs["drops"]) == 1

    [load] = attrs["loads"]
    assert load["supply_position_id"] == supply.id
    assert load["good_id"] == good.id
    assert load["planned_mt"] == "80"

    [drop] = attrs["drops"]
    assert drop["location_id"] == wh.id
    assert drop["sales_position_id"] == nil
    assert drop["supply_position_id"] == supply.id
    assert drop["good_id"] == good.id
    assert drop["planned_mt"] == "80"
  end
end
