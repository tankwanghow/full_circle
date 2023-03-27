defmodule FullCircle.AccountingTest do
  use FullCircle.DataCase
  alias FullCircle.Accounting

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  describe "account types" do
    test "should have" do
      assert [
               "Cash or Equivalent",
               "Bank",
               "Current Asset",
               "Fixed Asset",
               "Inventory",
               "Non-current Asset",
               "Prepayment",
               "Equity",
               "Current Liability",
               "Liability",
               "Non-current Liability",
               "Depreciation",
               "Direct Costs",
               "Expenses",
               "Overhead",
               "Other Income",
               "Revenue",
               "Sales"
             ] == Accounting.account_types()
    end
  end

  describe "accounts" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      %{admin: admin, com: com}
    end

    test "delete default accounts", %{com: com, admin: admin} do
      all = Accounting.filter_accounts("", com, admin, page: 1, per_page: 50)
      ac = Accounting.get_account!(Enum.at(all, 0).id)
      Accounting.delete_account(ac, admin, com)
      assert Enum.count(all) == Enum.count(Accounting.filter_accounts("", com, admin, page: 1, per_page: 50))
    end

    test "not in list account type", %{com: com, admin: admin} do
      actype =
        FullCircle.Accounting.account_types()
        |> Enum.at((FullCircle.Accounting.account_types() |> Enum.count() |> :rand.uniform()) - 1)

      {:ok, _ac} =
        Accounting.create_account(valid_account_attributes(%{account_type: actype}), admin, com)

      {:error, :create_account, cs, _} =
        Accounting.create_account(valid_account_attributes(%{account_type: "name"}), admin, com)

      assert "not in list" in errors_on(cs).account_type
    end

    test "unique account name", %{com: com, admin: admin} do
      {:ok, _ac} =
        Accounting.create_account(valid_account_attributes(%{name: "name"}), admin, com)

      {:ok, _ac} =
        Accounting.create_account(valid_account_attributes(%{name: "name2"}), admin, com)

      {:error, :create_account, cs, _} =
        Accounting.create_account(valid_account_attributes(%{name: "name"}), admin, com)

      assert "has already been taken" in errors_on(cs).name
    end

    test "require name, account_type and company_id", %{com: com, admin: admin} do
      v = %{name: nil, account_type: nil, company_id: nil, descriptions: nil}

      {:error, :create_account, changeset, _} = Accounting.create_account(v, admin, com)
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).account_type
      refute errors_on(changeset)[:descriptions] != nil
      refute errors_on(changeset)[:company_id] != nil
    end

    test "create_account with valid attributes", %{com: com, admin: admin} do
      {:ok, ac} = Accounting.create_account(valid_account_attributes(%{name: "name"}), admin, com)
      assert ac.name == "name"
      assert ac.company_id == com.id
      assert Enum.count(FullCircle.Sys.log_entry_for("accounts", ac.id, com.id)) == 1

      assert [
        "name",
        "Account Payables",
        "Account Receivables",
        "General Purchase",
        "General Sales",
        "Purchase Tax Receivale",
        "Sales Tax Payable"
      ] ==
               Enum.map(
                 Accounting.filter_accounts("na", com, admin, page: 1, per_page: 50),
                 fn x -> x.name end
               )
    end

    test "update account with valid attributes", %{com: com, admin: admin} do
      {:ok, nac} =
        Accounting.create_account(valid_account_attributes(%{name: "name"}), admin, com)

      {:ok, uac} =
        Accounting.update_account(
          nac,
          %{name: "kaka", account_type: "Sales", descriptions: "hello"},
          admin,
          com
        )

      assert uac.name == "kaka"
      assert uac.account_type == "Sales"
      assert uac.descriptions == "hello"
      assert uac.company_id == com.id
      assert Enum.count(FullCircle.Sys.log_entry_for("accounts", uac.id, com.id)) == 2
    end

    test "filter accounts", %{com: com, admin: admin} do
      aclist1 = [
        "name", "name1",
        "Account Payables",
        "Account Receivables",
        "General Purchase",
        "General Sales",
        "Purchase Tax Receivale",
        "Sales Tax Payable"
      ]

      aclist2 = [
        "name1", "name",
        "Account Payables",
        "Account Receivables",
        "General Purchase",
        "General Sales",
        "Purchase Tax Receivale",
        "Sales Tax Payable"
      ]

      com1 = company_fixture(admin, %{})
      Accounting.create_account(valid_account_attributes(%{name: "name"}), admin, com)
      Accounting.create_account(valid_account_attributes(%{name: "name"}), admin, com1)
      Accounting.create_account(valid_account_attributes(%{name: "name1"}), admin, com)
      Accounting.create_account(valid_account_attributes(%{name: "name1"}), admin, com1)

      assert [] ==
               Enum.map(
                 Accounting.filter_accounts("na", com, user_fixture(), page: 1, per_page: 50),
                 fn x -> x.name end
               )

      assert aclist1 ==
               Enum.map(
                 Accounting.filter_accounts("name", com, admin, page: 1, per_page: 50),
                 fn x -> x.name end
               )

      assert aclist1 ==
               Enum.map(
                 Accounting.filter_accounts("name", com1, admin, page: 1, per_page: 50),
                 fn x -> x.name end
               )

      assert aclist2 ==
               Enum.map(
                 Accounting.filter_accounts("name1", com, admin, page: 1, per_page: 50),
                 fn x -> x.name end
               )

      assert aclist2 ==
               Enum.map(
                 Accounting.filter_accounts("name1", com1, admin, page: 1, per_page: 50),
                 fn x -> x.name end
               )
    end
  end
end
