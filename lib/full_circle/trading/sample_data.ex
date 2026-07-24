defmodule FullCircle.Trading.SampleData do
  @moduledoc """
  Dev/demo sample data for the Trading Desk.

  Prefer `mix full_circle.seed_trading` (see Mix.Tasks.FullCircle.SeedTrading).
  Creates ~50 supplies, ~50 sales, and ~50 trips (mixed statuses), settlement-ready
  singles, and explicit **multi-load / multi-drop** trips for workflow testing.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Sys.{Company, CompanyUser}
  alias FullCircle.UserAccounts.User
  alias FullCircle.Accounting
  alias FullCircle.Accounting.Contact
  alias FullCircle.Product
  alias FullCircle.Product.Good
  alias FullCircle.StdInterface
  alias FullCircle.Trading

  @batch_prefix "DEMO"
  @sample_count 50

  @doc """
  Seed sample trading data for a company as an authorized user.

  Options:
  - `:company` — company name substring or id (binary)
  - `:email` — user email with manage_trading on that company
  - `:batch` — optional tag appended to titles (default timestamp)
  """
  def seed!(opts \\ []) do
    company = resolve_company!(opts)
    user = resolve_user!(company, opts)
    batch = Keyword.get(opts, :batch) || Calendar.strftime(DateTime.utc_now(), "%m%d%H%M")

    maize = get_good!(company, user, "Maize")
    pollard = get_good!(company, user, "Wheat Pollard")
    soy = get_good!(company, user, "Soybean Meal")

    suppliers = ensure_suppliers!(company, user)
    customers = ensure_customers!(company, user)
    locs = ensure_locations!(company, user, suppliers, customers)

    supplies = create_supplies!(company, user, batch, suppliers, maize, pollard, soy)
    sales = create_sales!(company, user, batch, customers, supplies, maize, pollard, soy)
    trips = create_trips!(company, user, batch, locs, supplies, sales, customers, maize, pollard, soy)

    # Dedicated settlement-ready deliveries (completed + sales drop, never stock-in-only)
    settlement_trips =
      create_settlement_ready_trips!(
        company,
        user,
        batch,
        locs,
        supplies,
        sales,
        maize,
        pollard,
        soy
      )

    multi_trips =
      create_multi_line_trips!(
        company,
        user,
        batch,
        locs,
        supplies,
        sales,
        customers,
        maize,
        pollard,
        soy
      )

    trips = trips ++ settlement_trips ++ multi_trips
    uninvoiced = Trading.list_uninvoiced_drops(company, user)
    unbilled_loads = Trading.list_unbilled_loads(company, user)
    unbilled_transport = Trading.list_unbilled_transport_lines(company, user)

    summary = %{
      company: company.name,
      company_id: company.id,
      user: user.email,
      batch: batch,
      goods: %{
        maize: good_label(maize),
        pollard: good_label(pollard),
        soy: good_label(soy)
      },
      locations: Map.new(locs, fn {k, v} -> {k, v.name} end),
      supplies: Enum.map(supplies, &{&1.title, &1.status}),
      sales: Enum.map(sales, &{&1.title, &1.status}),
      trips: Enum.map(trips, &{&1.reference_no, &1.status}),
      settlement_trips: Enum.map(settlement_trips, & &1.reference_no),
      multi_line_trips:
        Enum.map(multi_trips, fn t ->
          {t.reference_no, t.status, length(t.loads || []), length(t.drops || [])}
        end),
      uninvoiced_drop_count: length(uninvoiced),
      unbilled_load_count: length(unbilled_loads),
      unbilled_transport_count: length(unbilled_transport),
      desk_path: "/companies/#{company.id}/trading/desk",
      settlement_path: "/companies/#{company.id}/trading/settlement"
    }

    {:ok, summary}
  end

  # --- masters ---

  defp ensure_suppliers!(company, user) do
    names = [
      vessel: "Grain Supplier Asia",
      local: "Local Corn Trader",
      thai: "Thai Feed Ingredients",
      indon: "Indo Bulk Grains",
      vietnam: "Mekong Agri Trade",
      domestic: "Central Grain Depot"
    ]

    Map.new(names, fn {key, name} ->
      {key, ensure_contact!(company, user, "#{@batch_prefix} #{name}", "Supplier")}
    end)
  end

  defp ensure_customers!(company, user) do
    names = [
      farm_a: "Kajang Layer Farm",
      farm_b: "Seremban Broiler Coop",
      farm_c: "Ipoh Poultry Hub",
      farm_d: "Malacca Feed Users",
      farm_e: "Johor Integrator",
      mill: "Internal Feed Intake",
      trader: "Spot Trader KL"
    ]

    Map.new(names, fn {key, name} ->
      {key, ensure_contact!(company, user, "#{@batch_prefix} #{name}", "Customer")}
    end)
  end

  defp ensure_locations!(company, user, suppliers, customers) do
    # contact_id links site → supplier/customer for trip form auto-filter/select
    specs = [
      port: {"Port Klang Godown", "port", "3.0010", "101.3910", suppliers.vessel.id},
      supplier_wh: {"Supplier WH - Kapar", "supplier_site", "3.1200", "101.3800", suppliers.local.id},
      silo: {"Main Silo", "own_warehouse", "3.0500", "101.5500", nil},
      feed_bay: {"Feedmill Bay", "own_warehouse", "3.0510", "101.5510", nil},
      silo_b: {"North Silo B", "own_warehouse", "3.0550", "101.5520", nil},
      silo_c: {"South Bag Store", "own_warehouse", "3.0480", "101.5490", nil},
      silo_d: {"Transit Bay 2", "own_warehouse", "3.0520", "101.5530", nil},
      silo_e: {"Old Godown C", "own_warehouse", "3.0460", "101.5480", nil},
      farm_a: {"Kajang Farm Gate", "customer_site", "2.9930", "101.7900", customers.farm_a.id},
      farm_b: {"Seremban Farm", "customer_site", "2.7260", "101.9420", customers.farm_b.id},
      farm_c: {"Ipoh Farm Gate", "customer_site", "4.5970", "101.0900", customers.farm_c.id},
      farm_d: {"Malacca Drop", "customer_site", "2.1890", "102.2500", customers.farm_d.id},
      farm_e: {"Johor Integrator Gate", "customer_site", "1.4927", "103.7414", customers.farm_e.id}
    ]

    Map.new(specs, fn {key, {name, kind, lat, lng, contact_id}} ->
      loc =
        ensure_location!(company, user, %{
          "name" => "#{@batch_prefix} #{name}",
          "kind" => kind,
          "latitude" => lat,
          "longitude" => lng,
          "contact_id" => contact_id
        })

      {key, loc}
    end)
  end

  # --- supplies: ~50 with mixed statuses ---

  defp create_supplies!(company, user, batch, suppliers, maize, pollard, soy) do
    supplier_list = Map.values(suppliers)
    goods = [maize, pollard, soy]
    # Weighted toward board-visible statuses
    statuses = ~w(open open open collect collect hold hold closed)

    labels = [
      "Vessel lot",
      "Local PO",
      "Spot buy",
      "Contract fill",
      "Depot draw",
      "Import parcel",
      "Mill intake"
    ]

    for i <- 1..@sample_count do
      supplier = Enum.at(supplier_list, rem(i - 1, length(supplier_list)))
      good = Enum.at(goods, rem(i - 1, length(goods)))
      status = Enum.at(statuses, rem(i - 1, length(statuses)))
      label = Enum.at(labels, rem(i - 1, length(labels)))
      qty = Integer.to_string(80 + rem(i * 17, 920))
      price = Integer.to_string(950 + rem(i * 23, 1100))
      from = Date.add(~D[2026-05-01], rem(i * 3, 100))

      {:ok, s} =
        Trading.create_supply_position(
          %{
            "quantity" => qty,
            "unit_price" => price,
            "status" => status,
            "available_from" => Date.to_iso8601(from),
            "supplier_id" => supplier.id,
            "good_id" => good.id,
            "notes" => "#{@batch_prefix} #{label} ##{i} #{batch}"
          },
          company,
          user
        )

      s
    end
  end

  # --- sales: ~50 with mixed statuses ---

  defp create_sales!(company, user, batch, customers, supplies, maize, pollard, soy) do
    customer_list = Map.values(customers)
    goods = [maize, pollard, soy]
    statuses = ~w(open open open open draft draft hold hold fulfilled cancelled)
    active_supplies = Enum.reject(supplies, &(&1.status == "closed"))

    labels = [
      "Spot order",
      "Call-off",
      "Farm delivery",
      "Mill draw",
      "Trader lot",
      "Contract month",
      "Urgent lift"
    ]

    for i <- 1..@sample_count do
      customer = Enum.at(customer_list, rem(i - 1, length(customer_list)))
      good = Enum.at(goods, rem(i - 1, length(goods)))
      status = Enum.at(statuses, rem(i - 1, length(statuses)))
      label = Enum.at(labels, rem(i - 1, length(labels)))
      qty = Integer.to_string(10 + rem(i * 11, 120))
      price = Integer.to_string(1050 + rem(i * 19, 1200))
      from = Date.add(~D[2026-06-01], rem(i * 2, 90))

      # Prefer a supply of the same good when possible
      preferred =
        active_supplies
        |> Enum.filter(&(&1.good_id == good.id))
        |> case do
          [] -> Enum.at(active_supplies, rem(i - 1, max(length(active_supplies), 1)))
          same -> Enum.at(same, rem(i - 1, length(same)))
        end

      attrs = %{
        "quantity" => qty,
        "unit_price" => price,
        "status" => status,
        "available_from" => Date.to_iso8601(from),
        "customer_id" => customer.id,
        "good_id" => good.id,
        "notes" => "#{@batch_prefix} #{label} ##{i} #{batch}"
      }

      # Skip preferred supply on cancelled quotes sometimes
      attrs =
        if status == "cancelled" and rem(i, 3) == 0 do
          attrs
        else
          if preferred, do: Map.put(attrs, "preferred_supply_id", preferred.id), else: attrs
        end

      {:ok, s} = Trading.create_sales_position(attrs, company, user)
      s
    end
  end

  # --- trips: ~50 (stock-in, deliveries, draft/planned/cancelled mix) ---

  defp create_trips!(
         company,
         user,
         batch,
         locs,
         supplies,
         sales,
         customers,
         maize,
         pollard,
         soy
       ) do
    goods = [maize, pollard, soy]
    load_locs = [locs.port, locs.supplier_wh, locs.silo, locs.feed_bay, locs.silo_b]
    wh_locs = [locs.silo, locs.feed_bay, locs.silo_b, locs.silo_c, locs.silo_d, locs.silo_e]
    drop_locs = [locs.farm_a, locs.farm_b, locs.farm_c, locs.farm_d, locs.farm_e]
    agents = [customers.mill, customers.trader]

    active_supplies = Enum.reject(supplies, &(&1.status == "closed"))
    open_sales = Enum.filter(sales, &(&1.status in ~w(draft open hold)))

    # Status mix: many completed, then draft/planned/cancelled
    trip_statuses =
      List.duplicate("completed", 35) ++
        List.duplicate("draft", 6) ++
        List.duplicate("planned", 6) ++
        List.duplicate("cancelled", 3)

    for i <- 1..@sample_count do
      status = Enum.at(trip_statuses, rem(i - 1, length(trip_statuses)))
      good = Enum.at(goods, rem(i - 1, length(goods)))
      supply =
        active_supplies
        |> Enum.filter(&(&1.good_id == good.id))
        |> case do
          [] -> Enum.at(active_supplies, rem(i - 1, length(active_supplies)))
          same -> Enum.at(same, rem(i - 1, length(same)))
        end

      sales_row =
        open_sales
        |> Enum.filter(&(&1.good_id == good.id))
        |> case do
          [] -> Enum.at(open_sales, rem(i - 1, max(length(open_sales), 1)))
          same -> Enum.at(same, rem(i - 1, length(same)))
        end

      mt = Integer.to_string(8 + rem(i * 7, 55))
      vehicle = "DEMO #{1000 + i}"
      date = Date.add(~D[2026-06-15], rem(i * 2, 60))
      # Alternate stock-in vs delivery for variety
      stock_in? = rem(i, 3) == 0

      {load_loc, drop_loc, drop_sales_id, drop_supply_id, notes_tag} =
        if stock_in? do
          {
            Enum.at(load_locs, rem(i - 1, length(load_locs))),
            Enum.at(wh_locs, rem(i - 1, length(wh_locs))),
            nil,
            supply.id,
            "stock-in"
          }
        else
          {
            Enum.at(wh_locs, rem(i - 1, length(wh_locs))),
            Enum.at(drop_locs, rem(i - 1, length(drop_locs))),
            sales_row && sales_row.id,
            supply.id,
            "delivery"
          }
        end

      agent? = rem(i, 5) == 0
      agent = Enum.at(agents, rem(i - 1, length(agents)))

      load_line = %{
        "planned_mt" => mt,
        "actual_mt" => mt,
        "good_id" => good.id,
        "location_id" => load_loc.id,
        "supply_position_id" => supply.id
      }

      drop_line = %{
        "planned_mt" => mt,
        "actual_mt" => mt,
        "good_id" => good.id,
        "location_id" => drop_loc.id,
        "supply_position_id" => drop_supply_id
      }

      drop_line =
        if drop_sales_id, do: Map.put(drop_line, "sales_position_id", drop_sales_id), else: drop_line

      attrs = %{
        "date" => Date.to_iso8601(date),
        "transport_mode" => if(agent?, do: "agent", else: "company_own"),
        "status" => "draft",
        "vehicle_number" => vehicle,
        "notes" => "#{@batch_prefix} #{notes_tag} ##{i} #{batch}",
        "loads" => [load_line],
        "drops" => [drop_line]
      }

      attrs =
        if agent? do
          attrs
          |> Map.put("transport_agent_id", agent.id)
          |> Map.put("transport_agent_name", agent.name)
        else
          attrs
        end

      case status do
        "completed" ->
          complete_trip!(company, user, attrs)

        "cancelled" ->
          {:ok, t} = Trading.create_trip(attrs, company, user)

          case cancel_trip_if_possible(t, company, user) do
            {:ok, t2} -> t2
            _ -> t
          end

        other when other in ~w(draft planned) ->
          {:ok, t} =
            Trading.create_trip(Map.put(attrs, "status", other), company, user)

          t
      end
    end
  end

  defp complete_trip!(company, user, attrs) do
    {:ok, trip} = Trading.create_trip(attrs, company, user)
    {:ok, trip, _} = Trading.complete_trip(trip, company, user)
    trip
  end

  defp cancel_trip_if_possible(trip, company, user) do
    Trading.cancel_trip(trip, company, user)
  end

  # Explicit completed customer deliveries for Phase A invoicing tests.
  # Grouped so several drops share a customer (multi-drop invoice).
  defp create_settlement_ready_trips!(
         company,
         user,
         batch,
         locs,
         supplies,
         sales,
         maize,
         pollard,
         soy
       ) do
    goods = [maize, pollard, soy]
    open_sales = Enum.filter(sales, &(&1.status in ~w(draft open hold)))
    active_supplies = Enum.reject(supplies, &(&1.status == "closed"))
    farm_locs = [locs.farm_a, locs.farm_b, locs.farm_c, locs.farm_d, locs.farm_e]

    if open_sales == [] or active_supplies == [] do
      []
    else
      # 12 completed deliveries: pair indices share sales when possible
      for i <- 1..12 do
        good = Enum.at(goods, rem(i - 1, length(goods)))

        supply =
          active_supplies
          |> Enum.filter(&(&1.good_id == good.id))
          |> case do
            [] -> Enum.at(active_supplies, rem(i - 1, length(active_supplies)))
            same -> Enum.at(same, rem(i - 1, length(same)))
          end

        pair_idx = div(i - 1, 2)

        sales_for_good = Enum.filter(open_sales, &(&1.good_id == good.id))
        sales_pool = if sales_for_good == [], do: open_sales, else: sales_for_good
        sales_row = Enum.at(sales_pool, rem(pair_idx, length(sales_pool)))

        mt = Integer.to_string(15 + rem(i * 3, 40))
        date = Date.add(Date.utc_today(), -rem(i, 10))
        farm = Enum.at(farm_locs, rem(i - 1, length(farm_locs)))

        attrs = %{
          "date" => Date.to_iso8601(date),
          "transport_mode" => "company_own",
          "status" => "draft",
          "vehicle_number" => "BILL #{2000 + i}",
          "notes" => "#{@batch_prefix} settlement-ready delivery ##{i} #{batch}",
          "loads" => [
            %{
              "planned_mt" => mt,
              "actual_mt" => mt,
              "good_id" => good.id,
              "location_id" => locs.port.id,
              "supply_position_id" => supply.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => mt,
              "actual_mt" => mt,
              "good_id" => good.id,
              "location_id" => farm.id,
              "sales_position_id" => sales_row.id,
              "supply_position_id" => supply.id
            }
          ]
        }

        complete_trip!(company, user, attrs)
      end
    end
  end

  # Multi-load / multi-drop trips for desk + settlement workflow testing.
  # Covers company-own and agent modes, multi-customer, multi-supplier, multi-good.
  defp create_multi_line_trips!(
         company,
         user,
         batch,
         locs,
         supplies,
         sales,
         customers,
         maize,
         pollard,
         soy
       ) do
    open_sales = Enum.filter(sales, &(&1.status in ~w(draft open hold)))
    active_supplies = Enum.reject(supplies, &(&1.status == "closed"))

    if open_sales == [] or active_supplies == [] do
      []
    else
      by_good = fn list, good ->
        case Enum.filter(list, &(&1.good_id == good.id)) do
          [] -> list
          same -> same
        end
      end

      pick = fn list, good, i ->
        pool = by_good.(list, good)
        Enum.at(pool, rem(i, length(pool)))
      end

      agent_a = customers.mill
      agent_b = customers.trader
      today = Date.utc_today()

      scenarios = [
        # 1) 2 loads (same supply) → 2 drops (same customer) — company own
        #    Test: multi-select same customer invoice + multi-select supplier bill
        fn ->
          good = maize
          supply = pick.(active_supplies, good, 0)
          sales_row = pick.(open_sales, good, 0)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, -2)),
            "transport_mode" => "company_own",
            "vehicle_number" => "MULTI L2D2",
            "notes" => "#{@batch_prefix} multi 2L→2D same customer #{batch}",
            "loads" => [
              load_line(good, locs.port, supply, "18", "18"),
              load_line(good, locs.supplier_wh, supply, "12", "12")
            ],
            "drops" => [
              drop_line(good, locs.farm_a, sales_row, supply, "18", "18"),
              drop_line(good, locs.farm_a, sales_row, supply, "12", "11.5")
            ]
          }

          complete_trip!(company, user, attrs)
        end,

        # 2) 2 loads (2 supplies, same supplier if possible) → 2 drops (2 customers)
        #    Test: separate customer invoices; one or two supplier bills
        fn ->
          good = pollard
          s1 = pick.(active_supplies, good, 1)
          s2 = pick.(active_supplies, good, 2)
          sale_a = pick.(open_sales, good, 1)
          sale_b = pick.(open_sales, good, 2)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, -3)),
            "transport_mode" => "company_own",
            "vehicle_number" => "MULTI 2SUP 2CUS",
            "notes" => "#{@batch_prefix} multi 2 supplies → 2 customers #{batch}",
            "loads" => [
              load_line(good, locs.port, s1, "20", "20"),
              load_line(good, locs.supplier_wh, s2, "15", "15")
            ],
            "drops" => [
              drop_line(good, locs.farm_b, sale_a, s1, "20", "19.8"),
              drop_line(good, locs.farm_c, sale_b, s2, "15", "15")
            ]
          }

          complete_trip!(company, user, attrs)
        end,

        # 3) Agent: 1 load → 3 drops (different farms) — transport origin = single load
        #    Test: transport tab 3 haul lines Port → Farm*; customer multi-invoice if same cust
        fn ->
          good = maize
          supply = pick.(active_supplies, good, 3)
          sale_a = pick.(open_sales, good, 3)
          sale_b = pick.(open_sales, good, 4)
          sale_c = pick.(open_sales, good, 5)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, -1)),
            "transport_mode" => "agent",
            "transport_agent_id" => agent_a.id,
            "transport_agent_name" => agent_a.name,
            "vehicle_number" => "MULTI AGT 1L3D",
            "notes" => "#{@batch_prefix} multi agent 1L→3D #{batch}",
            "loads" => [
              load_line(good, locs.port, supply, "45", "45")
            ],
            "drops" => [
              drop_line(good, locs.farm_a, sale_a, supply, "15", "15"),
              drop_line(good, locs.farm_b, sale_b, supply, "15", "14.5"),
              drop_line(good, locs.farm_c, sale_c, supply, "15", "15")
            ]
          }

          complete_trip!(company, user, attrs)
        end,

        # 4) Agent: 2 loads (2 origins) → 1 drop — transport N loads → 1 drop
        #    Test: origin resolution prefers matching supply on drop
        fn ->
          good = soy
          s1 = pick.(active_supplies, good, 0)
          s2 = pick.(active_supplies, good, 1)
          sale = pick.(open_sales, good, 0)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, -4)),
            "transport_mode" => "agent",
            "transport_agent_id" => agent_b.id,
            "transport_agent_name" => agent_b.name,
            "vehicle_number" => "MULTI AGT 2L1D",
            "notes" => "#{@batch_prefix} multi agent 2L→1D #{batch}",
            "loads" => [
              load_line(good, locs.port, s1, "22", "22"),
              load_line(good, locs.supplier_wh, s2, "10", "10")
            ],
            "drops" => [
              drop_line(good, locs.farm_d, sale, s1, "32", "31.5")
            ]
          }

          complete_trip!(company, user, attrs)
        end,

        # 5) Agent: 2 loads × 2 drops, multi-good (maize + pollard) N×N
        #    Test: origin matches drop.supply_position_id; mixed goods on one trip
        fn ->
          s_maize = pick.(active_supplies, maize, 4)
          s_pollard = pick.(active_supplies, pollard, 4)
          sale_m = pick.(open_sales, maize, 6)
          sale_p = pick.(open_sales, pollard, 6)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, -5)),
            "transport_mode" => "agent",
            "transport_agent_id" => agent_a.id,
            "transport_agent_name" => agent_a.name,
            "vehicle_number" => "MULTI AGT MIX",
            "notes" => "#{@batch_prefix} multi agent 2L2D multi-good #{batch}",
            "loads" => [
              load_line(maize, locs.port, s_maize, "25", "25"),
              load_line(pollard, locs.supplier_wh, s_pollard, "18", "18")
            ],
            "drops" => [
              drop_line(maize, locs.farm_e, sale_m, s_maize, "25", "24.8"),
              drop_line(pollard, locs.farm_d, sale_p, s_pollard, "18", "18")
            ]
          }

          complete_trip!(company, user, attrs)
        end,

        # 6) Company-own: 3 loads → warehouse + customer (mixed drop types)
        #    Test: warehouse drop not on customer invoice queue; load still supplier-billable
        fn ->
          good = maize
          supply = pick.(active_supplies, good, 5)
          sale = pick.(open_sales, good, 7)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, -6)),
            "transport_mode" => "company_own",
            "vehicle_number" => "MULTI WH+CUST",
            "notes" => "#{@batch_prefix} multi 2L → warehouse + customer #{batch}",
            "loads" => [
              load_line(good, locs.port, supply, "30", "30"),
              load_line(good, locs.supplier_wh, supply, "10", "10")
            ],
            "drops" => [
              %{
                "planned_mt" => "20",
                "actual_mt" => "20",
                "good_id" => good.id,
                "location_id" => locs.silo.id,
                "supply_position_id" => supply.id
              },
              drop_line(good, locs.farm_a, sale, supply, "20", "19.5")
            ]
          }

          complete_trip!(company, user, attrs)
        end,

        # 7) Draft multi-line agent trip (visible, not billable yet)
        fn ->
          good = soy
          supply = pick.(active_supplies, good, 2)
          sale_a = pick.(open_sales, good, 2)
          sale_b = pick.(open_sales, good, 3)

          attrs = %{
            "date" => Date.to_iso8601(Date.add(today, 1)),
            "transport_mode" => "agent",
            "transport_agent_id" => agent_b.id,
            "transport_agent_name" => agent_b.name,
            "status" => "planned",
            "vehicle_number" => "MULTI PLANNED",
            "notes" => "#{@batch_prefix} multi planned agent 1L2D #{batch}",
            "loads" => [
              load_line(good, locs.port, supply, "28", "28")
            ],
            "drops" => [
              drop_line(good, locs.farm_b, sale_a, supply, "14", "14"),
              drop_line(good, locs.farm_c, sale_b, supply, "14", "14")
            ]
          }

          {:ok, t} = Trading.create_trip(attrs, company, user)
          t
        end
      ]

      Enum.map(scenarios, fn fun -> fun.() end)
    end
  end

  defp load_line(good, location, supply, planned, actual) do
    %{
      "planned_mt" => planned,
      "actual_mt" => actual,
      "good_id" => good.id,
      "location_id" => location.id,
      "supply_position_id" => supply.id
    }
  end

  defp drop_line(good, location, sales, supply, planned, actual) do
    %{
      "planned_mt" => planned,
      "actual_mt" => actual,
      "good_id" => good.id,
      "location_id" => location.id,
      "sales_position_id" => sales.id,
      "supply_position_id" => supply.id
    }
  end

  # --- helpers ---

  defp resolve_company!(opts) do
    case Keyword.get(opts, :company) do
      nil ->
        case Repo.one(from c in Company, order_by: c.name, limit: 1) do
          nil -> raise "No companies in database"
          c -> c
        end

      id when is_binary(id) ->
        # Prefer name match first: Ecto.UUID.cast/1 accepts any 16-byte string as a UUID
        # (e.g. "Kim Poh Sitt Tat"), which is not a real company id.
        case Repo.one(
               from c in Company,
                 where: ilike(c.name, ^"%#{id}%"),
                 order_by: c.name,
                 limit: 1
             ) do
          %Company{} = c ->
            c

          nil ->
            case Ecto.UUID.cast(id) do
              {:ok, uuid} -> Sys.get_company!(uuid)
              :error -> raise "Company not found matching #{inspect(id)}"
            end
        end
    end
  end

  defp resolve_user!(company, opts) do
    email = Keyword.get(opts, :email)

    user =
      if email do
        case Repo.get_by(User, email: email) do
          nil -> raise "User not found: #{email}"
          u -> u
        end
      else
        Repo.one(
          from u in User,
            join: cu in CompanyUser,
            on: cu.user_id == u.id,
            where: cu.company_id == ^company.id and cu.role in ["admin", "manager"],
            order_by: u.email,
            limit: 1
        )
      end

    if is_nil(user), do: raise("No admin/manager user for company #{company.name}")

    case Sys.get_company_user(company.id, user.id) do
      nil ->
        raise "User #{user.email} has no access to #{company.name}"

      %{role: role} when role in ~w(admin manager supervisor clerk cashier) ->
        user

      %{role: role} ->
        raise "User #{user.email} role #{role} cannot manage_trading"
    end
  end

  defp get_good!(company, user, name) do
    case Product.get_good_by_name(name, company, user) do
      %{id: _} = g ->
        g

      _ ->
        create_demo_good!(company, user, name)
    end
  end

  # get_good_by_name returns a map with :value; create_demo_good! returns a Good struct with :name
  defp good_label(%{name: name}) when is_binary(name), do: name
  defp good_label(%{value: value}) when is_binary(value), do: value
  defp good_label(other), do: inspect(other)

  defp create_demo_good!(company, user, name) do
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)
    pur_acct = Accounting.get_account_by_name("General Purchases", company, user)

    no_stax =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    no_ptax =
      Repo.one!(
        from tc in FullCircle.Accounting.TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoPTax"
      )

    attrs = %{
      "name" => name,
      "unit" => "Mt",
      "category" => "General",
      "sales_account_name" => sales_acct.name,
      "sales_account_id" => sales_acct.id,
      "purchase_account_name" => pur_acct.name,
      "purchase_account_id" => pur_acct.id,
      "sales_tax_code_name" => no_stax.code,
      "sales_tax_code_id" => no_stax.id,
      "purchase_tax_code_name" => no_ptax.code,
      "purchase_tax_code_id" => no_ptax.id,
      "packagings" => %{
        "0" => %{
          "name" => "default_pkg",
          "unit_multiplier" => "1",
          "cost_per_package" => "0",
          "default" => "true",
          "_persistent_id" => "1"
        }
      }
    }

    {:ok, good} = StdInterface.create(Good, "good", attrs, company, user)
    good
  end

  defp ensure_contact!(company, user, name, category) do
    case Accounting.get_contact_by_name(name, company, user) do
      %{id: _} = c ->
        c

      _ ->
        {:ok, c} =
          StdInterface.create(
            Contact,
            "contact",
            %{
              "name" => name,
              "reg_no" => "DEMO",
              "tax_id" => "DEMO",
              "country" => "Malaysia",
              "category" => category
            },
            company,
            user
          )

        c
    end
  end

  defp ensure_location!(company, user, attrs) do
    name = attrs["name"]

    case Repo.get_by(FullCircle.Trading.Location, company_id: company.id, name: name) do
      nil ->
        {:ok, loc} = Trading.create_location(attrs, company, user)
        loc

      loc ->
        # Backfill contact_id when re-seeding existing demo locations
        contact_id = attrs["contact_id"]

        if contact_id && is_nil(loc.contact_id) do
          case Trading.update_location(loc, %{"contact_id" => contact_id}, company, user) do
            {:ok, updated} -> updated
            _ -> loc
          end
        else
          loc
        end
    end
  end
end
