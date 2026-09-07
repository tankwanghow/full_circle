defmodule FullCircleWeb.PunchDeviceLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, comp: comp}
  end

  test "lists empty and creates a device showing pairing QR", %{conn: conn, comp: comp} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/punch_devices")
    assert html =~ "Punch Devices"

    html =
      lv
      |> form("#device-form", device: %{name: "Gate 1"})
      |> render_submit()

    assert html =~ "Gate 1"
    assert html =~ "fcpair:"
  end

  test "clerk is redirected", %{comp: comp, user: admin} do
    clerk = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(comp, clerk, "clerk", admin)
    conn = log_in_user(build_conn(), clerk)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/companies/#{comp.id}/punch_devices")

    assert to =~ "/companies/#{comp.id}/dashboard"
  end
end
