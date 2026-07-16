defmodule FullCircle.Reporting.CashForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.CashForecast

  defp d(n), do: Decimal.new("#{n}")

  describe "fd_ladder/2" do
    test "rolling minimums and non-negative tenure increments (30-day periods)" do
      frees = [55, 60, 58, 70, 72, 80, 65, 90, 100, 100, 110, 120]
      periods = for {f, i} <- Enum.with_index(frees, 1), do: %{n: i, free_cash: d(f)}

      ladder = CashForecast.fd_ladder(periods, 30)

      assert ladder.lockable_1mo == d(55)
      assert ladder.lockable_3mo == d(55)
      assert ladder.lockable_6mo == d(55)
      assert ladder.lockable_12mo == d(55)
      assert ladder.place_12mo == d(55)
      assert ladder.place_6mo == d(0)
      assert ladder.place_3mo == d(0)
      assert ladder.place_1mo == d(0)
    end

    test "stepping-down free cash gives a real ladder (30-day periods)" do
      frees = [100, 100, 100, 80, 80, 80, 60, 60, 60, 50, 50, 50]
      periods = for {f, i} <- Enum.with_index(frees, 1), do: %{n: i, free_cash: d(f)}

      ladder = CashForecast.fd_ladder(periods, 30)

      # min period 1 (ceil(30/30)=1)
      assert ladder.lockable_1mo == d(100)
      # min 1-3 (ceil(90/30)=3)
      assert ladder.lockable_3mo == d(100)
      # min 1-6 (ceil(180/30)=6)
      assert ladder.lockable_6mo == d(80)
      # min 1-12 (ceil(365/30)->capped 12)
      assert ladder.lockable_12mo == d(50)
      assert ladder.place_12mo == d(50)
      # 80 - 50
      assert ladder.place_6mo == d(30)
      # 100 - 80
      assert ladder.place_3mo == d(20)
      # 100 - 100
      assert ladder.place_1mo == d(0)
    end

    test "14-day periods map tenures onto more buckets" do
      frees = for i <- 1..26, do: %{n: i, free_cash: d(i * 10)}
      ladder = CashForecast.fd_ladder(frees, 14)

      # min of first ceil(30/14)=3 -> period 1
      assert ladder.lockable_1mo == d(10)
      # min of first 7
      assert ladder.lockable_3mo == d(10)
      # min of first 13
      assert ladder.lockable_6mo == d(10)
    end
  end

  describe "seasonal_factors/1" do
    test "empty list gives no factors" do
      assert CashForecast.seasonal_factors([]) == []
    end

    test "all-zero shape falls back to flat (all 1)" do
      assert CashForecast.seasonal_factors([d(0), d(0), d(0)]) == [d(1), d(1), d(1)]
    end

    test "normalizes to mean 1 and shrinks 50% toward flat" do
      # raw factors for [0, 3000, 0] are [0, 3, 0]; shrunk halfway to 1 -> [0.5, 2, 0.5]
      factors = CashForecast.seasonal_factors([d(0), d(3000), d(0)])

      assert Enum.map(factors, &Decimal.to_string/1) == ["0.5", "2", "0.5"]
    end

    test "factors average to 1 so the run-rate level is preserved" do
      factors = CashForecast.seasonal_factors([d(100), d(200), d(300), d(400)])

      mean =
        factors
        |> Enum.reduce(d(0), &Decimal.add(&2, &1))
        |> Decimal.div(d(4))

      assert Decimal.equal?(mean, d(1))
    end
  end

  describe "build_forecast/3 roll-forward" do
    test "rolls balance forward from per-period base flows" do
      start = ~D[2026-06-08]

      res =
        CashForecast.build_forecast(
          %{
            opening: d(5000),
            base_in: List.duplicate(d(100), 12),
            base_out: List.duplicate(d(50), 12),
            sources: List.duplicate(:forecast, 12)
          },
          start,
          period_days: 30,
          periods_count: 12,
          buffer_periods: 1
        )

      [p1, p2 | _] = res.periods
      assert p1.period_start == ~D[2026-06-08]
      assert p1.source == :forecast
      assert p1.opening == d(5000)
      assert p1.baseline_in == d(100)
      assert p1.baseline_out == d(50)
      # 5000 + 100 - 50
      assert p1.closing == d(5050)
      assert p2.opening == d(5050)
      # 5050 + 100 - 50
      assert p2.closing == d(5100)
      assert length(res.periods) == 12
    end

    test "actual periods carry their own base flow and source, ladder uses forecast only" do
      start = ~D[2026-06-08]

      res =
        CashForecast.build_forecast(
          %{
            opening: d(1000),
            # period 1 actual (real flow), periods 2-3 forecast
            base_in: [d(500), d(100), d(100)],
            base_out: [d(200), d(50), d(50)],
            sources: [:actual, :forecast, :forecast]
          },
          start,
          period_days: 30,
          periods_count: 3,
          buffer_periods: 1
        )

      [p1, p2, _p3] = res.periods
      assert p1.source == :actual
      assert p1.baseline_in == d(500)
      # 1000 + 500 - 200
      assert p1.closing == d(1300)
      assert p2.source == :forecast
      # 1300 + 100 - 50
      assert p2.closing == d(1350)
      assert Map.has_key?(res.ladder, :place_12mo)
    end
  end
