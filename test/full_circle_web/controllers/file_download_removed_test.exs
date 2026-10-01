defmodule FullCircleWeb.FileDownloadRemovedTest do
  # Regression: /companies/:id/download/:filename used to send_download any
  # absolute path on the server to any logged-in user. The route must not exist.
  use FullCircleWeb.ConnCase
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  test "arbitrary-path download route is gone", %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    conn = log_in_user(conn, user)

    conn = get(conn, "/companies/#{company.id}/download/%2Fetc%2Fpasswd")
    assert conn.status == 404
    refute conn.resp_body =~ "root:"
  end

  test "Files page route is gone", %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    conn = log_in_user(conn, user)

    assert get(conn, "/companies/#{company.id}/upload_files").status == 404
  end
end
