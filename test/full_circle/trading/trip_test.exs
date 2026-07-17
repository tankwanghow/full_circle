defmodule FullCircle.Trading.TripTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances

  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup do
    trading_setup()
  end

  test "supply 100; load actual 40 complete → remaining 60", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    loc = location_fixture(company, admin, %{"kind" => "supplier_site"})
    drop_loc = location_fixture(company, admin, %{"kind" => "own_warehouse"})

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
              "location_id" => loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "location_id" => drop_loc.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, completed, _warnings} = Trading.complete_trip(trip, company, admin)
    assert completed.status == "completed"
    assert Decimal.eq?(Balances.supply_remaining(supply), Decimal.new("60"))
    assert Decimal.eq?(Balances.supply_loaded(supply), Decimal.new("40"))
  end

  test "sales drop actual 33.5 of 35; undelivered 1.5; fulfill allowed", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})

    sales =
      sales_position_fixture(company, admin, %{
        "quantity" => "35",
        "good_id" => good.id,
        "status" => "open"
      })

    load_loc = location_fixture(company, admin, %{"kind" => "supplier_site"})
    drop_loc = location_fixture(company, admin, %{"kind" => "customer_site"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-02",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "33.5",
              "actual_mt" => "33.5",
              "location_id" => load_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "33.5",
              "actual_mt" => "33.5",
              "location_id" => drop_loc.id,
              "sales_position_id" => sales.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, _, _} = Trading.complete_trip(trip, company, admin)
    assert Decimal.eq?(Balances.sales_delivered(sales), Decimal.new("33.5"))
    assert Decimal.eq?(Balances.sales_undelivered(sales), Decimal.new("1.5"))

    assert {:ok, fulfilled} =
             Trading.fulfill_sales_position(
               sales,
               %{"fulfilled_note" => "short accepted"},
               company,
               admin
             )

    assert fulfilled.status == "fulfilled"
  end

  test "multi-load multi-drop math", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    s1 = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    s2 = supply_position_fixture(company, admin, %{"quantity" => "50", "good_id" => good.id})

    sales =
      sales_position_fixture(company, admin, %{
        "quantity" => "90",
        "good_id" => good.id,
        "status" => "open"
      })

    l1 = location_fixture(company, admin)
    l2 = location_fixture(company, admin)
    d1 = location_fixture(company, admin, %{"kind" => "customer_site"})
    d2 = location_fixture(company, admin, %{"kind" => "customer_site"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-03",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "location_id" => l1.id,
              "supply_position_id" => s1.id
            },
            %{
              "planned_mt" => "50",
              "actual_mt" => "50",
              "location_id" => l2.id,
              "supply_position_id" => s2.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "55",
              "actual_mt" => "55",
              "location_id" => d1.id,
              "sales_position_id" => sales.id
            },
            %{
              "planned_mt" => "35",
              "actual_mt" => "35",
              "location_id" => d2.id,
              "sales_position_id" => sales.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, _, warnings} = Trading.complete_trip(trip, company, admin)
    # 90 load == 90 drop — no mismatch warning required; may still have empty crew warnings
    refute Enum.any?(warnings, &String.contains?(&1, "do not equal"))

    assert Decimal.eq?(Balances.supply_remaining(s1), Decimal.new("60"))
    assert Decimal.eq?(Balances.supply_remaining(s2), Decimal.new("0"))
    assert Decimal.eq?(Balances.sales_delivered(sales), Decimal.new("90"))
    assert Decimal.eq?(Balances.sales_undelivered(sales), Decimal.new("0"))
  end

  test "warehouse_board shows on hand after stock in and out", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    wh = location_fixture(company, admin, %{"kind" => "own_warehouse", "name" => "Silo board"})
    supplier_loc = location_fixture(company, admin, %{"kind" => "supplier_site"})
    customer_loc = location_fixture(company, admin, %{"kind" => "customer_site"})

    sales =
      sales_position_fixture(company, admin, %{
        "quantity" => "10",
        "good_id" => good.id,
        "status" => "open"
      })

    {:ok, in_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "location_id" => supplier_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "location_id" => wh.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, _, _} = Trading.complete_trip(in_trip, company, admin)

    board = Trading.warehouse_board(company, admin)
    row = Enum.find(board, &(&1.location.id == wh.id))
    assert row
    assert Decimal.eq?(row.on_hand, Decimal.new("40"))
    assert Decimal.eq?(row.inbound, Decimal.new("40"))
    assert Decimal.eq?(row.outbound, Decimal.new(0))

    {:ok, out_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-22",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{"planned_mt" => "15", "actual_mt" => "15", "location_id" => wh.id}
          ],
          "drops" => [
            %{
              "planned_mt" => "15",
              "actual_mt" => "15",
              "location_id" => customer_loc.id,
              "sales_position_id" => sales.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, _, _} = Trading.complete_trip(out_trip, company, admin)

    board = Trading.warehouse_board(company, admin)
    row = Enum.find(board, &(&1.location.id == wh.id))
    assert Decimal.eq?(row.on_hand, Decimal.new("25"))
    assert Decimal.eq?(row.outbound, Decimal.new("15"))
  end

  test "own warehouse drop in then load out", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    wh = location_fixture(company, admin, %{"kind" => "own_warehouse", "name" => "Main silo"})
    supplier_loc = location_fixture(company, admin, %{"kind" => "supplier_site"})
    customer_loc = location_fixture(company, admin, %{"kind" => "customer_site"})

    sales =
      sales_position_fixture(company, admin, %{
        "quantity" => "20",
        "good_id" => good.id,
        "status" => "open"
      })

    # Stock in to warehouse
    {:ok, in_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-04",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "location_id" => supplier_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "location_id" => wh.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, _, _} = Trading.complete_trip(in_trip, company, admin)
    assert Decimal.eq?(Balances.own_warehouse_qty(wh), Decimal.new("25"))

    # Stock out from warehouse to customer
    {:ok, out_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-05",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{"planned_mt" => "20", "actual_mt" => "20", "location_id" => wh.id}
          ],
          "drops" => [
            %{
              "planned_mt" => "20",
              "actual_mt" => "20",
              "location_id" => customer_loc.id,
              "sales_position_id" => sales.id
            }
          ]
        },
        company,
        admin
      )

    assert {:ok, _, _} = Trading.complete_trip(out_trip, company, admin)
    assert Decimal.eq?(Balances.own_warehouse_qty(wh), Decimal.new("5"))
    assert Decimal.eq?(Balances.sales_delivered(sales), Decimal.new("20"))
  end

  test "draft trip does not affect remaining", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    loc = location_fixture(company, admin)
    drop_loc = location_fixture(company, admin)

    {:ok, _trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-06",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "status" => "draft",
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "location_id" => loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{"planned_mt" => "40", "actual_mt" => "40", "location_id" => drop_loc.id}
          ]
        },
        company,
        admin
      )

    assert Decimal.eq?(Balances.supply_remaining(supply), Decimal.new("100"))
    assert Decimal.eq?(Balances.supply_loaded(supply), Decimal.new(0))
  end

  test "soft hold still does not reduce remaining after trips", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})

    sales_position_fixture(company, admin, %{
      "quantity" => "40",
      "good_id" => good.id,
      "preferred_supply_id" => supply.id,
      "status" => "open"
    })

    assert Decimal.eq?(Balances.soft_held_for_supply(supply.id), Decimal.new("40"))
    assert Decimal.eq?(Balances.supply_remaining(supply), Decimal.new("100"))
  end

  test "cancel completed without invoice restores remaining", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    loc = location_fixture(company, admin)
    drop_loc = location_fixture(company, admin)

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-07",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "location_id" => loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{"planned_mt" => "40", "actual_mt" => "40", "location_id" => drop_loc.id}
          ]
        },
        company,
        admin
      )

    assert {:ok, completed, _} = Trading.complete_trip(trip, company, admin)
    assert Decimal.eq?(Balances.supply_remaining(supply), Decimal.new("60"))

    assert {:ok, cancelled} = Trading.cancel_trip(completed, company, admin)
    assert cancelled.status == "cancelled"
    assert Decimal.eq?(Balances.supply_remaining(supply), Decimal.new("100"))
  end

  test "complete requires actuals", %{admin: admin, company: company} do
    good = good_fixture(company, admin)
    loc = location_fixture(company, admin)

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-08",
          "transport_mode" => "company_own",
          "good_id" => good.id,
          "loads" => [%{"planned_mt" => "10", "location_id" => loc.id}],
          "drops" => [%{"planned_mt" => "10", "location_id" => loc.id}]
        },
        company,
        admin
      )

    assert Trading.complete_trip(trip, company, admin) == {:error, :missing_actuals}
  end

  test "creating load on open supply auto-promotes status to collect", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)

    supply =
      supply_position_fixture(company, admin, %{
        "quantity" => "100",
        "good_id" => good.id,
        "status" => "open"
      })

    assert supply.status == "open"
    loc = location_fixture(company, admin)
    drop_loc = location_fixture(company, admin)

    assert {:ok, _trip} =
             Trading.create_trip(
               %{
                 "date" => "2026-07-12",
                 "transport_mode" => "company_own",
                 "good_id" => good.id,
                 "loads" => [
                   %{
                     "planned_mt" => "10",
                     "actual_mt" => "10",
                     "location_id" => loc.id,
                     "supply_position_id" => supply.id
                   }
                 ],
                 "drops" => [
                   %{"planned_mt" => "10", "actual_mt" => "10", "location_id" => drop_loc.id}
                 ]
               },
               company,
               admin
             )

    reloaded = Trading.get_supply_position!(supply.id, company, admin)
    assert reloaded.status == "collect"
  end

  test "mismatched good on supply is rejected", %{admin: admin, company: company} do
    good_a = good_fixture(company, admin)
    good_b = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"good_id" => good_b.id})
    loc = location_fixture(company, admin)

    assert {:error, cs} =
             Trading.create_trip(
               %{
                 "date" => "2026-07-09",
                 "transport_mode" => "company_own",
                 "good_id" => good_a.id,
                 "loads" => [
                   %{
                     "planned_mt" => "10",
                     "actual_mt" => "10",
                     "location_id" => loc.id,
                     "supply_position_id" => supply.id
                   }
                 ],
                 "drops" => [
                   %{"planned_mt" => "10", "actual_mt" => "10", "location_id" => loc.id}
                 ]
               },
               company,
               admin
             )

    assert %{good_id: _} = errors_on(cs)
  end
end
