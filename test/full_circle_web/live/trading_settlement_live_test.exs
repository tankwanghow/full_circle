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

  defp completed_drop(company, user, opts \\ []) do
    tag = Keyword.get(opts, :tag, "A")
    good = good_fixture(company, user, %{"name" => "Settle maize #{tag}"})
    customer = contact_fixture(company, user, %{"name" => "Settle customer #{tag}"})
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

    port = location_fixture(company, user, %{"kind" => "port", "name" => "Settle port #{tag}"})

    site =
      location_fixture(company, user, %{"kind" => "customer_site", "name" => "Settle farm #{tag}"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "SET#{tag}",
          "loads" => [
            %{
              "planned" => "30",
              "actual" => "29.5",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "30",
              "actual" => "29.5",
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
    assert html =~ "Settle maize A"
    assert html =~ "Settle farm A"
    assert html =~ "29.5"
    assert html =~ ~s(id="settlement-row-#{drop.id}")
    assert html =~ ~s(id="select-row-#{drop.id}")
    assert html =~ ~s(id="open-trip-#{trip.id}-#{drop.id}")
  end

  test "trip_id opens single-trip page with all three bill sections", %{
    conn: conn,
    company: company,
    user: user
  } do
    {trip_a, drop_a, load_a, _customer, _supplier} = completed_drop(company, user, tag: "A")
    {trip_b, drop_b, _load_b, _c2, _s2} = completed_drop(company, user, tag: "B")

    {:ok, lv, html} =
      live(conn, ~p"/companies/#{company.id}/trading/settlement?trip_id=#{trip_a.id}")

    assert html =~ "Trip Settlement"
    assert html =~ trip_a.reference_no
    assert has_element?(lv, "#settlement-trip-page")
    assert has_element?(lv, "#settlement-back-desk")
    assert has_element?(lv, "#settlement-stream-customer")
    assert has_element?(lv, "#settlement-stream-supplier")
    assert has_element?(lv, "#settlement-stream-transport")
    assert has_element?(lv, "#create-trading-doc-customer")
    assert has_element?(lv, "#create-trading-doc-supplier")
    assert has_element?(lv, "#create-trading-doc-transport")

    # No board tabs / filters / show-all on trip page
    refute has_element?(lv, "#tab-customer")
    refute has_element?(lv, "#tab-supplier")
    refute has_element?(lv, "#settlement-filters")
    refute has_element?(lv, "#settlement-clear-trip-filter")

    assert has_element?(lv, "#settlement-row-#{drop_a.id}")
    assert has_element?(lv, "#settlement-row-#{load_a.id}")
    refute has_element?(lv, "#settlement-row-#{drop_b.id}")
    refute html =~ trip_b.reference_no
  end

  test "admin waives and un-waives settlement lines on the trip page", %{
    conn: conn,
    company: company,
    user: user
  } do
    {trip, drop, load, _customer, _supplier} = completed_drop(company, user)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/trading/settlement?trip_id=#{trip.id}")

    # Unbilled billable rows offer Waive to an admin (both streams)
    assert has_element?(lv, "#waive-row-#{drop.id}")
    assert has_element?(lv, "#waive-row-#{load.id}")

    # Waive the customer drop with a reason
    lv |> element("#waive-row-#{drop.id}") |> render_click()
    assert has_element?(lv, "#settlement-waive-form")

    lv
    |> form("#settlement-waive-form", %{"reason" => "free delivery"})
    |> render_submit()

    refute has_element?(lv, "#settlement-waive-form")
    assert has_element?(lv, "#settlement-waived-#{drop.id}")
    # No longer selectable for billing; waive button gone, un-waive offered
    refute has_element?(lv, "#select-row-#{drop.id}")
    refute has_element?(lv, "#waive-row-#{drop.id}")
    assert has_element?(lv, "#unwaive-row-#{drop.id}")
    assert render(lv) =~ "free delivery"

    # Un-waive restores billability
    lv |> element("#unwaive-row-#{drop.id}") |> render_click()
    refute has_element?(lv, "#settlement-waived-#{drop.id}")
    assert has_element?(lv, "#select-row-#{drop.id}")
    assert has_element?(lv, "#waive-row-#{drop.id}")
  end

  test "waive with blank reason is rejected", %{conn: conn, company: company, user: user} do
    {trip, drop, _load, _customer, _supplier} = completed_drop(company, user)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/trading/settlement?trip_id=#{trip.id}")

    lv |> element("#waive-row-#{drop.id}") |> render_click()

    lv
    |> form("#settlement-waive-form", %{"reason" => "   "})
    |> render_submit()

    refute has_element?(lv, "#settlement-waived-#{drop.id}")
    assert has_element?(lv, "#waive-row-#{drop.id}")
  end

  test "non-admin sees no waive controls", %{company: company, user: admin} do
    {trip, drop, load, _customer, _supplier} = completed_drop(company, admin)

    manager = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, manager, "manager", admin)
    conn = log_in_user(Phoenix.ConnTest.build_conn(), manager)

    {:ok, lv, _html} =
      live(conn, ~p"/companies/#{company.id}/trading/settlement?trip_id=#{trip.id}")

    assert has_element?(lv, "#settlement-row-#{drop.id}")
    refute has_element?(lv, "#waive-row-#{drop.id}")
    refute has_element?(lv, "#waive-row-#{load.id}")
  end

  test "trip filter shows billed drop with invoice link", %{
    conn: conn,
    company: company,
    user: user
  } do
    {trip, drop, _load, _customer, _supplier} = completed_drop(company, user, tag: "Bill")
    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert {:ok, %{create_invoice: inv}} =
             Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    {:ok, lv, html} =
      live(conn, ~p"/companies/#{company.id}/trading/settlement?trip_id=#{trip.id}")

    assert has_element?(lv, "#settlement-row-#{drop.id}")
    refute has_element?(lv, "#select-row-#{drop.id}")
    assert has_element?(lv, "#settlement-doc-#{drop.id}")
    assert html =~ inv.invoice_no
    assert html =~ ~s(href="/companies/#{company.id}/Invoice/#{inv.id}/edit")
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
    assert html =~ "SETA"
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

  test "transport tab lists agent haul and opens pur invoice", %{
    conn: conn,
    company: company,
    user: user
  } do
    good = good_fixture(company, user)
    customer = contact_fixture(company, user)
    supplier = contact_fixture(company, user)
    agent = contact_fixture(company, user, %{"name" => "Live Haul Agent"})

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

    port = location_fixture(company, user, %{"kind" => "port", "name" => "Live Port"})
    site = location_fixture(company, user, %{"kind" => "customer_site", "name" => "Live Farm"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "agent",
          "transport_agent_id" => agent.id,
          "transport_agent_name" => agent.name,
          "vehicle_number" => "LVH 1",
          "loads" => [
            %{
              "planned" => "15",
              "actual" => "15",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "15",
              "actual" => "15",
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
    drop = hd(trip.drops)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/trading/settlement")

    html =
      lv
      |> element("#tab-transport")
      |> render_click()

    assert html =~ "Live Haul Agent"
    assert html =~ "Live Port"
    assert html =~ "Live Farm"
    assert html =~ ~s(id="settlement-row-#{drop.id}")
    assert html =~ ~s(id="select-row-#{drop.id}")

    lv
    |> element("#select-row-#{drop.id}")
    |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} =
             lv
             |> element("#create-trading-doc")
             |> render_click()

    assert path =~ "/PurInvoice/new"
    assert path =~ "trading_transport_drops="
    assert path =~ drop.id

    {:ok, _lv, html} = live(conn, path)
    assert html =~ agent.name
    assert html =~ "Live Port" or html =~ "Live Farm"
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
              "planned" => "12",
              "actual" => "12",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "12",
              "actual" => "12",
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
