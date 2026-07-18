defmodule FullCircle.Trading.SampleData do
  @moduledoc """
  Dev/demo sample data for the Trading Desk.

  Prefer `mix full_circle.seed_trading` (see Mix.Tasks.FullCircle.SeedTrading).
  Creates ~12 rows per desk table (supply, sales, trips) plus multi-location
  warehouse stock so scrolling and status variety can be tested.
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
    locs = ensure_locations!(company, user)

    supplies = create_supplies!(company, user, batch, suppliers, maize, pollard, soy)
    sales = create_sales!(company, user, batch, customers, supplies, maize, pollard, soy)
    trips = create_trips!(company, user, batch, locs, supplies, sales, customers, maize, pollard, soy)

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
      desk_path: "/companies/#{company.id}/trading/desk"
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

  defp ensure_locations!(company, user) do
    specs = [
      port: {"Port Klang Godown", "port", "3.0010", "101.3910"},
      supplier_wh: {"Supplier WH - Kapar", "supplier_site", "3.1200", "101.3800"},
      silo: {"Main Silo", "own_warehouse", "3.0500", "101.5500"},
      feed_bay: {"Feedmill Bay", "own_warehouse", "3.0510", "101.5510"},
      silo_b: {"North Silo B", "own_warehouse", "3.0550", "101.5520"},
      silo_c: {"South Bag Store", "own_warehouse", "3.0480", "101.5490"},
      silo_d: {"Transit Bay 2", "own_warehouse", "3.0520", "101.5530"},
      silo_e: {"Old Godown C", "own_warehouse", "3.0460", "101.5480"},
      farm_a: {"Kajang Farm Gate", "customer_site", "2.9930", "101.7900"},
      farm_b: {"Seremban Farm", "customer_site", "2.7260", "101.9420"},
      farm_c: {"Ipoh Farm Gate", "customer_site", "4.5970", "101.0900"},
      farm_d: {"Malacca Drop", "customer_site", "2.1890", "102.2500"},
      farm_e: {"Johor Integrator Gate", "customer_site", "1.4927", "103.7414"}
    ]

    Map.new(specs, fn {key, {name, kind, lat, lng}} ->
      loc =
        ensure_location!(company, user, %{
          "name" => "#{@batch_prefix} #{name}",
          "kind" => kind,
          "latitude" => lat,
          "longitude" => lng
        })

      {key, loc}
    end)
  end

  # --- supplies: 12 active + 1 closed (closed not on desk board) ---

  defp create_supplies!(company, user, batch, suppliers, maize, pollard, soy) do
    specs = [
      {"Vessel JON DOE Maize", "collect", "1000", "1150", suppliers.vessel, maize, ~D[2026-05-15]},
      {"Jun Vessel MARY JAIN", "open", "500", "1180", suppliers.vessel, maize, ~D[2026-06-20]},
      {"Local Pollard PO", "hold", "200", "980", suppliers.local, pollard, ~D[2026-07-01]},
      {"Thai SBM July", "open", "300", "1850", suppliers.thai, soy, ~D[2026-07-05]},
      {"Indo Maize Aug", "hold", "800", "1165", suppliers.indon, maize, ~D[2026-08-01]},
      {"Mekong Pollard", "collect", "150", "990", suppliers.vietnam, pollard, ~D[2026-06-28]},
      {"Central Depot Spot", "open", "120", "1200", suppliers.domestic, maize, ~D[2026-07-10]},
      {"Vessel OCEAN STAR", "collect", "2000", "1140", suppliers.vessel, maize, ~D[2026-04-20]},
      {"Thai Maize Spot", "open", "250", "1195", suppliers.thai, maize, ~D[2026-07-15]},
      {"Indo Pollard Hold", "hold", "180", "970", suppliers.indon, pollard, ~D[2026-07-08]},
      {"Local Soymeal", "collect", "100", "1900", suppliers.local, soy, ~D[2026-07-12]},
      {"Vietnam Maize", "open", "400", "1175", suppliers.vietnam, maize, ~D[2026-07-22]},
      # closed — not shown on supply board, still useful in history
      {"Closed Vessel OLD", "closed", "600", "1100", suppliers.vessel, maize, ~D[2026-03-01]}
    ]

    Enum.map(specs, fn {label, status, qty, price, supplier, good, from} ->
      {:ok, s} =
        Trading.create_supply_position(
          %{
            "quantity" => qty,
            "unit_price" => price,
            "status" => status,
            "available_from" => Date.to_iso8601(from),
            "supplier_id" => supplier.id,
            "good_id" => good.id,
            "notes" => "#{@batch_prefix} #{label} #{batch}"
          },
          company,
          user
        )

      s
    end)
  end

  # --- sales: 12 active (draft/open/hold) + fulfilled + cancelled ---

  defp create_sales!(company, user, batch, customers, supplies, maize, pollard, soy) do
    # Index supplies created above for preferred links
    [
      s_vessel,
      s_open,
      s_hold,
      s_thai_soy,
      s_indo,
      s_mekong,
      s_central,
      s_ocean,
      s_thai_m,
      s_indo_p,
      s_local_soy,
      s_viet,
      _closed
    ] = supplies

    specs = [
      {"Spot 60MT Maize", "open", "60", "1320", customers.farm_a, maize, s_vessel, ~D[2026-07-18]},
      {"Draft Pollard 35MT", "draft", "35", "1100", customers.farm_b, pollard, s_hold, ~D[2026-07-25]},
      {"Held 40MT Maize", "hold", "40", "1300", customers.farm_b, maize, s_open, ~D[2026-07-20]},
      {"Partial 50MT Maize", "open", "50", "1310", customers.farm_a, maize, s_vessel, ~D[2026-07-12]},
      {"Ipoh 25MT SBM", "open", "25", "2100", customers.farm_c, soy, s_thai_soy, ~D[2026-07-19]},
      {"Malacca Pollard", "draft", "40", "1080", customers.farm_d, pollard, s_mekong, ~D[2026-07-28]},
      {"Johor 80MT Maize", "open", "80", "1295", customers.farm_e, maize, s_ocean, ~D[2026-07-16]},
      {"Trader Spot 15", "hold", "15", "1340", customers.trader, maize, s_central, ~D[2026-07-14]},
      {"Feedmill 100MT", "open", "100", "1280", customers.mill, maize, s_indo, ~D[2026-07-21]},
      {"Seremban 30 Pollard", "open", "30", "1110", customers.farm_b, pollard, s_indo_p, ~D[2026-07-17]},
      {"Kajang SBM 20", "draft", "20", "2050", customers.farm_a, soy, s_local_soy, ~D[2026-08-01]},
      {"Ipoh Maize Hold", "hold", "45", "1315", customers.farm_c, maize, s_thai_m, ~D[2026-07-23]},
      {"Viet link 55", "open", "55", "1305", customers.farm_e, maize, s_viet, ~D[2026-07-26]},
      # not on open-sales board
      {"Fulfilled old deal", "fulfilled", "10", "1250", customers.farm_a, maize, s_vessel, ~D[2026-06-01]},
      {"Cancelled quote", "cancelled", "12", "1400", customers.trader, maize, nil, ~D[2026-06-15]}
    ]

    Enum.map(specs, fn {label, status, qty, price, customer, good, preferred, from} ->
      attrs = %{
        "quantity" => qty,
        "unit_price" => price,
        "status" => status,
        "available_from" => Date.to_iso8601(from),
        "customer_id" => customer.id,
        "good_id" => good.id,
        "notes" => "#{@batch_prefix} #{label} #{batch}"
      }

      attrs =
        if preferred do
          Map.put(attrs, "preferred_supply_id", preferred.id)
        else
          attrs
        end

      {:ok, s} = Trading.create_sales_position(attrs, company, user)
      s
    end)
  end

  # --- trips: stock warehouse rows + ~12 trip list rows ---

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
    [
      s_vessel,
      _s_open,
      _s_hold,
      s_thai_soy,
      _s_indo,
      s_mekong,
      _s_central,
      s_ocean,
      _s_thai_m,
      _s_indo_p,
      s_local_soy,
      _s_viet,
      _closed
    ] = supplies

    [
      sales_open,
      _draft,
      _hold,
      sales_partial,
      sales_ipoh_soy,
      _malacca,
      sales_johor,
      _trader,
      _sales_mill,
      sales_seremban_p,
      _kajang_soy,
      _ipoh_hold,
      sales_viet,
      _fulfilled,
      _cancelled
    ] = sales

    # Stock-in movements → multiple warehouse × good on-hand rows
    stock_ins = [
      {~D[2026-07-01], s_vessel, maize, locs.port, locs.silo, "120", "BKK 1234"},
      {~D[2026-07-02], s_vessel, maize, locs.port, locs.feed_bay, "40", "BKK 2345"},
      {~D[2026-07-03], s_ocean, maize, locs.port, locs.silo_b, "90", "WXY 3456"},
      {~D[2026-07-04], s_mekong, pollard, locs.supplier_wh, locs.silo_c, "55", "VKL 4567"},
      {~D[2026-07-05], s_thai_soy, soy, locs.port, locs.silo_d, "35", "JHB 5678"},
      {~D[2026-07-06], s_local_soy, soy, locs.supplier_wh, locs.silo, "20", "SGR 6789"},
      {~D[2026-07-07], s_mekong, pollard, locs.supplier_wh, locs.feed_bay, "25", "BKK 7890"},
      {~D[2026-07-08], s_vessel, maize, locs.port, locs.silo_e, "50", "TRG 8901"}
    ]

    completed_stock =
      Enum.map(stock_ins, fn {date, supply, good, load_loc, drop_loc, mt, vehicle} ->
        complete_trip!(
          company,
          user,
          %{
            "date" => Date.to_iso8601(date),
            "transport_mode" => "company_own",
            "status" => "draft",
            "good_id" => good.id,
            "vehicle_number" => vehicle,
            "notes" => "#{@batch_prefix} stock-in #{batch}",
            "loads" => [
              %{
                "planned_mt" => mt,
                "actual_mt" => mt,
                "good_id" => good.id,
                "location_id" => load_loc.id,
                "supply_position_id" => supply.id
              }
            ],
            "drops" => [
              %{
                "planned_mt" => mt,
                "actual_mt" => mt,
                "good_id" => good.id,
                "location_id" => drop_loc.id,
                "supply_position_id" => supply.id
              }
            ]
          }
        )
      end)

    # Deliveries out of warehouse
    deliveries = [
      {~D[2026-07-10], maize, locs.silo, locs.farm_a, sales_partial, s_vessel, "33.5", "BKK 1122"},
      {~D[2026-07-11], maize, locs.silo_b, locs.farm_e, sales_johor, s_ocean, "40", "JHB 2233"},
      {~D[2026-07-12], soy, locs.silo_d, locs.farm_c, sales_ipoh_soy, s_thai_soy, "15", "IPH 3344"},
      {~D[2026-07-13], pollard, locs.silo_c, locs.farm_b, sales_seremban_p, s_mekong, "18", "NSN 4455"}
    ]

    completed_del =
      Enum.map(deliveries, fn {date, good, load_loc, drop_loc, sales, supply, mt, vehicle} ->
        complete_trip!(
          company,
          user,
          %{
            "date" => Date.to_iso8601(date),
            "transport_mode" => "company_own",
            "status" => "draft",
            "good_id" => good.id,
            "vehicle_number" => vehicle,
            "notes" => "#{@batch_prefix} delivery #{batch}",
            "loads" => [
              %{"planned_mt" => mt, "actual_mt" => mt, "location_id" => load_loc.id}
            ],
            "drops" => [
              %{
                "planned_mt" => mt,
                "actual_mt" => mt,
                "good_id" => good.id,
                "location_id" => drop_loc.id,
                "sales_position_id" => sales.id,
                "supply_position_id" => supply.id
              }
            ]
          }
        )
      end)

    # Draft / planned trips (visible on desk, not completed)
    {:ok, draft1} =
      Trading.create_trip(
        %{
          "date" => Date.to_iso8601(Date.utc_today()),
          "transport_mode" => "agent",
          "status" => "draft",
          "good_id" => maize.id,
          "notes" => "#{@batch_prefix}-DRAFT-A-#{batch}",
          "vehicle_number" => "AGT 5566",
          "transport_agent_id" => customers.mill.id,
          "loads" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "good_id" => maize.id,
              "location_id" => locs.port.id,
              "supply_position_id" => s_vessel.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "25",
              "actual_mt" => "25",
              "good_id" => maize.id,
              "location_id" => locs.farm_a.id,
              "sales_position_id" => sales_open.id,
              "supply_position_id" => s_vessel.id
            }
          ]
        },
        company,
        user
      )

    {:ok, draft2} =
      Trading.create_trip(
        %{
          "date" => Date.to_iso8601(Date.add(Date.utc_today(), 1)),
          "transport_mode" => "company_own",
          "status" => "draft",
          "good_id" => pollard.id,
          "notes" => "#{@batch_prefix}-DRAFT-B-#{batch}",
          "vehicle_number" => "BKK 6677",
          "loads" => [
            %{
              "planned_mt" => "12",
              "actual_mt" => "12",
              "good_id" => pollard.id,
              "location_id" => locs.feed_bay.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "12",
              "actual_mt" => "12",
              "good_id" => pollard.id,
              "location_id" => locs.farm_b.id,
              "sales_position_id" => sales_seremban_p.id
            }
          ]
        },
        company,
        user
      )

    {:ok, planned1} =
      Trading.create_trip(
        %{
          "date" => Date.to_iso8601(Date.add(Date.utc_today(), 2)),
          "transport_mode" => "company_own",
          "status" => "planned",
          "good_id" => maize.id,
          "notes" => "#{@batch_prefix}-PLAN-A-#{batch}",
          "vehicle_number" => "JHB 7788",
          "loads" => [
            %{
              "planned_mt" => "30",
              "actual_mt" => "30",
              "good_id" => maize.id,
              "location_id" => locs.silo.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "30",
              "actual_mt" => "30",
              "good_id" => maize.id,
              "location_id" => locs.farm_e.id,
              "sales_position_id" => sales_johor.id
            }
          ]
        },
        company,
        user
      )

    {:ok, planned2} =
      Trading.create_trip(
        %{
          "date" => Date.to_iso8601(Date.add(Date.utc_today(), 3)),
          "transport_mode" => "agent",
          "status" => "planned",
          "good_id" => soy.id,
          "notes" => "#{@batch_prefix}-PLAN-B-#{batch}",
          "vehicle_number" => "IPH 8899",
          "transport_agent_id" => customers.trader.id,
          "loads" => [
            %{
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => soy.id,
              "location_id" => locs.silo_d.id
            }
          ],
          "drops" => [
            %{
              "planned_mt" => "10",
              "actual_mt" => "10",
              "good_id" => soy.id,
              "location_id" => locs.farm_c.id,
              "sales_position_id" => sales_ipoh_soy.id
            }
          ]
        },
        company,
        user
      )

    # One cancelled trip (create draft then cancel if API exists; else leave draft)
    cancelled =
      case Trading.create_trip(
             %{
               "date" => Date.to_iso8601(~D[2026-07-09]),
               "transport_mode" => "company_own",
               "status" => "draft",
               "good_id" => maize.id,
               "notes" => "#{@batch_prefix}-CXL-#{batch}",
               "vehicle_number" => "CXL 9900",
               "loads" => [
                 %{
                   "planned_mt" => "5",
                   "actual_mt" => "5",
                   "good_id" => maize.id,
                   "location_id" => locs.silo.id
                 }
               ],
               "drops" => [
                 %{
                   "planned_mt" => "5",
                   "actual_mt" => "5",
                   "good_id" => maize.id,
                   "location_id" => locs.farm_d.id,
                   "sales_position_id" => sales_viet.id
                 }
               ]
             },
             company,
             user
           ) do
        {:ok, t} ->
          case cancel_trip_if_possible(t, company, user) do
            {:ok, t2} -> t2
            _ -> t
          end

        _ ->
          nil
      end

    open_trips = [draft1, draft2, planned1, planned2] ++ List.wrap(cancelled)

    completed_stock ++ completed_del ++ open_trips
  end

  defp complete_trip!(company, user, attrs) do
    {:ok, trip} = Trading.create_trip(attrs, company, user)
    {:ok, trip, _} = Trading.complete_trip(trip, company, user)
    trip
  end

  defp cancel_trip_if_possible(trip, company, user) do
    Trading.cancel_trip(trip, company, user)
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
        cond do
          match?({:ok, _}, Ecto.UUID.cast(id)) ->
            Sys.get_company!(id)

          true ->
            case Repo.one(
                   from c in Company,
                     where: ilike(c.name, ^"%#{id}%"),
                     order_by: c.name,
                     limit: 1
                 ) do
              nil -> raise "Company not found matching #{inspect(id)}"
              c -> c
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
        loc
    end
  end
end
