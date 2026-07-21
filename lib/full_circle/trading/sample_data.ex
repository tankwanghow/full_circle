defmodule FullCircle.Trading.SampleData do
  @moduledoc """
  Dev/demo sample data for the Trading Desk.

  Prefer `mix full_circle.seed_trading` (see Mix.Tasks.FullCircle.SeedTrading).
  Creates ~50 supplies, ~50 sales, and ~50 trips (mixed statuses) plus warehouse
  stock so scrolling and filters can be tested.
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
