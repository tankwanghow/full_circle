defmodule FullCircleWeb.NoteLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp}
  end

  describe "index" do
    test "lists visible notes and searches", %{conn: conn, admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"title" => "Welding", "body" => "Ali welds"})
      note_fixture(comp, admin, %{"body" => "Ah Seng pays late"})

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes")
      assert html =~ "Welding"
      assert html =~ "Ah Seng pays late"

      lv |> form("#search-form", %{"search" => %{"terms" => "weld"}}) |> render_submit()
      assert_patch(lv)
      html = render(lv)
      assert html =~ "Welding"
      refute html =~ "Ah Seng pays late"
    end

    test "restricted notes are not listed for a clerk", %{admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"body" => "manager only", "visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, _lv, html} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes")
      refute html =~ "manager only"
    end

    test "a guest is sent back to the dashboard", %{admin: admin, comp: comp} do
      guest = user_with_role(comp, admin, "guest")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), guest), ~p"/companies/#{comp.id}/notes")

      assert to == "/companies/#{comp.id}/dashboard"
    end
  end
end
