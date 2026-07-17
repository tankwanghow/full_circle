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
    good = good_fixture(company, user)
    supply_position_fixture(company, user, %{"title" => "Desk supply A", "good_id" => good.id})
    location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Desk silo"})
    sales_position_fixture(company, user, %{"title" => "Desk sales B", "status" => "open", "good_id" => good.id})

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/desk")
    assert html =~ "Trading Desk"
    assert html =~ "Desk supply A"
    assert html =~ "Desk silo"
    assert html =~ "Desk sales B"
    assert html =~ "Trips"
  end

  test "create supply from desk modal appears on board", %{
    conn: conn,
    company: company,
    user: user
  } do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)

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
    refute has_element?(lv, "#desk-modal")
  end

  test "create sales from desk modal appears on open sales", %{
    conn: conn,
    company: company,
    user: user
  } do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)

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
    assert html =~ "Modal sales Y"
    refute has_element?(lv, "#desk-modal")
  end

  test "row click opens supply edit modal", %{conn: conn, company: company, user: user} do
    supply =
      supply_position_fixture(company, user, %{"title" => "Edit me supply"})

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/desk")

    lv |> element("#desk-supply-#{supply.id}") |> render_click()
    assert has_element?(lv, "#desk-modal")
    assert has_element?(lv, "#desk-supply-form")
    assert render(lv) =~ "Edit me supply"
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
        good_name: good.name,
        reference_no: "DESK-T1",
        loads: %{
          "0" => %{
            location_id: load_loc.id,
            supply_position_id: supply.id,
            planned_mt: "10",
            actual_mt: "10"
          }
        },
        drops: %{
          "0" => %{location_id: drop_loc.id, planned_mt: "10", actual_mt: "10"}
        }
      }
    )
    |> render_submit()

    assert render(lv) =~ "DESK-T1"
  end
end
