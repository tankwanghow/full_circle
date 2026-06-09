defmodule FullCircle.Reporting.CashForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.CashForecast

  defp d(n), do: Decimal.new("#{n}")

  describe "fd_ladder/1" do
    test "rolling minimums and non-negative tenure increments" do
      # free_cash by week 1..13
      frees = [55, 60, 58, 70, 72, 80, 65, 90, 100, 100, 110, 120, 130]
      weeks = for {f, i} <- Enum.with_index(frees, 1), do: %{n: i, free_cash: d(f)}

      ladder = FullCircle.Reporting.CashForecast.fd_ladder(weeks)

      assert ladder.lockable_1mo == d(55)   # min weeks 1-4
      assert ladder.lockable_2mo == d(55)   # min weeks 1-8
      assert ladder.lockable_3mo == d(55)   # min weeks 1-13
      assert ladder.place_3mo == d(55)
      assert ladder.place_2mo == d(0)       # lockable_2mo - lockable_3mo
      assert ladder.place_1mo == d(0)       # lockable_1mo - lockable_2mo
    end

    test "decreasing free cash gives a real ladder" do
      frees = [100, 100, 100, 100, 80, 80, 80, 80, 60, 60, 60, 60, 60]
      weeks = for {f, i} <- Enum.with_index(frees, 1), do: %{n: i, free_cash: d(f)}

      ladder = FullCircle.Reporting.CashForecast.fd_ladder(weeks)

      assert ladder.lockable_1mo == d(100)  # min 1-4
      assert ladder.lockable_2mo == d(80)   # min 1-8
      assert ladder.lockable_3mo == d(60)   # min 1-13
      assert ladder.place_3mo == d(60)
      assert ladder.place_2mo == d(20)      # 80 - 60
      assert ladder.place_1mo == d(20)      # 100 - 80
    end
  end

  describe "build_forecast/3 roll-forward" do
    test "buckets events into weeks and rolls balance forward" do
      start = ~D[2026-06-08]  # a Monday

      events = [
        %{date: ~D[2026-06-10], in: d(1000), out: d(0), kind: :known},   # week 1
        %{date: ~D[2026-06-12], in: d(0), out: d(400), kind: :known},    # week 1
        %{date: ~D[2026-06-16], in: d(0), out: d(700), kind: :known}     # week 2
      ]

      res =
        CashForecast.build_forecast(
          %{opening: d(5000), baseline_in: d(0), baseline_out: d(0), events: events},
          start,
          weeks_count: 13, buffer_weeks: 2
        )

      [w1, w2 | _] = res.weeks
      assert w1.opening == d(5000)
      assert w1.known_in == d(1000)
      assert w1.known_out == d(400)
      assert w1.closing == d(5600)            # 5000 + 1000 - 400
      assert w2.opening == d(5600)
      assert w2.known_out == d(700)
      assert w2.closing == d(4900)            # 5600 - 700
      assert length(res.weeks) == 13
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
end
