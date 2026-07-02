defmodule FullCircleWeb.BundleControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{admin: admin, com: com}
  end

  test "admin downloads the bundle as JSON", %{conn: conn, admin: admin, com: com} do
    conn =
      conn
      |> log_in_user(admin)
      |> get(~p"/companies/#{com.id}/statutory_bundle/export")

    body = response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert %{"bundle_version" => 1} = Jason.decode!(body)
  end

  test "non-admin member is redirected without a body", %{conn: conn, admin: admin, com: com} do
    clerk = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)

    conn =
      conn
      |> log_in_user(clerk)
      |> get(~p"/companies/#{com.id}/statutory_bundle/export")

    assert redirected_to(conn) == "/companies/#{com.id}/dashboard"
  end
end
