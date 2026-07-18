defmodule FullCircleWeb.TradingOpenSalesLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "open sales lists active commitments", %{conn: conn, company: company, user: user} do
    sales =
      sales_position_fixture(company, user, %{
        "quantity" => "35",
        "status" => "open"
      })

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/open_sales")
    assert html =~ "Open Sales"
    assert html =~ sales.title
    assert html =~ "35"
  end

  test "mark fulfilled removes from open sales", %{conn: conn, company: company, user: user} do
    sales =
      sales_position_fixture(company, user, %{
        "quantity" => "20",
        "status" => "open"
      })

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/open_sales")
    assert has_element?(lv, "#open-sales-#{sales.id}")

    lv
    |> element("#fulfill-#{sales.id}")
    |> render_click()

    refute has_element?(lv, "#open-sales-#{sales.id}")
  end

  test "soft hold appears on position board without reducing remaining", %{
    conn: conn,
    company: company,
    user: user
  } do
    supply =
      supply_position_fixture(company, user, %{
        "quantity" => "100"
      })

    sales_position_fixture(company, user, %{
      "quantity" => "40",
      "preferred_supply_id" => supply.id,
      "status" => "open"
    })

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/position_board")
    assert html =~ supply.title
    assert html =~ "100"
    assert html =~ "40"
  end

  test "can create sales position via form", %{conn: conn, company: company, user: user} do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/sales_positions/new")

    # IDs resolved server-side from names; sales no is system-generated
    {:ok, _, html} =
      lv
      |> form("#sales-form",
        sales_position: %{
          quantity: "15",
          unit_price: "1300",
          customer_name: contact.name,
          good_name: good.name,
          status: "open"
        }
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/companies/#{company.id}/trading/sales_positions")

    assert html =~ "SAL-" or html =~ "Sales position"
  end
end
