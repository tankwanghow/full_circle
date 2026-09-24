defmodule FullCircleWeb.CsvControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), com: com}
  end

  # The exports are sent with send_chunked/2 rather than one send_resp/3, so the
  # rows and their encoded copy are not both resident at once. A chunked reply
  # has no content-length and an empty body is a valid response, which is what
  # these assert — the shape, not the volume.
  describe "chunked CSV export" do
    test "sends a chunked CSV with the download headers", %{conn: conn, com: com} do
      conn =
        get(conn, ~p"/companies/#{com.id}/csv", %{
          "report" => "fixed_assets_report",
          "tdate" => "2026-09-30"
        })

      assert conn.state == :chunked
      assert response(conn, 200)

      assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="fixed_assets_report_2026-09-30.csv")
             ]
    end

    test "the first chunk is the header row", %{conn: conn, com: com} do
      conn =
        get(conn, ~p"/companies/#{com.id}/csv", %{
          "report" => "fixed_assets_report",
          "tdate" => "2026-09-30"
        })

      assert response(conn, 200) =~ "acname"
    end
  end
end
