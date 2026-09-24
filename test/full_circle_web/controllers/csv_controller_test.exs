defmodule FullCircleWeb.CsvControllerTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Repo
  alias FullCircle.UserQueries.Query

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), com: com, admin: admin}
  end

  defp query_fixture(com, name \\ "My Query") do
    Repo.insert!(%Query{
      qry_name: name,
      sql_string: "select 1 as one",
      company_id: com.id
    })
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

  describe "a report that finds nothing" do
    # Map.keys/1 on Enum.at(0) raised a 500 whenever the date range matched no
    # rows. An empty report is a normal outcome, not a server error.
    test "exports an empty file instead of raising", %{conn: conn, com: com} do
      conn =
        get(conn, ~p"/companies/#{com.id}/csv", %{
          "report" => "tagged_bills",
          "tags" => "all",
          "fdate" => "2026-09-01",
          "tdate" => "2026-09-30"
        })

      assert conn.state == :chunked
      assert response(conn, 200) == ""
    end
  end

  describe "saved query export" do
    # No happy-path test: QueryRepo has no database configured in the test env,
    # so a query that actually executes cannot run here. Both cases below are
    # refusals, which short-circuit before QueryRepo is touched.

    # execute/3 returns {:error, :not_authorise}, which matches {col, row} and
    # used to reach the CSV encoder as column names.
    test "refuses a role that may not run queries", %{conn: conn, com: com, admin: admin} do
      cashier = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, cashier, "cashier", admin)
      q = query_fixture(com)

      conn =
        conn
        |> log_in_user(cashier)
        |> get(~p"/companies/#{com.id}/csv", %{"report" => "queries", "id" => q.id})

      assert conn.status == 403
    end

    test "a malformed query id is not found, not a 500", %{conn: conn, com: com} do
      conn = get(conn, ~p"/companies/#{com.id}/csv", %{"report" => "queries", "id" => "nope"})

      assert conn.status == 404
    end

    test "will not run another company's saved query", %{conn: conn, com: com} do
      other_q = query_fixture(company_fixture(user_fixture(), %{name: "Other Sdn Bhd"}))

      conn = get(conn, ~p"/companies/#{com.id}/csv", %{"report" => "queries", "id" => other_q.id})

      assert conn.status == 404
    end
  end
end
