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
                 %{"name" => "Main silo", "kind" => "own_warehouse"},
                 company,
                 admin
               )

      assert loc.name == "Main silo"
      assert loc.kind == "own_warehouse"
      assert loc.company_id == company.id
      assert loc.active == true
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
      contact = contact_fixture(company, admin, %{"name" => "Swift Haul", "category" => "Transporter"})

      agents = Trading.list_transport_agents(company, admin)
      assert Enum.any?(agents, &(&1.id == contact.id))

      filtered = Trading.list_transport_agents(company, admin, category: "Transporter")
      assert Enum.any?(filtered, &(&1.id == contact.id))

      assert %Contact{} = Trading.get_transport_agent!(contact.id, company, admin)
    end
  end
end
