defmodule FullCircle.SysTest do
  use FullCircle.DataCase

  alias FullCircle.Sys

  describe "Sys" do
    import FullCircle.SysFixtures
    import FullCircle.UserAccountsFixtures

    test "default accounts should have" do
      assert [
               %{name: "General Purchase", account_type: "Expenses"},
               %{name: "General Sales", account_type: "Sales"},
               %{name: "Account Payables", account_type: "Current Liability"},
               %{name: "Account Receivables", account_type: "Current Asset"},
               %{name: "Sales Tax Payable", account_type: "Current Liability"},
               %{name: "Purchase Tax Receivale", account_type: "Current Asset"}
             ] == Sys.default_accounts()
    end

    test "new company should have default accounts" do
      admin = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)

      assert [
               "Account Payables",
               "Account Receivables",
               "General Purchase",
               "General Sales",
               "Purchase Tax Receivale",
               "Sales Tax Payable"
             ] ==
               Enum.map(
                 FullCircle.Accounting.filter_accounts("", com1, admin, page: 1, per_page: 50),
                 fn x -> x.name end
               )
    end

    test "insert log" do
      admin = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      attrs = valid_user_attributes(%{company_id: com1.id})

      {:ok, %{"register_user_log" => log}} =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(
          :register_user,
          FullCircle.UserAccounts.User.admin_add_user_changeset(
            %FullCircle.UserAccounts.User{},
            attrs
          )
        )
        |> Sys.insert_log_for(:register_user, attrs, com1, admin)
        |> FullCircle.Repo.transaction()

      assert log.entity == "users"
      assert log.company_id == com1.id
    end

    test "admin reset user password" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      Sys.allow_user_to_access(com1, user, "guest", admin)
      old_password = user.hashed_password
      {:ok, user, pwd} = Sys.reset_user_password(user, admin, com1)

      assert FullCircle.UserAccounts.get_user_by_email_and_password(user.email, pwd).email ==
               user.email

      refute FullCircle.UserAccounts.get_user_by_email_and_password(user.email, pwd).hashed_password ==
               old_password
    end

    test "cannot reset user password" do
      admin = user_fixture()
      user = user_fixture()
      user1 = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      Sys.allow_user_to_access(com1, user, "guest", admin)
      Sys.allow_user_to_access(com1, user1, "manager", admin)
      assert :not_authorise = Sys.reset_user_password(user, user1, com1)
    end

    test "update user default company" do
      v1 = valid_company_attributes(%{name: "haha0"})
      v2 = valid_company_attributes(%{name: "haha1"})
      v3 = valid_company_attributes(%{name: "haha2"})
      v4 = valid_company_attributes(%{name: "haha3"})
      v5 = valid_company_attributes(%{name: "haha4"})
      u1 = user_fixture()
      u2 = user_fixture()
      {:ok, com1} = Sys.create_company(v1, u1)
      {:ok, _com2} = Sys.create_company(v2, u1)
      {:ok, com3} = Sys.create_company(v3, u1)
      {:ok, com4} = Sys.create_company(v4, u2)
      {:ok, com5} = Sys.create_company(v5, u2)

      assert com1.id == Sys.get_default_company(u1).company_id
      assert com4.id == Sys.get_default_company(u2).company_id

      Sys.set_default_company(u1.id, com3.id)
      Sys.set_default_company(u2.id, com5.id)

      assert com3.id == Sys.get_default_company(u1).company_id
      assert com5.id == Sys.get_default_company(u2).company_id
    end

    test "only show user's companies" do
      v1 = valid_company_attributes(%{name: "haha0"})
      v2 = valid_company_attributes(%{name: "haha1"})
      v3 = valid_company_attributes(%{name: "haha2"})
      v4 = valid_company_attributes(%{name: "haha3"})
      v5 = valid_company_attributes(%{name: "haha4"})
      u1 = user_fixture()
      u2 = user_fixture()
      u3 = user_fixture()
      {:ok, com1} = Sys.create_company(v1, u1)
      {:ok, com2} = Sys.create_company(v2, u1)
      {:ok, com3} = Sys.create_company(v3, u1)
      {:ok, com4} = Sys.create_company(v4, u2)
      {:ok, com5} = Sys.create_company(v5, u2)

      Sys.allow_user_to_access(com1, u3, "guest", u1)
      Sys.allow_user_to_access(com4, u3, "guest", u2)
      Sys.allow_user_to_access(com5, u3, "disable", u2)

      assert Enum.map([com1, com2, com3], fn x -> x.name end) ==
               Enum.map(Sys.list_companies(u1), fn x -> x.name end)

      assert Enum.map([com4, com5], fn x -> x.name end) ==
               Enum.map(Sys.list_companies(u2), fn x -> x.name end)

      assert Enum.map([com1, com4], fn x -> x.name end) ==
               Enum.map(Sys.list_companies(u3), fn x -> x.name end)
    end

    test "create_company with valid attributes" do
      v = valid_company_attributes()
      {:ok, com} = Sys.create_company(v, user_fixture())
      assert com.name == v.name
      assert com.address1 == v.address1
      assert com.address2 == v.address2
      assert com.city == v.city
      assert com.closing_month == v.closing_month
      assert com.closing_day == v.closing_day
      assert com.state == v.state
      assert com.country == v.country
      assert com.timezone == v.timezone
      assert com.zipcode == v.zipcode
      assert com.reg_no == v.reg_no
      assert com.tax_id == v.tax_id
      assert com.fax == v.fax
      assert com.tel == v.tel
      assert com.email == v.email
      assert com.descriptions == v.descriptions
    end

    test "require name, country, timezone, closing_month, closing_day" do
      v = valid_company_attributes(%{name: nil, country: nil, timezone: nil})
      {:error, :create_company, changeset, _} = Sys.create_company(v, user_fixture())
      assert changeset.changes.descriptions == v.descriptions
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).country
      assert "can't be blank" in errors_on(changeset).timezone
    end

    test "validate closing_month(1-12), closing_day(1-31)" do
      v = valid_company_attributes(%{closing_month: 0, closing_day: 32})
      {:error, :create_company, changeset, _} = Sys.create_company(v, user_fixture())
      assert changeset.changes.descriptions == v.descriptions
      assert "must between 1 to 31" in errors_on(changeset).closing_day
      assert "must between 1 to 12" in errors_on(changeset).closing_month
    end

    test "validate country, timezone in list" do
      v = valid_company_attributes(%{country: "jupiter", timezone: "marc"})
      {:error, :create_company, changeset, _} = Sys.create_company(v, user_fixture())
      assert changeset.changes.descriptions == v.descriptions
      assert "not in list" in errors_on(changeset).country
      assert "not in list" in errors_on(changeset).timezone
    end

    test "create user is the admin of the company" do
      v = valid_company_attributes()
      u = user_fixture()
      {:ok, com} = Sys.create_company(v, u)
      assert "admin" == Util.attempt(Sys.get_company_user(com.id, u.id), :role)
    end

    test "first company will be the defautl company" do
      v1 = valid_company_attributes()
      v2 = valid_company_attributes()
      u = user_fixture()

      {:ok, com1} = Sys.create_company(v1, u)
      cu = Sys.get_company_user(com1.id, u.id)
      assert true == cu.default_company

      {:ok, com2} = Sys.create_company(v2, u)
      cu = Sys.get_company_user(com2.id, u.id)
      assert false == cu.default_company
    end

    test "get_default_company" do
      v1 = valid_company_attributes()
      v2 = valid_company_attributes()
      u = user_fixture()
      {:ok, com2} = Sys.create_company(v2, u)
      {:ok, _} = Sys.create_company(v1, u)
      assert com2.name == Sys.get_default_company(u).name
    end

    test "cannot edit if not admin" do
      v = valid_company_attributes()
      admin = user_fixture()
      not_admin = user_fixture()
      {:ok, com} = Sys.create_company(v, admin)
      status = Sys.update_company(com, %{name: "any"}, not_admin)
      assert status == :not_authorise
    end

    test "unique company by user, when create" do
      v1 = valid_company_attributes(%{name: "haha"})
      v2 = valid_company_attributes(%{name: "haha"})
      u = user_fixture()
      {:ok, _} = Sys.create_company(v1, u)
      {:error, :create_company, changeset, _} = Sys.create_company(v2, u)
      assert "has already been taken" in errors_on(changeset).name
    end

    test "unique company by user, when edit" do
      v1 = valid_company_attributes(%{name: "haha"})
      v2 = valid_company_attributes(%{name: "haha1"})
      u = user_fixture()
      {:ok, com1} = Sys.create_company(v1, u)
      {:ok, com2} = Sys.create_company(v2, u)
      {:error, :update_company, c, _} = Sys.update_company(com2, %{name: "haha"}, u)
      {:ok, _} = Sys.update_company(com1, %{name: "haha"}, u)
      assert "has already been taken" in errors_on(c).name
    end

    test "do not allow add user to company" do
      admin = user_fixture()
      not_admin = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      status = Sys.allow_user_to_access(com1, admin, "guest", not_admin)
      assert status == :not_authorise
    end

    test "cannot add same user to a company" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      {:ok, _} = Sys.allow_user_to_access(com1, user, "guest", admin)
      {:error, cu} = Sys.allow_user_to_access(com1, user, "guest", admin)
      assert "already in company" in errors_on(cu).email
    end

    test "company_user cannot empty fields" do
      cu = Sys.company_user_changeset(%FullCircle.Sys.CompanyUser{}, %{})
      assert "can't be blank" in errors_on(cu).role
      assert "can't be blank" in errors_on(cu).user_id
      assert "can't be blank" in errors_on(cu).company_id
    end

    test "company_user have not in list value" do
      cu = Sys.company_user_changeset(%FullCircle.Sys.CompanyUser{}, %{role: "crazy"})
      assert "not in list" in errors_on(cu).role
    end

    test "cannot add user to not in list role into company" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      {:error, cu} = Sys.allow_user_to_access(com1, user, "not in list role", admin)
      assert "not in list" in errors_on(cu).role
    end

    test "change user role in company" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      {:ok, _} = Sys.allow_user_to_access(com1, user, "guest", admin)
      {:ok, cu} = Sys.change_user_role_in(com1, user.id, "admin", admin)
      assert cu.role == "admin"
      assert cu.company_id == cu.company_id
    end

    test "change user role in to not inlist" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      {:ok, _} = Sys.allow_user_to_access(com1, user, "guest", admin)
      {:error, cu} = Sys.change_user_role_in(com1, user.id, "not in list role", admin)
      assert "not in list" in errors_on(cu).role
    end

    test "cannot change user role in company" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      {:ok, _} = Sys.allow_user_to_access(com1, user, "guest", admin)
      status = Sys.change_user_role_in(com1, admin.id, "admin", user)
      assert status == :not_authorise
    end

    test "cannot change own role in company" do
      admin = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      status = Sys.change_user_role_in(com1, admin.id, "admin", admin)
      assert status == :not_authorise
    end

    test "add registered user to a company" do
      admin = user_fixture()
      user = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      {:ok, cu} = Sys.allow_user_to_access(com1, user, "guest", admin)
      assert cu.company_id == com1.id
      assert cu.user_id == user.id
      assert cu.role == "guest"
      assert cu.default_company == false
    end

    test "add same user to company" do
      admin = user_fixture()
      user = user_fixture(%{email: "duplicate_user@place.stuff"})
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)
      Sys.allow_user_to_access(com1, user, "guest", admin)
      {:error, cs} = Sys.add_user_to_company(com1, "duplicate_user@place.stuff", "manager", admin)
      assert "already in company" in errors_on(cs).email
    end

    test "add a new user to the company" do
      admin = user_fixture()
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)

      {:ok, {u, cu, pwd}} =
        Sys.add_user_to_company(com1, "unregister_user@place.stuff", "clerk", admin)

      assert cu.company_id == com1.id
      assert u.email == "unregister_user@place.stuff"
      refute is_nil(pwd)
      assert cu.role == "clerk"
      assert cu.default_company == false
    end

    test "add a registered user to the company by email" do
      admin = user_fixture()
      user = user_fixture(%{email: "registered_user@place.stuff"})
      v1 = valid_company_attributes(%{name: "haha"})
      {:ok, com1} = Sys.create_company(v1, admin)

      {:ok, {u, cu, _}} =
        Sys.add_user_to_company(com1, "registered_user@place.stuff", "manager", admin)

      assert cu.company_id == com1.id
      assert u.email == user.email
      assert cu.role == "manager"
      assert cu.default_company == false
    end
  end
end
