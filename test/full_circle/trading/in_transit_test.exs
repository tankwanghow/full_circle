defmodule FullCircle.Trading.InTransitTest do
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

  test "draft trip shows sales in transit, supply in transit, warehouse incoming", %{
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
        "quantity" => "50",
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Transit silo"})
    farm = location_fixture(company, user, %{"kind" => "customer_site"})

    assert Decimal.eq?(Balances.sales_in_transit(sales), Decimal.new(0))
    assert Decimal.eq?(Balances.supply_in_transit(supply), Decimal.new(0))

    {:ok, _trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "status" => "draft",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "50",
              "actual_mt" => "50"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => farm.id,
              "sales_position_id" => sales.id,
              "planned_mt" => "30",
              "actual_mt" => "30"
            },
            %{
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "20",
              "actual_mt" => "20"
            }
          ]
        },
        company,
        user
      )

    assert Decimal.eq?(Balances.sales_in_transit(sales), Decimal.new("30"))
    assert Decimal.eq?(Balances.supply_in_transit(supply), Decimal.new("50"))
    # completed stock still zero
    assert Decimal.eq?(Balances.sales_undelivered(sales), Decimal.new("50"))
    assert Decimal.eq?(Balances.supply_remaining(supply), Decimal.new("100"))

    board = Trading.warehouse_board(company, user)
    row = Enum.find(board, &(&1.location.id == wh.id and &1.good && &1.good.id == good.id))
    assert row
    assert Decimal.eq?(row.on_hand, Decimal.new(0))
    assert Decimal.eq?(row.incoming, Decimal.new("20"))
    assert Decimal.eq?(row.outgoing, Decimal.new(0))
  end

  test "planned load from warehouse shows outgoing", %{user: user, company: company} do
    good = good_fixture(company, user)
    customer = contact_fixture(company, user)

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "15",
        "status" => "open"
      })

    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Out silo"})
    farm = location_fixture(company, user, %{"kind" => "customer_site"})
    port = location_fixture(company, user, %{"kind" => "port"})

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "100",
        "status" => "collect"
      })

    # Complete stock-in so warehouse has physical stock
    {:ok, in_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-18",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "40",
              "actual_mt" => "40"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => wh.id,
              "planned_mt" => "40",
              "actual_mt" => "40"
            }
          ]
        },
        company,
        user
      )

    assert {:ok, _, _} = Trading.complete_trip(in_trip, company, user)

    # Draft delivery load out of warehouse
    {:ok, _out_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "status" => "planned",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => wh.id,
              "planned_mt" => "15",
              "actual_mt" => "15"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => farm.id,
              "sales_position_id" => sales.id,
              "planned_mt" => "15",
              "actual_mt" => "15"
            }
          ]
        },
        company,
        user
      )

    board = Trading.warehouse_board(company, user)
    row = Enum.find(board, &(&1.location.id == wh.id and &1.good && &1.good.id == good.id))
    assert row
    assert Decimal.eq?(row.on_hand, Decimal.new("40"))
    assert Decimal.eq?(row.outgoing, Decimal.new("15"))
    assert Decimal.eq?(row.incoming, Decimal.new(0))

    open_out =
      Trading.list_open_trips_for(company, user, :warehouse_outgoing,
        location_id: wh.id,
        good_id: good.id
      )

    assert length(open_out) == 1
    assert Decimal.eq?(hd(open_out).qty, Decimal.new("15"))
  end
end
