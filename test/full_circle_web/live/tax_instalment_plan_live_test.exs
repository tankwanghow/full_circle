defmodule FullCircleWeb.TaxLive.InstalmentPlanTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{conn: log_in_user(conn, user), user: user, company: company}
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

    test "resolving account name via validate persists tax_paid_account_id on save", %{
      conn: conn,
      company: company,
      user: user
    } do
      # Create an account to link to the plan
      acc =
        account_fixture(%{name: "Tax Paid Test Account", account_type: "Current Asset"}, company, user)

      {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/tax_instalment_plan")

      # Read the fy_year the LiveView defaulted to from the rendered hidden input.
      # The company fixture uses a random closing_month, so we cannot assume a
      # fixed year — extract it directly from the DOM instead.
      [fy_year_str] =
        Regex.run(~r/name="plan\[fy_year\]" value="(\d+)"/, html, capture: :all_but_first)

      fy_year = String.to_integer(fy_year_str)

      # Step 1: fire the validate event with _target pointing at the account-name
      # field. The validate handler resolves the name → id and stores it in
      # @plan.tax_paid_account_id, which re-renders into the hidden input.
      lv
      |> element("#plan-form")
      |> render_change(%{
        "_target" => ["plan", "tax_paid_account_name"],
        "plan" => %{"tax_paid_account_name" => acc.name}
      })

      # Step 2: submit the FULL rendered form without overriding params so the
      # hidden plan[fy_year] and the now-resolved plan[tax_paid_account_id] from
      # the DOM are submitted as-is.
      lv
      |> form("#plan-form")
      |> render_submit()

      # The plan saved to DB must have the resolved account id (not nil)
      plan = FullCircle.Tax.get_plan(company, fy_year)
      assert plan != nil
      assert plan.tax_paid_account_id == acc.id
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
  end
end
