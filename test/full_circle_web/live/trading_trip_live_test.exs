defmodule FullCircleWeb.TradingTripLiveTest do
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

  test "trips index and create trip with load/drop", %{conn: conn, company: company, user: user} do
    good = good_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "quantity" => "100",
        "title" => "Open vessel for trip",
        "status" => "open"
      })

    load_loc = location_fixture(company, user, %{"kind" => "supplier_site"})
    drop_loc = location_fixture(company, user, %{"kind" => "own_warehouse"})

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/trips")
    assert html =~ "Trips"

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/trading/trips/new")
    # open supplies appear in the load supply select
    assert html =~ "Open vessel for trip"

    # good_id resolved server-side from good_name (hidden empty fields can't be forced in LVTest)
    {:ok, _, html} =
      lv
      |> form("#trip-form",
        trip: %{
          date: "2026-07-10",
          transport_mode: "company_own",
          status: "draft",
          good_name: good.name,
          reference_no: "T-100",
          loads: %{
            "0" => %{
              location_id: load_loc.id,
              supply_position_id: supply.id,
              planned_mt: "40",
              actual_mt: "40"
            }
          },
          drops: %{
            "0" => %{
              location_id: drop_loc.id,
              supply_position_id: supply.id,
              planned_mt: "40",
              actual_mt: "40"
            }
          }
        }
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/companies/#{company.id}/trading/trips")

    assert html =~ "T-100" or html =~ "Trip saved"

    trips = Trading.list_trips(company, user)
    assert Enum.any?(trips, &(&1.reference_no == "T-100"))

    # open supply was promoted to collect because a load was created
    reloaded = Trading.get_supply_position!(supply.id, company, user)
    assert reloaded.status == "collect"
  end

  test "complete trip updates position board remaining", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "title" => "Board supply",
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
          "good_id" => good.id,
          "loads" => [
            %{
              "location_id" => load_loc.id,
              "supply_position_id" => supply.id,
              "planned_mt" => "40",
              "actual_mt" => "40"
            }
          ],
          "drops" => [
            %{
              "location_id" => drop_loc.id,
              "planned_mt" => "40",
              "actual_mt" => "40"
            }
          ]
        },
        company,
        user
      )

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/trips/#{trip.id}/edit")

    lv
    |> element("button", "Complete trip")
    |> render_click()

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/position_board")
    assert html =~ "Board supply"
    assert html =~ "60"
  end
end
