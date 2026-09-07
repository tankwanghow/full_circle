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

  test "pairing QR uses the browser origin, not Endpoint.url", %{conn: conn, comp: comp} do
    conn = %{conn | host: "192.168.1.112", port: 4000, scheme: :http}

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/punch_devices")

    html =
      lv
      |> form("#device-form", device: %{name: "Gate LAN"})
      |> render_submit()

    assert html =~ "fcpair:"
    assert html =~ "http://192.168.1.112:4000"
    refute html =~ FullCircleWeb.Endpoint.url()
  end

  test "warns when Punch Devices is opened on localhost", %{conn: conn, comp: comp} do
    conn = %{conn | host: "localhost", port: 4000, scheme: :http}

    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/punch_devices")

    assert html =~ "gate phone cannot reach localhost"
  end

  test "revoked gate name can be reused", %{conn: conn, comp: comp} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/punch_devices")

    lv
    |> form("#device-form", device: %{name: "Gate 1"})
    |> render_submit()

    lv
    |> element("button", "Revoke")
    |> render_click()

    html =
      lv
      |> form("#device-form", device: %{name: "Gate 1"})
      |> render_submit()

    assert html =~ "fcpair:"
    refute html =~ "has already been taken"
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
