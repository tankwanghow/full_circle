defmodule FullCircle.Trading.SalesPositionTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.{SalesPosition, Balances}

  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  setup do
    trading_setup()
  end

  test "create draft sales; undelivered equals quantity", %{admin: admin, company: company} do
    customer = contact_fixture(company, admin)
    good = good_fixture(company, admin)

    assert {:ok, %SalesPosition{} = s} =
             Trading.create_sales_position(
               %{
                 "title" => "Spot 35MT pollard",
                 "quantity" => "35",
                 "unit_price" => "1400",
                 "customer_id" => customer.id,
                 "good_id" => good.id
               },
               company,
               admin
             )

    assert s.status == "draft"
    assert Decimal.eq?(s.quantity, Decimal.new("35"))
    assert Decimal.eq?(Balances.sales_delivered(s), Decimal.new(0))
    assert Decimal.eq?(Balances.sales_undelivered(s), Decimal.new("35"))
  end

  test "soft hold does not change supply remaining", %{admin: admin, company: company} do
    supply = supply_position_fixture(company, admin, %{"quantity" => "100"})
    remaining_before = Balances.supply_remaining(supply)

    sales =
      sales_position_fixture(company, admin, %{
        "quantity" => "40",
        "preferred_supply_id" => supply.id,
        "good_id" => supply.good_id,
        "status" => "open"
      })

    assert Decimal.eq?(Balances.supply_remaining(supply), remaining_before)
    assert Decimal.eq?(Balances.soft_held_for_supply(supply.id), Decimal.new("40"))

    board = Trading.position_board(company, admin)
    row = Enum.find(board, &(&1.supply.id == supply.id))
    assert Decimal.eq?(row.soft_held, Decimal.new("40"))
    assert Decimal.eq?(row.remaining, Decimal.new("100"))

    # keep sales in scope for clarity
    assert sales.preferred_supply_id == supply.id
  end

  test "soft_held only counts draft and open preferred sales", %{admin: admin, company: company} do
    supply = supply_position_fixture(company, admin, %{"quantity" => "100"})

    sales_position_fixture(company, admin, %{
      "quantity" => "10",
      "preferred_supply_id" => supply.id,
      "status" => "draft"
    })

    sales_position_fixture(company, admin, %{
      "quantity" => "20",
      "preferred_supply_id" => supply.id,
      "status" => "open"
    })

    fulfilled =
      sales_position_fixture(company, admin, %{
        "quantity" => "30",
        "preferred_supply_id" => supply.id,
        "status" => "open"
      })

    assert {:ok, _} =
             Trading.fulfill_sales_position(
               fulfilled,
               %{"fulfilled_note" => "short delivery accepted"},
               company,
               admin
             )

    cancelled =
      sales_position_fixture(company, admin, %{
        "quantity" => "15",
        "preferred_supply_id" => supply.id,
        "status" => "open"
      })

    assert {:ok, _} = Trading.cancel_sales_position(cancelled, %{}, company, admin)

    # draft 10 + open 20 = 30; fulfilled and cancelled excluded
    assert Decimal.eq?(Balances.soft_held_for_supply(supply.id), Decimal.new("30"))
  end

  test "fulfill allowed with undelivered remaining", %{admin: admin, company: company} do
    s = sales_position_fixture(company, admin, %{"quantity" => "35", "status" => "open"})
    assert Decimal.eq?(Balances.sales_undelivered(s), Decimal.new("35"))

    assert {:ok, fulfilled} =
             Trading.fulfill_sales_position(
               s,
               %{"fulfilled_note" => "customer accepted shortfall"},
               company,
               admin
             )

    assert fulfilled.status == "fulfilled"
    assert fulfilled.fulfilled_note == "customer accepted shortfall"
  end

  test "open_sales_position sets status open", %{admin: admin, company: company} do
    s = sales_position_fixture(company, admin, %{"status" => "draft"})
    assert {:ok, opened} = Trading.open_sales_position(s, company, admin)
    assert opened.status == "open"
  end

  test "cancel_sales_position sets status cancelled", %{admin: admin, company: company} do
    s = sales_position_fixture(company, admin, %{"status" => "open"})
    assert {:ok, cancelled} = Trading.cancel_sales_position(s, %{}, company, admin)
    assert cancelled.status == "cancelled"
  end

  test "list_open_sales returns open and draft only", %{admin: admin, company: company} do
    open = sales_position_fixture(company, admin, %{"status" => "open", "title" => "Open deal"})

    draft =
      sales_position_fixture(company, admin, %{"status" => "draft", "title" => "Draft deal"})

    fulfilled = sales_position_fixture(company, admin, %{"status" => "open"})
    {:ok, _} = Trading.fulfill_sales_position(fulfilled, %{}, company, admin)

    list = Trading.list_open_sales(company, admin)
    ids = Enum.map(list, & &1.id)
    assert open.id in ids
    assert draft.id in ids
    refute fulfilled.id in ids
  end

  test "requires quantity > 0, customer and good", %{admin: admin, company: company} do
    assert {:error, cs} =
             Trading.create_sales_position(%{"quantity" => "0"}, company, admin)

    errs = errors_on(cs)
    assert Map.has_key?(errs, :quantity) or Map.has_key?(errs, :customer_id)
  end

  test "guest cannot create sales position", %{company: company} do
    guest = FullCircle.UserAccountsFixtures.user_fixture()

    assert Trading.create_sales_position(
             %{"quantity" => "10"},
             company,
             guest
           ) == :not_authorise
  end
end
