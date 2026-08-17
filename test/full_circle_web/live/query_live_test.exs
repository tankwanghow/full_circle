defmodule FullCircleWeb.QueryLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  test "hides generate when the company has no LLM", %{conn: conn, company: company} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/queries/new")
    refute html =~ "Generate SQL"
  end

  test "shows generate when the company has an LLM provider", %{
    conn: conn,
    company: company
  } do
    {:ok, _} =
      FullCircle.Sys.update_company_settings(company, "llm", %{
        "llm-provider" => "gemini",
        "llm-api-key" => "test"
      })

    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/queries/new")
    assert html =~ "Generate SQL"
    assert html =~ "Ask AI to draft SQL"

    html = lv |> element("#generate-sql") |> render_click()
    assert html =~ "Describe the query first"
  end

  test "prompt blur with the browser value payload does not crash", %{
    conn: conn,
    company: company
  } do
    {:ok, _} =
      FullCircle.Sys.update_company_settings(company, "llm", %{
        "llm-provider" => "gemini",
        "llm-api-key" => "test"
      })

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/queries/new")

    html =
      lv
      |> element("#ai-query-prompt")
      |> render_blur(%{"value" => ""})

    assert html =~ "Generate SQL"
  end
end
