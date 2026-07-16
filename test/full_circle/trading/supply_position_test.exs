defmodule FullCircle.Trading.SupplyPositionTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.{SupplyPosition, Balances}

  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup do
    trading_setup()
  end

  test "create open supply 100 MT; remaining is 100", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)

    assert {:ok, %SupplyPosition{} = s} =
             Trading.create_supply_position(
               %{
                 "title" => "JON DOE May maize",
                 "available_from" => "2026-05-15",
                 "quantity" => "100",
                 "unit_price" => "1100",
                 "supplier_id" => contact.id,
                 "good_id" => good.id
               },
               company,
               admin
             )

    assert Decimal.eq?(s.quantity, Decimal.new("100"))
    assert s.status == "open"
    assert Decimal.eq?(Balances.supply_remaining(s), Decimal.new("100"))
    assert Decimal.eq?(Balances.supply_loaded(s), Decimal.new(0))
  end

  test "status transitions: open → hold → collect → close", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin)
    assert s.status == "open"

    assert {:ok, held} = Trading.hold_supply_position(s, company, admin)
    assert held.status == "hold"

    assert {:ok, collecting} = Trading.collect_supply_position(held, company, admin)
    assert collecting.status == "collect"

    assert {:ok, closed} = Trading.close_supply_position(collecting, company, admin)
    assert closed.status == "close"
  end

  test "requires title, quantity > 0, supplier and good", %{admin: admin, company: company} do
    assert {:error, cs} =
             Trading.create_supply_position(%{"quantity" => "0"}, company, admin)

    errs = errors_on(cs)
    assert Map.has_key?(errs, :title)
    assert Map.has_key?(errs, :quantity) or Map.has_key?(errs, :supplier_id)

    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)

    assert {:error, cs} =
             Trading.create_supply_position(
               %{
                 "title" => "   ",
                 "quantity" => "10",
                 "supplier_id" => contact.id,
                 "good_id" => good.id
               },
               company,
               admin
             )

    assert %{title: _} = errors_on(cs)
  end

  test "position_board lists open supplies with remaining", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin, %{"quantity" => "50", "title" => "Board row"})
    board = Trading.position_board(company, admin)
    row = Enum.find(board, &(&1.supply.id == s.id))
    assert row
    assert Decimal.eq?(row.remaining, Decimal.new("50"))
    assert Decimal.eq?(row.loaded, Decimal.new(0))
    assert Decimal.eq?(row.soft_held, Decimal.new(0))
  end

  test "closed supply not on position board; hold and collect are", %{
    admin: admin,
    company: company
  } do
    open = supply_position_fixture(company, admin, %{"title" => "Open one"})
    hold = supply_position_fixture(company, admin, %{"title" => "Held one"})
    collect = supply_position_fixture(company, admin, %{"title" => "Collect one"})
    closed = supply_position_fixture(company, admin, %{"title" => "Closed one"})

    {:ok, _} = Trading.hold_supply_position(hold, company, admin)
    {:ok, _} = Trading.collect_supply_position(collect, company, admin)
    {:ok, _} = Trading.close_supply_position(closed, company, admin)

    board = Trading.position_board(company, admin)
    ids = Enum.map(board, & &1.supply.id)

    assert open.id in ids
    assert hold.id in ids
    assert collect.id in ids
    refute closed.id in ids
  end

  test "soft-hold typeahead includes open/hold/collect not close", %{
    admin: admin,
    company: company
  } do
    open = supply_position_fixture(company, admin, %{"title" => "Type open maize"})
    hold = supply_position_fixture(company, admin, %{"title" => "Type hold maize"})
    collect = supply_position_fixture(company, admin, %{"title" => "Type collect maize"})
    closed = supply_position_fixture(company, admin, %{"title" => "Type close maize"})

    {:ok, _} = Trading.hold_supply_position(hold, company, admin)
    {:ok, _} = Trading.collect_supply_position(collect, company, admin)
    {:ok, _} = Trading.close_supply_position(closed, company, admin)

    names = Trading.open_supply_position_names("maize", company, admin) |> Enum.map(& &1.value)
    assert "Type open maize" in names
    assert "Type hold maize" in names
    assert "Type collect maize" in names
    refute "Type close maize" in names

    assert %{id: id} =
             Trading.get_open_supply_position_by_title("Type open maize", company, admin)

    assert id == open.id
    assert Trading.get_open_supply_position_by_title("Type close maize", company, admin) == nil
  end
end
