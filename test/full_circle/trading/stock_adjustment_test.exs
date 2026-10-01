defmodule FullCircle.Trading.StockAdjustmentTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.{Balances, StockAdjustment}

  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup do
    %{admin: admin, company: company} = trading_setup()
    good = good_fixture(company, admin)
    wh = location_fixture(company, admin, %{"kind" => "own_warehouse", "name" => "Main silo"})
    stock_in(company, admin, good, wh, "25")
    %{admin: admin, company: company, good: good, wh: wh}
  end

  defp stock_in(company, admin, good, wh, qty) do
    supply = supply_position_fixture(company, admin, %{"quantity" => "100", "good_id" => good.id})
    supplier_loc = location_fixture(company, admin, %{"kind" => "supplier_site"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-04",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "planned" => qty,
              "actual" => qty,
              "good_id" => good.id,
              "location_id" => supplier_loc.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => qty,
              "actual" => qty,
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        admin
      )

    {:ok, _, _} = Trading.complete_trip(trip, company, admin)
  end

  defp user_with_role(company, admin, role) do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(company, user, role, admin)
    user
  end

  defp adjust(company, user, wh, good, counted, extra \\ %{}) do
    Trading.create_stock_adjustment(
      Map.merge(
        %{
          "location_id" => wh.id,
          "good_id" => good.id,
          "adjust_date" => "2026-07-10",
          "counted_qty" => counted,
          "reason" => "stocktake"
        },
        extra
      ),
      company,
      user
    )
  end

  test "stocktake stores the signed difference and moves on-hand to the count", %{
    admin: admin,
    company: company,
    good: good,
    wh: wh
  } do
    assert {:ok, %StockAdjustment{} = adj} = adjust(company, admin, wh, good, "23.5")

    assert adj.reference_no =~ ~r/^ADJ-\d{6}$/
    assert Decimal.eq?(adj.system_qty, Decimal.new("25"))
    assert Decimal.eq?(adj.counted_qty, Decimal.new("23.5"))
    assert Decimal.eq?(adj.qty, Decimal.new("-1.5"))
    assert adj.created_by_id == admin.id

    assert Decimal.eq?(Balances.own_warehouse_on_hand(wh.id, good.id), Decimal.new("23.5"))
    assert Decimal.eq?(Balances.own_warehouse_qty(wh), Decimal.new("23.5"))

    row = Enum.find(Trading.warehouse_board(company, admin), &(&1.location.id == wh.id))
    assert Decimal.eq?(row.on_hand, Decimal.new("23.5"))
    assert Decimal.eq?(row.adjusted, Decimal.new("-1.5"))

    # A second count is measured against the adjusted book
    assert {:ok, again} = adjust(company, admin, wh, good, "24")
    assert Decimal.eq?(again.system_qty, Decimal.new("23.5"))
    assert Decimal.eq?(again.qty, Decimal.new("0.5"))
  end

  test "opening balance on a warehouse × good with no trips gets a board row", %{
    admin: admin,
    company: company
  } do
    good = good_fixture(company, admin)
    wh = location_fixture(company, admin, %{"kind" => "own_warehouse", "name" => "New silo"})

    assert {:ok, adj} =
             adjust(company, admin, wh, good, "40", %{"reason" => "opening balance"})

    assert Decimal.eq?(adj.qty, Decimal.new("40"))

    row =
      Enum.find(
        Trading.warehouse_board(company, admin),
        &((&1.location.id == wh.id and &1.good) && &1.good.id == good.id)
      )

    assert Decimal.eq?(row.on_hand, Decimal.new("40"))
  end

  test "count equal to book, blank reason or missing count is rejected", %{
    admin: admin,
    company: company,
    good: good,
    wh: wh
  } do
    assert {:error, cs} = adjust(company, admin, wh, good, "25")
    assert "no difference from the system quantity" in errors_on(cs).counted_qty

    assert {:error, cs} = adjust(company, admin, wh, good, "20", %{"reason" => " "})
    assert "can't be blank" in errors_on(cs).reason

    assert {:error, cs} = adjust(company, admin, wh, good, "")
    assert "can't be blank" in errors_on(cs).counted_qty

    assert {:error, cs} = adjust(company, admin, wh, good, "-1")
    assert errors_on(cs).counted_qty != []

    assert Decimal.eq?(Balances.own_warehouse_on_hand(wh.id, good.id), Decimal.new("25"))
  end

  test "location must be one of the company's own warehouses", %{
    admin: admin,
    company: company,
    good: good
  } do
    port = location_fixture(company, admin, %{"kind" => "port"})

    assert {:error, cs} = adjust(company, admin, port, good, "5")
    assert "must be an own warehouse" in errors_on(cs).location_id
  end

  test "admin and manager may adjust; other roles may not", %{
    admin: admin,
    company: company,
    good: good,
    wh: wh
  } do
    manager = user_with_role(company, admin, "manager")
    assert {:ok, _} = adjust(company, manager, wh, good, "24")

    for role <- ~w(supervisor clerk cashier auditor guest) do
      user = user_with_role(company, admin, role)
      assert adjust(company, user, wh, good, "1") == :not_authorise
    end
  end

  test "adjustments show in the warehouse history", %{
    admin: admin,
    company: company,
    good: good,
    wh: wh
  } do
    {:ok, adj} = adjust(company, admin, wh, good, "22", %{"reason" => "moisture loss"})

    moves = Trading.list_warehouse_recent_movements(wh.id, good.id, company, admin)
    row = Enum.find(moves, &(&1.kind == "adj"))

    assert row.line_id == adj.id
    assert row.reference_no == adj.reference_no
    assert row.trip_id == nil
    assert Decimal.eq?(row.qty, Decimal.new("-3"))
    assert row.notes == "moisture loss"
    assert Enum.any?(moves, &(&1.kind == "in"))
  end

  test "history is newest-first by calendar date, not by struct field order", %{
    admin: admin,
    company: company,
    good: good,
    wh: wh
  } do
    # Struct comparison would rank day 30 of July above day 27 of August
    {:ok, _} = adjust(company, admin, wh, good, "24", %{"adjust_date" => "2026-07-30"})
    {:ok, _} = adjust(company, admin, wh, good, "23", %{"adjust_date" => "2026-08-27"})

    dates =
      Trading.list_warehouse_recent_movements(wh.id, good.id, company, admin)
      |> Enum.filter(&(&1.kind == "adj"))
      |> Enum.map(& &1.date)

    assert dates == [~D[2026-08-27], ~D[2026-07-30]]
  end

  test "deleting the company removes its adjustments", %{
    admin: admin,
    company: company,
    good: good,
    wh: wh
  } do
    {:ok, adj} = adjust(company, admin, wh, good, "20")
    assert {:ok, _} = FullCircle.Sys.delete_company(company, admin)
    refute Repo.get(StockAdjustment, adj.id)
  end
end
