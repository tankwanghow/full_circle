defmodule FullCircleWeb.ActiveCompanyTest do
  use FullCircleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    not_admin = user_fixture()
    comp = company_fixture(user, %{name: "haha0"})
    FullCircle.Sys.allow_user_to_access(comp, not_admin, "clerk", user)
    %{conn: log_in_user(conn, user), user: user, comp: comp, not_admin: not_admin}
  end

  describe "active company" do
    test "store active company to session", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, "/companies")
      assert html =~ comp.name
      assert html =~ "Company Listing"
    end

    test "show company name", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ comp.name
      assert html =~ "Dashboard"
    end

    test "show users list menu", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ comp.name
      assert html =~ "Dashboard"
      assert html =~ "Users"
    end

    test "don't show users list in menu", %{conn: conn, comp: comp, not_admin: not_admin} do
      conn = log_in_user(conn, not_admin)
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ comp.name
      assert html =~ "Dashboard"
      refute html =~ "Users"
    end

    test "not authorise company", %{conn: conn} do
      comp1 = company_fixture(user_fixture(), %{name: "Tan How"})

      assert {:error, {:redirect, %{to: "/"}}} =
               result = live(conn, ~p"/companies/#{comp1.id}/dashboard")

      {:ok, conn} = follow_redirect(result, conn)
      assert conn.resp_body =~ "Not Authorise."
    end
  end
end
