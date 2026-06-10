defmodule FullCircle.Reporting.ProfitLossForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  defp d(n), do: Decimal.new("#{n}")

  describe "build_periods/2" do
    test "computes category lines, subtotals, margins and cumulative net" do
      bounds = [{~D[2026-01-01], ~D[2026-01-30]}, {~D[2026-01-31], ~D[2026-03-01]}]

      # values are already sign-normalized (income & expense both positive)
      bt1 = %{"Revenue" => d(1000), "Cost Of Goods Sold" => d(400), "Expenses" => d(100)}
      bt2 = %{"Revenue" => d(500), "Cost Of Goods Sold" => d(200)}

      [p1, p2] = PLF.build_periods(bounds, [{bt1, :actual}, {bt2, :forecast}])

      assert p1.source == :actual
      assert Decimal.equal?(p1.revenue, d(1000))
      assert Decimal.equal?(p1.gross_profit, d(600))        # 1000 - 400
      assert Decimal.equal?(p1.operating_profit, d(500))    # 600 - 100
      assert Decimal.equal?(p1.net_profit, d(500))
      assert Decimal.equal?(p1.gross_margin, d("60.0"))     # 600/1000*100
      assert Decimal.equal?(p1.net_margin, d("50.0"))
      assert Decimal.equal?(p1.cumulative_net, d(500))

      assert p2.source == :forecast
      assert Decimal.equal?(p2.net_profit, d(300))          # 500 - 200
      assert Decimal.equal?(p2.cumulative_net, d(800))      # running 500 + 300
    end

    test "zero revenue gives zero margin (no divide-by-zero)" do
      bounds = [{~D[2026-01-01], ~D[2026-01-30]}]
      [p1] = PLF.build_periods(bounds, [{%{"Expenses" => d(100)}, :actual}])
      assert Decimal.equal?(p1.revenue, d(0))
      assert Decimal.equal?(p1.net_profit, d(-100))
      assert Decimal.equal?(p1.gross_margin, d(0))
    end
  end
end

