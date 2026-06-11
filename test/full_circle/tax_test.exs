defmodule FullCircle.TaxComputeTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax

  defp d(n), do: Decimal.new("#{n}")

  describe "suggested_estimate/2" do
    test "reduces by the tolerance" do
      assert Decimal.equal?(Tax.suggested_estimate(d(130000), d(30)), d(100000))
    end

    test "tolerance 0 returns the forecast unchanged" do
      assert Decimal.equal?(Tax.suggested_estimate(d(50000), d(0)), d(50000))
    end

    test "non-positive forecast returns 0" do
      assert Decimal.equal?(Tax.suggested_estimate(d(0), d(30)), d(0))
      assert Decimal.equal?(Tax.suggested_estimate(d(-100), d(30)), d(0))
    end
  end

  describe "under_estimated?/3" do
    test "true below the floor, false at/above it" do
      assert Tax.under_estimated?(d(99999), d(130000), d(30))
      refute Tax.under_estimated?(d(100000), d(130000), d(30))
      refute Tax.under_estimated?(d(120000), d(130000), d(30))
    end
  end

  describe "build_schedule/4" do
    defp bounds do
      for m <- 1..12, do: {Date.new!(2026, m, 1), Date.new!(2026, m, Date.days_in_month(Date.new!(2026, m, 1)))}
    end

    test "spreads estimate evenly from month 1 with no paid" do
      rows = Tax.build_schedule(bounds(), %{}, d(120000), 1)
      assert length(rows) == 12
      assert Enum.all?(rows, &Decimal.equal?(&1.instalment_due, d(10000)))
      # no paid -> balance = estimate - cumulative_paid(0) = estimate, every month
      assert Decimal.equal?(hd(rows).balance, d(120000))
      assert Decimal.equal?(List.last(rows).balance, d(120000))
    end

    test "re-spreads remaining balance from estimate_month over remaining months" do
      paid = %{1 => d(10000), 2 => d(10000), 3 => d(10000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 4)
      assert Decimal.equal?(Enum.at(rows, 0).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 3).instalment_due, d(10000))
      assert Decimal.equal?(Enum.at(rows, 11).instalment_due, d(10000))
    end

    test "forward instalment floored at 0 when already over-paid" do
      paid = %{1 => d(200000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 2)
      assert Decimal.equal?(Enum.at(rows, 1).instalment_due, d(0))
    end

    test "estimate 0 -> all due 0" do
      rows = Tax.build_schedule(bounds(), %{}, d(0), 1)
      assert Enum.all?(rows, &Decimal.equal?(&1.instalment_due, d(0)))
    end

    test "estimate_month = 12 puts the entire remaining balance in the last month" do
      paid = %{1 => d(5000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 12)
      # paid_to_date = 5000 (months < 12); remaining = 1; forward = 115000
      assert Decimal.equal?(Enum.at(rows, 11).instalment_due, d(115000))
      assert Enum.all?(Enum.take(rows, 11), &Decimal.equal?(&1.instalment_due, d(0)))
    end

    test "balance goes negative when over-paid (outstanding semantic)" do
      paid = %{1 => d(200000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 2)
      assert Decimal.compare(Enum.at(rows, 0).balance, d(0)) == :lt
    end
  end

  describe "current_fy_month/3" do
    test "maps a date to its FY month index, clamped to 1..12" do
      com = %{closing_month: 12, closing_day: 31}
      assert Tax.current_fy_month(com, 2026, ~D[2026-01-15]) == 1
      assert Tax.current_fy_month(com, 2026, ~D[2026-07-10]) == 7
      assert Tax.current_fy_month(com, 2026, ~D[2025-01-01]) == 1
      assert Tax.current_fy_month(com, 2026, ~D[2027-05-01]) == 12
    end

    test "works for a non-calendar (30-Jun closing) financial year" do
      com = %{closing_month: 6, closing_day: 30}
      # FY 2026 runs 2025-07-01 .. 2026-06-30
      assert Tax.current_fy_month(com, 2026, ~D[2025-07-15]) == 1
      assert Tax.current_fy_month(com, 2026, ~D[2026-06-20]) == 12
      assert Tax.current_fy_month(com, 2026, ~D[2025-12-15]) == 6
    end
  end
end

defmodule FullCircle.TaxSchemaTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.InstalmentPlan

  defp chg(attrs), do: InstalmentPlan.changeset(%InstalmentPlan{}, attrs)

  describe "changeset/2" do
    test "requires company_id and fy_year" do
      cs = chg(%{})
      refute cs.valid?
      assert cs.errors[:company_id]
      assert cs.errors[:fy_year]
    end

    test "valid with the minimum fields" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026})
      assert cs.valid?
    end

    test "rejects negative tolerance and out-of-range estimate_month" do
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, tolerance_pct: -1}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, estimate_month: 0}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, estimate_month: 13}).valid?
    end

    test "rejects an out-of-range fy_year" do
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 1800}).valid?
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 3000}).valid?
    end

    test "accepts a paid_overrides map" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, paid_overrides: %{"3" => "100.00"}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :paid_overrides) == %{"3" => "100.00"}
    end
  end
end

defmodule FullCircle.TaxDBTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Tax
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
    com = company_fixture(admin, %{closing_month: 12, closing_day: 31})
    tax_acc = account_fixture(%{account_type: "Current Asset", name: "Tax Paid #{System.unique_integer([:positive])}"}, com, admin)
    %{admin: admin, com: com, tax_acc: tax_acc}
  end

  describe "create_or_update_plan/3 and get_plan/2" do
    test "creates then updates the singleton per (company, fy)", %{com: com, admin: admin} do
      assert is_nil(Tax.get_plan(com, 2026))
      {:ok, plan} = Tax.create_or_update_plan(%{"fy_year" => 2026, "tolerance_pct" => "30", "estimate" => "100000", "estimate_month" => 1}, com, admin)
      assert plan.fy_year == 2026

      {:ok, plan2} = Tax.create_or_update_plan(%{"fy_year" => 2026, "estimate" => "120000"}, com, admin)
      assert plan2.id == plan.id
      assert Decimal.equal?(plan2.estimate, d(120000))
      assert Tax.get_plan(com, 2026).id == plan.id
    end
  end

  describe "paid_by_month/2" do
    test "sums GL postings into FY months and applies overrides", %{com: com, admin: admin, tax_acc: tax_acc} do
      txn!(com, tax_acc.id, ~D[2026-02-10], 5000)
      txn!(com, tax_acc.id, ~D[2026-02-20], 3000)
      txn!(com, tax_acc.id, ~D[2026-05-01], 4000)

      {:ok, plan} =
        Tax.create_or_update_plan(
          %{"fy_year" => 2026, "tax_paid_account_id" => tax_acc.id, "paid_overrides" => %{"5" => "9999"}},
          com, admin
        )

      pm = Tax.paid_by_month(plan, com)
      assert Decimal.equal?(Map.get(pm, 2), d(8000))
      assert Decimal.equal?(Map.get(pm, 5), d(9999))
      assert Decimal.equal?(Map.get(pm, 1, d(0)), d(0))
    end

    test "no account -> zeros plus overrides only", %{com: com, admin: admin} do
      {:ok, plan} = Tax.create_or_update_plan(%{"fy_year" => 2026, "paid_overrides" => %{"3" => "100"}}, com, admin)
      pm = Tax.paid_by_month(plan, com)
      assert Decimal.equal?(Map.get(pm, 3), d(100))
      assert Decimal.equal?(Map.get(pm, 1, d(0)), d(0))
    end
  end
end
