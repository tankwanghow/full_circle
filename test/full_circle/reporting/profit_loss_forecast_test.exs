defmodule FullCircle.Reporting.ProfitLossForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  defp d(n), do: Decimal.new("#{n}")

  describe "build_periods/2" do
    test "computes category lines, subtotals and margins" do
      bounds = [{~D[2026-01-01], ~D[2026-01-30]}, {~D[2026-01-31], ~D[2026-03-01]}]

      # values are already sign-normalized (income & expense both positive)
      bt1 = %{"Revenue" => d(1000), "Cost Of Goods Sold" => d(400), "Expenses" => d(100)}
      bt2 = %{"Revenue" => d(500), "Cost Of Goods Sold" => d(200)}

      [p1, p2] = PLF.build_periods(bounds, [{bt1, :actual}, {bt2, :forecast}])

      assert p1.source == :actual
      assert Decimal.equal?(p1.revenue, d(1000))
      # 1000 - 400
      assert Decimal.equal?(p1.gross_profit, d(600))
      # 600 - 100
      assert Decimal.equal?(p1.operating_profit, d(500))
      assert Decimal.equal?(p1.net_profit, d(500))
      # 600/1000*100
      assert Decimal.equal?(p1.gross_margin, d("60.0"))
      assert Decimal.equal?(p1.net_margin, d("50.0"))

      assert p2.source == :forecast
      # 500 - 200
      assert Decimal.equal?(p2.net_profit, d(300))
    end

    test "zero revenue gives zero margin (no divide-by-zero)" do
      bounds = [{~D[2026-01-01], ~D[2026-01-30]}]
      [p1] = PLF.build_periods(bounds, [{%{"Expenses" => d(100)}, :actual}])
      assert Decimal.equal?(p1.revenue, d(0))
      assert Decimal.equal?(p1.net_profit, d(-100))
      assert Decimal.equal?(p1.gross_margin, d(0))
    end
  end

  describe "apply_tax/3" do
    defp periods(nets), do: Enum.map(nets, fn n -> %{net_profit: d(n)} end)
    defp tot(net), do: %{net_profit: d(net)}

    test "rate 0 -> zero tax, after-tax equals net" do
      {ps, ts} = PLF.apply_tax(periods([600, 400]), tot(1000), d(0))
      assert Decimal.equal?(ts.estimated_tax, d(0))
      assert Decimal.equal?(ts.net_profit_after_tax, d(1000))
      assert Enum.all?(ps, &Decimal.equal?(&1.estimated_tax, d(0)))
      assert Decimal.equal?(hd(ps).net_profit_after_tax, d(600))
    end

    test "flat 24% on a profitable year; per-period tax sums to the total" do
      {ps, ts} = PLF.apply_tax(periods([600, 400]), tot(1000), d(24))
      assert Decimal.equal?(ts.estimated_tax, d(240))
      assert Decimal.equal?(ts.net_profit_after_tax, d(760))
      [p1, p2] = ps
      assert Decimal.equal?(p1.estimated_tax, d(144))
      assert Decimal.equal?(p2.estimated_tax, d(96))
      assert Decimal.equal?(p1.net_profit_after_tax, d(456))
      sum = Decimal.add(p1.estimated_tax, p2.estimated_tax)
      assert Decimal.equal?(sum, ts.estimated_tax)
    end

    test "annual loss -> zero tax, after-tax equals net" do
      {ps, ts} = PLF.apply_tax(periods([-300, -100]), tot(-400), d(24))
      assert Decimal.equal?(ts.estimated_tax, d(0))
      assert Decimal.equal?(ts.net_profit_after_tax, d(-400))
      assert Enum.all?(ps, &Decimal.equal?(&1.estimated_tax, d(0)))
    end

    test "net = 0 exactly -> zero tax, no divide-by-zero" do
      {ps, ts} = PLF.apply_tax(periods([100, -100]), tot(0), d(24))
      assert Decimal.equal?(ts.estimated_tax, d(0))
      assert Decimal.equal?(ts.net_profit_after_tax, d(0))
      assert Enum.all?(ps, &Decimal.equal?(&1.estimated_tax, d(0)))
    end

    test "mixed-sign periods in a profitable year still reconcile" do
      {ps, ts} = PLF.apply_tax(periods([1000, -100]), tot(900), d(24))
      [p1, p2] = ps
      # full-year tax = 900 * 0.24 = 216; loss period gets a proportional credit
      assert Decimal.equal?(ts.estimated_tax, d(216))
      assert Decimal.compare(p2.estimated_tax, d(0)) == :lt
      sum = Decimal.add(p1.estimated_tax, p2.estimated_tax)
      assert Decimal.equal?(sum, ts.estimated_tax)
    end
  end

  describe "fy_month_bounds/2" do
    test "returns 12 calendar months for a 31-Dec closing company" do
      com = %{closing_month: 12, closing_day: 31}
      bounds = PLF.fy_month_bounds(com, 2026)
      assert length(bounds) == 12
      assert hd(bounds) == {~D[2026-01-01], ~D[2026-01-31]}
      assert List.last(bounds) == {~D[2026-12-01], ~D[2026-12-31]}
    end

    test "anchors on a non-calendar closing day" do
      com = %{closing_month: 6, closing_day: 30}
      bounds = PLF.fy_month_bounds(com, 2026)
      assert hd(bounds) == {~D[2025-07-01], ~D[2025-07-30]}
      assert List.last(bounds) == {~D[2026-05-31], ~D[2026-06-30]}
    end
  end

  describe "tax_rate/1" do
    test "defaults to 0 when unset" do
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: nil}), d(0))
    end

    test "reads a saved numeric or string rate" do
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => 24}}), d(24))

      assert Decimal.equal?(
               PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => "17.5"}}),
               d("17.5")
             )
    end

    test "blank, invalid or negative becomes 0" do
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => ""}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => "abc"}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => -5}}), d(0))
      assert Decimal.equal?(PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => "NaN"}}), d(0))

      assert Decimal.equal?(
               PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => "Infinity"}}),
               d(0)
             )

      assert Decimal.equal?(
               PLF.tax_rate(%{settings: %{"pl_forecast_tax_rate" => Decimal.new("-5")}}),
               d(0)
             )
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

  setup do
    admin = user_fixture()
    # closing 31 Dec -> financial year == calendar year
    com = company_fixture(admin, %{closing_month: 12, closing_day: 31})

    rev =
      account_fixture(
        %{account_type: "Revenue", name: "Sales #{System.unique_integer([:positive])}"},
        com,
        admin
      )

    exp =
      account_fixture(
        %{account_type: "Expenses", name: "Rent #{System.unique_integer([:positive])}"},
        com,
        admin
      )

    %{admin: admin, com: com, rev: rev, exp: exp}
  end

  describe "pl_forecast/2 actual periods" do
    test "shows real per-category P&L for the first month of the FY (sign-normalized)", %{
      com: com,
      rev: rev,
      exp: exp
    } do
      # Revenue is credit-normal: a sale posts a NEGATIVE amount on the revenue account.
      txn!(com, rev.id, ~D[2026-01-10], d(-1000))
      txn!(com, exp.id, ~D[2026-01-12], d(300))

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)
      p1 = hd(res.periods)

      assert res.start_date == ~D[2026-01-01]
      assert p1.period_start == ~D[2026-01-01]
      assert p1.period_end == ~D[2026-01-31]
      assert p1.source == :actual
      # flipped to positive income
      assert Decimal.equal?(p1.revenue, d(1000))
      assert Decimal.equal?(p1.expenses, d(300))
      # 1000 - 300
      assert Decimal.equal?(p1.net_profit, d(700))
      assert length(res.periods) == 12
    end

    test "quarterly produces 4 periods aligned to the closing day", %{com: com} do
      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :quarterly}, com)
      assert length(res.periods) == 4
      assert hd(res.periods).period_start == ~D[2026-01-01]
      assert hd(res.periods).period_end == ~D[2026-03-31]
      assert List.last(res.periods).period_end == ~D[2026-12-31]
    end

    test "as_of anchors the actual/forecast split", %{com: com} do
      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly, as_of: ~D[2026-03-15]}, com)
      assert res.as_of == ~D[2026-03-15]
      # Jan and Feb fully elapsed; March ends 03-31 > 03-15 -> forecast
      assert Enum.count(res.periods, &(&1.source == :actual)) == 2
    end
  end

  describe "period_category_transactions/4" do
    test "lists Revenue transactions as positive income", %{com: com, rev: rev} do
      txn!(com, rev.id, ~D[2026-01-10], d(-1000))
      txn!(com, rev.id, ~D[2026-01-20], d(-250))

      rows = PLF.period_category_transactions("Revenue", ~D[2026-01-01], ~D[2026-01-30], com)

      assert length(rows) == 2

      assert Enum.reduce(rows, Decimal.new(0), &Decimal.add(&2, &1.amount))
             |> Decimal.equal?(d(1250))
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
      # string coerced to int
      assert t2["Depreciation"] == 730
      # untouched -> default
      assert t2["Overhead"] == 365
      assert PLF.category_trailing(PLF.company_with_settings(com))["Revenue"] == 90
    end

    test "a category's run-rate uses only its own trailing window", %{com: com, rev: rev} do
      today = Date.utc_today()
      # outside a 30-day window
      txn!(com, rev.id, Date.add(today, -70), d(-7000))
      # inside it
      txn!(com, rev.id, Date.add(today, -10), d(-1000))

      {:ok, com} = PLF.save_category_trailing(com, %{"Revenue" => 30})
      res = PLF.pl_forecast(%{fy_year: today.year, granularity: :monthly}, com)

      fc = Enum.find(res.periods, &(&1.source == :forecast))
      days = Date.diff(fc.period_end, fc.period_start) + 1
      expected = Decimal.mult(Decimal.div(d(1000), d(30)), d(days))
      assert Decimal.equal?(fc.revenue, expected)
    end
  end

  describe "save_tax_rate/2 and tax_rate/1" do
    test "round-trips through settings", %{com: com} do
      assert Decimal.equal?(PLF.tax_rate(com), d(0))
      {:ok, _} = PLF.save_tax_rate(com, "24")
      com = PLF.company_with_settings(com)
      assert Decimal.equal?(PLF.tax_rate(com), d(24))

      {:ok, _} = PLF.save_tax_rate(com, "")
      com = PLF.company_with_settings(com)
      assert Decimal.equal?(PLF.tax_rate(com), d(0))
    end
  end

  describe "previous-FY fallback for zero-run-rate categories" do
    test "depreciation booked once last year is spread over the whole forecast year", %{
      com: com,
      admin: admin
    } do
      dep =
        account_fixture(
          %{account_type: "Depreciation", name: "Dep #{System.unique_integer([:positive])}"},
          com,
          admin
        )

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

    test "spreads over actuals even when the lump is inside the trailing window", %{
      com: com,
      admin: admin
    } do
      dep =
        account_fixture(
          %{account_type: "Depreciation", name: "Dep #{System.unique_integer([:positive])}"},
          com,
          admin
        )

      # annual lump booked at last year-end, which IS inside the 365-day trailing window
      txn!(com, dep.id, ~D[2025-12-31], d(12_000))

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)

      assert "Depreciation" in res.estimated_types
      jan = hd(res.periods)
      assert jan.source == :actual
      # spread across the row, not zero
      refute Decimal.equal?(jan.depreciation, d(0))
    end

    test "does nothing when the previous FY is also zero", %{com: com, admin: admin} do
      _dep =
        account_fixture(
          %{account_type: "Depreciation", name: "Dep #{System.unique_integer([:positive])}"},
          com,
          admin
        )

      res = PLF.pl_forecast(%{fy_year: 2026, granularity: :monthly}, com)

      refute "Depreciation" in res.estimated_types
      assert Decimal.equal?(hd(res.periods).depreciation, d(0))
    end
  end
end