defmodule FullCircle.Reporting.ProfitLossForecastDBTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Reporting.ProfitLossForecast, as: PLF
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  defp d(n), do: Decimal.new("#{n}")

  defp txn!(com, account_id, date, amount) do
    %Transaction{}
    |> Transaction.changeset(%{
      doc_type: "Journal", doc_no: "J#{System.unique_integer([:positive])}",
      doc_date: date, particulars: "t", amount: amount,
      company_id: com.id, account_id: account_id
    })
    |> Repo.insert!()
  end

  setup do
    admin = user_fixture()
    # closing 31 Dec -> financial year == calendar year
    com = company_fixture(admin, %{closing_month: 12, closing_day: 31})
    rev = account_fixture(%{account_type: "Revenue", name: "Sales #{System.unique_integer([:positive])}"}, com, admin)
    exp = account_fixture(%{account_type: "Expenses", name: "Rent #{System.unique_integer([:positive])}"}, com, admin)
    %{admin: admin, com: com, rev: rev, exp: exp}
  end

  describe "pl_forecast/2 actual periods" do
    test "shows real per-category P&L for the first month of the FY (sign-normalized)", %{com: com, rev: rev, exp: exp} do
      # Revenue is credit-normal: a sale posts a NEGATIVE amount on the revenue account.
      txn!(com, rev.id, ~D[2026-01-10], d(-1000))
      txn!(com, exp.id, ~D[2026-01-12], d(300))

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)
      p1 = hd(res.periods)

      assert res.start_date == ~D[2026-01-01]
      assert p1.period_start == ~D[2026-01-01]
      assert p1.period_end == ~D[2026-01-31]
      assert p1.source == :actual
      assert Decimal.equal?(p1.revenue, d(1000))        # flipped to positive income
      assert Decimal.equal?(p1.expenses, d(300))
      assert Decimal.equal?(p1.net_profit, d(700))      # 1000 - 300
      assert length(res.periods) == 12
    end

    test "quarterly produces 4 periods aligned to the closing day", %{com: com} do
      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :quarterly}, com)
      assert length(res.periods) == 4
      assert hd(res.periods).period_start == ~D[2026-01-01]
      assert hd(res.periods).period_end == ~D[2026-03-31]
      assert List.last(res.periods).period_end == ~D[2026-12-31]
    end
  end

  describe "period_category_transactions/4" do
    test "lists Revenue transactions as positive income", %{com: com, rev: rev} do
      txn!(com, rev.id, ~D[2026-01-10], d(-1000))
      txn!(com, rev.id, ~D[2026-01-20], d(-250))

      rows = PLF.period_category_transactions("Revenue", ~D[2026-01-01], ~D[2026-01-30], com)

      assert length(rows) == 2
      assert Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.amount)) |> Decimal.equal?(d(1250))
    end
  end

  describe "settings (per-category trailing days)" do
    test "defaults to 365 and saves per-category overrides", %{com: com} do
      t = PLF.category_trailing(com)
      assert t["Revenue"] == 365
      assert t["Depreciation"] == 365

      {:ok, com2} = PLF.save_category_trailing(com, %{"Revenue" => 90, "Depreciation" => "730"})
      t2 = PLF.category_trailing(com2)
      assert t2["Revenue"] == 90
      assert t2["Depreciation"] == 730        # string coerced to int
      assert t2["Overhead"] == 365            # untouched -> default
      assert PLF.category_trailing(PLF.company_with_settings(com))["Revenue"] == 90
    end

    test "a category's run-rate uses only its own trailing window", %{com: com, rev: rev} do
      today = Date.utc_today()
      txn!(com, rev.id, Date.add(today, -70), d(-7000))  # outside a 30-day window
      txn!(com, rev.id, Date.add(today, -10), d(-1000))  # inside it

      {:ok, com} = PLF.save_category_trailing(com, %{"Revenue" => 30})
      res = PLF.pl_forecast(%{fy_year: today.year, granularity: :monthly}, com)

      fc = Enum.find(res.periods, &(&1.source == :forecast))
      days = Date.diff(fc.period_end, fc.period_start) + 1
      expected = Decimal.mult(Decimal.div(d(1000), d(30)), d(days))
      assert Decimal.equal?(fc.revenue, expected)
    end
  end

  describe "previous-FY fallback for zero-run-rate categories" do
    test "depreciation booked once last year is spread over the whole forecast year", %{com: com, admin: admin} do
      dep = account_fixture(%{account_type: "Depreciation", name: "Dep #{System.unique_integer([:positive])}"}, com, admin)
      # annual depreciation booked once in the previous FY (2025), outside the 365-day window
      txn!(com, dep.id, ~D[2025-01-15], d(12_000))

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)

      assert "Depreciation" in res.estimated_types

      # every period (here the elapsed January) carries 12000/365 * days_in_period
      jan = hd(res.periods)
      assert jan.source == :actual
      assert jan.period_end == ~D[2026-01-31]
      expected = Decimal.mult(Decimal.div(d(12_000), d(365)), d(31))
      assert Decimal.equal?(jan.depreciation, expected)
    end

    test "spreads over actuals even when the lump is inside the trailing window", %{com: com, admin: admin} do
      dep = account_fixture(%{account_type: "Depreciation", name: "Dep #{System.unique_integer([:positive])}"}, com, admin)
      # annual lump booked at last year-end, which IS inside the 365-day trailing window
      txn!(com, dep.id, ~D[2025-12-31], d(12_000))

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)

      assert "Depreciation" in res.estimated_types
      jan = hd(res.periods)
      assert jan.source == :actual
      refute Decimal.equal?(jan.depreciation, d(0))   # spread across the row, not zero
    end

    test "does nothing when the previous FY is also zero", %{com: com, admin: admin} do
      _dep = account_fixture(%{account_type: "Depreciation", name: "Dep #{System.unique_integer([:positive])}"}, com, admin)

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)

      refute "Depreciation" in res.estimated_types
      assert Decimal.equal?(hd(res.periods).depreciation, d(0))
    end
  end
end
