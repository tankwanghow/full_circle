defmodule FullCircleWeb.CashForecastLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  describe "Cash Forecast LiveView" do
    test "renders the form with Cash Forecast heading", %{conn: conn, company: company} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/cash_forecast")
      assert html =~ "Cash Forecast"
    end

    test "form contains Start Date input", %{conn: conn, company: company} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/cash_forecast")

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s|input[name="search[s_date]"]|)
             |> LazyHTML.to_tree() != []
    end

    test "with query params renders the weekly table and Free Cash header", %{
      conn: conn,
      company: company
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{company.id}/cash_forecast?search[s_date]=2026-06-08")

      html = render_async(lv)
      assert html =~ "Free Cash"
    end

    test "with query params renders the FD ladder box", %{conn: conn, company: company} do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{company.id}/cash_forecast?search[s_date]=2026-06-08")

      html = render_async(lv)
      assert html =~ "Fixed Deposit Tenure Ladder"
    end
  end
end
