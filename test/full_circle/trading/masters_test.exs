defmodule FullCircle.Trading.MastersTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.Location
  alias FullCircle.HR.Employee
  alias FullCircle.Accounting.Contact

  import FullCircle.TradingFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.BillingFixtures
  import FullCircle.HRFixtures

  setup do
    trading_setup()
  end

  describe "authorization" do
    test_authorise_to(
      :view_trading,
      ["admin", "manager", "supervisor", "clerk", "cashier", "auditor"]
    )

    test_authorise_to(
      :manage_trading,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )
  end

  describe "locations (new table)" do
    test "admin can create location with own_warehouse kind", %{admin: admin, company: company} do
      assert {:ok, %Location{} = loc} =
               Trading.create_location(
                 %{
                   "name" => "Main silo",
                   "kind" => "own_warehouse",
                   "latitude" => "3.1390",
                   "longitude" => "101.6869"
                 },
                 company,
                 admin
               )

      assert loc.name == "Main silo"
      assert loc.kind == "own_warehouse"
      assert loc.company_id == company.id
      assert loc.active == true
      assert Decimal.eq?(loc.latitude, Decimal.new("3.1390"))
      assert Decimal.eq?(loc.longitude, Decimal.new("101.6869"))

      maps = Location.google_maps_url(loc)
      assert maps =~ "google.com/maps"
      assert maps =~ "3.1390"
      assert maps =~ "101.6869"
    end

    test "gps requires both latitude and longitude", %{admin: admin, company: company} do
      assert {:error, cs} =
               Trading.create_location(
                 %{"name" => "X", "kind" => "port", "latitude" => "3.1"},
                 company,
                 admin
               )

      assert %{longitude: _} = errors_on(cs)
    end



    test "rejects invalid kind", %{admin: admin, company: company} do
      assert {:error, cs} =
               Trading.create_location(
                 %{"name" => "X", "kind" => "not_a_kind"},
                 company,
                 admin
               )

      assert %{kind: _} = errors_on(cs)
    end

    test "requires name", %{admin: admin, company: company} do
      assert {:error, cs} =
               Trading.create_location(%{"kind" => "port"}, company, admin)

      assert %{name: _} = errors_on(cs)
    end

    test "guest cannot create location", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      assert :not_authorise =
               Trading.create_location(
                 %{"name" => "Nope", "kind" => "port"},
                 company,
                 guest
               )
    end

    test "list_locations is company-scoped", %{admin: admin, company: company} do
      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})

      {:ok, _} =
        Trading.create_location(%{"name" => "A", "kind" => "port"}, company, admin)

      {:ok, _} =
        Trading.create_location(%{"name" => "B", "kind" => "port"}, other_company, other_admin)

      names = Trading.list_locations(company, admin) |> Enum.map(& &1.name)
      assert "A" in names
      refute "B" in names
    end

    test "update_location", %{admin: admin, company: company} do
      loc = location_fixture(company, admin, %{"name" => "Old"})

      assert {:ok, updated} =
               Trading.update_location(loc, %{"name" => "New"}, company, admin)

      assert updated.name == "New"
    end
  end

  describe "drivers are employees" do
    test "list_drivers returns company employees", %{admin: admin, company: company} do
      emp = employee_fixture(%{"name" => "Driver Ali", "status" => "Active"}, company, admin)

      drivers = Trading.list_drivers(company, admin)
      assert Enum.any?(drivers, &(&1.id == emp.id))
      assert %Employee{} = Trading.get_driver!(emp.id, company, admin)
    end
  end

  describe "transport agents are contacts" do
    test "list_transport_agents returns company contacts", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{"name" => "Swift Haul", "category" => "Transporter"})

      agents = Trading.list_transport_agents(company, admin)
      assert Enum.any?(agents, &(&1.id == contact.id))

      filtered = Trading.list_transport_agents(company, admin, category: "Transporter")
      assert Enum.any?(filtered, &(&1.id == contact.id))

      assert %Contact{} = Trading.get_transport_agent!(contact.id, company, admin)
    end
  end

  describe "location contact link" do
    test "location contact_id filters typeahead and sole_location_for_contact", %{
      admin: admin,
      company: company
    } do
      supplier = contact_fixture(company, admin, %{"name" => "LocSupplierX"})
      other = contact_fixture(company, admin, %{"name" => "LocOtherY"})

      {:ok, site} =
        Trading.create_location(
          %{
            "name" => "Supplier Gate A",
            "kind" => "supplier_site",
            "contact_id" => supplier.id
          },
          company,
          admin
        )

      {:ok, _other_site} =
        Trading.create_location(
          %{
            "name" => "Other Gate",
            "kind" => "supplier_site",
            "contact_id" => other.id
          },
          company,
          admin
        )

      names =
        Trading.location_names("Gate", company, admin, contact_id: supplier.id)
        |> Enum.map(& &1.id)

      assert site.id in names
      refute Enum.any?(names, &(&1 != site.id))

      assert %{} = sole = Trading.sole_location_for_contact(supplier.id, company, admin)
      assert sole.id == site.id

      # Two sites → no sole auto-select
      {:ok, _} =
        Trading.create_location(
          %{
            "name" => "Supplier Gate B",
            "kind" => "supplier_site",
            "contact_id" => supplier.id
          },
          company,
          admin
        )

      assert Trading.sole_location_for_contact(supplier.id, company, admin) == nil
    end
  end
end
