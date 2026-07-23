defmodule FullCircle.Trading.SettlementTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Trading
  alias FullCircle.Repo
  alias FullCircle.Trading.TripDrop

  setup do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{user: user, company: company}
  end

  defp completed_sales_drop(company, user, opts \\ []) do
    good = Keyword.get_lazy(opts, :good, fn -> good_fixture(company, user) end)
    customer = Keyword.get_lazy(opts, :customer, fn -> contact_fixture(company, user) end)
    supplier = Keyword.get_lazy(opts, :supplier, fn -> contact_fixture(company, user) end)
    actual = Keyword.get(opts, :actual_mt, "29.6")
    unit_price = Keyword.get(opts, :unit_price, "1050")

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "quantity" => "100",
        "status" => "collect"
      })

    sales =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "quantity" => "30",
        "unit_price" => unit_price,
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    site = location_fixture(company, user, %{"kind" => "customer_site"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-20",
          "transport_mode" => "company_own",
          "vehicle_number" => "ABC1234",
          "loads" => [
            %{
              "planned_mt" => actual,
              "actual_mt" => actual,
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => actual,
              "actual_mt" => actual,
              "good_id" => good.id,
              "location_id" => site.id,
              "sales_position_id" => sales.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    assert {:ok, trip, _} = Trading.complete_trip(trip, company, user)
    drop = hd(trip.drops)

    %{
      trip: trip,
      drop: drop,
      sales: sales,
      customer: customer,
      good: good,
      supply: supply
    }
  end

  test "list_uninvoiced_drops shows completed as invoiceable and draft as not", %{
    user: user,
    company: company
  } do
    %{drop: drop, customer: customer} = completed_sales_drop(company, user)

    # warehouse drop only (no sales) — not listable
    good = good_fixture(company, user)
    supply = supply_position_fixture(company, user, %{"good_id" => good.id, "status" => "collect"})
    port = location_fixture(company, user, %{"kind" => "port"})
    wh = location_fixture(company, user, %{"kind" => "own_warehouse"})

    {:ok, wh_trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "company_own",
          "vehicle_number" => "XYZ9999",
          "loads" => [
            %{
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => good.id,
              "location_id" => wh.id,
              "supply_position_id" => supply.id
            }
          ]
        },
        company,
        user
      )

    assert {:ok, _, _} = Trading.complete_trip(wh_trip, company, user)

    # draft trip sales drop — listed but not invoiceable
    sales2 =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => customer.id,
        "status" => "open"
      })

    site = location_fixture(company, user, %{"kind" => "customer_site"})

    {:ok, draft} =
      Trading.create_trip(
        %{
          "date" => "2026-07-22",
          "transport_mode" => "company_own",
          "vehicle_number" => "DFT0001",
          "status" => "draft",
          "loads" => [
            %{
              "planned_mt" => "5",
              "actual_mt" => "5",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "5",
              "actual_mt" => "5",
              "good_id" => good.id,
              "location_id" => site.id,
              "sales_position_id" => sales2.id
            }
          ]
        },
        company,
        user
      )

    draft_drop = hd(draft.drops)
    rows = Trading.list_uninvoiced_drops(company, user)
    by_id = Map.new(rows, &{&1.id, &1})

    assert Map.has_key?(by_id, drop.id)
    assert by_id[drop.id].invoiceable == true
    assert by_id[drop.id].trip_status == "completed"

    assert Map.has_key?(by_id, draft_drop.id)
    assert by_id[draft_drop.id].invoiceable == false
    assert by_id[draft_drop.id].trip_status == "draft"

    # warehouse-only drop never listed
    refute Enum.any?(rows, &is_nil(&1.sales_title))
  end

  test "build_invoice_attrs_from_drop_ids prefills customer qty price", %{
    user: user,
    company: company
  } do
    %{drop: drop, customer: customer, good: good} =
      completed_sales_drop(company, user, actual_mt: "29.6", unit_price: "1050")

    assert {:ok, attrs} =
             Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert attrs["contact_id"] == customer.id
    assert attrs["contact_name"] == customer.name

    detail = attrs["invoice_details"]["0"]
    assert detail["good_id"] == good.id
    assert detail["quantity"] == "29.6"
    assert detail["unit_price"] == "1050"
    assert detail["account_id"]
    assert detail["tax_code_id"]
    assert attrs["descriptions"] in [nil, ""]
    # drop date · vehicle · sales no · location
    assert detail["descriptions"] =~ "2026-07-20"
    assert detail["descriptions"] =~ "ABC1234"
    assert detail["descriptions"] =~ "SAL-"
    assert detail["descriptions"] =~ " · "
  end

  test "create_invoice_from_drops creates invoice and links drop", %{
    user: user,
    company: company
  } do
    %{drop: drop, customer: customer} =
      completed_sales_drop(company, user, actual_mt: "12.5", unit_price: "900")

    assert {:ok, attrs} =
             Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert {:ok, %{create_invoice: inv}} =
             Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    assert inv.contact_id == customer.id
    reloaded = Repo.get!(TripDrop, drop.id)
    assert reloaded.invoice_id == inv.id

    # no longer uninvoiced
    rows = Trading.list_uninvoiced_drops(company, user)
    refute Enum.any?(rows, &(&1.id == drop.id))
  end

  test "cannot double-invoice same drop", %{user: user, company: company} do
    %{drop: drop} = completed_sales_drop(company, user)
    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert {:ok, _} = Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    assert {:error, :ineligible_drops} =
             Trading.create_invoice_from_drops([drop.id], attrs, company, user)
  end

  test "mixed customers rejected", %{user: user, company: company} do
    good = good_fixture(company, user)
    c1 = contact_fixture(company, user)
    c2 = contact_fixture(company, user)

    %{drop: d1} = completed_sales_drop(company, user, good: good, customer: c1)
    %{drop: d2} = completed_sales_drop(company, user, good: good, customer: c2)

    assert {:error, :mixed_customers} =
             Trading.build_invoice_attrs_from_drop_ids([d1.id, d2.id], company, user)
  end

  test "cancel completed trip blocked when drop invoiced", %{user: user, company: company} do
    %{trip: trip, drop: drop} = completed_sales_drop(company, user)
    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)
    assert {:ok, _} = Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    assert {:error, :has_invoices} = Trading.cancel_trip(trip, company, user)
  end
end
