defmodule FullCircle.Trading.SupplyPositionTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.{SupplyPosition, Balances}

  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup do
    trading_setup()
  end

  test "create open supply 100 MT; remaining is 100; supply no is system-generated", %{
    admin: admin,
    company: company
  } do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)

    assert {:ok, %SupplyPosition{} = s} =
             Trading.create_supply_position(
               %{
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
    assert s.title =~ ~r/^SUP-\d{6}$/
    assert Decimal.eq?(Balances.supply_remaining(s), Decimal.new("100"))
    assert Decimal.eq?(Balances.supply_loaded(s), Decimal.new(0))
  end

  test "create supply auto-creates supplier site location when missing", %{
    admin: admin,
    company: company
  } do
    supplier =
      contact_fixture(company, admin, %{
        "name" => "Very Long Supplier Name That Exceeds Twenty",
        "address1" => "88 Port Road",
        "city" => "Klang",
        "state" => "Selangor",
        "zipcode" => "42000"
      })

    good = good_fixture(company, admin)

    assert Trading.list_locations_for_contact(supplier.id, company, admin) == []

    assert {:ok, _s} =
             Trading.create_supply_position(
               %{
                 "quantity" => "10",
                 "supplier_id" => supplier.id,
                 "good_id" => good.id
               },
               company,
               admin
             )

    [loc] = Trading.list_locations_for_contact(supplier.id, company, admin)
    assert loc.kind == "supplier_site"
    assert loc.contact_id == supplier.id
    assert loc.name == "Very Long Supplier N"
    assert String.length(loc.name) <= 20
    assert loc.address_note =~ "88 Port Road"
    assert loc.address_note =~ "Klang"

    # Second supply for same supplier does not create another location
    assert {:ok, _} =
             Trading.create_supply_position(
               %{
                 "quantity" => "5",
                 "supplier_id" => supplier.id,
                 "good_id" => good.id
               },
               company,
               admin
             )

    assert length(Trading.list_locations_for_contact(supplier.id, company, admin)) == 1
  end

  test "status transitions: open → hold → collect → closed", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin)
    assert s.status == "open"

    assert {:ok, held} = Trading.hold_supply_position(s, company, admin)
    assert held.status == "hold"

    assert {:ok, collecting} = Trading.collect_supply_position(held, company, admin)
    assert collecting.status == "collect"

    assert {:ok, closed} = Trading.close_supply_position(collecting, company, admin)
    assert closed.status == "closed"
  end


  test "requires quantity > 0, supplier and good; supply no assigned by system", %{
    admin: admin,
    company: company
  } do
    assert {:error, cs} =
             Trading.create_supply_position(%{"quantity" => "0"}, company, admin)

    errs = errors_on(cs)
    assert Map.has_key?(errs, :quantity) or Map.has_key?(errs, :supplier_id)

    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)

    assert {:ok, s} =
             Trading.create_supply_position(
               %{
                 "quantity" => "10",
                 "supplier_id" => contact.id,
                 "good_id" => good.id
               },
               company,
               admin
             )

    assert s.title =~ ~r/^SUP-\d{6}$/
  end

  test "position_board lists open supplies with remaining", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin, %{"quantity" => "50"})
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
    open = supply_position_fixture(company, admin)
    hold = supply_position_fixture(company, admin)
    collect = supply_position_fixture(company, admin)
    closed = supply_position_fixture(company, admin)

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
    open = supply_position_fixture(company, admin)
    hold = supply_position_fixture(company, admin)
    collect = supply_position_fixture(company, admin)
    closed = supply_position_fixture(company, admin)

    {:ok, _} = Trading.hold_supply_position(hold, company, admin)
    {:ok, _} = Trading.collect_supply_position(collect, company, admin)
    {:ok, _} = Trading.close_supply_position(closed, company, admin)

    # Labels are "SUP-000001 · SupplierName"
    names = Trading.open_supply_position_names("SUP-", company, admin) |> Enum.map(& &1.value)
    assert Enum.any?(names, &String.starts_with?(&1, open.title <> " · "))
    assert Enum.any?(names, &String.starts_with?(&1, hold.title <> " · "))
    assert Enum.any?(names, &String.starts_with?(&1, collect.title <> " · "))
    refute Enum.any?(names, &String.starts_with?(&1, closed.title))

    full = Enum.find(names, &String.starts_with?(&1, open.title <> " · "))

    assert %{id: id} =
             Trading.get_open_supply_position_by_title(full, company, admin)

    assert id == open.id
    assert %{id: ^id} = Trading.get_open_supply_position_by_title(open.title, company, admin)
    assert Trading.get_open_supply_position_by_title(closed.title, company, admin) == nil
  end

  test "open supply typeahead filters by good_id and good_ids", %{admin: admin, company: company} do
    good_a = good_fixture(company, admin, %{"name" => "FilterMaizeA"})
    good_b = good_fixture(company, admin, %{"name" => "FilterMaizeB"})

    sa =
      supply_position_fixture(company, admin, %{
        "good_id" => good_a.id,
        "quantity" => "10",
        "status" => "open"
      })

    sb =
      supply_position_fixture(company, admin, %{
        "good_id" => good_b.id,
        "quantity" => "10",
        "status" => "open"
      })

    only_a =
      Trading.open_supply_position_names("SUP-", company, admin, good_id: good_a.id)
      |> Enum.map(& &1.id)

    assert sa.id in only_a
    refute sb.id in only_a

    both =
      Trading.open_supply_position_names("SUP-", company, admin, good_ids: [good_a.id, good_b.id])
      |> Enum.map(& &1.id)

    assert sa.id in both
    assert sb.id in both
  end

  test "update cannot change system supply no", %{admin: admin, company: company} do
    s = supply_position_fixture(company, admin)
    original = s.title

    assert {:ok, updated} =
             Trading.update_supply_position(s, %{"title" => "HACKED", "notes" => "x"}, company, admin)

    assert updated.title == original
    assert updated.notes == "x"
  end
end