end

defmodule FullCircle.Reporting.CashForecastDBTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Reporting.CashForecast
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo
  import Ecto.Query

  defp d(n), do: Decimal.new("#{n}")

  defp txn!(com, account_id, date, amount, attrs \\ %{}) do
    %Transaction{}
    |> Transaction.changeset(
      Map.merge(
        %{
          doc_type: "Journal",
          doc_no: "J#{System.unique_integer([:positive])}",
          doc_date: date,
          particulars: "t",
          amount: amount,
          company_id: com.id,
          account_id: account_id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    bank = account_fixture(%{account_type: "Bank", name: "Test Bank"}, com, admin)
    %{admin: admin, com: com, bank: bank}
  end

  describe "opening_liquid_balance/3" do
    test "sums liquid txns strictly before start_date", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-01], d(1000))
      txn!(com, bank.id, ~D[2026-06-07], d(-300))
      # on start date -> excluded from opening
      txn!(com, bank.id, ~D[2026-06-08], d(999))

      ids = CashForecast.liquid_account_ids(com, :all)
      assert bank.id in ids

      bal = CashForecast.opening_liquid_balance(ids, ~D[2026-06-08], com)
      assert bal == d(700)
    end
  end

  describe "run_rate_flows/5" do
    test "scales ALL contact-null liquid churn from the trailing window to a period",
         %{com: com, bank: bank} do
      # the run-rate must include customer/supplier cash (Receipt/Payment/Deposit) and
      # operating flows (Journal) alike — it is the full liquid throughput.
      # Journal in
      txn!(com, bank.id, ~D[2026-04-01], d(1200))
      # customer in
      txn!(com, bank.id, ~D[2026-04-02], d(9000), %{doc_type: "Receipt"})
      # banked-in
      txn!(com, bank.id, ~D[2026-04-03], d(500), %{doc_type: "Deposit"})
      # supplier out
      txn!(com, bank.id, ~D[2026-04-04], d(-8000), %{doc_type: "Payment"})

      # contact-bearing flow is ignored (bank-side lines are contact-null)
      cont =
        Repo.one(
          from c in FullCircle.Accounting.Contact, where: c.company_id == ^com.id, limit: 1
        ) ||
          Repo.insert!(%FullCircle.Accounting.Contact{
            name: "C#{System.unique_integer([:positive])}",
            company_id: com.id
          })

      txn!(com, bank.id, ~D[2026-05-02], d(9_999_999), %{contact_id: cont.id})

      {rin, rout} =
        CashForecast.run_rate_flows(
          CashForecast.liquid_account_ids(com, :all),
          ~D[2026-06-08],
          365,
          30,
          com
        )

      factor = Decimal.div(d(30), d(365))
      # 1200 + 9000 + 500
      assert Decimal.equal?(rin, Decimal.mult(d(10_700), factor))
      assert Decimal.equal?(rout, Decimal.mult(d(8000), factor))
    end

    test "excludes pure asset transfers (cash -> fixed deposit) but keeps operating cash",
         %{com: com, bank: bank, admin: admin} do
      fd =
        account_fixture(
          %{account_type: "Non-current Asset", name: "FD #{System.unique_integer([:positive])}"},
          com,
          admin
        )

      # Bank -> Fixed Deposit transfer: no contact, all legs asset accounts -> excluded
      did = Ecto.UUID.generate()

      com
      |> txn!(bank.id, ~D[2026-04-10], d(-5000))
      |> Ecto.Changeset.change(%{doc_id: did})
      |> Repo.update!()

      com
      |> txn!(fd.id, ~D[2026-04-10], d(5000))
      |> Ecto.Changeset.change(%{doc_id: did})
      |> Repo.update!()

      # a normal operating bank inflow (doc-less) -> kept
      txn!(com, bank.id, ~D[2026-04-11], d(1200))

      {rin, rout} =
        CashForecast.run_rate_flows(
          CashForecast.liquid_account_ids(com, :all),
          ~D[2026-06-08],
          365,
          30,
          com
        )

      factor = Decimal.div(d(30), d(365))
      # only the operating inflow
      assert Decimal.equal?(rin, Decimal.mult(d(1200), factor))
      # the FD transfer is excluded
      assert Decimal.equal?(rout, d(0))
    end

    test "excludes documents touching a user-listed account (e.g. director fee)",
         %{com: com, bank: bank, admin: admin} do
      dirfee =
        account_fixture(
          %{account_type: "Expenses", name: "Director Fee #{System.unique_integer([:positive])}"},
          com,
          admin
        )

      did = Ecto.UUID.generate()
      # Director fee payment: Dr Director Fee / Cr Bank — has a P&L leg, so by default
      # it stays in the run-rate. Listing the account excludes the whole document.
      com
      |> txn!(bank.id, ~D[2026-04-10], d(-5000))
      |> Ecto.Changeset.change(%{doc_id: did})
      |> Repo.update!()

      com
      |> txn!(dirfee.id, ~D[2026-04-10], d(5000))
      |> Ecto.Changeset.change(%{doc_id: did})
      |> Repo.update!()

      # operating inflow, kept
      txn!(com, bank.id, ~D[2026-04-11], d(1200))

      ids = CashForecast.liquid_account_ids(com, :all)
      factor = Decimal.div(d(30), d(365))

      {_in0, out0} = CashForecast.run_rate_flows(ids, ~D[2026-06-08], 365, 30, com, [])
      # included by default
      assert Decimal.equal?(out0, Decimal.mult(d(5000), factor))

      {in1, out1} = CashForecast.run_rate_flows(ids, ~D[2026-06-08], 365, 30, com, [dirfee.id])
      # excluded
      assert Decimal.equal?(out1, d(0))
      # operating inflow kept
      assert Decimal.equal?(in1, Decimal.mult(d(1200), factor))
    end

    test "save/read excluded account ids via company settings", %{com: com, bank: bank} do
      assert CashForecast.excluded_account_ids(com) == []
      {:ok, com2} = CashForecast.save_excluded_account_ids(com, [bank.id])
      assert CashForecast.excluded_account_ids(com2) == [bank.id]

      assert CashForecast.excluded_account_ids(CashForecast.company_with_settings(com)) == [
               bank.id
             ]
    end
  end

  describe "period_liquid_transactions/5" do
    test "lists the liquid txns making up a period's in / out", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-04-05], d(1000))
      txn!(com, bank.id, ~D[2026-04-10], d(-300))
      txn!(com, bank.id, ~D[2026-04-15], d(200))

      ids = CashForecast.liquid_account_ids(com, :all)

      ins = CashForecast.period_liquid_transactions(ids, ~D[2026-04-01], ~D[2026-04-30], :in, com)

      outs =
        CashForecast.period_liquid_transactions(ids, ~D[2026-04-01], ~D[2026-04-30], :out, com)

      assert length(ins) == 2

      assert Enum.reduce(ins, Decimal.new(0), &Decimal.add(&2, &1.amount))
             |> Decimal.equal?(d(1200))

      assert length(outs) == 1
      # positive magnitude
      assert Decimal.equal?(hd(outs).amount, d(300))
    end
  end

  describe "ar_ap_balance/2" do
    test "totals debtor (receivable) and creditor (payable) contact balances", %{
      com: com,
      bank: bank
    } do
      cust =
        Repo.insert!(%FullCircle.Accounting.Contact{
          name: "Cust #{System.unique_integer([:positive])}",
          company_id: com.id
        })

      supp =
        Repo.insert!(%FullCircle.Accounting.Contact{
          name: "Supp #{System.unique_integer([:positive])}",
          company_id: com.id
        })

      # customer owes us
      txn!(com, bank.id, ~D[2026-04-01], d(1000), %{contact_id: cust.id})
      # we owe supplier
      txn!(com, bank.id, ~D[2026-04-02], d(-600), %{contact_id: supp.id})
      # after the as-of date
      txn!(com, bank.id, ~D[2026-07-01], d(500), %{contact_id: cust.id})

      {recv, pay} = CashForecast.ar_ap_balance(com, ~D[2026-06-30])
      assert Decimal.equal?(recv, d(1000))
      assert Decimal.equal?(pay, d(600))
    end
  end

  describe "cash_forecast/2 end-to-end" do
    test "produces N periods, opening, run-rate, and a 1/3/6/12 ladder", %{com: com, bank: bank} do
      # opening (before start)
      txn!(com, bank.id, ~D[2026-06-01], d(10_000))
      # posted future inflow (overlay)
      txn!(com, bank.id, ~D[2026-06-10], d(2000))

      res =
        CashForecast.cash_forecast(
          %{
            start_date: ~D[2026-06-08],
            period_days: 30,
            periods_count: 12,
            buffer_periods: 1,
            trailing_days: 365,
            account_ids: :all
          },
          com
        )

      assert Decimal.equal?(res.opening, d(10_000))
      assert length(res.periods) == 12
      assert Decimal.equal?(hd(res.periods).opening, d(10_000))
      assert hd(res.periods).source in [:actual, :forecast]
      assert Map.has_key?(res.ladder, :place_12mo)
    end

    test "forecast level uses the YoY ratio when the prior-year 90-day window has data",
         %{com: com, bank: bank} do
      # last 90d + long window
      txn!(com, bank.id, ~D[2026-05-09], d(1800))
      # long window only
      txn!(com, bank.id, ~D[2025-10-15], d(1850))
      # same 90d one year earlier only
      txn!(com, bank.id, ~D[2025-04-20], d(600))

      as_of = ~D[2026-06-08]

      res =
        CashForecast.cash_forecast(
          %{
            start_date: as_of,
            period_days: 30,
            periods_count: 3,
            buffer_periods: 1,
            trailing_days: 365,
            as_of: as_of,
            account_ids: :all
          },
          com
        )

      long = Decimal.mult(d(1800 + 1850), Decimal.div(d(30), d(365)))
      # ratio = 1800 / 600 = 3 -> level = long * (1 + 3) / 2
      level = Decimal.mult(long, d(1) |> Decimal.add(d(3)) |> Decimal.div(d(2)))

      assert Enum.all?(res.periods, &(&1.source == :forecast))
      for p <- res.periods, do: assert(Decimal.equal?(p.baseline_in, level))
    end

    test "YoY ratio is clamped so a tiny prior-year window cannot explode the level",
         %{com: com, bank: bank} do
      # last 90d + long window
      txn!(com, bank.id, ~D[2026-05-09], d(1800))
      # prior-year 90d -> raw ratio 180
      txn!(com, bank.id, ~D[2025-04-20], d(10))

      as_of = ~D[2026-06-08]

      res =
        CashForecast.cash_forecast(
          %{
            start_date: as_of,
            period_days: 30,
            periods_count: 3,
            buffer_periods: 1,
            trailing_days: 365,
            as_of: as_of,
            account_ids: :all
          },
          com
        )

      long = Decimal.mult(d(1800), Decimal.div(d(30), d(365)))
      # ratio clamped to 4 -> level = long * (1 + 4) / 2
      level = Decimal.mult(long, d(1) |> Decimal.add(d(4)) |> Decimal.div(d(2)))

      for p <- res.periods, do: assert(Decimal.equal?(p.baseline_in, level))
    end

    test "forecast level falls back to the 90-day blend when the prior-year window is empty", %{
      com: com,
      bank: bank
    } do
      # inflow 236 days before as_of: inside the 365-day window, outside the 90-day one,
      # and outside the horizon's year-earlier shape windows (2025-06-08..2025-09-05).
      txn!(com, bank.id, ~D[2025-10-15], d(3650))
      # inflow 30 days before as_of: inside both windows.
      txn!(com, bank.id, ~D[2026-05-09], d(1800))

      as_of = ~D[2026-06-08]

      res =
        CashForecast.cash_forecast(
          %{
            start_date: as_of,
            period_days: 30,
            periods_count: 3,
            buffer_periods: 1,
            trailing_days: 365,
            as_of: as_of,
            account_ids: :all
          },
          com
        )

      long = Decimal.mult(d(3650 + 1800), Decimal.div(d(30), d(365)))
      short = Decimal.mult(d(1800), Decimal.div(d(30), d(90)))
      blended = long |> Decimal.add(short) |> Decimal.div(d(2))

      # no flow a year before the horizon -> flat shape, every forecast period = blend
      assert Enum.all?(res.periods, &(&1.source == :forecast))
      for p <- res.periods, do: assert(Decimal.equal?(p.baseline_in, blended))
    end

    test "forecast shape follows the same calendar window one year earlier", %{
      com: com,
      bank: bank
    } do
      as_of = ~D[2026-06-08]
      # horizon: p1 06-08..07-07, p2 07-08..08-06, p3 08-07..09-05 (all forecast).
      # Shape windows are those bounds shifted -365 days; 2025-07-21 falls in p2's window.
      txn!(com, bank.id, ~D[2025-07-21], d(3000))

      res =
        CashForecast.cash_forecast(
          %{
            start_date: as_of,
            period_days: 30,
            periods_count: 3,
            buffer_periods: 1,
            trailing_days: 365,
            as_of: as_of,
            account_ids: :all
          },
          com
        )

      [p1, p2, p3] = res.periods
      # 90-day rate is 0, so blended level = long-window rate / 2
      rate = Decimal.mult(d(3000), Decimal.div(d(30), d(365))) |> Decimal.div(d(2))

      # raw shape [0, 3000, 0] -> factors [0.5, 2, 0.5] applied to the blended rate
      assert Decimal.equal?(p1.baseline_in, Decimal.mult(rate, d("0.5")))
      assert Decimal.equal?(p2.baseline_in, Decimal.mult(rate, d(2)))
      assert Decimal.equal?(p3.baseline_in, Decimal.mult(rate, d("0.5")))
      # level preserved: the three periods still sum to ~3x the blended rate
      total = [p1, p2, p3] |> Enum.reduce(d(0), &Decimal.add(&2, &1.baseline_in))
      diff = total |> Decimal.sub(Decimal.mult(rate, d(3))) |> Decimal.abs()
      assert Decimal.compare(diff, d("0.0001")) == :lt
    end

    test "actual periods carry an operating/treasury/discretionary split", %{
      com: com,
      bank: bank,
      admin: admin
    } do
      fd =
        account_fixture(
          %{account_type: "Non-current Asset", name: "FD #{System.unique_integer([:positive])}"},
          com,
          admin
        )

      div_acc =
        account_fixture(
          %{
            account_type: "Current Liability",
            name: "Div Payable #{System.unique_integer([:positive])}"
          },
          com,
          admin
        )

      {:ok, com} = CashForecast.save_excluded_account_ids(com, [div_acc.id])
      com = CashForecast.company_with_settings(com)

      # operating inflow (doc-less journal)
      txn!(com, bank.id, ~D[2026-06-05], d(1000))

      # treasury transfer: bank -> FD, no contact, all-asset legs
      tid = Ecto.UUID.generate()

      com
      |> txn!(bank.id, ~D[2026-06-10], d(-500))
      |> Ecto.Changeset.change(%{doc_id: tid})
      |> Repo.update!()

      com
      |> txn!(fd.id, ~D[2026-06-10], d(500))
      |> Ecto.Changeset.change(%{doc_id: tid})
      |> Repo.update!()

      # discretionary payment: bank -> excluded dividend account
      did = Ecto.UUID.generate()

      com
      |> txn!(bank.id, ~D[2026-06-15], d(-700))
      |> Ecto.Changeset.change(%{doc_id: did})
      |> Repo.update!()

      com
      |> txn!(div_acc.id, ~D[2026-06-15], d(700))
      |> Ecto.Changeset.change(%{doc_id: did})
      |> Repo.update!()

      res =
        CashForecast.cash_forecast(
          %{
            start_date: ~D[2026-06-01],
            period_days: 30,
            periods_count: 2,
            buffer_periods: 1,
            trailing_days: 365,
            as_of: ~D[2026-06-30],
            account_ids: :all
          },
          com
        )

      [p1, p2] = res.periods
      assert p1.source == :actual
      # totals unchanged: Base In/Out remain the full real flows
      assert Decimal.equal?(p1.baseline_in, d(1000))
      assert Decimal.equal?(p1.baseline_out, d(1200))
      # split: 1000 operating in; out = 500 treasury + 700 discretionary
      assert Decimal.equal?(p1.oper_in, d(1000))
      assert Decimal.equal?(p1.oper_out, d(0))
      assert Decimal.equal?(p1.treas_out, d(500))
      assert Decimal.equal?(p1.disc_out, d(700))
      assert Decimal.equal?(p1.treas_in, d(0))
      assert Decimal.equal?(p1.disc_in, d(0))
      # forecast rows: baseline IS operating, treasury zero
      assert p2.source == :forecast
      assert Decimal.equal?(p2.oper_in, p2.baseline_in)
      assert Decimal.equal?(p2.treas_in, d(0))
    end

    test "as_of anchors the actual/forecast split", %{com: com} do
      res =
        CashForecast.cash_forecast(
          %{
            start_date: ~D[2026-01-01],
            period_days: 30,
            periods_count: 12,
            buffer_periods: 1,
            trailing_days: 365,
            as_of: ~D[2026-03-15],
            account_ids: :all
          },
          com
        )

      assert res.as_of == ~D[2026-03-15]
      # 30-day periods from 01-01: p1 ends 01-30, p2 ends 03-01 (both <= 03-15);
      # p3 ends 03-31 -> forecast.
      assert Enum.count(res.periods, &(&1.source == :actual)) == 2
    end
  end
end
