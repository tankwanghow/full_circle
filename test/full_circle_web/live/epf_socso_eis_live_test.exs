defmodule FullCircleWeb.EpfSocsoEisLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), com: com}
  end

  test "Contributions report renders and survives persisted settings", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, "/companies/#{com.id}/epfsocsoeis")

    # switching the dropdown must not crash (code_key has no clause for it in HR.Statutory)
    html =
      lv
      |> element("#search-form")
      |> render_change(%{"search" => %{"report" => "Contributions"}})

    assert html =~ "Contributions"

    # querying goes through handle_params and persists report = "Contributions"
    qry =
      URI.encode_query(%{
        "search[report]" => "Contributions",
        "search[month]" => "6",
        "search[year]" => "2026",
        "search[code]" => ""
      })

    {:ok, _lv, html} = live(conn, "/companies/#{com.id}/epfsocsoeis?#{qry}")
    assert html =~ "SOCSO EMPLOYEE"

    # a fresh visit reads the persisted setting back — must not crash either
    {:ok, _lv, html} = live(conn, "/companies/#{com.id}/epfsocsoeis")
    assert html =~ "Contributions"
  end
end
