defmodule FullCircleWeb.PageControllerTest do
  use FullCircleWeb.ConnCase
  import FullCircle.UserAccountsFixtures

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Log in"
    assert html_response(conn, 200) =~ "Register"
  end

  test "GET / login user", %{conn: conn} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/")

    assert html_response(conn, 200) =~ "Dashboard"
    assert html_response(conn, 200) =~ "Farms"
    assert html_response(conn, 200) =~ "Log out"
  end
end
