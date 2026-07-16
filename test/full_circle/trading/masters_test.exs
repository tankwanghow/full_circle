defmodule FullCircle.Trading.MastersTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.Trading
  alias FullCircle.Trading.Location

  import FullCircle.TradingFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

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

  describe "locations" do
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

  describe "drivers and agents" do
    test "create driver and agent", %{admin: admin, company: company} do
      assert {:ok, driver} =
               Trading.create_driver(%{"name" => "Ali", "phone" => "012"}, company, admin)

      assert {:ok, agent} =
               Trading.create_transport_agent(%{"name" => "Swift"}, company, admin)

      assert driver.name == "Ali"
      assert agent.name == "Swift"
      assert length(Trading.list_drivers(company, admin)) == 1
      assert length(Trading.list_transport_agents(company, admin)) == 1
    end
  end
end
