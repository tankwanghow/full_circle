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
    actual = Keyword.get(opts, :actual, "29.6")
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
              "planned" => actual,
              "actual" => actual,
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => actual,
              "actual" => actual,
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

    supply =
      supply_position_fixture(company, user, %{"good_id" => good.id, "status" => "collect"})

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
              "planned" => "10",
              "actual" => "10",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "10",
              "actual" => "10",
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
              "planned" => "5",
              "actual" => "5",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "5",
              "actual" => "5",
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
      completed_sales_drop(company, user, actual: "29.6", unit_price: "1050")

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
      completed_sales_drop(company, user, actual: "12.5", unit_price: "900")

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
    refute Trading.trip_has_settlement_docs?(trip)

    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)
    assert {:ok, _} = Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    trip = Trading.get_trip!(trip.id, company, user)
    assert Trading.trip_has_settlement_docs?(trip)
    assert {:error, :has_invoices} = Trading.cancel_trip(trip, company, user)
  end

  test "list queues filter by trip_id", %{user: user, company: company} do
    %{trip: trip_a, drop: drop_a} = completed_sales_drop(company, user)
    %{trip: trip_b, drop: drop_b} = completed_sales_drop(company, user)
    load_a = hd(trip_a.loads)

    drops_a = Trading.list_uninvoiced_drops(company, user, trip_id: trip_a.id)
    assert Enum.map(drops_a, & &1.id) == [drop_a.id]
    refute Enum.any?(drops_a, &(&1.id == drop_b.id))

    loads_a = Trading.list_unbilled_loads(company, user, trip_id: trip_a.id)
    assert Enum.map(loads_a, & &1.id) == [load_a.id]

    assert Trading.list_uninvoiced_drops(company, user, trip_id: trip_b.id)
           |> Enum.map(& &1.id) == [drop_b.id]
  end

  test "trip_id filter includes billed lines with doc link fields", %{
    user: user,
    company: company
  } do
    %{trip: trip, drop: drop} = completed_sales_drop(company, user)
    load = hd(trip.loads)

    {:ok, inv_attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert {:ok, %{create_invoice: inv}} =
             Trading.create_invoice_from_drops([drop.id], inv_attrs, company, user)

    {:ok, load_attrs} = Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)

    assert {:ok, %{create_pur_invoice: pinv}} =
             Trading.create_pur_invoice_from_loads([load.id], load_attrs, company, user)

    # Global board still hides settled
    refute Enum.any?(Trading.list_uninvoiced_drops(company, user), &(&1.id == drop.id))
    refute Enum.any?(Trading.list_unbilled_loads(company, user), &(&1.id == load.id))

    drops = Trading.list_uninvoiced_drops(company, user, trip_id: trip.id)
    row = Enum.find(drops, &(&1.id == drop.id))
    assert row
    refute row.invoiceable
    assert row.doc_id == inv.id
    assert row.doc_no == inv.invoice_no
    assert row.doc_kind == "invoice"

    loads = Trading.list_unbilled_loads(company, user, trip_id: trip.id)
    load_row = Enum.find(loads, &(&1.id == load.id))
    assert load_row
    refute load_row.billable
    assert load_row.doc_id == pinv.id
    assert load_row.doc_no == pinv.pur_invoice_no
    assert load_row.doc_kind == "pur_invoice"
  end

  test "list_unbilled_loads shows completed commercial loads as billable", %{
    user: user,
    company: company
  } do
    %{trip: trip, customer: customer} = completed_sales_drop(company, user)
    load = hd(trip.loads)

    rows = Trading.list_unbilled_loads(company, user)
    by_id = Map.new(rows, &{&1.id, &1})

    assert Map.has_key?(by_id, load.id)
    assert by_id[load.id].billable == true
    assert by_id[load.id].trip_status == "completed"
    # customer not on load list — has supplier
    assert is_binary(by_id[load.id].supplier_name)

    refute Map.has_key?(by_id[load.id], :customer_id) or
             by_id[load.id][:customer_id] == customer.id
  end

  test "create_pur_invoice_from_loads creates pur invoice and links load", %{
    user: user,
    company: company
  } do
    %{trip: trip, good: good} =
      completed_sales_drop(company, user, actual: "18.0", unit_price: "900")

    load = hd(trip.loads)
    supply = FullCircle.Repo.get!(FullCircle.Trading.SupplyPosition, load.supply_position_id)

    assert {:ok, attrs} =
             Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)

    assert attrs["contact_id"] == supply.supplier_id
    detail = attrs["pur_invoice_details"]["0"]
    assert detail["good_id"] == good.id
    assert detail["quantity"] == "18.0"

    assert detail["unit_price"] == "900" or
             detail["unit_price"] == Decimal.to_string(supply.unit_price)

    assert attrs["descriptions"] in [nil, ""]
    assert detail["descriptions"] =~ "SUP-"

    assert {:ok, %{create_pur_invoice: pinv}} =
             Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)

    reloaded = FullCircle.Repo.get!(FullCircle.Trading.TripLoad, load.id)
    assert reloaded.pur_invoice_id == pinv.id

    rows = Trading.list_unbilled_loads(company, user)
    refute Enum.any?(rows, &(&1.id == load.id))
  end

  test "cannot double-bill same load", %{user: user, company: company} do
    %{trip: trip} = completed_sales_drop(company, user)
    load = hd(trip.loads)
    {:ok, attrs} = Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)
    assert {:ok, _} = Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)

    assert {:error, :ineligible_loads} =
             Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)
  end

  test "cancel completed trip blocked when load billed", %{user: user, company: company} do
    %{trip: trip} = completed_sales_drop(company, user)
    load = hd(trip.loads)
    {:ok, attrs} = Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)
    assert {:ok, _} = Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)

    assert {:error, :has_invoices} = Trading.cancel_trip(trip, company, user)
  end

  defp completed_agent_drop(company, user, opts \\ []) do
    good = Keyword.get_lazy(opts, :good, fn -> good_fixture(company, user) end)
    customer = Keyword.get_lazy(opts, :customer, fn -> contact_fixture(company, user) end)
    supplier = Keyword.get_lazy(opts, :supplier, fn -> contact_fixture(company, user) end)

    agent =
      Keyword.get_lazy(opts, :agent, fn ->
        contact_fixture(company, user, %{"name" => "Haul Co"})
      end)

    actual = Keyword.get(opts, :actual, "20")

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
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port", "name" => "Agent Port"})
    site = location_fixture(company, user, %{"kind" => "customer_site", "name" => "Agent Farm"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-07-21",
          "transport_mode" => "agent",
          "transport_agent_id" => agent.id,
          "transport_agent_name" => agent.name,
          "vehicle_number" => "AGT 9001",
          "loads" => [
            %{
              "planned" => actual,
              "actual" => actual,
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => actual,
              "actual" => actual,
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

    %{trip: trip, drop: drop, agent: agent, good: good, port: port, site: site}
  end

  test "list_unbilled_transport_lines shows agent haul with origin", %{
    user: user,
    company: company
  } do
    %{drop: drop, agent: agent, port: port, site: site} = completed_agent_drop(company, user)

    rows = Trading.list_unbilled_transport_lines(company, user)
    by_id = Map.new(rows, &{&1.id, &1})

    assert Map.has_key?(by_id, drop.id)
    row = by_id[drop.id]
    assert row.billable == true
    assert row.agent_id == agent.id
    assert row.from_location_id == port.id
    assert row.to_location_id == site.id
    assert row.from_location_name =~ "Agent Port"
    assert row.to_location_name =~ "Agent Farm"
  end

  test "create_pur_invoice_from_transport_drops links haul lines", %{
    user: user,
    company: company
  } do
    %{drop: drop, agent: agent} = completed_agent_drop(company, user, actual: "22")

    assert {:ok, attrs} =
             Trading.build_pur_invoice_attrs_from_transport_drop_ids([drop.id], company, user)

    assert attrs["contact_id"] == agent.id
    assert attrs["descriptions"] in [nil, ""]
    detail = attrs["pur_invoice_details"]["0"]
    assert detail["quantity"] == "22"
    assert detail["unit_price"] == "0"
    # Service good — not the grain product hauled
    # Priority: Transport Services Purchase | Transport Charges | Note | (create) Haulage
    assert detail["good_name"] in [
             "Transport Services Purchase",
             "Transport Charges",
             "Note",
             "Haulage"
           ]

    assert detail["descriptions"] =~ "Agent Port"
    assert detail["descriptions"] =~ "Agent Farm"
    assert detail["descriptions"] =~ "AGT 9001"

    # Clerk sets haulage rate from agent bill
    detail = Map.put(detail, "unit_price", "50")
    attrs = put_in(attrs, ["pur_invoice_details", "0"], detail)

    assert {:ok, %{create_pur_invoice: pinv}} =
             Trading.create_pur_invoice_from_transport_drops([drop.id], attrs, company, user)

    reloaded = FullCircle.Repo.get!(FullCircle.Trading.TripDrop, drop.id)
    assert reloaded.transport_pur_invoice_id == pinv.id
    assert pinv.contact_id == agent.id

    rows = Trading.list_unbilled_transport_lines(company, user)
    refute Enum.any?(rows, &(&1.id == drop.id))
  end

  test "cancel trip blocked when transport haul billed", %{user: user, company: company} do
    %{trip: trip, drop: drop} = completed_agent_drop(company, user)

    {:ok, attrs} =
      Trading.build_pur_invoice_attrs_from_transport_drop_ids([drop.id], company, user)

    detail = Map.put(attrs["pur_invoice_details"]["0"], "unit_price", "10")
    attrs = put_in(attrs, ["pur_invoice_details", "0"], detail)

    assert {:ok, _} =
             Trading.create_pur_invoice_from_transport_drops([drop.id], attrs, company, user)

    assert {:error, :has_invoices} = Trading.cancel_trip(trip, company, user)
  end

  test "unlink invoice settlement clears drop link and reopens queue", %{
    user: user,
    company: company
  } do
    %{drop: drop, customer: customer} = completed_sales_drop(company, user)
    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)

    assert {:ok, %{create_invoice: inv}} =
             Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    info = Trading.invoice_settlement_info(inv.id, company)
    assert info.linked?
    assert info.line_count == 1

    assert Trading.contact_change_blocked_for_invoice?(
             inv,
             %{"contact_id" => Ecto.UUID.generate(), "contact_name" => "Other"}
           )

    refute Trading.contact_change_blocked_for_invoice?(
             inv,
             %{"contact_id" => customer.id, "contact_name" => customer.name}
           )

    assert {:ok, %{unlinked: 1}} = Trading.unlink_invoice_settlement(inv, company, user)
    info2 = Trading.invoice_settlement_info(inv.id, company)
    refute info2.linked?

    rows = Trading.list_uninvoiced_drops(company, user)
    assert Enum.any?(rows, &(&1.id == drop.id and &1.invoiceable))
  end

  test "unlink pur invoice settlement clears load link", %{user: user, company: company} do
    %{trip: trip} = completed_sales_drop(company, user)
    load = hd(trip.loads)
    {:ok, attrs} = Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)

    assert {:ok, %{create_pur_invoice: pinv}} =
             Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)

    assert Trading.pur_invoice_settlement_info(pinv.id, company).linked?

    assert {:ok, %{loads_unlinked: 1, transport_unlinked: 0}} =
             Trading.unlink_pur_invoice_settlement(pinv, company, user)

    refute Trading.pur_invoice_settlement_info(pinv.id, company).linked?
    rows = Trading.list_unbilled_loads(company, user)
    assert Enum.any?(rows, &(&1.id == load.id and &1.billable))
  end

  test "trip_settlement_badges for completed company-own trip", %{user: user, company: company} do
    %{trip: trip, drop: drop} = completed_sales_drop(company, user)
    trip = Trading.get_trip!(trip.id, company, user)

    badges = Trading.trip_settlement_badges(trip)
    assert badges.show?
    assert badges.customer == :open
    assert badges.supplier == :open
    assert badges.transport == :n_a
    assert badges.customer_total == 1
    assert badges.supplier_total == 1

    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)
    assert {:ok, _} = Trading.create_invoice_from_drops([drop.id], attrs, company, user)

    trip = Trading.get_trip!(trip.id, company, user)
    badges2 = Trading.trip_settlement_badges(trip)
    assert badges2.customer == :done
    assert badges2.supplier == :open
  end

  test "trip_settlement_badges transport for agent trip", %{user: user, company: company} do
    %{trip: trip} = completed_agent_drop(company, user)
    trip = Trading.get_trip!(trip.id, company, user)
    badges = Trading.trip_settlement_badges(trip)
    assert badges.show?
    assert badges.transport == :open
    assert badges.transport_total == 1
  end
end
