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

    test "shows As of date label and latest liquid hint", %{conn: conn, user: user, company: company} do
      import FullCircle.AccountingFixtures
      bank = account_fixture(%{account_type: "Bank", name: "Hint Bank"}, company, user)

      %FullCircle.Accounting.Transaction{}
      |> FullCircle.Accounting.Transaction.changeset(%{
        doc_type: "Journal",
        doc_no: "J1",
        doc_date: ~D[2026-06-30],
        particulars: "t",
        amount: Decimal.new(1000),
        company_id: company.id,
        account_id: bank.id
      })
      |> FullCircle.Repo.insert!()

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/companies/#{company.id}/cash_forecast?search[s_date]=2026-01-01&search[as_of]=2026-06-30"
        )

      html = render_async(lv)
      assert html =~ "As of date"
      assert html =~ "Latest liquid transaction"
      assert html =~ "2026-06-30"
    end
  end
end
