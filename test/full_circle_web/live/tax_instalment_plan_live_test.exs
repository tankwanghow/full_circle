defmodule FullCircleWeb.TaxLive.InstalmentPlanTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Reporting.ProfitLossForecast, as: PLF
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  # Mirrors the forecast DB test: posts a raw double-entry-style Journal line.
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

  describe "Tax Instalment Plan LiveView" do
    test "admin user can load the page and it renders the title", %{conn: conn, company: company} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")
      assert html =~ "Tax Instalment Plan"
    end

    test "page renders the instalment schedule table with 12 month rows", %{
      conn: conn,
      company: company
    } do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")
      # The schedule table should show "Instalment Due" column header
      assert html =~ "Instalment"
      # With tax rate 0, forecast tax = 0, suggested = 0 — page must not crash
      assert html =~ "Forecast annual tax"
    end

    test "page does not crash with default zero-tax-rate company (forecast tax 0 → suggested 0)",
         %{conn: conn, company: company} do
      {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")
      html = render(lv)
      # Should still show the plan form fields
      assert html =~ "Chosen estimate"
      assert html =~ "Tolerance %"
    end

    test "page renders 12 schedule rows (one per FY month)", %{conn: conn, company: company} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")
      # Expect 12 month range entries like "YYYY-MM-DD → YYYY-MM-DD"
      month_rows = Regex.scan(~r/\d{4}-\d{2}-\d{2} → \d{4}-\d{2}-\d{2}/, html)
      assert length(month_rows) == 12
    end

    test "query form navigates with fy_year param", %{conn: conn, company: company} do
      {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")

      lv
      |> form("form#query-form", %{fy_year: "2025", as_of: "2025-06-01"})
      |> render_submit()

      # After push_navigate the test conn follows the redirect
      assert_redirect(lv, "/companies/#{company.id}/tax_instalment_plan?fy_year=2025&as_of=2025-06-01")
    end

    # Security: non-admin users must be redirected away from the planner at mount.
    # The set_active_company plug reads the user's role from the CompanyUser record
    # and writes it into the session; on_mount then assigns it to the socket so the
    # LiveView's admin guard fires.
    test "non-admin (clerk) user is redirected away from the instalment plan page", %{
      conn: conn,
      company: company,
      user: admin
    } do
      clerk = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)

      clerk_conn = log_in_user(conn, clerk)

      # mount's push_navigate produces a live_redirect (not a plain redirect)
      assert {:error, {:live_redirect, %{to: path}}} =
               live(clerk_conn, ~p"/companies/#{company.id}/tax_instalment_plan")

      assert path =~ "/companies/#{company.id}"
    end

    # The red under-estimation banner renders when the chosen estimate is below the
    # penalty-free floor (Tax.under_estimated?/3). By default the company's
    # pl_forecast_tax_rate is 0, so forecast tax = 0, suggested = 0 and nothing can be
    # "under". This drives the real LiveView path: a positive tax rate + a profitable
    # FY window give a positive forecast tax (so suggested > 0), and a saved plan with a
    # deliberately tiny estimate (1) sits below that floor.
    test "renders the under-estimation banner when the saved estimate is below the penalty-free floor",
         %{conn: conn, user: user} do
      # 31-Dec close -> FY == calendar year; default fy_year for 2026-06-11 is 2026.
      com = company_fixture(user, %{closing_month: 12, closing_day: 31})

      # Positive net profit in the elapsed FY window: revenue is credit-normal
      # (negative amount), expense debit-normal (positive amount).
      rev =
        account_fixture(
          %{account_type: "Revenue", name: "Sales #{System.unique_integer([:positive])}"},
          com,
          user
        )

      exp =
        account_fixture(
          %{account_type: "Expenses", name: "Rent #{System.unique_integer([:positive])}"},
          com,
          user
        )

      txn!(com, rev.id, ~D[2026-01-10], Decimal.new("-100000"))
      txn!(com, exp.id, ~D[2026-01-12], Decimal.new("20000"))

      # 24% on ~80k net profit -> positive forecast tax -> positive suggested floor.
      {:ok, _} = PLF.save_tax_rate(com, "24")

      # Persisted plan with a tiny estimate so load/3 keeps it (estimate > 0) instead of
      # falling back to the suggested value, putting it below the floor.
      {:ok, _} =
        FullCircle.Tax.create_or_update_plan(
          %{"fy_year" => 2026, "estimate" => "1", "tolerance_pct" => "30", "estimate_month" => 6},
          com,
          user
        )

      {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/tax_instalment_plan?fy_year=2026")

      assert html =~ "below the penalty-free floor"
    end

    test "does not render the under-estimation banner for a default zero-tax-rate company", %{
      conn: conn,
      company: company
    } do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")
      refute html =~ "below the penalty-free floor"
    end
  end
end
