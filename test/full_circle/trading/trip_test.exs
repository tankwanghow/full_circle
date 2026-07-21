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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "33.5",
              "actual_mt" => "33.5",
              "good_id" => good.id,
              "location_id" => load_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "33.5",
              "actual_mt" => "33.5",
              "good_id" => good.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => l1.id,
              "supply_position_id" => s1.id
            },
            %{
              "planned_mt" => "50",
              "actual_mt" => "50",
              "good_id" => good.id,
              "location_id" => l2.id,
              "supply_position_id" => s2.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "55",
              "actual_mt" => "55",
              "good_id" => good.id,
              "location_id" => d1.id,
              "sales_position_id" => sales.id
            },
            %{
              "planned_mt" => "35",
              "actual_mt" => "35",
              "good_id" => good.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => supplier_loc.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{"planned_mt" => "15", "actual_mt" => "15", "good_id" => good.id, "location_id" => wh.id}
          ],
          "drops" => [
            %{
              "planned_mt" => "15",
              "actual_mt" => "15",
              "good_id" => good.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "good_id" => good.id,
              "location_id" => supplier_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "good_id" => good.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{"planned_mt" => "20", "actual_mt" => "20", "good_id" => good.id, "location_id" => wh.id}
          ],
          "drops" => [
            %{
              "planned_mt" => "20",
              "actual_mt" => "20",
              "good_id" => good.id,
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "status" => "draft",
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{"planned_mt" => "40", "actual_mt" => "40", "good_id" => good.id, "location_id" => drop_loc.id}
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
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{"planned_mt" => "40", "actual_mt" => "40", "good_id" => good.id, "location_id" => drop_loc.id}
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
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{"planned_mt" => "10", "good_id" => good.id, "location_id" => loc.id}
          ],
          "drops" => [
            %{"planned_mt" => "10", "good_id" => good.id, "location_id" => loc.id}
          ]
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
                 "vehicle_number" => "ABC1234",
                 "good_id" => good.id,
                 "loads" => [
                   %{
                     "planned_mt" => "10",
                     "actual_mt" => "10",
                     "good_id" => good.id,
                     "location_id" => loc.id,
                     "supply_position_id" => supply.id
                   }
                 ],
                 "drops" => [
                   %{
                     "planned_mt" => "10",
                     "actual_mt" => "10",
                     "good_id" => good.id,
                     "location_id" => drop_loc.id
                   }
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
                 "vehicle_number" => "ABC1234",
                 "loads" => [
                   %{
                     "planned_mt" => "10",
                     "actual_mt" => "10",
                     "good_id" => good_a.id,
                     "location_id" => loc.id,
                     "supply_position_id" => supply.id
                   }
                 ],
                 "drops" => [
                   %{
                     "planned_mt" => "10",
                     "actual_mt" => "10",
                     "good_id" => good_a.id,
                     "location_id" => loc.id
                   }
                 ]
               },
               company,
               admin
             )

    errs = errors_on(cs)
    assert errs != %{}
  end

  test "trip_from_names and trip_to_names summarise multi-party trips", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)
    sup_a = contact_fixture(company, admin, %{"name" => "Supplier Alpha"})
    sup_b = contact_fixture(company, admin, %{"name" => "Supplier Beta"})
    cust = contact_fixture(company, admin, %{"name" => "Customer Gamma"})

    supply_a =
      supply_position_fixture(company, admin, %{
        "good_id" => good.id,
        "supplier_id" => sup_a.id,
        "quantity" => "50"
      })

    supply_b =
      supply_position_fixture(company, admin, %{
        "good_id" => good.id,
        "supplier_id" => sup_b.id,
        "quantity" => "50"
      })

    sales =
      sales_position_fixture(company, admin, %{
        "good_id" => good.id,
        "customer_id" => cust.id,
        "quantity" => "40",
        "status" => "open"
      })

    load_loc = location_fixture(company, admin, %{"kind" => "port", "name" => "Port X"})
    drop_loc = location_fixture(company, admin, %{"kind" => "customer_site", "name" => "Farm Z"})
    silo = location_fixture(company, admin, %{"kind" => "own_warehouse", "name" => "Silo Y"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "planned_mt" => "20",
              "actual_mt" => "20",
              "good_id" => good.id,
              "location_id" => load_loc.id,
              "supply_position_id" => supply_a.id
            },
            %{
              "planned_mt" => "20",
              "actual_mt" => "20",
              "good_id" => good.id,
              "location_id" => load_loc.id,
              "supply_position_id" => supply_b.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "good_id" => good.id,
              "location_id" => drop_loc.id,
              "sales_position_id" => sales.id
            },
            %{
              "planned_mt" => "15",
              "actual_mt" => "15",
              "good_id" => good.id,
              "location_id" => silo.id
            }
          ]
        },
        company,
        admin
      )

    trip = Trading.get_trip!(trip.id, company, admin)
    # list_trips preload includes nested supplier/customer; get_trip! may not —
    # re-list to exercise desk preload path
    listed = Trading.list_trips(company, admin) |> Enum.find(&(&1.id == trip.id))

    froms = Trading.trip_from_names(listed)
    tos = Trading.trip_to_names(listed)

    assert "Supplier Alpha" in froms
    assert "Supplier Beta" in froms
    assert "Customer Gamma" in tos
    assert "Silo Y" in tos

    assert Trading.trip_parties_label(froms) == "Supplier Alpha, Supplier Beta"
    assert Trading.trip_parties_label(["A", "B", "C", "D"]) == "A, B +2"
    assert Trading.trip_parties_label([]) == ""
  end

  test "load and drop seq are assigned in form order and reverse drops works", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)
    loc_a = location_fixture(company, admin, %{"kind" => "port", "name" => "Port A"})
    loc_b = location_fixture(company, admin, %{"kind" => "port", "name" => "Port B"})
    drop_a = location_fixture(company, admin, %{"kind" => "customer_site", "name" => "Farm A"})
    drop_b = location_fixture(company, admin, %{"kind" => "customer_site", "name" => "Farm B"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "seq" => 1,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => loc_a.id
            },
            %{
              "seq" => 2,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => loc_b.id
            }
          ],
          "drops" => [
            %{
              "seq" => 1,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => drop_a.id
            },
            %{
              "seq" => 2,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => drop_b.id
            }
          ]
        },
        company,
        admin
      )

    trip = Trading.get_trip!(trip.id, company, admin)
    assert Enum.map(trip.loads, & &1.seq) == [1, 2]
    assert Enum.map(trip.loads, & &1.location_id) == [loc_a.id, loc_b.id]
    assert Enum.map(trip.drops, & &1.seq) == [1, 2]
    assert Enum.map(trip.drops, & &1.location_id) == [drop_a.id, drop_b.id]

    # Reverse drop order on update (FILO helper)
    {:ok, updated} =
      Trading.update_trip(
        trip,
        %{
          "drops" => [
            %{
              "id" => Enum.at(trip.drops, 1).id,
              "seq" => 1,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => drop_b.id
            },
            %{
              "id" => Enum.at(trip.drops, 0).id,
              "seq" => 2,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => drop_a.id
            }
          ]
        },
        company,
        admin
      )

    assert Enum.map(updated.drops, & &1.location_id) == [drop_b.id, drop_a.id]
    assert Enum.map(updated.drops, & &1.seq) == [1, 2]
  end

  test "agent transport mode requires transport agent", %{company: company} do
    alias FullCircle.Trading.Trip

    base = %{
      "date" => "2026-07-01",
      "status" => "draft",
      "reference_no" => "TRP-TEST-001",
      "vehicle_number" => "ABC1234",
      "company_id" => company.id
    }

    cs =
      Trip.changeset(%Trip{}, Map.put(base, "transport_mode", "agent"))

    refute cs.valid?
    assert {"can't be blank", _} = Keyword.get(cs.errors, :transport_agent_name)

    cs_ok =
      Trip.changeset(
        %Trip{},
        base
        |> Map.put("transport_mode", "agent")
        |> Map.put("transport_agent_name", "Haulage Co")
        |> Map.put("transport_agent_id", Ecto.UUID.generate())
      )

    assert cs_ok.valid? or not Keyword.has_key?(cs_ok.errors, :transport_agent_name)

    for mode <- ["company_own", "customer_arranged"] do
      cs_other = Trip.changeset(%Trip{}, Map.put(base, "transport_mode", mode))
      refute Keyword.has_key?(cs_other.errors, :transport_agent_name)
    end
  end

  test "create/update/complete/cancel write Sys logs for diversion trail", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)
    load_loc = location_fixture(company, admin, %{"kind" => "supplier_site", "name" => "Port A"})
    drop_loc = location_fixture(company, admin, %{"kind" => "customer_site", "name" => "Farm A"})
    alt_loc = location_fixture(company, admin, %{"kind" => "own_warehouse", "name" => "Own WH"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-01",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "good_name" => good.name,
              "location_id" => load_loc.id,
              "location_name" => load_loc.name
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "good_name" => good.name,
              "location_id" => drop_loc.id,
              "location_name" => drop_loc.name
            }
          ]
        },
        company,
        admin
      )

    create_logs = FullCircle.Sys.list_logs("trading_trips", trip.id)
    assert length(create_logs) == 1
    assert hd(create_logs).action == "create_trip"
    assert create_logs |> hd() |> Map.get(:delta) =~ "vehicle_number"

    # Divert: change drop location (and note)
    trip = Trading.get_trip!(trip.id, company, admin)
    drop = hd(trip.drops)
    load = hd(trip.loads)

    {:ok, trip} =
      Trading.update_trip(
        trip,
        %{
          "date" => "2026-07-01",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "notes" => "Diverted to own warehouse — customer postponed",
          "loads" => [
            %{
              "id" => load.id,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "good_name" => good.name,
              "location_id" => load_loc.id,
              "location_name" => load_loc.name
            }
          ],
          "drops" => [
            %{
              "id" => drop.id,
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "good_name" => good.name,
              "location_id" => alt_loc.id,
              "location_name" => alt_loc.name,
              "variance_note" => "Customer postponed; stock into WH"
            }
          ]
        },
        company,
        admin
      )

    logs = FullCircle.Sys.list_logs("trading_trips", trip.id)
    assert length(logs) == 2
    update_log = Enum.find(logs, &(&1.action == "update_trip"))
    assert update_log
    assert update_log.delta =~ "Own WH" or update_log.delta =~ "own warehouse" or update_log.delta =~ "Diverted"
    assert update_log.delta =~ "variance_note" or update_log.delta =~ "Customer postponed"

    {:ok, trip, _warnings} = Trading.complete_trip(trip, company, admin)
    logs = FullCircle.Sys.list_logs("trading_trips", trip.id)
    assert Enum.any?(logs, &(&1.action == "complete_trip"))

    {:ok, trip} = Trading.cancel_trip(trip, company, admin)
    logs = FullCircle.Sys.list_logs("trading_trips", trip.id)
    assert Enum.any?(logs, &(&1.action == "cancel_trip"))
    assert length(logs) == 4
  end

  test "list_supply/sales line history includes loads and drops", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})

    sales =
      sales_position_fixture(company, admin, %{
        "quantity" => "40",
        "good_id" => good.id,
        "status" => "open"
      })

    load_loc = location_fixture(company, admin, %{"kind" => "supplier_site", "name" => "Port"})
    drop_loc = location_fixture(company, admin, %{"kind" => "customer_site", "name" => "Farm"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-15",
          "transport_mode" => "company_own",
          "vehicle_number" => "XYZ999",
          "loads" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => load_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "40",
              "actual_mt" => "40",
              "good_id" => good.id,
              "location_id" => drop_loc.id,
              "sales_position_id" => sales.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        admin
      )

    history = Trading.list_supply_line_history(supply.id, company, admin)
    assert length(history) == 1
    row = hd(history)
    assert row.trip_id == trip.id
    assert row.reference_no == trip.reference_no
    assert hd(row.loads).place == "Port"
    assert hd(row.loads).qty == "40"
    assert hd(row.drops).place == "Farm"
    assert hd(row.drops).qty == "40"
    assert is_binary(row.unit) and row.unit != ""

    sales_hist = Trading.list_sales_line_history(sales.id, company, admin)
    assert length(sales_hist) == 1
    srow = hd(sales_hist)
    assert srow.trip_id == trip.id
    assert hd(srow.loads).place == "Port"
    assert hd(srow.drops).place == "Farm"
    assert hd(srow.drops).qty == "40"
    assert is_binary(srow.unit) and srow.unit != ""
  end
end
