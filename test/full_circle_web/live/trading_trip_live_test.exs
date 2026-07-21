defmodule FullCircleWeb.TradingTripLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Trading
  alias FullCircle.Trading.Balances

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "legacy trips index URL opens trading desk", %{conn: conn, company: company} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/trips")
    assert html =~ "desk_supply" or html =~ "desk_trips"
  end

  test "trip new URL opens desk with trip modal", %{conn: conn, company: company} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/trips/new")
    assert html =~ "desk-modal" or html =~ "desk-trip-form" or html =~ "trip-form"
  end

  test "trip edit URL opens desk with trip modal and complete works", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "100"
      })

    load_loc = location_fixture(company, user)
    drop_loc = location_fixture(company, user)

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-11",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "good_id" => good.id,
              "location_id" => load_loc.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "40",
              "actual_mt" => "40"
            }
          ],
          "drops" => [
            %{
              "good_id" => good.id,
              "location_id" => drop_loc.id,
              "planned_mt" => "40",
              "actual_mt" => "40"
            }
          ]
        },
        company,
        user
      )

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/trips/#{trip.id}/edit")
    assert html =~ "desk-modal" or html =~ trip.reference_no or html =~ "trip-form"

    lv
    |> element("button", "Complete trip")
    |> render_click()

    remaining = Balances.supply_remaining(Trading.get_supply_position!(supply.id, company, user))
    assert Decimal.eq?(remaining, Decimal.new("60"))
  end
end
