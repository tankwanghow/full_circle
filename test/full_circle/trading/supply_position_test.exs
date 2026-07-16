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
                 "title" => "JON DOE maize",
                 "vessel_name" => "JON DOE",
                 "period" => "May 2026",
                 "quantity" => "100",
                 "unit" => "MT",
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

  test "close_supply_position sets status closed", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin)
    assert {:ok, closed} = Trading.close_supply_position(s, company, admin)
    assert closed.status == "closed"
  end

  test "requires quantity > 0, supplier and good", %{admin: admin, company: company} do
    assert {:error, cs} =
             Trading.create_supply_position(%{"quantity" => "0"}, company, admin)

    errs = errors_on(cs)
    assert Map.has_key?(errs, :quantity) or Map.has_key?(errs, :supplier_id)
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

  test "closed supply not on open position board", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin)
    {:ok, _} = Trading.close_supply_position(s, company, admin)
    board = Trading.position_board(company, admin)
    refute Enum.any?(board, &(&1.supply.id == s.id))
  end
end
