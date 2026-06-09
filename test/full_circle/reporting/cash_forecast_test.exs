defmodule FullCircle.Reporting.CashForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.CashForecast

  defp d(n), do: Decimal.new("#{n}")

  defp periods_from(start, n, period_days),
    do: for(i <- 0..(n - 1), do: Date.add(start, i * period_days))

  describe "fd_ladder/2" do
    test "rolling minimums and non-negative tenure increments (30-day periods)" do
      # free_cash by period 1..12, first period the lowest
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

      assert ladder.lockable_1mo == d(100)  # min period 1 (ceil(30/30)=1)
      assert ladder.lockable_3mo == d(100)  # min 1-3 (ceil(90/30)=3)
      assert ladder.lockable_6mo == d(80)   # min 1-6 (ceil(180/30)=6)
      assert ladder.lockable_12mo == d(50)  # min 1-12 (ceil(365/30)->capped 12)
      assert ladder.place_12mo == d(50)
      assert ladder.place_6mo == d(30)      # 80 - 50
      assert ladder.place_3mo == d(20)      # 100 - 80
      assert ladder.place_1mo == d(0)       # 100 - 100
    end

    test "14-day periods map tenures onto more buckets" do
      # 26 periods of 14 days ~ 1 year. ceil(30/14)=3, ceil(90/14)=7, ceil(180/14)=13.
      frees = for i <- 1..26, do: %{n: i, free_cash: d(i * 10)}
      ladder = CashForecast.fd_ladder(frees, 14)

      assert ladder.lockable_1mo == d(10)   # min of first 3 -> period 1 = 10
      assert ladder.lockable_3mo == d(10)   # min of first 7
      assert ladder.lockable_6mo == d(10)   # min of first 13
    end
  end

  describe "clamp_due/2" do
    test "past-due dates clamp to start_date, future dates pass through" do
      start = ~D[2026-06-08]
      assert CashForecast.clamp_due(~D[2026-05-01], start) == start
      assert CashForecast.clamp_due(~D[2026-07-01], start) == ~D[2026-07-01]
    end
  end

  describe "distribute_outstanding/4" do
    test "spreads outstanding across periods per the lag profile" do
      start = ~D[2026-06-01]
      periods = periods_from(start, 12, 30)
      open = [%{due_date: ~D[2026-06-15], amount: d(1000)}]
      profile = %{0 => Decimal.new("0.5"), 1 => Decimal.new("0.3"), 2 => Decimal.new("0.2")}

      res = CashForecast.distribute_outstanding(open, profile, periods, 30)

      assert Decimal.equal?(Enum.at(res, 0), d(500))
      assert Decimal.equal?(Enum.at(res, 1), d(300))
      assert Decimal.equal?(Enum.at(res, 2), d(200))
      assert Decimal.equal?(Enum.at(res, 3), d(0))
    end

    test "overdue invoice drops already-elapsed lag buckets (conservative, no renormalize)" do
      start = ~D[2026-06-01]
      periods = periods_from(start, 12, 30)
      # due 2 periods (60 days) before start -> due_idx = -2; period 0 has lag 2
      open = [%{due_date: Date.add(start, -60), amount: d(1000)}]

      profile = %{
        0 => Decimal.new("0.5"),
        1 => Decimal.new("0.3"),
        2 => Decimal.new("0.15"),
        3 => Decimal.new("0.05")
      }

      res = CashForecast.distribute_outstanding(open, profile, periods, 30)

      assert Decimal.equal?(Enum.at(res, 0), d(150))
      assert Decimal.equal?(Enum.at(res, 1), d(50))
      assert Decimal.equal?(Enum.at(res, 2), d(0))
      total = Enum.reduce(res, Decimal.new(0), &Decimal.add(&2, &1))
      assert Decimal.equal?(total, d(200))
    end

    test "future-dated invoice beyond the horizon contributes ~nothing" do
      start = ~D[2026-06-01]
      periods = periods_from(start, 12, 30)
      open = [%{due_date: Date.add(start, 20 * 30), amount: d(1000)}]
      profile = %{0 => Decimal.new("1.0")}

      res = CashForecast.distribute_outstanding(open, profile, periods, 30)
      total = Enum.reduce(res, Decimal.new(0), &Decimal.add(&2, &1))
      assert Decimal.equal?(total, d(0))
    end
  end

  describe "build_forecast/3 roll-forward" do
    test "buckets events into periods and rolls balance forward" do
      start = ~D[2026-06-08]

      events = [
        %{date: ~D[2026-06-10], in: d(1000), out: d(0), kind: :known},   # period 1
        %{date: ~D[2026-06-12], in: d(0), out: d(400), kind: :known},    # period 1
        %{date: ~D[2026-07-16], in: d(0), out: d(700), kind: :known}     # period 2 (day 38)
      ]

      res =
        CashForecast.build_forecast(
          %{opening: d(5000), baseline_in: d(0), baseline_out: d(0), events: events},
          start,
          period_days: 30, periods_count: 12, buffer_periods: 1
        )

      [p1, p2 | _] = res.periods
      assert p1.period_start == ~D[2026-06-08]
      assert p1.opening == d(5000)
      assert p1.known_in == d(1000)
      assert p1.known_out == d(400)
      assert p1.closing == d(5600)            # 5000 + 1000 - 400
      assert p2.opening == d(5600)
      assert p2.known_out == d(700)
      assert p2.closing == d(4900)            # 5600 - 700
      assert length(res.periods) == 12
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
          doc_type: "Journal", doc_no: "J#{System.unique_integer([:positive])}",
          doc_date: date, particulars: "t", amount: amount,
          company_id: com.id, account_id: account_id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})

    # company_fixture does NOT seed Bank/Cash accounts; create one explicitly
    bank = account_fixture(%{account_type: "Bank", name: "Test Bank"}, com, admin)

    %{admin: admin, com: com, bank: bank}
  end

  describe "opening_liquid_balance/3" do
    test "sums liquid txns strictly before start_date", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-01], d(1000))
      txn!(com, bank.id, ~D[2026-06-07], d(-300))
      txn!(com, bank.id, ~D[2026-06-08], d(999))  # on start date -> excluded from opening

      ids = CashForecast.liquid_account_ids(com, :all)
      assert bank.id in ids

      bal = CashForecast.opening_liquid_balance(ids, ~D[2026-06-08], com)
      assert bal == d(700)
    end
  end

  describe "posted_future_flows/4" do
    test "returns dated events split by sign within horizon", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-10], d(1000))
      txn!(com, bank.id, ~D[2026-06-12], d(-400))
      txn!(com, bank.id, ~D[2027-12-31], d(5000)) # beyond horizon -> excluded

      ids = CashForecast.liquid_account_ids(com, :all)
      end_date = ~D[2026-09-06]
      events = CashForecast.posted_future_flows(ids, ~D[2026-06-08], end_date, com)

      ins = Enum.filter(events, &(Decimal.compare(&1.in, d(0)) == :gt))
      outs = Enum.filter(events, &(Decimal.compare(&1.out, d(0)) == :gt))
      assert Enum.any?(ins, &(&1.date == ~D[2026-06-10] and &1.in == d(1000)))
      assert Enum.any?(outs, &(&1.date == ~D[2026-06-12] and &1.out == d(400)))
      refute Enum.any?(events, &(&1.date == ~D[2027-12-31]))
    end
  end

  describe "outstanding_ar_by_due/1" do
    test "unpaid sales invoice surfaces with its outstanding on its due_date", %{com: com} do
      cont =
        Repo.insert!(%FullCircle.Accounting.Contact{
          name: "AR Cont #{System.unique_integer([:positive])}", company_id: com.id})

      debtor =
        Repo.one!(from a in FullCircle.Accounting.Account,
          where: a.company_id == ^com.id and a.account_type == "Current Asset",
          limit: 1)

      inv =
        %FullCircle.Billing.Invoice{}
        |> Ecto.Changeset.change(%{
          invoice_no: "INV-T1", invoice_date: ~D[2026-06-01], due_date: ~D[2026-06-20],
          company_id: com.id, contact_id: cont.id
        })
        |> Repo.insert!()

      # AR transaction: positive contact balance, doc_id points to the invoice
      %Transaction{}
      |> Transaction.changeset(%{
        doc_type: "Invoice", doc_no: "INV-T1", doc_date: ~D[2026-06-01],
        particulars: "sale", amount: d(800),
        company_id: com.id, account_id: debtor.id, contact_id: cont.id
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(%{doc_id: inv.id})
      |> Repo.update!()

      rows = CashForecast.outstanding_ar_by_due(com)

      assert Enum.any?(rows, &(&1.due_date == ~D[2026-06-20] and Decimal.equal?(&1.amount, d(800))))
    end

    test "ignores the contra (non-contact) GL lines of the invoice", %{com: com} do
      # A real invoice posts BOTH a receivable line (contact set, +amount) and
      # offsetting revenue/tax lines (contact_id nil, -amount) that net the
      # document to zero. Only the receivable line is money owed; the contra
      # lines must NOT be counted (regression for the 23x AR overstatement).
      cont =
        Repo.insert!(%FullCircle.Accounting.Contact{
          name: "AR Cont #{System.unique_integer([:positive])}",
          company_id: com.id
        })

      debtor =
        Repo.one!(
          from a in FullCircle.Accounting.Account,
            where: a.company_id == ^com.id and a.account_type == "Current Asset",
            limit: 1
        )

      revenue =
        Repo.one!(
          from a in FullCircle.Accounting.Account,
            where: a.company_id == ^com.id and a.account_type == "Revenue",
            limit: 1
        )

      inv =
        %FullCircle.Billing.Invoice{}
        |> Ecto.Changeset.change(%{
          invoice_no: "INV-T2",
          invoice_date: ~D[2026-06-01],
          due_date: ~D[2026-06-20],
          company_id: com.id,
          contact_id: cont.id
        })
        |> Repo.insert!()

      # Receivable line: contact set, +800
      %Transaction{}
      |> Transaction.changeset(%{
        doc_type: "Invoice", doc_no: "INV-T2", doc_date: ~D[2026-06-01],
        particulars: "debtor", amount: d(800),
        company_id: com.id, account_id: debtor.id, contact_id: cont.id
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(%{doc_id: inv.id})
      |> Repo.update!()

      # Contra revenue line: NO contact, -800 (nets the document to zero)
      %Transaction{}
      |> Transaction.changeset(%{
        doc_type: "Invoice", doc_no: "INV-T2", doc_date: ~D[2026-06-01],
        particulars: "sales", amount: d(-800),
        company_id: com.id, account_id: revenue.id
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(%{doc_id: inv.id})
      |> Repo.update!()

      rows = CashForecast.outstanding_ar_by_due(com)
      matching = Enum.filter(rows, &(&1.due_date == ~D[2026-06-20]))

      total = Enum.reduce(matching, Decimal.new(0), fn r, a -> Decimal.add(a, r.amount) end)
      assert Decimal.equal?(total, d(800))
    end
  end

  describe "cash_forecast/2 end-to-end" do
    test "produces N periods, opening, and a 1/3/6/12 ladder", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-01], d(10_000))     # opening (before start)
      txn!(com, bank.id, ~D[2026-06-10], d(2000))       # posted future inflow

      res =
        CashForecast.cash_forecast(
          %{start_date: ~D[2026-06-08], period_days: 30, periods_count: 12,
            buffer_periods: 1, trailing_days: 365, account_ids: :all},
          com
        )

      assert Decimal.equal?(res.opening, d(10_000))
      assert length(res.periods) == 12
      assert Decimal.equal?(hd(res.periods).opening, d(10_000))
      assert Map.has_key?(res.ladder, :place_12mo)
    end
  end

  describe "baseline_flows/5" do
    test "scales contact-null liquid flows from the trailing window to a period", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-04-01], d(1300))   # contact_id nil -> in
      txn!(com, bank.id, ~D[2026-05-01], d(-650))   # contact_id nil -> out

      # contact-bearing flow must be IGNORED by baseline:
      cont =
        Repo.one(from c in FullCircle.Accounting.Contact,
          where: c.company_id == ^com.id, limit: 1) ||
          Repo.insert!(%FullCircle.Accounting.Contact{name: "Baseline Cont #{System.unique_integer([:positive])}", company_id: com.id})

      txn!(com, bank.id, ~D[2026-05-02], d(9999), %{contact_id: cont.id})

      # trailing 365 days, 30-day period -> per period = total * 30/365
      {bin, bout} =
        CashForecast.baseline_flows(
          CashForecast.liquid_account_ids(com, :all), ~D[2026-06-08], 365, 30, com)

      factor = Decimal.div(d(30), d(365))
      assert Decimal.equal?(bin, Decimal.mult(d(1300), factor))
      assert Decimal.equal?(bout, Decimal.mult(d(650), factor))
    end
  end
end
