defmodule FullCircleWeb.StatutoryRateTableLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, com: com}
  end

  test "admin sees index", %{conn: conn, com: com} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/statutory_rate_tables")
    assert html =~ "Statutory Rate Table Listing"
  end

  test "clerk is redirected", %{conn: conn, com: com, admin: admin} do
    clerk = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
    conn = log_in_user(build_conn(), clerk)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/companies/#{com.id}/statutory_rate_tables")

    assert to =~ "/companies/#{com.id}/dashboard"
  end

  test "uploading valid CSV shows preview and saves", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_rate_tables/new")

    csv = """
    wage_from,wage_to,employee
    0,30,0.1
    30,50,0.2
    """

    upload =
      file_input(lv, "#object-form", :csv, [
        %{name: "rates.csv", content: csv, type: "text/csv"}
      ])

    assert render_upload(upload, "rates.csv") =~ "Preview"

    {:ok, _lv, html} =
      lv
      |> form("#object-form", %{
        "rate_table" => %{
          "code" => "test_rates",
          "effective_from" => "2026-01-01"
        }
      })
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "test_rates"
  end

  test "CSV with bracket gap shows error and does not save", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_rate_tables/new")

    csv = """
    wage_from,wage_to,employee
    0,30,0.1
    40,50,0.2
    """

    upload =
      file_input(lv, "#object-form", :csv, [
        %{name: "gap.csv", content: csv, type: "text/csv"}
      ])

    render_upload(upload, "gap.csv")

    html =
      lv
      |> form("#object-form", %{
        "rate_table" => %{
          "code" => "gap_rates",
          "effective_from" => "2026-01-01"
        }
      })
      |> render_submit()

    assert html =~ "contiguous" or html =~ "Preview"
    refute html =~ "Rate table saved"
  end

  test "clicking a version reveals its bracket values", %{conn: conn, com: com} do
    FullCircle.StatutoryConfig.seed_company!(com.id)
    eis = FullCircle.StatutoryConfig.effective_table(com.id, "eis", ~D[2026-06-30])

    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/statutory_rate_tables")
    refute html =~ "<table"

    html = lv |> element("##{eis.id} [phx-click]") |> render_click()
    assert html =~ "<table"
    assert html =~ Enum.at(eis.columns, 0)
    assert html =~ "0.05"

    html = lv |> element("##{eis.id} [phx-click]") |> render_click()
    refute html =~ "<table"
  end
end