defmodule FullCircleWeb.TradingLocationLiveTest do
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

  test "index lists locations and new form creates one", %{
    conn: conn,
    company: company,
    user: user
  } do
    location_fixture(company, user, %{"name" => "Port Klang"})

    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/trading/locations")
    assert html =~ "Trading Locations"
    assert html =~ "Port Klang"

    {:ok, form_lv, _} = live(conn, ~p"/companies/#{company.id}/trading/locations/new")

    {:ok, _, html} =
      form_lv
      |> form("#location-form", location: %{name: "Kajang farm", kind: "customer_site"})
      |> render_submit()
      |> follow_redirect(conn, ~p"/companies/#{company.id}/trading/locations")

    assert html =~ "Location saved successfully"
    assert html =~ "Kajang farm"
  end

  test "guest is redirected from locations", %{conn: conn, company: company, user: admin} do
    guest = user_fixture()
    FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)
    conn = log_in_user(conn, guest)

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, ~p"/companies/#{company.id}/trading/locations")

    assert path == "/companies/#{company.id}/dashboard"
  end
end
