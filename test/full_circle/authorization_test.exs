defmodule FullCircle.AuthorizationTest do
  use FullCircle.DataCase

  alias FullCircle.SysFixtures
  alias FullCircle.UserAccountsFixtures
  alias FullCircle.Authorization

  setup do
    admin = UserAccountsFixtures.user_fixture()
    company = SysFixtures.company_fixture(admin, %{})
    %{company: company, admin: admin}
  end

  test_authorise_to(:see_user_list, ["admin"])
  test_authorise_to(:invite_user, ["admin"])
  test_authorise_to(:add_user_to_company, ["admin"])
  test_authorise_to(:delete_company, ["admin"])
  test_authorise_to(:update_company, ["admin"])
  test_authorise_to(:reset_user_password, ["admin"])

  test_not_authorise_to(:create_account, ["disable", "guest", "auditor", "cashier", "clerk"])
  test_not_authorise_to(:update_account, ["disable", "guest", "auditor", "cashier", "clerk"])
  test_not_authorise_to(:delete_account, ["disable", "guest", "auditor", "cashier", "clerk"])

  describe "authorization" do
    test "should have roles" do
      assert Enum.count(Authorization.roles()) == 8
      assert Enum.any?(Authorization.roles(), fn x -> x == "guest" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "admin" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "clerk" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "manager" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "disable" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "supervisor" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "cashier" end)
      assert Enum.any?(Authorization.roles(), fn x -> x == "auditor" end)
    end
  end
end
