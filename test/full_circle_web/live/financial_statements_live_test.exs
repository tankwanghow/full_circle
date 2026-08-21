defmodule FullCircleWeb.FinancialStatementsLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{closing_month: 12, closing_day: 31})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp txn!(com, account_id, date, amount) do
    %Transaction{}
    |> Transaction.changeset(%{
      doc_type: "Journal",
      doc_no: "J#{System.unique_integer([:positive])}",
      doc_date: date,
      particulars: "t",
      amount: amount,
      company_id: com.id,
      account_id: account_id
    })
    |> Repo.insert!()
  end

  defp acc!(com, user, type, name) do
    account_fixture(
      %{account_type: type, name: "#{name} #{System.unique_integer([:positive])}"},
      com,
      user
    )
  end

  describe "Financial Statements LiveView" do
    test "renders the form with the heading and report options", %{
      conn: conn,
      company: company
    } do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/financial_statements")
      assert html =~ "Financial Statements"
      assert html =~ "Trail Balance"
      assert html =~ "Cash Flow"
    end

    test "renders a trail balance", %{conn: conn, user: user, company: company} do
      bank = acc!(company, user, "Bank", "Maybank")
      rev = acc!(company, user, "Revenue", "Sales")
      txn!(company, bank.id, ~D[2026-02-01], 1000)
      txn!(company, rev.id, ~D[2026-02-01], -1000)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/companies/#{company.id}/financial_statements?search[report]=Trail Balance&search[t_date]=2026-07-31"
        )

      html = render_async(lv)
      assert html =~ rev.name
      assert html =~ bank.name
    end

    test "renders a cash flow with sections and cash reconciliation", %{
      conn: conn,
      user: user,
      company: company
    } do
      bank = acc!(company, user, "Bank", "Maybank")
      rev = acc!(company, user, "Revenue", "Sales")
      fa = acc!(company, user, "Fixed Asset", "Machinery")
      equity = acc!(company, user, "Equity", "Capital")

      # opening cash before the period
      txn!(company, bank.id, ~D[2025-06-01], 5000)
      txn!(company, equity.id, ~D[2025-06-01], -5000)
      # cash sale in period
      txn!(company, bank.id, ~D[2026-02-01], 1000)
      txn!(company, rev.id, ~D[2026-02-01], -1000)
      # machine bought in period
      txn!(company, bank.id, ~D[2026-03-01], -500)
      txn!(company, fa.id, ~D[2026-03-01], 500)

      {:ok, lv, _html} =
        live(
          conn,
          ~p"/companies/#{company.id}/financial_statements?search[report]=Cash Flow&search[f_date]=2026-01-01&search[t_date]=2026-07-31"
        )

      html = render_async(lv)

      assert html =~ "Revenue"
      assert html =~ "Fixed Asset"
      assert html =~ rev.name
      assert html =~ fa.name
      # cash accounts appear only in the reconciliation, not as rows
      refute html =~ bank.name

      assert html =~ "Net Cash Change"
      assert html =~ "Cash at Beginning of Period"
      assert html =~ "Cash at End of Period"
      # 5,000 opening; +1,000 - 500 in period; 5,500 closing
      assert html =~ "5,000.00"
      assert html =~ "500.00"
      assert html =~ "5,500.00"
    end
  end
end
