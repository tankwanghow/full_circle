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
end
