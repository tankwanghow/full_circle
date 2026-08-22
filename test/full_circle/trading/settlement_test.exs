defmodule FullCircle.Trading.SettlementTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.TradingFixtures
  import FullCircle.BillingFixtures

  alias FullCircle.Trading
  alias FullCircle.Repo
  alias FullCircle.Trading.{TripDrop, TripLoad}

  setup do
    user = user_fixture()
    company = company_fixture(user, %{})
    %{user: user, company: company}
  end

  # PurInvoice create no longer auto-fills e_inv_internal_id (user must supply it).
  defp with_e_inv_internal_id(attrs, id \\ "SUP-TEST-INV") do
    Map.put(attrs, "e_inv_internal_id", id)
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

  test "create_invoice_from_drops into a closed period is rejected as :period_closed", %{
    user: user,
    company: company
  } do
    %{drop: drop} = completed_sales_drop(company, user)
    {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)
    {:ok, _} = FullCircle.Sys.close_period_through(company, Date.utc_today(), user)

    assert {:error, :period_closed} =
             Trading.create_invoice_from_drops([drop.id], attrs, company, user)
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
    load_attrs = with_e_inv_internal_id(load_attrs)

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

    attrs = with_e_inv_internal_id(attrs)

    assert {:ok, %{create_pur_invoice: pinv}} =
             Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)

    reloaded = FullCircle.Repo.get!(FullCircle.Trading.TripLoad, load.id)
    assert reloaded.pur_invoice_id == pinv.id
    assert pinv.e_inv_internal_id == "SUP-TEST-INV"

    rows = Trading.list_unbilled_loads(company, user)
    refute Enum.any?(rows, &(&1.id == load.id))
  end

  test "cannot double-bill same load", %{user: user, company: company} do
    %{trip: trip} = completed_sales_drop(company, user)
    load = hd(trip.loads)
    {:ok, attrs} = Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)
    attrs = with_e_inv_internal_id(attrs)
    assert {:ok, _} = Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)

    assert {:error, :ineligible_loads} =
             Trading.create_pur_invoice_from_loads([load.id], attrs, company, user)
  end

  test "cancel completed trip blocked when load billed", %{user: user, company: company} do
    %{trip: trip} = completed_sales_drop(company, user)
    load = hd(trip.loads)
    {:ok, attrs} = Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)
    attrs = with_e_inv_internal_id(attrs)
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

    attrs =
      attrs
      |> put_in(["pur_invoice_details", "0"], detail)
      |> with_e_inv_internal_id()

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

    attrs =
      attrs
      |> put_in(["pur_invoice_details", "0"], detail)
      |> with_e_inv_internal_id()

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
    attrs = with_e_inv_internal_id(attrs)

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

  # Trading settles on the trip date rather than on payment terms, so all three
  # settlement documents are due the day they are dated.
  test "customer invoice prefills due_date equal to invoice date", %{
    user: user,
    company: company
  } do
    %{drop: drop} = completed_sales_drop(company, user)

    assert {:ok, attrs} = Trading.build_invoice_attrs_from_drop_ids([drop.id], company, user)
    assert attrs["due_date"] == attrs["invoice_date"]
  end

  test "supplier bill prefills due_date equal to pur invoice date", %{
    user: user,
    company: company
  } do
    %{trip: trip} = completed_sales_drop(company, user)
    load = hd(trip.loads)

    assert {:ok, attrs} =
             Trading.build_pur_invoice_attrs_from_load_ids([load.id], company, user)

    assert attrs["due_date"] == attrs["pur_invoice_date"]
  end

  test "transport bill prefills due_date equal to pur invoice date", %{
    user: user,
    company: company
  } do
    %{drop: drop} = completed_agent_drop(company, user)

    assert {:ok, attrs} =
             Trading.build_pur_invoice_attrs_from_transport_drop_ids([drop.id], company, user)

    assert attrs["due_date"] == attrs["pur_invoice_date"]
  end

  # --- Attach direction: linking trading lines to a PurInvoice that already
  # exists. This is the path a received e-invoice takes, since EInvMetas.Prefill
  # creates the bill without ever touching trading. ---

  defp pur_invoice_for(contact, company, user) do
    good = good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
      )

    attrs = pur_invoice_attrs(contact, good, pur_acct, pur_tc, tax_rate: "0")

    {:ok, %{create_pur_invoice: pinv}} =
      FullCircle.Billing.create_pur_invoice(attrs, company, user)

    pinv
  end

  test "link_loads_to_pur_invoice links a completed load to an existing bill", %{
    user: user,
    company: company
  } do
    supplier = contact_fixture(company, user)
    %{trip: trip} = completed_sales_drop(company, user, supplier: supplier)
    load = hd(trip.loads)
    pinv = pur_invoice_for(supplier, company, user)

    assert {:ok, 1} = Trading.link_loads_to_pur_invoice([load.id], pinv, company, user)
    assert Repo.get!(TripLoad, load.id).pur_invoice_id == pinv.id

    # and it drops off the settlement queue
    refute Enum.any?(Trading.list_unbilled_loads(company, user), &(&1.id == load.id))
  end

  test "link_loads_to_pur_invoice refuses a load already billed elsewhere", %{
    user: user,
    company: company
  } do
    supplier = contact_fixture(company, user)
    %{trip: trip} = completed_sales_drop(company, user, supplier: supplier)
    load = hd(trip.loads)

    first = pur_invoice_for(supplier, company, user)
    second = pur_invoice_for(supplier, company, user)

    assert {:ok, 1} = Trading.link_loads_to_pur_invoice([load.id], first, company, user)

    assert {:error, :ineligible_loads} =
             Trading.link_loads_to_pur_invoice([load.id], second, company, user)

    # the first link is untouched
    assert Repo.get!(TripLoad, load.id).pur_invoice_id == first.id
  end

  test "link_loads_to_pur_invoice refuses a bill for a different supplier", %{
    user: user,
    company: company
  } do
    supplier = contact_fixture(company, user)
    other = contact_fixture(company, user)
    %{trip: trip} = completed_sales_drop(company, user, supplier: supplier)
    load = hd(trip.loads)
    pinv = pur_invoice_for(other, company, user)

    assert {:error, :supplier_mismatch} =
             Trading.link_loads_to_pur_invoice([load.id], pinv, company, user)

    assert is_nil(Repo.get!(TripLoad, load.id).pur_invoice_id)
  end

  test "link_loads_to_pur_invoice refuses loads from mixed suppliers", %{
    user: user,
    company: company
  } do
    supplier = contact_fixture(company, user)
    other = contact_fixture(company, user)
    %{trip: trip_a} = completed_sales_drop(company, user, supplier: supplier)
    %{trip: trip_b} = completed_sales_drop(company, user, supplier: other)
    pinv = pur_invoice_for(supplier, company, user)

    ids = [hd(trip_a.loads).id, hd(trip_b.loads).id]

    assert {:error, :mixed_suppliers} =
             Trading.link_loads_to_pur_invoice(ids, pinv, company, user)
  end

  test "link_loads_to_pur_invoice cannot reach another company's load", %{
    user: user,
    company: company
  } do
    other_company = company_fixture(user, %{})
    supplier = contact_fixture(company, user)

    %{trip: foreign_trip} = completed_sales_drop(other_company, user)
    foreign_load = hd(foreign_trip.loads)

    pinv = pur_invoice_for(supplier, company, user)

    assert {:error, :ineligible_loads} =
             Trading.link_loads_to_pur_invoice([foreign_load.id], pinv, company, user)

    assert is_nil(Repo.get!(TripLoad, foreign_load.id).pur_invoice_id)
  end

  test "link_transport_drops_to_pur_invoice links a haul to an agent bill", %{
    user: user,
    company: company
  } do
    %{drop: drop, agent: agent} = completed_agent_drop(company, user)
    pinv = pur_invoice_for(agent, company, user)

    assert {:ok, 1} =
             Trading.link_transport_drops_to_pur_invoice([drop.id], pinv, company, user)

    assert Repo.get!(TripDrop, drop.id).transport_pur_invoice_id == pinv.id

    info = Trading.pur_invoice_settlement_info(pinv.id, company)
    assert info.linked?
    assert info.transport_drop_count == 1
  end

  test "link_transport_drops_to_pur_invoice refuses a bill from another agent", %{
    user: user,
    company: company
  } do
    %{drop: drop} = completed_agent_drop(company, user)
    other = contact_fixture(company, user, %{"name" => "Some Other Haulier"})
    pinv = pur_invoice_for(other, company, user)

    assert {:error, :agent_mismatch} =
             Trading.link_transport_drops_to_pur_invoice([drop.id], pinv, company, user)

    assert is_nil(Repo.get!(TripDrop, drop.id).transport_pur_invoice_id)
  end

  test "attach_links_multi links loads while the bill is being created", %{
    user: user,
    company: company
  } do
    supplier = contact_fixture(company, user)
    %{trip: trip} = completed_sales_drop(company, user, supplier: supplier)
    load = hd(trip.loads)

    good = good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
      )

    attrs = pur_invoice_attrs(supplier, good, pur_acct, pur_tc, tax_rate: "0")

    assert {:ok, %{create_pur_invoice: pinv}} =
             FullCircle.Billing.create_pur_invoice(
               attrs,
               company,
               user,
               &Trading.attach_links_multi(
                 &1,
                 :create_pur_invoice,
                 [load.id],
                 [],
                 company,
                 user
               )
             )

    assert Repo.get!(TripLoad, load.id).pur_invoice_id == pinv.id
  end

  test "a failed link rolls the whole bill back", %{user: user, company: company} do
    supplier = contact_fixture(company, user)
    other = contact_fixture(company, user)
    %{trip: trip} = completed_sales_drop(company, user, supplier: other)
    load = hd(trip.loads)

    good = good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    pur_tc =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
      )

    before_count = Repo.aggregate(FullCircle.Billing.PurInvoice, :count)
    attrs = pur_invoice_attrs(supplier, good, pur_acct, pur_tc, tax_rate: "0")

    assert {:error, :link_trading_loads, :supplier_mismatch, _} =
             FullCircle.Billing.create_pur_invoice(
               attrs,
               company,
               user,
               &Trading.attach_links_multi(
                 &1,
                 :create_pur_invoice,
                 [load.id],
                 [],
                 company,
                 user
               )
             )

    assert Repo.aggregate(FullCircle.Billing.PurInvoice, :count) == before_count
  end

  test "billable_line_counts drives the unbilled nudge", %{user: user, company: company} do
    supplier = contact_fixture(company, user)
    %{trip: trip} = completed_sales_drop(company, user, supplier: supplier)
    load = hd(trip.loads)

    assert %{loads: 1, transport: 0, total: 1} =
             Trading.billable_line_counts(supplier.id, company, user)

    pinv = pur_invoice_for(supplier, company, user)
    assert {:ok, 1} = Trading.link_loads_to_pur_invoice([load.id], pinv, company, user)

    assert %{total: 0} = Trading.billable_line_counts(supplier.id, company, user)
  end

  test "billable_line_counts is zero for a contact with no trading lines", %{
    user: user,
    company: company
  } do
    contact = contact_fixture(company, user)

    assert %{loads: 0, transport: 0, total: 0} =
             Trading.billable_line_counts(contact.id, company, user)
  end

  test "attach_invoice_drops_multi links drops while invoice is created", %{
    user: user,
    company: company
  } do
    %{drop: drop, customer: customer, good: good} =
      completed_sales_drop(company, user, actual: "15", unit_price: "1000")

    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    attrs = invoice_attrs(customer, good, sales_acct, sales_tc, quantity: "15", tax_rate: "0")

    assert {:ok, %{create_invoice: inv}} =
             FullCircle.Billing.create_invoice(
               attrs,
               company,
               user,
               &Trading.attach_invoice_drops_multi(
                 &1,
                 :create_invoice,
                 [drop.id],
                 company,
                 user
               )
             )

    assert Repo.get!(TripDrop, drop.id).invoice_id == inv.id
    assert Trading.invoice_settlement_info(inv.id, company).linked?
  end

  test "multi-customer trip: list and attach are customer-scoped", %{
    user: user,
    company: company
  } do
    good = good_fixture(company, user)
    c1 = contact_fixture(company, user, %{"name" => "Cust A"})
    c2 = contact_fixture(company, user, %{"name" => "Cust B"})
    supplier = contact_fixture(company, user)

    supply =
      supply_position_fixture(company, user, %{
        "good_id" => good.id,
        "supplier_id" => supplier.id,
        "quantity" => "100",
        "status" => "collect"
      })

    s1 =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => c1.id,
        "quantity" => "20",
        "status" => "open"
      })

    s2 =
      sales_position_fixture(company, user, %{
        "good_id" => good.id,
        "customer_id" => c2.id,
        "quantity" => "30",
        "status" => "open"
      })

    port = location_fixture(company, user, %{"kind" => "port"})
    site1 = location_fixture(company, user, %{"kind" => "customer_site", "name" => "Farm A"})
    site2 = location_fixture(company, user, %{"kind" => "customer_site", "name" => "Farm B"})

    {:ok, trip} =
      Trading.create_trip(
        %{
          "date" => "2026-08-04",
          "transport_mode" => "company_own",
          "vehicle_number" => "MULTI1",
          "loads" => [
            %{
              "planned" => "50",
              "actual" => "50",
              "good_id" => good.id,
              "location_id" => port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned" => "20",
              "actual" => "20",
              "good_id" => good.id,
              "location_id" => site1.id,
              "sales_position_id" => s1.id
            },
            %{
              "planned" => "30",
              "actual" => "30",
              "good_id" => good.id,
              "location_id" => site2.id,
              "sales_position_id" => s2.id
            }
          ]
        },
        company,
        user
      )

    assert {:ok, trip, _} = Trading.complete_trip(trip, company, user)
    [d1, d2] = Enum.sort_by(trip.drops, & &1.seq)

    # Customer filter: only that customer's drop (same trip appears for both)
    for_c1 = Trading.list_uninvoiced_drops(company, user, customer_id: c1.id)
    for_c2 = Trading.list_uninvoiced_drops(company, user, customer_id: c2.id)
    assert Enum.map(for_c1, & &1.id) == [d1.id]
    assert Enum.map(for_c2, & &1.id) == [d2.id]
    assert Enum.all?(for_c1, & &1.billable)
    assert Enum.all?(for_c2, & &1.billable)

    # Attach invoice for c1 cannot take c2's drop
    inv_c1 = invoice_fixture(company, user)
    inv_c1 = %{inv_c1 | contact_id: c1.id}

    assert {:error, :customer_mismatch} =
             Trading.link_drops_to_invoice([d2.id], inv_c1, company, user)

    assert is_nil(Repo.get!(TripDrop, d2.id).invoice_id)

    # Attach c1's drop only
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    sales_tc =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    attrs = invoice_attrs(c1, good, sales_acct, sales_tc, quantity: "20", tax_rate: "0")

    assert {:ok, %{create_invoice: inv}} =
             FullCircle.Billing.create_invoice(
               attrs,
               company,
               user,
               &Trading.attach_invoice_drops_multi(&1, :create_invoice, [d1.id], company, user)
             )

    assert Repo.get!(TripDrop, d1.id).invoice_id == inv.id
    assert is_nil(Repo.get!(TripDrop, d2.id).invoice_id)
    assert Trading.billable_drop_count(c1.id, company, user) == 0
    assert Trading.billable_drop_count(c2.id, company, user) == 1
  end

  describe "settlement exemptions (admin-only waivers)" do
    defp manager_user(company, admin) do
      other = user_fixture()
      {:ok, _} = FullCircle.Sys.allow_user_to_access(company, other, "manager", admin)
      other
    end

    test "non-admin cannot exempt or unexempt", %{user: admin, company: company} do
      %{drop: drop} = completed_sales_drop(company, admin)
      manager = manager_user(company, admin)

      assert {:error, :not_authorise} =
               Trading.exempt_settlement_lines(
                 :customer,
                 [drop.id],
                 "free delivery",
                 company,
                 manager
               )

      assert {:ok, 1} =
               Trading.exempt_settlement_lines(
                 :customer,
                 [drop.id],
                 "free delivery",
                 company,
                 admin
               )

      assert {:error, :not_authorise} =
               Trading.unexempt_settlement_lines(:customer, [drop.id], company, manager)
    end

    test "exempt requires a reason", %{user: admin, company: company} do
      %{drop: drop} = completed_sales_drop(company, admin)

      assert {:error, :reason_required} =
               Trading.exempt_settlement_lines(:customer, [drop.id], "  ", company, admin)
    end

    test "customer waiver: audit fields, queue exclusion, badge, unexempt round-trip", %{
      user: admin,
      company: company
    } do
      %{trip: trip, drop: drop, customer: customer} = completed_sales_drop(company, admin)

      assert {:ok, 1} =
               Trading.exempt_settlement_lines(:customer, [drop.id], "goodwill", company, admin)

      saved = Repo.get!(TripDrop, drop.id)
      assert saved.invoice_exempt_reason == "goodwill"
      assert saved.invoice_exempt_by_id == admin.id
      assert %DateTime{} = saved.invoice_exempt_at

      # Global board excludes the waived drop; trip deep-link still shows it
      assert [] == Trading.list_uninvoiced_drops(company, admin)
      [row] = Trading.list_uninvoiced_drops(company, admin, trip_id: trip.id)
      assert row.id == drop.id
      assert row.exempt_reason == "goodwill"
      refute row.billable
      assert Trading.billable_drop_count(customer.id, company, admin) == 0

      # Badge reports waived, not open
      trip = Trading.get_trip!(trip.id, company, admin)
      badges = Trading.trip_settlement_badges(trip)
      assert badges.customer == :waived
      assert badges.customer_exempt == 1

      # Un-waive restores the queue and badge
      assert {:ok, 1} = Trading.unexempt_settlement_lines(:customer, [drop.id], company, admin)
      assert [%{id: _}] = Trading.list_uninvoiced_drops(company, admin)
      trip = Trading.get_trip!(trip.id, company, admin)
      assert Trading.trip_settlement_badges(trip).customer == :open
    end

    test "supplier waiver excludes load from queue and flips badge", %{
      user: admin,
      company: company
    } do
      %{trip: trip} = completed_sales_drop(company, admin)
      load = hd(trip.loads)

      assert {:ok, 1} =
               Trading.exempt_settlement_lines(
                 :supplier,
                 [load.id],
                 "settled outside",
                 company,
                 admin
               )

      assert [] == Trading.list_unbilled_loads(company, admin)
      [row] = Trading.list_unbilled_loads(company, admin, trip_id: trip.id)
      assert row.exempt_reason == "settled outside"
      refute row.billable

      trip = Trading.get_trip!(trip.id, company, admin)
      assert Trading.trip_settlement_badges(trip).supplier == :waived
    end

    test "transport waiver excludes haul line and flips badge", %{user: admin, company: company} do
      %{trip: trip, drop: drop, agent: agent} = completed_agent_drop(company, admin)

      assert {:ok, 1} =
               Trading.exempt_settlement_lines(
                 :transport,
                 [drop.id],
                 "haul waived",
                 company,
                 admin
               )

      assert [] == Trading.list_unbilled_transport_lines(company, admin)
      [row] = Trading.list_unbilled_transport_lines(company, admin, trip_id: trip.id)
      assert row.exempt_reason == "haul waived"
      refute row.billable
      assert Trading.billable_line_counts(agent.id, company, admin).transport == 0

      trip = Trading.get_trip!(trip.id, company, admin)
      badges = Trading.trip_settlement_badges(trip)
      assert badges.transport == :waived
      # Customer stream untouched
      assert badges.customer == :open
    end

    test "billed or already-waived lines cannot be exempted", %{user: admin, company: company} do
      %{trip: trip, drop: drop, customer: customer, good: good} =
        completed_sales_drop(company, admin)

      assert {:ok, 1} =
               Trading.exempt_settlement_lines(:customer, [drop.id], "once", company, admin)

      assert {:error, :ineligible_lines} =
               Trading.exempt_settlement_lines(:customer, [drop.id], "twice", company, admin)

      assert {:ok, 1} = Trading.unexempt_settlement_lines(:customer, [drop.id], company, admin)

      # Bill it, then exemption must refuse
      sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, admin)

      sales_tc =
        Repo.one!(
          from tc in FullCircle.Accounting.TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = invoice_attrs(customer, good, sales_acct, sales_tc, quantity: "20", tax_rate: "0")

      assert {:ok, %{create_invoice: _}} =
               FullCircle.Billing.create_invoice(
                 attrs,
                 company,
                 admin,
                 &Trading.attach_invoice_drops_multi(
                   &1,
                   :create_invoice,
                   [drop.id],
                   company,
                   admin
                 )
               )

      assert {:error, :ineligible_lines} =
               Trading.exempt_settlement_lines(:customer, [drop.id], "nope", company, admin)

      _ = trip
    end

    test "mixed stream: one drop billed, one waived reports waived badge", %{
      user: admin,
      company: company
    } do
      good = good_fixture(company, admin)
      c1 = contact_fixture(company, admin, %{"name" => "Waive Cust 1"})
      c2 = contact_fixture(company, admin, %{"name" => "Waive Cust 2"})
      supplier = contact_fixture(company, admin)

      supply =
        supply_position_fixture(company, admin, %{
          "good_id" => good.id,
          "supplier_id" => supplier.id,
          "quantity" => "100",
          "status" => "collect"
        })

      s1 =
        sales_position_fixture(company, admin, %{
          "good_id" => good.id,
          "customer_id" => c1.id,
          "quantity" => "30",
          "status" => "open"
        })

      s2 =
        sales_position_fixture(company, admin, %{
          "good_id" => good.id,
          "customer_id" => c2.id,
          "quantity" => "30",
          "status" => "open"
        })

      port = location_fixture(company, admin, %{"kind" => "port"})
      site = location_fixture(company, admin, %{"kind" => "customer_site"})

      {:ok, trip} =
        Trading.create_trip(
          %{
            "date" => "2026-07-22",
            "transport_mode" => "company_own",
            "vehicle_number" => "MIX1",
            "loads" => [
              %{
                "planned" => "20",
                "actual" => "20",
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
                "location_id" => site.id,
                "sales_position_id" => s1.id,
                "supply_position_id" => supply.id
              },
              %{
                "planned" => "10",
                "actual" => "10",
                "good_id" => good.id,
                "location_id" => site.id,
                "sales_position_id" => s2.id,
                "supply_position_id" => supply.id
              }
            ]
          },
          company,
          admin
        )

      assert {:ok, trip, _} = Trading.complete_trip(trip, company, admin)
      [d1, d2] = Enum.sort_by(trip.drops, & &1.seq)

      sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, admin)

      sales_tc =
        Repo.one!(
          from tc in FullCircle.Accounting.TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = invoice_attrs(c1, good, sales_acct, sales_tc, quantity: "10", tax_rate: "0")

      assert {:ok, _} =
               FullCircle.Billing.create_invoice(
                 attrs,
                 company,
                 admin,
                 &Trading.attach_invoice_drops_multi(&1, :create_invoice, [d1.id], company, admin)
               )

      assert {:ok, 1} =
               Trading.exempt_settlement_lines(:customer, [d2.id], "sample", company, admin)

      trip = Trading.get_trip!(trip.id, company, admin)
      badges = Trading.trip_settlement_badges(trip)
      assert badges.customer == :waived
      assert badges.customer_done == 1
      assert badges.customer_exempt == 1
      assert badges.customer_total == 2
    end
  end
end
