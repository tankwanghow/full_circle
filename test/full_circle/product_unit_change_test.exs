defmodule FullCircle.ProductUnitChangeTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Product

  import FullCircle.BillingFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    good = good_fixture(company, admin)
    %{admin: admin, company: company, good: good}
  end

  test "quantity_line_usage is zero with no document lines", %{good: good} do
    usage = Product.quantity_line_usage(good.id)
    assert usage.total == 0
    refute Product.unit_change_risk?(good.id, good.unit, "KG")
    assert Product.unit_change_warning_message(good.id) == nil
  end

  test "trading supply positions count toward unit-change risk", %{
    admin: admin,
    company: company,
    good: good
  } do
    contact = contact_fixture(company, admin)

    {:ok, _} =
      FullCircle.Trading.create_supply_position(
        %{
          "title" => "test supply",
          "quantity" => "10",
          "unit_price" => "1",
          "supplier_id" => contact.id,
          "good_id" => good.id
        },
        company,
        admin
      )

    usage = Product.quantity_line_usage(good.id)
    assert usage.trading_supply_positions >= 1
    assert usage.total >= 1

    assert Product.unit_change_risk?(good.id, good.unit, "BAG")
    refute Product.unit_change_risk?(good.id, good.unit, good.unit)

    msg = Product.unit_change_warning_message(good.id)
    assert is_binary(msg)
    assert msg =~ "trading supply" or msg =~ "Warning"
  end

  test "packaging unit_multiplier change risks when package is referenced", %{
    admin: admin,
    company: company,
    good: good
  } do
    good = Product.get_good!(good.id, company, admin)
    pack = hd(good.packagings)

    # no document refs yet
    refute Product.packaging_unit_multiplier_change_risk?(
             pack.id,
             pack.unit_multiplier,
             Decimal.add(pack.unit_multiplier, 1)
           )

    # Simulate a document line pointing at this packaging
    %FullCircle.Billing.InvoiceDetail{}
    |> Ecto.Changeset.change(%{
      good_id: good.id,
      package_id: pack.id,
      quantity: Decimal.new("1"),
      unit_price: Decimal.new("1"),
      discount: Decimal.new("0"),
      tax_rate: Decimal.new("0"),
      package_qty: Decimal.new("1")
    })
    |> FullCircle.Repo.insert!()

    assert Product.packaging_unit_multiplier_change_risk?(
             pack.id,
             pack.unit_multiplier,
             Decimal.add(pack.unit_multiplier, 1)
           )

    msg = Product.packaging_unit_multiplier_warning_message(pack.id, pack.name)
    assert is_binary(msg)
    assert msg =~ pack.name or msg =~ "packaging"

    warnings =
      Product.packaging_multiplier_change_warnings(good.packagings, %{
        "0" => %{
          "id" => pack.id,
          "name" => pack.name,
          "unit_multiplier" => Decimal.to_string(Decimal.add(pack.unit_multiplier, 1))
        }
      })

    assert length(warnings) >= 1
  end
end

