defmodule FullCircleWeb.TradingWarehouseBoardLiveTest do
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

  test "board lists own warehouse on hand from completed trips", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    supply = supply_position_fixture(company, user, %{"good_id" => good.id, "quantity" => "100"})
    wh = location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Main silo"})
    supplier = location_fixture(company, user, %{"kind" => "supplier_site"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "good_id" => good.id,
          "loads" => [
            %{
              "planned_mt" => "30",
              "actual_mt" => "30",
              "good_id" => good.id,
              "location_id" => supplier.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "30",
              "actual_mt" => "30",
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    assert {:ok, _, _} = Trading.complete_trip(trip, company, user)

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/warehouse_board")
    assert html =~ "Warehouse Board"
    assert html =~ "Main silo"
    assert html =~ "30"
  end

  test "empty own warehouse shows zero on hand", %{conn: conn, company: company, user: user} do
    location_fixture(company, user, %{"kind" => "own_warehouse", "name" => "Empty bay"})

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/warehouse_board")
    assert html =~ "Empty bay"
    assert html =~ "0"
  end
end
