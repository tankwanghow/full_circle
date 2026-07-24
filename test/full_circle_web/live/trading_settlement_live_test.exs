defmodule FullCircleWeb.TradingSettlementLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Trading

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp completed_drop(company, user) do
    good = good_fixture(company, user, %{"name" => "Settle maize"})
    customer = contact_fixture(company, user, %{"name" => "Settle customer"})
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
        "quantity" => "30",
        "unit_price" => "1100",
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port", "name" => "Settle port"})
    site = location_fixture(company, user, %{"kind" => "customer_site", "name" => "Settle farm"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "SET1234",
          "loads" => [
            %{
              "planned_mt" => "30",
              "actual_mt" => "29.5",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "30",
              "actual_mt" => "29.5",
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

    {:ok, trip, _} = Trading.complete_trip(trip, company, user)
    {trip, hd(trip.drops), hd(trip.loads), customer, supplier}
  end

  test "settlement page lists uninvoiced drop", %{conn: conn, company: company, user: user} do
    {trip, drop, _load, customer, _supplier} = completed_drop(company, user)

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/settlement")

    assert html =~ "Trading Settlement"
    assert html =~ customer.name
    assert html =~ "Settle maize"
    assert html =~ "Settle farm"
    assert html =~ "29.5"
    assert html =~ ~s(id="settlement-row-#{drop.id}")
    assert html =~ ~s(id="select-row-#{drop.id}")
    assert html =~ ~s(id="open-trip-#{trip.id}-#{drop.id}")
  end

  test "clicking trip no opens trip form modal", %{conn: conn, company: company, user: user} do
    {trip, drop, _load, _customer, _supplier} = completed_drop(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/settlement")

    html =
      lv
      |> element("#open-trip-#{trip.id}-#{drop.id}")
      |> render_click()

    assert html =~ "Edit Trip"
    assert html =~ trip.reference_no
    assert has_element?(lv, "#settlement-trip-modal")
  end

  test "create invoice navigates to invoice form with prefill", %{
    conn: conn,
    company: company,
    user: user
  } do
    {_trip, drop, _load, customer, _supplier} = completed_drop(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/settlement")

    lv
    |> element("#select-row-#{drop.id}")
    |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} =
             lv
             |> element("#create-trading-doc")
             |> render_click()

    assert path =~ "/Invoice/new"
    assert path =~ "trading_drops="
    assert path =~ drop.id

    {:ok, _inv_lv, html} = live(conn, path)

    assert html =~ "New Invoice"
    assert html =~ customer.name
    assert html =~ "29.5" or html =~ "29.50"
    assert html =~ "SET1234"
    assert html =~ "SAL-"
    assert html =~ "Settle farm"
  end

  test "supplier tab lists unbilled load and creates pur invoice", %{
    conn: conn,
    company: company,
    user: user
  } do
    {_trip, _drop, load, _customer, supplier} = completed_drop(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/settlement")

    html =
      lv
      |> element("#tab-supplier")
      |> render_click()

    assert html =~ supplier.name
    assert html =~ ~s(id="settlement-row-#{load.id}")
    assert html =~ ~s(id="select-row-#{load.id}")

    lv
    |> element("#select-row-#{load.id}")
    |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} =
             lv
             |> element("#create-trading-doc")
             |> render_click()

    assert path =~ "/PurInvoice/new"
    assert path =~ "trading_loads="
    assert path =~ load.id

    {:ok, _lv, html} = live(conn, path)
    assert html =~ "New Purchase Invoice" or html =~ "Purchase Invoice"
    assert html =~ supplier.name
  end

  test "draft drops are listed without checkbox", %{conn: conn, company: company, user: user} do
    good = good_fixture(company, user, %{"name" => "Draft maize"})
    customer = contact_fixture(company, user, %{"name" => "Draft customer"})
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "status" => "collect"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    site = location_fixture(company, user, %{"kind" => "customer_site", "name" => "Draft site"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-22",
          "transport_mode" => "company_own",
          "vehicle_number" => "DFT9999",
          "status" => "draft",
          "loads" => [
            %{
              "planned_mt" => "12",
              "actual_mt" => "12",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "12",
              "actual_mt" => "12",
              "good_id" => good.id,
              "location_id" => site.id,
              "sales_position_id" => sales.id
            }
          ]
        },
        company,
        user
      )

    drop = hd(trip.drops)
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/settlement")

    assert html =~ "Draft customer"
    assert html =~ "Draft site"
    assert html =~ ~s(id="settlement-row-#{drop.id}")
    refute html =~ ~s(id="select-row-#{drop.id}")
    assert html =~ "draft"
  end
end
