defmodule FullCircle.Trading.StorageTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Trading
  alias FullCircle.Trading.Storage
  alias FullCircle.Trading.SupplyPosition

  setup do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{user: user, company: company}
  end

  # Supply with storage terms in collect; loads added via completed
  # port -> own-warehouse trips (stock-in needs no sales position).
  defp storage_supply(company, user, attrs \\ %{}) do
    good = good_fixture(company, user)
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(
        company,
        user,
        Map.merge(
          %{
            "good_id" => good.id,
            "supplier_id" => supplier.id,
            "quantity" => "30",
            "status" => "collect",
            "grace_period_end_date" => "2026-07-19"
          },
          attrs
        )
      )

    port = location_fixture(company, user, %{"kind" => "port"})
    wh = location_fixture(company, user, %{"kind" => "own_warehouse"})

    %{supply: supply, good: good, port: port, wh: wh}
  end

  defp add_completed_load(ctx, company, user, date, qty) do
    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => date,
          "transport_mode" => "company_own",
          "vehicle_number" => "STO-#{date}",
          "loads" => [
            %{
              "planned" => qty,
              "actual" => qty,
              "good_id" => ctx.good.id,
              "location_id" => ctx.port.id,
              "supply_position_id" => ctx.supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => qty,
              "actual" => qty,
              "good_id" => ctx.good.id,
              "location_id" => ctx.wh.id
            }
          ]
        },
        company,
        user
      )

    {:ok, _trip, _} = Trading.complete_trip(trip, company, user)
    :ok
  end

  defp reload_supply(ctx, company, user),
    do: Trading.get_supply_position!(ctx.supply.id, company, user)

  describe "chip_state/3" do
    test "no grace date set means no tracking" do
      s = %SupplyPosition{grace_period_end_date: nil, status: "collect"}
      assert Storage.chip_state(s, Decimal.new(20), ~D[2026-07-25]) == :none
    end

    test "within grace shows days left" do
      s = %SupplyPosition{grace_period_end_date: ~D[2026-07-30], status: "collect"}
      assert Storage.chip_state(s, Decimal.new(20), ~D[2026-07-25]) == {:grace, 5}
      assert Storage.chip_state(s, Decimal.new(20), ~D[2026-07-30]) == {:grace, 0}
    end

    test "past grace with stock remaining accrues (day after grace end counts as day 1)" do
      s = %SupplyPosition{grace_period_end_date: ~D[2026-07-19], status: "collect"}
      assert Storage.chip_state(s, Decimal.new(20), ~D[2026-07-20]) == {:accruing, 1}
      assert Storage.chip_state(s, Decimal.new(20), ~D[2026-07-25]) == {:accruing, 6}
    end

    test "closed or exhausted supplies show ended" do
      closed = %SupplyPosition{grace_period_end_date: ~D[2026-07-19], status: "closed"}
      assert Storage.chip_state(closed, Decimal.new("0.01"), ~D[2026-07-25]) == :ended

      collect = %SupplyPosition{grace_period_end_date: ~D[2026-07-19], status: "collect"}
      assert Storage.chip_state(collect, Decimal.new(0), ~D[2026-07-25]) == :ended
    end
  end

  describe "breakdown/4" do
    test "no grace date returns :none", %{user: user, company: company} do
      ctx = storage_supply(company, user, %{"grace_period_end_date" => ""})
      assert Storage.breakdown(ctx.supply, company, user, ~D[2026-07-25]) == :none
    end

    test "still accruing: periods split at load dates, loads charge through their own day", %{
      user: user,
      company: company
    } do
      ctx = storage_supply(company, user)
      :ok = add_completed_load(ctx, company, user, "2026-07-18", "10")
      :ok = add_completed_load(ctx, company, user, "2026-07-22", "5")

      b = Storage.breakdown(ctx.supply, company, user, ~D[2026-07-25])

      assert b.first_charge_date == ~D[2026-07-20]
      assert b.end_date == ~D[2026-07-25]
      assert b.end_reason == :running

      assert [p1, p2] = b.periods
      assert p1.from == ~D[2026-07-20]
      assert p1.to == ~D[2026-07-22]
      assert p1.days == 3
      assert Decimal.equal?(p1.remaining, Decimal.new(20))
      assert Decimal.equal?(p1.ton_days, Decimal.new(60))

      assert p2.from == ~D[2026-07-23]
      assert p2.to == ~D[2026-07-25]
      assert p2.days == 3
      assert Decimal.equal?(p2.remaining, Decimal.new(15))
      assert Decimal.equal?(p2.ton_days, Decimal.new(45))

      assert b.total_days == 6
      assert Decimal.equal?(b.total_ton_days, Decimal.new(105))
    end

    test "over-collection clamps at the zero-crossing day", %{user: user, company: company} do
      ctx = storage_supply(company, user)
      :ok = add_completed_load(ctx, company, user, "2026-07-18", "10")
      :ok = add_completed_load(ctx, company, user, "2026-07-21", "20.03")

      b = Storage.breakdown(ctx.supply, company, user, ~D[2026-07-25])

      assert b.end_date == ~D[2026-07-21]
      assert b.end_reason == :exhausted
      assert [p1] = b.periods
      assert p1.from == ~D[2026-07-20]
      assert p1.to == ~D[2026-07-21]
      assert Decimal.equal?(p1.remaining, Decimal.new(20))
      assert b.total_days == 2
      assert Decimal.equal?(b.total_ton_days, Decimal.new(40))
      assert Decimal.equal?(b.leftover_remaining, Decimal.new(0))
    end

    test "tiny short residue keeps accruing until the clerk closes the supply", %{
      user: user,
      company: company
    } do
      ctx = storage_supply(company, user)
      :ok = add_completed_load(ctx, company, user, "2026-07-18", "10")
      :ok = add_completed_load(ctx, company, user, "2026-07-21", "19.99")

      # Not closed: the 0.01 residue keeps charging to today
      b = Storage.breakdown(ctx.supply, company, user, ~D[2026-07-30])
      assert b.end_date == ~D[2026-07-30]
      assert b.end_reason == :running
      assert [_, p2] = b.periods
      assert Decimal.equal?(p2.remaining, Decimal.new("0.01"))

      # Closed: accrual ends at the last load date, residue absorbed
      {:ok, _} = Trading.close_supply_position(reload_supply(ctx, company, user), company, user)
      b = Storage.breakdown(reload_supply(ctx, company, user), company, user, ~D[2026-07-30])

      assert b.end_date == ~D[2026-07-21]
      assert b.end_reason == :closed
      assert [p1] = b.periods
      assert p1.from == ~D[2026-07-20]
      assert p1.to == ~D[2026-07-21]
      assert Decimal.equal?(p1.remaining, Decimal.new(20))
      assert b.total_days == 2
      assert Decimal.equal?(b.total_ton_days, Decimal.new(40))
      assert Decimal.equal?(b.leftover_remaining, Decimal.new("0.01"))
    end

    test "fully collected within grace: no chargeable days", %{user: user, company: company} do
      ctx = storage_supply(company, user)
      :ok = add_completed_load(ctx, company, user, "2026-07-18", "30")

      b = Storage.breakdown(ctx.supply, company, user, ~D[2026-07-25])
      assert b.periods == []
      assert b.total_days == 0
      assert Decimal.equal?(b.total_ton_days, Decimal.new(0))
      assert b.end_reason == :exhausted
    end

    test "closed with no loads runs to today with full leftover", %{user: user, company: company} do
      ctx = storage_supply(company, user)
      {:ok, _} = Trading.close_supply_position(reload_supply(ctx, company, user), company, user)

      b = Storage.breakdown(reload_supply(ctx, company, user), company, user, ~D[2026-07-25])
      assert b.end_date == ~D[2026-07-25]
      assert b.end_reason == :running
      assert [p1] = b.periods
      assert Decimal.equal?(p1.remaining, Decimal.new(30))
      assert Decimal.equal?(b.leftover_remaining, Decimal.new(30))
    end

    test "grace date can be entered retroactively on a closed supply", %{
      user: user,
      company: company
    } do
      ctx = storage_supply(company, user, %{"grace_period_end_date" => ""})
      :ok = add_completed_load(ctx, company, user, "2026-07-18", "10")
      :ok = add_completed_load(ctx, company, user, "2026-07-21", "20")
      {:ok, _} = Trading.close_supply_position(reload_supply(ctx, company, user), company, user)

      # Bill arrives later; clerk enters the grace end date on the closed supply
      {:ok, supply} =
        Trading.update_supply_position(
          reload_supply(ctx, company, user),
          %{"grace_period_end_date" => "2026-07-19"},
          company,
          user
        )

      assert supply.grace_period_end_date == ~D[2026-07-19]

      b = Storage.breakdown(supply, company, user, ~D[2026-08-10])
      assert b.end_date == ~D[2026-07-21]
      assert b.end_reason == :exhausted
      assert b.total_days == 2
      assert Decimal.equal?(b.total_ton_days, Decimal.new(40))
    end
  end
end
