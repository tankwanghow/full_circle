defmodule FullCircleWeb.TradingDeskLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures
  import FullCircle.HRFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "desk shows supply warehouse sales and trips sections", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "Desk good"})
    supplier = contact_fixture(company, user, %{"name" => "Desk supplier"})
    customer = contact_fixture(company, user, %{"name" => "Desk customer"})

    supply_position_fixture(company, user, %{
      "title" => "Desk supply A",
      "good_id" => good.id,
      "supplier_id" => supplier.id
    })

    location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Desk silo"})

    sales_position_fixture(company, user, %{
      "title" => "Desk sales B",
      "status" => "open",
      "good_id" => good.id,
      "customer_id" => customer.id
    })

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert html =~ "Desk supplier"
    assert html =~ "Desk good"
    assert html =~ "Desk silo"
    assert html =~ "Desk customer"
    assert has_element?(lv, "#desk_supply")
    assert has_element?(lv, "#desk_warehouse")
    assert has_element?(lv, "#desk_sales")
    # trips panel shown by default (no rows until trips exist)
    assert has_element?(lv, "#desk_trips[data-trips-panel=shown]")
    assert has_element?(lv, "#desk-trips-hide")
    assert has_element?(lv, "#desk-trips-maximize")
    refute has_element?(lv, "#desk-trip-")
  end

  test "trips panel show hide maximize", %{conn: conn, company: company, user: user} do
    good = good_fixture(company, user)
    load_loc = location_fixture(company, user, %{"kind" => "supplier_site"})
    drop_loc = location_fixture(company, user, %{"kind" => "own_warehouse"})

    {:ok, trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => Date.utc_today() |> Date.to_iso8601(),
          "transport_mode" => "company_own",
          "vehicle_number" => "MAX001",
          "status" => "draft",
          "loads" => [
            %{
              "planned" => "10",
              "good_id" => good.id,
              "location_id" => load_loc.id
            }
          ],
          "drops" => [
            %{
              "planned" => "10",
              "good_id" => good.id,
              "location_id" => drop_loc.id
            }
          ]
        },
        company,
        user
      )

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    # Mount defaults status to "draft, planned" — draft trips are visible without clearing Bill chips
    assert has_element?(lv, "#desk_trips[data-trips-panel=shown]")
    assert has_element?(lv, "#desk-trip-#{trip.id}")
    assert has_element?(lv, "#desk_supply")

    lv |> element("#desk-trips-hide") |> render_click()
    assert has_element?(lv, "#desk_trips[data-trips-panel=hidden]")
    refute has_element?(lv, "#desk-trip-#{trip.id}")
    assert has_element?(lv, "#desk-trips-show")
    assert has_element?(lv, "#desk_supply")

    lv |> element("#desk-trips-show") |> render_click()
    assert has_element?(lv, "#desk_trips[data-trips-panel=shown]")
    assert has_element?(lv, "#desk-trip-#{trip.id}")

    lv |> element("#desk-trips-maximize") |> render_click()
    assert has_element?(lv, "#desk_trips[data-trips-panel=maximized]")
    assert has_element?(lv, "#desk-trip-#{trip.id}")
    refute has_element?(lv, "#desk_supply")
    refute has_element?(lv, "#desk_warehouse")
    refute has_element?(lv, "#desk_sales")
    assert has_element?(lv, "#desk-trips-restore")
    assert has_element?(lv, "#desk-trips-hide")

    lv |> element("#desk-trips-restore") |> render_click()
    assert has_element?(lv, "#desk_trips[data-trips-panel=shown]")
    assert has_element?(lv, "#desk_supply")
    assert has_element?(lv, "#desk-trip-#{trip.id}")
  end

  test "click transit qty opens trip list then trip modal", %{
    conn: conn,
    company: company,
    user: user
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
        "quantity" => "25",
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    farm = location_fixture(company, user, %{"kind" => "customer_site"})

    {:ok, trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => "2026-07-22",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "status" => "planned",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id,
              "planned" => "25",
              "actual" => "25"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => farm.id,
              "sales_position_id" => sales.id,
              "planned" => "25",
              "actual" => "25"
            }
          ]
        },
        company,
        user
      )

    assert trip.reference_no =~ ~r/^TRP-\d{6}$/

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    assert has_element?(
             lv,
             "#desk-sales-#{sales.id} button[phx-click=show_transit_trips]"
           )

    lv
    |> element("#desk-sales-#{sales.id} button[phx-click=show_transit_trips]")
    |> render_click()

    assert has_element?(lv, "#desk-transit-list")
    assert render(lv) =~ trip.reference_no

    lv |> element("#transit-trip-#{trip.id}") |> render_click()
    assert has_element?(lv, "#desk-trip-form")
    assert render(lv) =~ trip.reference_no
  end

  test "create supply from desk modal appears on board", %{
    conn: conn,
    company: company,
    user: user
  } do
    contact = contact_fixture(company, user, %{"name" => "Modal supplier"})
    good = good_fixture(company, user, %{"name" => "Modal good S"})

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    lv |> element("#desk-new-supply") |> render_click()
    assert has_element?(lv, "#desk-modal")

    lv
    |> form("#desk-supply-form",
      supply_position: %{
        title: "Modal supply X",
        quantity: "50",
        unit_price: "1000",
        supplier_name: contact.name,
        good_name: good.name,
        status: "open"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "Modal supply X"
    assert html =~ "Modal supplier"
    assert html =~ "Modal good S"
    refute has_element?(lv, "#desk-modal")
  end

  test "create sales from desk modal appears on open sales", %{
    conn: conn,
    company: company,
    user: user
  } do
    contact = contact_fixture(company, user, %{"name" => "Modal customer"})
    good = good_fixture(company, user, %{"name" => "Modal good Y"})

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    lv |> element("#desk-new-sales") |> render_click()
    assert has_element?(lv, "#desk-modal")

    lv
    |> form("#desk-sales-form",
      sales_position: %{
        title: "Modal sales Y",
        quantity: "20",
        unit_price: "1500",
        customer_name: contact.name,
        good_name: good.name,
        status: "open"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "Modal customer"
    assert html =~ "Modal good Y"
    refute has_element?(lv, "#desk-modal")
  end

  test "row click opens supply edit modal", %{conn: conn, company: company, user: user} do
    supply = supply_position_fixture(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    lv
    |> element("#desk-supply-#{supply.id} [phx-click=open_modal]")
    |> render_click()

    assert has_element?(lv, "#desk-modal")
    assert has_element?(lv, "#desk-supply-form")
    assert render(lv) =~ supply.title
    assert supply.title =~ ~r/^SUP-\d{6}$/
  end

  test "checkbox selection locks good and enables create trip", %{
    conn: conn,
    company: company,
    user: user
  } do
    good_a = good_fixture(company, user, %{"name" => "AsmMaize"})
    good_b = good_fixture(company, user, %{"name" => "AsmPollard"})
    customer = contact_fixture(company, user, %{"name" => "Asm Customer"})
    supplier = contact_fixture(company, user, %{"name" => "Asm Supplier"})

    supply =
      supply_position_fixture(company, user, %{
        "title" => "Asm supply",
        "good_id" => good_a.id,
        "supplier_id" => supplier.id,
        "quantity" => "100",
        "status" => "collect"
      })

    sales =
      sales_position_fixture(company, user, %{
        "title" => "Asm sales",
        "good_id" => good_a.id,
        "customer_id" => customer.id,
        "quantity" => "20",
        "status" => "open"
      })

    other_supply =
      supply_position_fixture(company, user, %{
        "good_id" => good_b.id,
        "quantity" => "50",
        "status" => "open"
      })

    load_loc = location_fixture(company, user, %{"kind" => "supplier_site"})
    drop_loc = location_fixture(company, user, %{"kind" => "customer_site"})

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert html =~ "Asm Supplier"
    assert html =~ "Asm Customer"
    assert html =~ "AsmPollard"

    # Select sales then supply of same good
    lv
    |> element("#sel-sales-#{sales.id}")
    |> render_click()

    html = render(lv)
    assert html =~ "AsmMaize"
    # Selecting sales auto-filters supply/warehouse good to the sale's good
    refute html =~ "AsmPollard"
    refute has_element?(lv, "#desk-supply-#{other_supply.id}")

    lv
    |> element("#sel-supply-#{supply.id}")
    |> render_click()

    assert has_element?(lv, "#desk-selection-tray")
    assert has_element?(lv, "#desk-create-trip-selection:not([disabled])")

    lv |> element("#desk-create-trip-selection") |> render_click()
    assert has_element?(lv, "#desk-trip-form")
    html = render(lv)
    assert html =~ "AsmMaize"
    assert html =~ "20"
    # Typeahead labels prefilled from selection
    assert html =~ supply.title
    assert html =~ sales.title
    assert html =~ "Asm Supplier"
    assert html =~ "Asm Customer"
    # Typeahead fields render as textareas (not value= inputs) with title · party labels
    assert html =~ supply.title
    assert html =~ ~s(name="trip[loads][0][supply_title]")
    assert html =~ ~s(name="trip[drops][0][sales_title]")

    # Resolve locations via typeahead (hidden ids filled by validate), then save
    lv
    |> form("#desk-trip-form",
      trip: %{
        date: Date.utc_today() |> Date.to_iso8601(),
        vehicle_number: "TEST1234",
        loads: %{
          "0" => %{
            location_name: "#{load_loc.name} (#{load_loc.kind})",
            planned: "20",
            actual: "20"
          }
        },
        drops: %{
          "0" => %{
            location_name: "#{drop_loc.name} (#{drop_loc.kind})",
            planned: "20",
            actual: "20"
          }
        }
      }
    )
    |> render_change()

    lv |> form("#desk-trip-form") |> render_submit()

    assert render(lv) =~ "Trip saved successfully"
    refute has_element?(lv, "#desk-selection-tray")
    assert has_element?(lv, "#desk-supply-#{other_supply.id}")
    # Ops default status includes draft — new trips appear without clearing Bill chips
    assert render(lv) =~ "TRP-"
  end

  test "selecting sales with preferred supply auto-selects that supply", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "PrefMaize"})
    customer = contact_fixture(company, user, %{"name" => "Pref Customer"})
    supplier = contact_fixture(company, user, %{"name" => "Pref Supplier"})

    preferred =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "quantity" => "80",
        "status" => "open"
      })

    other =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "40",
        "status" => "open"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "25",
        "status" => "open",
        "preferred_supply_id" => preferred.id
      })

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    # Before selection neither supply is checked
    refute has_element?(lv, "#sel-supply-#{preferred.id}[checked]")
    refute has_element?(lv, "#sel-supply-#{other.id}[checked]")

    lv |> element("#sel-sales-#{sales.id}") |> render_click()

    # Preferred supply auto-selected; other remains off
    assert has_element?(lv, "#sel-supply-#{preferred.id}[checked]")
    refute has_element?(lv, "#sel-supply-#{other.id}[checked]")
    assert has_element?(lv, "#sel-sales-#{sales.id}[checked]")
    assert has_element?(lv, "#desk-selection-tray")
    assert has_element?(lv, "#desk-create-trip-selection:not([disabled])")
  end

  test "selecting sales auto-filters supply and warehouse good columns", %{
    conn: conn,
    company: company,
    user: user
  } do
    good_a = good_fixture(company, user, %{"name" => "AutoFilterMaize"})
    good_b = good_fixture(company, user, %{"name" => "AutoFilterPollard"})
    customer = contact_fixture(company, user, %{"name" => "AutoFilter Customer"})
    supplier = contact_fixture(company, user, %{"name" => "AutoFilter Supplier"})

    supply_a =
      supply_position_fixture(company, user, %{
        "good_id" => good_a.id,
        "supplier_id" => supplier.id,
        "quantity" => "50",
        "status" => "open"
      })

    supply_b =
      supply_position_fixture(company, user, %{
        "good_id" => good_b.id,
        "supplier_id" => supplier.id,
        "quantity" => "40",
        "status" => "open"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good_a.id,
        "customer_id" => customer.id,
        "quantity" => "20",
        "status" => "open"
      })

    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "AF Silo"})
    port = location_fixture(company, user, %{"kind" => "port", "name" => "AF Port"})

    # Stock both goods so warehouse rows exist
    for {good, supply} <- [{good_a, supply_a}, {good_b, supply_b}] do
      {:ok, trip} =
        FullCircle.Trading.create_trip(
          %{
            "date" => "2026-07-01",
            "transport_mode" => "company_own",
            "vehicle_number" => "AF1234",
            "loads" => [
              %{
                "good_id" => good.id,
                "location_id" => port.id,
                "supply_position_id" => supply.id,
                "planned" => "10",
                "actual" => "10"
              }
            ],
            "drops" => [
              %{
                "good_id" => good.id,
                "location_id" => wh.id,
                "supply_position_id" => supply.id,
                "planned" => "10",
                "actual" => "10"
              }
            ]
          },
          company,
          user
        )

      assert {:ok, _, _} = FullCircle.Trading.complete_trip(trip, company, user)
    end

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert has_element?(lv, "#desk-supply-#{supply_a.id}")
    assert has_element?(lv, "#desk-supply-#{supply_b.id}")

    lv |> element("#sel-sales-#{sales.id}") |> render_click()

    # Supply/warehouse good filters set to sale's good; other good rows hidden
    assert has_element?(
             lv,
             ~s(#desk-filter-supply-good input[name="value"][value="AutoFilterMaize"])
           )

    assert has_element?(
             lv,
             ~s(#desk-filter-warehouse-good input[name="value"][value="AutoFilterMaize"])
           )

    assert has_element?(lv, "#desk-supply-#{supply_a.id}")
    refute has_element?(lv, "#desk-supply-#{supply_b.id}")
    assert has_element?(lv, "#desk-wh-#{wh.id}-#{good_a.id}")
    refute has_element?(lv, "#desk-wh-#{wh.id}-#{good_b.id}")

    # Deselect sale → clear auto good filters; both supplies show again
    lv |> element("#sel-sales-#{sales.id}") |> render_click()
    assert has_element?(lv, "#desk-supply-#{supply_a.id}")
    assert has_element?(lv, "#desk-supply-#{supply_b.id}")
  end

  test "warehouse out and in are mutually exclusive on same row", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "XorMaize"})
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "quantity" => "100",
        "status" => "collect"
      })

    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Xor Silo"})
    port = location_fixture(company, user, %{"kind" => "port"})

    # Put stock in warehouse so Out is available
    {:ok, trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => "2026-07-01",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id,
              "planned" => "30",
              "actual" => "30"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id,
              "planned" => "30",
              "actual" => "30"
            }
          ]
        },
        company,
        user
      )

    assert {:ok, _, _} = FullCircle.Trading.complete_trip(trip, company, user)

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    out_id = "#sel-wh-out-#{wh.id}-#{good.id}"
    in_id = "#sel-wh-in-#{wh.id}-#{good.id}"

    # Select Out → In disabled
    lv |> element(out_id) |> render_click()
    assert has_element?(lv, "#{out_id}:checked")
    assert has_element?(lv, "#{in_id}[disabled]")

    # Uncheck Out, select In → Out disabled
    lv |> element(out_id) |> render_click()
    lv |> element(in_id) |> render_click()
    assert has_element?(lv, "#{in_id}:checked")
    assert has_element?(lv, "#{out_id}[disabled]")
  end

  test "status filter can load closed supplies and fulfilled sales", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    supplier = contact_fixture(company, user, %{"name" => "Closed Supplier Co"})
    customer = contact_fixture(company, user, %{"name" => "Fulfilled Customer Co"})

    closed =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "quantity" => "10",
        "status" => "closed"
      })

    open_supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "20",
        "status" => "open"
      })

    fulfilled =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "5",
        "status" => "fulfilled"
      })

    open_sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "8",
        "status" => "open"
      })

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    # default: active statuses prefilled in status boxes
    assert html =~ ~s(value="open, hold, collect")
    assert html =~ ~s(value="draft, open, hold")
    refute html =~ closed.title
    refute html =~ fulfilled.title
    assert html =~ open_supply.title
    assert html =~ open_sales.title

    lv
    |> form("#desk-filter-supply-status", %{
      "table" => "supply",
      "field" => "status",
      "value" => "closed"
    })
    |> render_change()

    html = render(lv)
    assert html =~ closed.title
    assert html =~ "closed"
    # open still in dataset until status filter narrows; "closed" does not match "open"
    refute html =~ open_supply.title
    # closed rows are not selectable for trips
    refute has_element?(lv, "#sel-supply-#{closed.id}")

    lv
    |> form("#desk-filter-sales-status", %{
      "table" => "sales",
      "field" => "status",
      "value" => "fulfilled"
    })
    |> render_change()

    html = render(lv)
    assert html =~ fulfilled.title
    refute html =~ open_sales.title
    refute has_element?(lv, "#sel-sales-#{fulfilled.id}")
  end

  test "stock-in: supply + warehouse enables create trip without sales", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "StockInMaize"})

    supply =
      supply_position_fixture(company, user, %{
        "title" => "StockIn supply",
        "good_id" => good.id,
        "quantity" => "50",
        "status" => "collect"
      })

    wh =
      location_fixture(company, user, %{
        "kind" => "own_warehouse",
        "name" => "StockIn Silo"
      })

    load_loc = location_fixture(company, user, %{"kind" => "port"})

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    lv |> element("#sel-supply-#{supply.id}") |> render_click()
    # Drop-in checkbox (In) on empty warehouse
    lv |> element("#sel-wh-in-#{wh.id}-any") |> render_click()

    assert has_element?(lv, "#desk-selection-tray")
    assert render(lv) =~ "Stock-in"
    assert has_element?(lv, "#desk-create-trip-selection:not([disabled])")

    lv |> element("#desk-create-trip-selection") |> render_click()
    assert has_element?(lv, "#desk-trip-form")
    html = render(lv)
    assert html =~ supply.title
    assert html =~ "StockInMaize"

    # Prefill already has supply/good; resolve load location if needed then save
    lv
    |> form("#desk-trip-form",
      trip: %{
        date: Date.utc_today() |> Date.to_iso8601(),
        vehicle_number: "TEST1234",
        loads: %{
          "0" => %{
            location_name: "#{load_loc.name} (#{load_loc.kind})",
            planned: "50",
            actual: "50"
          }
        },
        drops: %{
          "0" => %{
            location_name: "#{wh.name} (#{wh.kind})",
            planned: "50",
            actual: "50"
          }
        }
      }
    )
    |> render_change()

    lv |> form("#desk-trip-form") |> render_submit()

    assert render(lv) =~ "Trip saved successfully"
    assert render(lv) =~ "TRP-"
  end

  test "typing in column filter live-filters supply rows", %{
    conn: conn,
    company: company,
    user: user
  } do
    good_a = good_fixture(company, user, %{"name" => "FilterMaize"})
    good_b = good_fixture(company, user, %{"name" => "FilterPollard"})
    sup_a = contact_fixture(company, user, %{"name" => "Alpha Supplier Co"})
    sup_b = contact_fixture(company, user, %{"name" => "Beta Supplier Co"})

    supply_position_fixture(company, user, %{
      "title" => "S-A",
      "good_id" => good_a.id,
      "supplier_id" => sup_a.id
    })

    supply_position_fixture(company, user, %{
      "title" => "S-B",
      "good_id" => good_b.id,
      "supplier_id" => sup_b.id
    })

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert html =~ "Alpha Supplier Co"
    assert html =~ "Beta Supplier Co"

    html =
      lv
      |> form("#desk-filter-supply-supplier", %{value: "Alpha"})
      |> render_change()

    assert html =~ "Alpha Supplier Co"
    refute html =~ "Beta Supplier Co"

    html =
      lv
      |> form("#desk-filter-supply-supplier", %{value: ""})
      |> render_change()

    assert html =~ "Alpha Supplier Co"
    assert html =~ "Beta Supplier Co"
  end

  test "trip settle filter chips filter unbilled completed trips", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    customer = contact_fixture(company, user)
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "status" => "collect",
        "quantity" => "100"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    site = location_fixture(company, user, %{"kind" => "customer_site"})
    wh = location_fixture(company, user, %{"kind" => "own_warehouse"})

    {:ok, open_trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "OPEN1",
          "loads" => [
            %{
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => site.id,
              "sales_position_id" => sales.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    {:ok, open_trip, _} = FullCircle.Trading.complete_trip(open_trip, company, user)

    {:ok, draft} =
      FullCircle.Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "company_own",
          "vehicle_number" => "DRAFT1",
          "loads" => [
            %{
              "planned" => "5",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "5",
              "good_id" => good.id,
              "location_id" => wh.id
            }
          ]
        },
        company,
        user
      )

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert has_element?(lv, "#desk-trip-settle-filters")
    # Ops default: draft + planned; Bill chips off; completed trips hidden by status
    assert html =~ ~s(id="desk-trip-settle-any")
    assert html =~ ~s(value="draft, planned") or html =~ "draft, planned"
    assert has_element?(lv, "#desk-trip-#{draft.id}")
    refute has_element?(lv, "#desk-trip-#{open_trip.id}")

    # Bill chip forces status=completed and shows unbilled completed trips
    lv |> element("#desk-trip-settle-any") |> render_click()
    assert has_element?(lv, "#desk-trip-#{open_trip.id}")
    refute has_element?(lv, "#desk-trip-#{draft.id}")
    assert render(lv) =~ ~s(value="completed") or render(lv) =~ ">completed<"

    lv |> element("#desk-trip-settle-clear") |> render_click()
    # Clear removes Bill chips and status filter — both draft and completed show
    assert has_element?(lv, "#desk-trip-#{draft.id}")
    assert has_element?(lv, "#desk-trip-#{open_trip.id}")

    lv |> element("#desk-trip-settle-customer") |> render_click()
    assert has_element?(lv, "#desk-trip-#{open_trip.id}")
    refute has_element?(lv, "#desk-trip-#{draft.id}")
  end

  test "settlement badges on completed trip and expand lines", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    customer = contact_fixture(company, user)
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "status" => "collect",
        "quantity" => "100"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    site = location_fixture(company, user, %{"kind" => "customer_site"})

    {:ok, trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "BADGE1",
          "loads" => [
            %{
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => site.id,
              "sales_position_id" => sales.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    {:ok, trip, _} = FullCircle.Trading.complete_trip(trip, company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    # Ops default hides completed; Bill chip forces status=completed
    lv |> element("#desk-trip-settle-any") |> render_click()

    html = render(lv)
    assert html =~ trip.reference_no
    assert html =~ "Customer uninvoiced"
    assert html =~ "Supplier unbilled"
    assert html =~ "Transport n/a"
    assert has_element?(lv, "#desk-trip-settle-#{trip.id}")

    lv |> element("#desk-trip-expand-#{trip.id}") |> render_click()
    html = render(lv)
    assert html =~ "Loads"
    assert html =~ "Drops"
    assert html =~ supply.title
    assert html =~ sales.title
  end

  test "edit completed settled trip hides cancel action", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    customer = contact_fixture(company, user)
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "status" => "collect",
        "quantity" => "100"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    site = location_fixture(company, user, %{"kind" => "customer_site"})

    {:ok, trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "company_own",
          "vehicle_number" => "NOCAN1",
          "loads" => [
            %{
              "planned" => "5",
              "actual" => "5",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "5",
              "actual" => "5",
              "good_id" => good.id,
              "location_id" => site.id,
              "sales_position_id" => sales.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    {:ok, trip, _} = FullCircle.Trading.complete_trip(trip, company, user)
    drop = hd(trip.drops)
    {:ok, attrs} = FullCircle.Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert {:ok, _} =
             FullCircle.Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    # Clear status filter so completed trips appear (ops default is draft, planned)
    lv
    |> form("#desk-filter-trips-status", %{
      "table" => "trips",
      "field" => "status",
      "value" => "completed"
    })
    |> render_change()

    lv
    |> element("#desk-trip-#{trip.id} [phx-value-action=edit]")
    |> render_click()

    assert has_element?(lv, "#desk-trip-form")
    refute has_element?(lv, "#desk-trip-cancel")
    assert has_element?(lv, "#desk-trip-cancel-blocked")
  end

  test "desk new trip modal saves and lists trip", %{conn: conn, company: company, user: user} do
    good = good_fixture(company, user, %{"name" => "BlankTripGood"})

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "status" => "open"
      })

    load_loc =
      location_fixture(company, user, %{"kind" => "supplier_site", "name" => "BlankLoadLoc"})

    drop_loc =
      location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "BlankDropWh"})

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    lv |> element("#desk-new-trip") |> render_click()
    assert has_element?(lv, "#desk-trip-form")

    # Empty new trip: fill typeaheads then save
    lv
    |> form("#desk-trip-form",
      trip: %{
        date: Date.utc_today() |> Date.to_iso8601(),
        vehicle_number: "TEST1234",
        transport_mode: "company_own",
        status: "draft",
        loads: %{
          "0" => %{
            good_name: good.name,
            location_name: "#{load_loc.name} (#{load_loc.kind})",
            supply_title: "#{supply.title} · ",
            planned: "10",
            actual: "10"
          }
        },
        drops: %{
          "0" => %{
            good_name: good.name,
            location_name: "#{drop_loc.name} (#{drop_loc.kind})",
            planned: "10",
            actual: "10"
          }
        }
      }
    )
    |> render_change()

    # supply_title needs full label — set from resolved or exact title
    lv
    |> form("#desk-trip-form",
      trip: %{
        loads: %{
          "0" => %{
            supply_title: supply.title
          }
        }
      }
    )
    |> render_change()

    lv |> form("#desk-trip-form") |> render_submit()

    assert render(lv) =~ "Trip saved successfully"
    assert render(lv) =~ "TRP-"
  end

  test "switching transport_mode away from company_own/agent clears saved crew", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "CrewClearGood"})
    loc = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "CrewClearWh"})
    emp = employee_fixture(%{"name" => "Crew Clear Ali"}, company, user)

    {:ok, trip} =
      FullCircle.Trading.create_trip(
        %{
          "date" => Date.utc_today() |> Date.to_iso8601(),
          "transport_mode" => "company_own",
          "vehicle_number" => "CREWCLR1",
          "loads" => [
            %{
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => loc.id,
              "trip_load_employees" => [%{"employee_id" => emp.id}]
            }
          ],
          "drops" => [
            %{
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => loc.id,
              "trip_drop_employees" => [%{"employee_id" => emp.id}]
            }
          ]
        },
        company,
        user
      )

    trip = FullCircle.Trading.get_trip!(trip.id, company, user)
    assert length(hd(trip.loads).trip_load_employees) == 1
    assert length(hd(trip.drops).trip_drop_employees) == 1

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/trips/#{trip.id}/edit")
    assert has_element?(lv, "#desk-trip-form")

    # Crew inputs are only rendered for company_own / agent
    assert render(lv) =~ "trip[loads][0][trip_load_employees]"

    lv
    |> form("#desk-trip-form", trip: %{transport_mode: "customer_arranged"})
    |> render_change()

    # Crew UI is gone, so the submitted params carry no crew key at all
    refute render(lv) =~ "trip[loads][0][trip_load_employees]"

    lv |> form("#desk-trip-form") |> render_submit()
    assert render(lv) =~ "Trip saved successfully"

    reloaded = FullCircle.Trading.get_trip!(trip.id, company, user)
    assert reloaded.transport_mode == "customer_arranged"
    assert hd(reloaded.loads).trip_load_employees == []
    assert hd(reloaded.drops).trip_drop_employees == []
  end

  test "Bill chips surface an unbilled trip older than the desk's 50-trip cap", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "CapGood"})
    loc = location_fixture(company, user, %{"kind" => "port", "name" => "CapPort"})
    drop_loc = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "CapWh"})

    make_trip = fn date, vehicle, supply_id ->
      {:ok, t} =
        FullCircle.Trading.create_trip(
          %{
            "date" => date,
            "transport_mode" => "company_own",
            "vehicle_number" => vehicle,
            "loads" => [
              %{
                "planned" => "5",
                "actual" => "5",
                "good_id" => good.id,
                "location_id" => loc.id,
                "supply_position_id" => supply_id
              }
            ],
            "drops" => [
              %{
                "planned" => "5",
                "actual" => "5",
                "good_id" => good.id,
                "location_id" => drop_loc.id
              }
            ]
          },
          company,
          user
        )

      {:ok, t, _} = FullCircle.Trading.complete_trip(t, company, user)
      t
    end

    # Oldest completed trip, with a supplier load that was never billed
    supply =
      supply_position_fixture(company, user, %{"good_id" => good.id, "quantity" => "1000"})

    old = make_trip.("2020-01-01", "OLDCAP1", supply.id)

    # Bury it under more than the 50-trip desk cap
    for i <- 1..55 do
      make_trip.(
        "2026-07-#{String.pad_leading(to_string(rem(i, 28) + 1), 2, "0")}",
        "NEW#{i}",
        nil
      )
    end

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    # Ops view is capped and most-recent-first, so the old trip is not shown
    refute has_element?(lv, "#desk-trip-#{old.id}")

    # Turning on a Bill chip must find it regardless of age
    lv |> element("#desk-trip-settle-any") |> render_click()
    assert has_element?(lv, "#desk-trip-#{old.id}")

    # Clearing chips returns to the capped ops view
    lv |> element("#desk-trip-settle-clear") |> render_click()
    refute has_element?(lv, "#desk-trip-#{old.id}")
  end

  test "selecting a sale does not auto-tick a closed preferred supply", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user, %{"name" => "ClosedPrefGood"})
    customer = contact_fixture(company, user, %{"name" => "ClosedPrefCust"})

    closed_supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "100",
        "status" => "closed"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "10",
        "status" => "open",
        "preferred_supply_id" => closed_supply.id
      })

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    # Pull closed rows onto the supply board via the status filter
    lv
    |> form("#desk-filter-supply-status", %{
      "table" => "supply",
      "field" => "status",
      "value" => "open, hold, collect, closed"
    })
    |> render_change()

    assert has_element?(lv, "#desk-supply-#{closed_supply.id}")
    # A closed row renders no checkbox, so it must never be auto-selected
    refute has_element?(lv, "#sel-supply-#{closed_supply.id}")

    lv |> element("#sel-sales-#{sales.id}") |> render_click()

    # The sale is selected, but the unselectable closed supply is not dragged in
    assert has_element?(lv, "#desk-selection-tray")
    tray = lv |> element("#desk-selection-tray") |> render()
    assert tray =~ "1 sales"
    assert tray =~ "0 supply"
  end

  test "desk column filters support comma-OR tokens", %{
    conn: conn,
    company: company,
    user: user
  } do
    good_open = good_fixture(company, user, %{"name" => "OrOpenGood"})
    good_hold = good_fixture(company, user, %{"name" => "OrHoldGood"})
    good_collect = good_fixture(company, user, %{"name" => "OrCollectGood"})

    s_open =
      supply_position_fixture(company, user, %{
        "good_id" => good_open.id,
        "status" => "open"
      })

    s_hold =
      supply_position_fixture(company, user, %{
        "good_id" => good_hold.id,
        "status" => "hold"
      })

    s_collect =
      supply_position_fixture(company, user, %{
        "good_id" => good_collect.id,
        "status" => "collect"
      })

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    # Trip status default is comma-OR for ops statuses
    assert html =~ "draft, planned"

    lv
    |> form("#desk-filter-supply-status", %{
      "table" => "supply",
      "field" => "status",
      "value" => "open, hold"
    })
    |> render_change()

    assert has_element?(lv, "#desk-supply-#{s_open.id}")
    assert has_element?(lv, "#desk-supply-#{s_hold.id}")
    refute has_element?(lv, "#desk-supply-#{s_collect.id}")
  end
end
