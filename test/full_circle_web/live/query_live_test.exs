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

  defp query_fixture(com, name) do
    FullCircle.Repo.insert!(%FullCircle.UserQueries.Query{
      qry_name: name,
      sql_string: "select 1 as one",
      company_id: com.id
    })
  end

  describe "edit form scoping" do
    test "opens a query belonging to the active company", %{conn: conn, company: company} do
      q = query_fixture(company, "Mine")

      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/queries/#{q.id}/edit")

      assert html =~ "Mine"
    end

    # StdInterface.get!/2 is an unscoped Repo.get!, so the id alone decided what
    # was loaded — another company's saved SQL rendered in the edit form.
    test "will not open another company's query", %{conn: conn, company: company} do
      other = company_fixture(user_fixture(), %{name: "Other Sdn Bhd"})
      theirs = query_fixture(other, "Not Mine")

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/companies/#{company.id}/queries/#{theirs.id}/edit")
      end
    end
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
