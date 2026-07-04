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

  describe "build_schedule" do
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

    test "a month with tax paid is settled -> its due is 0" do
      paid = %{3 => d(5000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 1)
      assert Decimal.equal?(Enum.at(rows, 2).instalment_due, d(0))
      # untouched months keep the spread instalment
      assert Decimal.equal?(Enum.at(rows, 1).instalment_due, d(10000))
      assert Decimal.equal?(Enum.at(rows, 3).instalment_due, d(10000))
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

    test "revision filed at month 6 locks months 1-6 and re-spreads from month 7" do
      rows = Tax.build_schedule(bounds(), %{}, d(8500), 1, %{6 => d(5000)})
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 0).instalment_due, 2), d("708.33"))
      # the filing month itself is still locked at the old instalment
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 5).instalment_due, 2), d("708.33"))
      # payable through 6 = 6 x 708.33.. = 4250; (5000 - 4250) / 6
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 6).instalment_due, 2), d("125.00"))
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 11).instalment_due, 2), d("125.00"))
      assert Decimal.equal?(Enum.at(rows, 5).estimate_in_force, d(8500))
      assert Decimal.equal?(Enum.at(rows, 6).estimate_in_force, d(5000))
    end

    test "later revision supersedes the earlier one" do
      rows = Tax.build_schedule(bounds(), %{}, d(12000), 1, %{6 => d(9000), 9 => d(15000)})
      assert Decimal.equal?(Enum.at(rows, 5).instalment_due, d(1000))
      # months 7-9: (9000 - 6000) / 6
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 6).instalment_due, 2), d("500.00"))
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 8).instalment_due, 2), d("500.00"))
      # months 10-12: payable through 9 = 6000 + 3 x 500; (15000 - 7500) / 3
      assert Decimal.equal?(Decimal.round(Enum.at(rows, 9).instalment_due, 2), d("2500.00"))
      assert Decimal.equal?(Enum.at(rows, 11).estimate_in_force, d(15000))
    end

    test "revision below what is already payable floors remaining dues at 0" do
      rows = Tax.build_schedule(bounds(), %{}, d(12000), 1, %{9 => d(5000)})
      # month 9 (the filing month) stays locked; relief starts month 10
      assert Decimal.equal?(Enum.at(rows, 8).instalment_due, d(1000))
      assert Decimal.equal?(Enum.at(rows, 9).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 11).instalment_due, d(0))
    end

    test "revision before estimate_month is ignored" do
      rows = Tax.build_schedule(bounds(), %{}, d(12000), 8, %{6 => d(5000)})
      assert Decimal.equal?(Enum.at(rows, 5).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 7).instalment_due, d(2400))
      assert Decimal.equal?(Enum.at(rows, 7).estimate_in_force, d(12000))
    end

    test "balance tracks the estimate in force; settled months still count as payable" do
      rows = Tax.build_schedule(bounds(), %{1 => d(1000)}, d(12000), 1, %{6 => d(6000)})
      # month 1 paid -> displayed due 0, but its scheduled 1000 still counts toward payable
      assert Decimal.equal?(Enum.at(rows, 0).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 0).balance, d(11000))
      # month 6 (filing month) locked at the old instalment and old estimate
      assert Decimal.equal?(Enum.at(rows, 5).instalment_due, d(1000))
      assert Decimal.equal?(Enum.at(rows, 5).balance, d(11000))
      # months 7-12: payable through 6 = 6000 -> (6000 - 6000) / 6 = 0
      assert Decimal.equal?(Enum.at(rows, 6).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 6).balance, d(5000))
    end

    test "re-spread deducts actual payments when they exceed the schedule" do
      # Screenshot scenario: original 3.3M from month 5, paid 275k in months 1-9
      # (2,475,000 total), revised to 1.6M at 6/9/11 — everything after month 9
      # is already covered by actual payments, so no further instalments are due.
      paid = for m <- 1..9, into: %{}, do: {m, d(275_000)}
      revs = %{6 => d(1_600_000), 9 => d(1_600_000), 11 => d(1_600_000)}
      rows = Tax.build_schedule(bounds(), paid, d(3_300_000), 5, revs)

      assert Decimal.equal?(Enum.at(rows, 9).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 10).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 11).instalment_due, d(0))
      # balance vs the in-force 1.6M estimate: 1.6M - 2,475,000 paid
      assert Decimal.equal?(List.last(rows).balance, d(-875_000))
    end

    test "no revisions -> original spread, estimate-based balance, in_force = estimate (regression)" do
      rows = Tax.build_schedule(bounds(), %{1 => d(1000)}, d(120000), 1)
      assert Decimal.equal?(Enum.at(rows, 1).instalment_due, d(10000))
      assert Decimal.equal?(Enum.at(rows, 0).balance, d(119000))
      assert Enum.all?(rows, &Decimal.equal?(&1.estimate_in_force, d(120000)))
    end

    test "balance goes negative when over-paid (outstanding semantic)" do
      paid = %{1 => d(200000)}
      rows = Tax.build_schedule(bounds(), paid, d(120000), 2)
      assert Decimal.compare(Enum.at(rows, 0).balance, d(0)) == :lt
    end
  end

  describe "paid_by_month/1" do
    test "blank or invalid form values read as 0" do
      plan = %FullCircle.Tax.InstalmentPlan{paid_overrides: %{"2" => "", "3" => "abc", "4" => " 7500.50 "}}
      pm = Tax.paid_by_month(plan)
      assert Decimal.equal?(Map.get(pm, 2), d(0))
      assert Decimal.equal?(Map.get(pm, 3), d(0))
      assert Decimal.equal?(Map.get(pm, 4), d("7500.50"))
    end

    test "drops LiveView _unused_* form-tracking keys" do
      plan = %FullCircle.Tax.InstalmentPlan{
        paid_overrides: %{"1" => "1000", "_unused_1" => "", "_unused_12" => ""}
      }

      pm = Tax.paid_by_month(plan)
      assert Decimal.equal?(Map.get(pm, 1), d(1000))
      assert map_size(pm) == 1
    end
  end

  describe "revisions_by_month/1 and latest_estimate/1" do
    test "keeps only revision months with parseable values" do
      plan = %FullCircle.Tax.InstalmentPlan{
        revisions: %{"6" => "5000", "7" => "1234", "9" => "", "11" => "abc", "_unused_6" => ""}
      }

      r = Tax.revisions_by_month(plan)
      assert Decimal.equal?(r[6], d(5000))
      assert map_size(r) == 1
    end

    test "zero means not revised (money-input footgun), same as blank" do
      plan = %FullCircle.Tax.InstalmentPlan{revisions: %{"9" => "0", "11" => "0.00"}}
      assert Tax.revisions_by_month(plan) == %{}
    end

    test "latest_estimate precedence is 11 -> 9 -> 6 -> original" do
      base = %FullCircle.Tax.InstalmentPlan{estimate: d(8500)}
      assert Decimal.equal?(Tax.latest_estimate(base), d(8500))
      assert Decimal.equal?(Tax.latest_estimate(%{base | revisions: %{"6" => "5000"}}), d(5000))

      assert Decimal.equal?(
               Tax.latest_estimate(%{base | revisions: %{"6" => "5000", "9" => "7000"}}),
               d(7000)
             )

      assert Decimal.equal?(
               Tax.latest_estimate(%{base | revisions: %{"6" => "5000", "11" => "6000"}}),
               d(6000)
             )
    end

    test "revision_months/0" do
      assert Tax.revision_months() == [6, 9, 11]
    end
  end

  describe "suggest_revisions/4" do
    defp com12, do: %{closing_month: 12, closing_day: 31}

    defp plan_8500(attrs) do
      struct!(
        %FullCircle.Tax.InstalmentPlan{fy_year: 2026, estimate: Decimal.new(8500), estimate_month: 1},
        attrs
      )
    end

    test "paid through month 7 -> park at 9, penalty floor at 11" do
      paid = for m <- 1..7, into: %{}, do: {"#{m}", "708.33"}
      {:ok, revs} = Tax.suggest_revisions(plan_8500(%{paid_overrides: paid}), com12(), 7, d(5000))
      # payable through 9 = 9 x 708.33.. = 6375
      assert Decimal.equal?(Decimal.new(revs["9"]), d("6375.00"))
      assert Decimal.equal?(Decimal.new(revs["11"]), d("5000.00"))
      refute Map.has_key?(revs, "6")
    end

    test "all windows open -> park at 6, clear stale 9, floor at 11" do
      {:ok, revs} =
        Tax.suggest_revisions(plan_8500(%{revisions: %{"9" => "999999"}}), com12(), 1, d(5000))

      assert Decimal.equal?(Decimal.new(revs["6"]), d("4250.00"))
      refute Map.has_key?(revs, "9")
      assert Decimal.equal?(Decimal.new(revs["11"]), d("5000.00"))
    end

    test "passed window keeps its saved value and feeds the parking amount" do
      {:ok, revs} =
        Tax.suggest_revisions(plan_8500(%{revisions: %{"6" => "7000"}}), com12(), 8, d(5000))

      assert revs["6"] == "7000"
      # 6->7000 locked: months 7-12 = (7000 - 4250) / 6 = 458.33..;
      # payable through 9 = 4250 + 3 x 458.33.. = 5625
      assert Decimal.equal?(Decimal.new(revs["9"]), d("5625.00"))
      assert Decimal.equal?(Decimal.new(revs["11"]), d("5000.00"))
    end

    test "payment after month 9 -> only month 11 usable, single floor revision" do
      {:ok, revs} =
        Tax.suggest_revisions(plan_8500(%{paid_overrides: %{"10" => "1"}}), com12(), 10, d(5000))

      assert revs == %{"11" => "5000.00"}
    end

    test "no window left" do
      assert {:error, :no_window} = Tax.suggest_revisions(plan_8500(%{}), com12(), 12, d(5000))
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

    test "accepts a revisions map" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, revisions: %{"6" => "5000"}})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :revisions) == %{"6" => "5000"}
    end

    test "accepts prior_year_estimate, rejects negative" do
      cs = chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, prior_year_estimate: "10000"})
      assert cs.valid?
      assert Decimal.equal?(Ecto.Changeset.get_field(cs, :prior_year_estimate), Decimal.new(10000))
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, prior_year_estimate: -1}).valid?
    end

    test "accepts remedy director fields" do
      cs =
        chg(%{
          company_id: Ecto.UUID.generate(),
          fy_year: 2026,
          remedy_director_count: 3,
          remedy_existing_income: "360000"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :remedy_director_count) == 3
    end

    test "rejects remedy_director_count < 1" do
      refute chg(%{company_id: Ecto.UUID.generate(), fy_year: 2026, remedy_director_count: 0}).valid?
    end
  end
end

defmodule FullCircle.TaxDBTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Tax

  defp d(n), do: Decimal.new("#{n}")

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{closing_month: 12, closing_day: 31})
    %{admin: admin, com: com}
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

    test "saving keeps only valid CP204A revisions", %{com: com, admin: admin} do
      {:ok, plan} =
        Tax.create_or_update_plan(
          %{
            "fy_year" => 2026,
            "revisions" => %{"6" => "5000", "7" => "999", "9" => "", "11" => "0", "_unused_6" => ""}
          },
          com,
          admin
        )

      assert plan.revisions == %{"6" => "5000"}
    end
  end

  describe "paid_by_month/1" do
    test "reads manual overrides from the plan", %{com: com, admin: admin} do
      {:ok, plan} = Tax.create_or_update_plan(%{"fy_year" => 2026, "paid_overrides" => %{"2" => "8000", "5" => "9999"}}, com, admin)
      pm = Tax.paid_by_month(plan)
      assert Decimal.equal?(Map.get(pm, 2), d(8000))
      assert Decimal.equal?(Map.get(pm, 5), d(9999))
      assert Decimal.equal?(Map.get(pm, 1, d(0)), d(0))
    end

    test "saving strips _unused_* form-tracking keys from paid_overrides", %{com: com, admin: admin} do
      {:ok, plan} =
        Tax.create_or_update_plan(
          %{"fy_year" => 2026, "paid_overrides" => %{"2" => "8000", "_unused_2" => "", "_unused_5" => ""}},
          com, admin
        )

      assert plan.paid_overrides == %{"2" => "8000"}
    end

    test "no overrides -> empty map", %{com: com, admin: admin} do
      {:ok, plan} = Tax.create_or_update_plan(%{"fy_year" => 2026}, com, admin)
      pm = Tax.paid_by_month(plan)
      assert Decimal.equal?(Map.get(pm, 1, d(0)), d(0))
    end
  end

  describe "schedule/2" do
    test "builds a 12-row schedule from plan estimate + manual paid", %{com: com, admin: admin} do
      {:ok, plan} =
        Tax.create_or_update_plan(
          %{"fy_year" => 2026, "paid_overrides" => %{"1" => "1000"}, "estimate" => "120000", "estimate_month" => 1},
          com, admin
        )
      rows = Tax.schedule(plan, com)
      assert length(rows) == 12
      assert Decimal.equal?(Enum.at(rows, 0).paid, d(1000))
      # month 1 has tax paid -> settled, no instalment due
      assert Decimal.equal?(Enum.at(rows, 0).instalment_due, d(0))
      assert Decimal.equal?(Enum.at(rows, 1).instalment_due, d(10000))
    end
  end
end
