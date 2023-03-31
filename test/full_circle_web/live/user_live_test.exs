defmodule FullCircleWeb.UserLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture(email: "a@a")
    clerk = user_fixture(email: "c@c")
    manager = user_fixture(email: "b@b")
    comp = company_fixture(admin, %{})
    FullCircle.Sys.allow_user_to_access(comp, clerk, "clerk", admin)
    FullCircle.Sys.allow_user_to_access(comp, manager, "manager", admin)
    %{conn: log_in_user(conn, admin), admin: admin, clerk: clerk, manager: manager, comp: comp}
  end

  test "admin list users", %{conn: conn, admin: admin, clerk: clerk, manager: manager, comp: comp} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/users")

    assert Enum.join([admin.email, manager.email, clerk.email], "") ==
             Floki.find(html, "span.email") |> Floki.text()
  end

  test "not admin list user", %{conn: conn, clerk: clerk, comp: comp} do
    conn = log_in_user(conn, clerk)
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/users")
    assert clerk.email == Floki.find(html, "span.email") |> Floki.text()
  end

  test "change user role", %{conn: conn, clerk: clerk, comp: comp} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/users")

    html =
      lv
      |> form("#user-#{clerk.id}")
      |> render_change(%{"user_list" => %{"role" => "admin"}})

    assert FullCircle.Sys.get_company_user(comp.id, clerk.id).role == "admin"
    assert html =~ "Success"
  end

  test "reset user password", %{conn: conn, clerk: clerk, comp: comp} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/users")

    html =
      lv
      |> element("#reset_user_password_#{clerk.id}")
      |> render_click()

    assert Floki.find(html, "#new_user_password_#{clerk.id}") |> Floki.text() =~
             "Password reset to"
  end

  describe "add user" do
    setup %{conn: conn, admin: admin} do
      comp1 = company_fixture(admin, %{})
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp1.id}/users/new")
      %{conn: conn, lv: lv, html: html, comp1: comp1}
    end

    test "new user layout", %{html: html} do
      assert html =~ "Add User"
      assert html =~ "Email\n</label>"
      assert html =~ "Role\n</label>"
    end

    test_input_feedback("user", "email", "", "can't be blank")
    test_input_feedback("user", "email", "fds", "must have the @ sign and no spaces")
    test_input_feedback("user", "email", "a@a", "already in company")

    test "add registered user", %{lv: lv} do
      assert lv
             |> form("#user", user: %{"email" => "c@c"})
             |> render_submit()
             |> Floki.parse_document!()
             |> Floki.find(~s|#add-user-message|)
             |> Floki.text() =~ "Successfully added"
    end

    test "add new user", %{lv: lv} do
      html =
        lv
        |> form("#user", user: %{"email" => "z@z"})
        |> render_submit()
        |> Floki.parse_document!()
        |> Floki.find(~s|#add-user-message|)
        |> Floki.text()

      assert html =~ "Successfully added"
      assert html =~ "Password"
    end

    test "fail to add user", %{lv: lv} do
      html =
        lv
        |> form("#user", user: %{"email" => "a@a"})
        |> render_submit()
        |> Floki.parse_document!()
        |> Floki.find(~s|#add-user-message|)
        |> Floki.text()

      assert html =~ "Failed to add user"
    end
  end
end
