defmodule FullCircleWeb.TradingPositionBoardLiveTest do
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

  test "board shows open supply remaining", %{conn: conn, company: company, user: user} do
    supply_position_fixture(company, user, %{
      "title" => "May vessel maize",
      "quantity" => "100"
    })

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/position_board")
    assert html =~ "Position Board"
    assert html =~ "May vessel maize"
    assert html =~ "100"
  end
end
