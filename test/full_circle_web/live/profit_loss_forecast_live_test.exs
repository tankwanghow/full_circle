defmodule FullCircleWeb.ProfitLossForecastLiveTest do
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

  # Mirrors the instalment_plan_live_test: posts a raw double-entry-style Journal line.
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

  describe "Profit & Loss Forecast LiveView" do
    test "renders the form with the heading", %{conn: conn, company: company} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/profit_loss_forecast")
      assert html =~ "Profit &amp; Loss Forecast" or html =~ "Profit & Loss Forecast"
    end

    test "with query params renders the category table (Net Profit row)", %{conn: conn, company: company} do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{company.id}/profit_loss_forecast?search[fy_year]=2026&search[granularity]=monthly")

      html = render_async(lv)
      assert html =~ "Net Profit"
      assert html =~ "Gross Margin"
    end

    test "toggling 'Full amount' switches table cells between compact (K/M) and delimited", %{
      conn: conn,
      user: user
    } do
      # 31-Dec close so FY 2026 == calendar 2026; Jan 2026 is an elapsed period (exact actual).
      company = company_fixture(user, %{closing_month: 12, closing_day: 31})

      rev =
        account_fixture(
          %{account_type: "Revenue", name: "Sales #{System.unique_integer([:positive])}"},
          company,
          user
        )

      # Income is credit-normal; the forecast flips the sign to a positive 1,234,567.
      txn!(company, rev.id, ~D[2026-01-10], -1_234_567)

      {:ok, lv, _} =
        live(conn, ~p"/companies/#{company.id}/profit_loss_forecast?search[fy_year]=2026&search[granularity]=monthly")

      html = render_async(lv)
      assert html =~ "1.23M"

      html2 = lv |> element("input[phx-click=toggle_full_amounts]") |> render_click()
      assert html2 =~ "1,234,567"
    end

    test "tax rows hidden at rate 0, shown after setting a rate", %{conn: conn, company: company} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/profit_loss_forecast")
      refute html =~ "Net Profit After Tax"

      lv |> element("button", "Trailing") |> render_click()

      lv
      |> form("form[phx-submit=save_settings]")
      |> render_submit(%{"tax_rate" => "24", "trailing" => %{}})

      html2 = render_async(lv)
      assert html2 =~ "Net Profit After Tax"
      assert html2 =~ "Estimated Tax"
    end

    # Security: non-admin users must be redirected from the forecast page since it now WRITES.
    test "non-admin (clerk) user is redirected away from the forecast page", %{
      conn: conn,
      company: company,
      user: admin
    } do
      clerk = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)

      clerk_conn = log_in_user(conn, clerk)

      assert {:error, {:live_redirect, %{to: path}}} =
               live(clerk_conn, ~p"/companies/#{company.id}/profit_loss_forecast")

      assert path =~ "/companies/#{company.id}"
    end

    # The planner section renders below the P&L table after the forecast runs.
    test "planner section renders below the P&L table (Instalment Due + Suggested estimate)", %{
      conn: conn,
      company: company
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{company.id}/profit_loss_forecast?search[fy_year]=2026&search[granularity]=monthly")

      html = render_async(lv)
      assert html =~ "Instalment Due"
      assert html =~ "Suggested estimate"
    end

    # Saving a plan from the embedded form persists it to the DB.
    test "saving the embedded plan form persists the estimate", %{
      conn: conn,
      company: company,
      user: _user
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{company.id}/profit_loss_forecast?search[fy_year]=2026&search[granularity]=monthly")

      _html = render_async(lv)

      fy_year = 2026

      lv
      |> form("#plan-form")
      |> render_submit(%{
        "plan" => %{
          "fy_year" => fy_year,
          "estimate_month" => "1",
          "estimate" => "50000",
          "tolerance_pct" => "30",
          "paid_overrides" => %{}
        }
      })

      saved = FullCircle.Tax.get_plan(company, fy_year)
      assert saved != nil
      assert Decimal.compare(saved.estimate, Decimal.new("50000")) == :eq
    end

    # The red under-estimation banner renders when the chosen estimate is below the
    # penalty-free floor. Same scenario as the standalone planner test.
    test "renders the under-estimation banner when the saved estimate is below the penalty-free floor",
         %{conn: _conn, user: user} do
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

      # Persisted plan with a tiny estimate so the embed keeps it (estimate > 0) instead
      # of falling back to the suggested value, putting it below the floor.
      {:ok, _} =
        FullCircle.Tax.create_or_update_plan(
          %{"fy_year" => 2026, "estimate" => "1", "tolerance_pct" => "30", "estimate_month" => 6},
          com,
          user
        )

      {:ok, lv, _html} =
        live(
          log_in_user(build_conn(), user),
          ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026"
        )

      html = render_async(lv)

      assert html =~ "below the penalty-free floor"
      # the penalty-check panel also shows the estimated 10% penalty figure
      assert html =~ "Estimated penalty (10%)"
      # ...and the net-profit ceiling (tax ceiling converted via the forecast rate)
      assert html =~ "Net-profit ceiling before penalty"
    end

    # Revise fills the NEXT open CP204A window (6/9/11) at/after the as-of month with
    # the forecast-suggested estimate and persists it; the original estimate and
    # estimate_month are untouched. The exact suggested value depends on the forecast
    # projection, so we assert it is positive rather than locking a figure. Past month
    # 11 (Dec run) there is no window left and nothing is saved.
    test "Revise recomputes and persists a positive estimate for the current FY month", %{
      conn: _conn,
      user: user
    } do
      # 31-Dec close -> FY == calendar year; default fy_year for 2026-06-11 is 2026.
      com = company_fixture(user, %{closing_month: 12, closing_day: 31})

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

      # Profitable FY window -> positive forecast tax at 24%.
      txn!(com, rev.id, ~D[2026-01-10], Decimal.new("-100000"))
      txn!(com, exp.id, ~D[2026-01-12], Decimal.new("20000"))
      {:ok, _} = PLF.save_tax_rate(com, "24")

      {:ok, lv, _html} =
        live(
          log_in_user(build_conn(), user),
          ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026"
        )

      _html = render_async(lv)

      lv |> element("button", "Revise") |> render_click()

      fy_year = 2026
      cur = FullCircle.Tax.current_fy_month(com, fy_year, Date.utc_today())

      case Enum.find(FullCircle.Tax.revision_months(), &(&1 >= cur)) do
        nil ->
          # December run: no CP204A window left, Revise saves nothing.
          assert FullCircle.Tax.get_plan(com, fy_year) == nil

        window ->
          plan = FullCircle.Tax.get_plan(com, fy_year)
          assert plan != nil
          # the original estimate is untouched (this plan had none)
          assert Decimal.compare(plan.estimate, Decimal.new(0)) == :eq
          # the revision landed in the next open window with a positive suggestion
          revised = Map.fetch!(plan.revisions, "#{window}")
          assert Decimal.compare(Decimal.new(revised), Decimal.new(0)) == :gt
          assert Decimal.compare(FullCircle.Tax.latest_estimate(plan), Decimal.new(0)) == :gt
      end
    end

    # s.107C(3) floor: with no prior-year plan in the app, the manually entered
    # last-year estimate drives the 85% warning banner.
    test "85% floor banner renders from a manually entered last-year estimate", %{
      conn: _conn,
      user: user
    } do
      com = company_fixture(user, %{closing_month: 12, closing_day: 31})

      # Original estimate 5,000 vs manual last-year 10,000 -> floor 8,500 -> breach.
      {:ok, _} =
        FullCircle.Tax.create_or_update_plan(
          %{
            "fy_year" => 2026,
            "estimate" => "5000",
            "tolerance_pct" => "30",
            "estimate_month" => 1,
            "prior_year_estimate" => "10000"
          },
          com,
          user
        )

      {:ok, lv, _html} =
        live(
          log_in_user(build_conn(), user),
          ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026"
        )

      html = render_async(lv)
      assert html =~ "Below the 85% floor"
      assert html =~ "8,500"
    end

    test "remedy panel shows under-estimation comparison when estimate too low", %{conn: _conn, user: user} do
      com = company_fixture(user, %{closing_month: 12, closing_day: 31})

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
      {:ok, _} = PLF.save_tax_rate(com, "24")

      {:ok, _} =
        FullCircle.Tax.create_or_update_plan(
          %{"fy_year" => 2026, "estimate" => "1", "tolerance_pct" => "30", "estimate_month" => 6},
          com,
          user
        )

      {:ok, lv, _html} =
        live(
          log_in_user(build_conn(), user),
          ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026"
        )

      html = render_async(lv)
      assert html =~ "Remedy comparison"
      assert html =~ "Pay penalty"
      assert html =~ "Director fee"
    end

    test "remedy panel shows over-estimation comparison when estimate too high", %{conn: _conn, user: user} do
      com = company_fixture(user, %{closing_month: 12, closing_day: 31})

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
      {:ok, _} = PLF.save_tax_rate(com, "24")

      {:ok, _} =
        FullCircle.Tax.create_or_update_plan(
          %{
            "fy_year" => 2026,
            "estimate" => "100000",
            "tolerance_pct" => "30",
            "estimate_month" => 6,
            "paid_overrides" => %{"1" => "50000"}
          },
          com,
          user
        )

      {:ok, lv, _html} =
        live(
          log_in_user(build_conn(), user),
          ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026"
        )

      html = render_async(lv)
      assert html =~ "Over-estimated"
      assert html =~ "Remedy comparison"
      assert html =~ "revise the CP204 estimate"
      refute html =~ "Defer remuneration"
    end

    test "no remedy panel when within tolerance", %{conn: _conn, user: user} do
      com = company_fixture(user, %{closing_month: 12, closing_day: 31})

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
      {:ok, _} = PLF.save_tax_rate(com, "24")

      forecast_tax =
        FullCircle.Tax.forecast_annual_tax(com, 2026, Date.utc_today())

      {:ok, _} =
        FullCircle.Tax.create_or_update_plan(
          %{
            "fy_year" => 2026,
            "estimate" => Decimal.to_string(forecast_tax),
            "tolerance_pct" => "30",
            "estimate_month" => 6
          },
          com,
          user
        )

      {:ok, lv, _html} =
        live(
          log_in_user(build_conn(), user),
          ~p"/companies/#{com.id}/profit_loss_forecast?search[fy_year]=2026"
        )

      html = render_async(lv)
      assert html =~ "Within the margin"
      refute html =~ "Remedy comparison"
    end
  end
end
