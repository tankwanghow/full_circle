defmodule FullCircleWeb.TradingDeskLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

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
    # trips panel collapsed by default
    assert has_element?(lv, "#desk-trips-toggle")
    refute has_element?(lv, "#desk-trip-")
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
          "status" => "planned",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "25",
              "actual_mt" => "25"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => farm.id,
              "sales_position_id" => sales.id,
              "planned_mt" => "25",
              "actual_mt" => "25"
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
    # multi-good: other goods stay visible
    assert html =~ "AsmPollard"
    assert has_element?(lv, "#desk-supply-#{other_supply.id}")

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

    # Save prefilled trip (set locations required by form)
    lv
    |> form("#desk-trip-form",
      trip: %{
        date: "2026-07-26",
        transport_mode: "company_own",
        status: "draft",
        loads: %{
          "0" => %{
            good_id: good_a.id,
            location_id: load_loc.id,
            supply_position_id: supply.id,
            planned_mt: "20",
            actual_mt: "20"
          }
        },
        drops: %{
          "0" => %{
            good_id: good_a.id,
            location_id: drop_loc.id,
            sales_position_id: sales.id,
            planned_mt: "20",
            actual_mt: "20"
          }
        }
      }
    )
    |> render_submit()

    assert render(lv) =~ "Trip saved successfully"
    refute has_element?(lv, "#desk-selection-tray")
    assert has_element?(lv, "#desk-supply-#{other_supply.id}")

    lv |> element("#desk-trips-toggle") |> render_click()
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
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "30",
              "actual_mt" => "30"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "30",
              "actual_mt" => "30"
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
    # default: active only
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

    lv
    |> form("#desk-trip-form",
      trip: %{
        date: "2026-07-27",
        transport_mode: "company_own",
        status: "draft",
        loads: %{
          "0" => %{
            good_id: good.id,
            location_id: load_loc.id,
            supply_position_id: supply.id,
            planned_mt: "50",
            actual_mt: "50"
          }
        },
        drops: %{
          "0" => %{
            good_id: good.id,
            location_id: wh.id,
            planned_mt: "50",
            actual_mt: "50"
          }
        }
      }
    )
    |> render_submit()

    assert render(lv) =~ "Trip saved successfully"
    lv |> element("#desk-trips-toggle") |> render_click()
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

  test "desk new trip modal saves and lists trip", %{conn: conn, company: company, user: user} do
    good = good_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "status" => "open",
        "title" => "S1"
      })

    load_loc = location_fixture(company, user, %{"kind" => "supplier_site"})
    drop_loc = location_fixture(company, user, %{"kind" => "own_warehouse"})

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    lv |> element("#desk-new-trip") |> render_click()
    assert has_element?(lv, "#desk-trip-form")

    lv
    |> form("#desk-trip-form",
      trip: %{
        date: "2026-07-25",
        transport_mode: "company_own",
        status: "draft",
        loads: %{
          "0" => %{
            good_id: good.id,
            location_id: load_loc.id,
            supply_position_id: supply.id,
            planned_mt: "10",
            actual_mt: "10"
          }
        },
        drops: %{
          "0" => %{
            good_id: good.id,
            location_id: drop_loc.id,
            planned_mt: "10",
            actual_mt: "10"
          }
        }
      }
    )
    |> render_submit()

    assert render(lv) =~ "Trip saved successfully"
    lv |> element("#desk-trips-toggle") |> render_click()
    assert render(lv) =~ "TRP-"
  end
end
