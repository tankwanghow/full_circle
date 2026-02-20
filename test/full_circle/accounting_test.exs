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
               "Intangible Asset",
               "Accrual",
               "Post Dated Cheques",
               "Depreciation",
               "Direct Costs",
               "Expenses",
               "Overhead",
               "Other Income",
               "Revenue",
               "Cost Of Goods Sold"
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
      all =
        FullCircle.StdInterface.filter(
          FullCircle.Accounting.Account,
          [:name, :account_type, :descriptions],
          "",
          com,
          admin,
          page: 1,
          per_page: 50
        )

      ac = FullCircle.StdInterface.get!(FullCircle.Accounting.Account, Enum.at(all, 0).id)

      FullCircle.Accounting.delete_account(ac, com, admin)

      assert Enum.count(all) - 1 ==
               Enum.count(
                 FullCircle.StdInterface.filter(
                   FullCircle.Accounting.Account,
                   [:name, :account_type, :descriptions],
                   "",
                   com,
                   admin,
                   page: 1,
                   per_page: 50
                 )
               )
    end

    test "not in list account type", %{com: com, admin: admin} do
      actype =
        FullCircle.Accounting.account_types()
        |> Enum.at((FullCircle.Accounting.account_types() |> Enum.count() |> :rand.uniform()) - 1)

      {:ok, _ac} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{account_type: actype}),
          com,
          admin
        )

      {:error, :create_account, cs, _} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{account_type: "name"}),
          com,
          admin
        )

      assert "not in list" in errors_on(cs).account_type
    end

    test "unique account name", %{com: com, admin: admin} do
      {:ok, _ac} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{name: "name"}),
          com,
          admin
        )

      {:ok, _ac} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{name: "name2"}),
          com,
          admin
        )

      {:error, :create_account, cs, _} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{name: "name"}),
          com,
          admin
        )

      assert "has already been taken" in errors_on(cs).name
    end

    test "require name, account_type and company_id", %{com: com, admin: admin} do
      v = %{name: nil, account_type: nil, company_id: nil, descriptions: nil}

      {:error, :create_account, changeset, _} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          v,
          com,
          admin
        )

      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).account_type
      refute errors_on(changeset)[:descriptions] != nil
      refute errors_on(changeset)[:company_id] != nil
    end

    test "create_account with valid attributes", %{com: com, admin: admin} do
      {:ok, ac} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{name: "name"}),
          com,
          admin
        )

      assert ac.name == "name"
      assert ac.company_id == com.id
      assert Enum.count(FullCircle.Sys.log_entry_for("accounts", ac.id, com.id)) == 1

      assert "name" ==
               FullCircle.StdInterface.filter(
                 FullCircle.Accounting.Account,
                 [:name, :account_type, :descriptions],
                 "na",
                 com,
                 admin,
                 page: 1,
                 per_page: 50
               )
               |> Enum.map(fn x -> x.name end)
               |> Enum.at(0)
    end

    test "update account with valid attributes", %{com: com, admin: admin} do
      {:ok, nac} =
        FullCircle.StdInterface.create(
          FullCircle.Accounting.Account,
          "account",
          valid_account_attributes(%{name: "name"}),
          com,
          admin
        )

      {:ok, uac} =
        FullCircle.StdInterface.update(
          FullCircle.Accounting.Account,
          "account",
          nac,
          %{name: "kaka", account_type: "Revenue", descriptions: "hello"},
          com,
          admin
        )

      assert uac.name == "kaka"
      assert uac.account_type == "Revenue"
      assert uac.descriptions == "hello"
      assert uac.company_id == com.id
      assert Enum.count(FullCircle.Sys.log_entry_for("accounts", uac.id, com.id)) == 2
    end

    test "filter accounts", %{com: com, admin: admin} do
      com1 = company_fixture(admin, %{})

      FullCircle.StdInterface.create(
        FullCircle.Accounting.Account,
        "account",
        valid_account_attributes(%{name: "name"}),
        com,
        admin
      )

      FullCircle.StdInterface.create(
        FullCircle.Accounting.Account,
        "account",
        valid_account_attributes(%{name: "name"}),
        com1,
        admin
      )

      FullCircle.StdInterface.create(
        FullCircle.Accounting.Account,
        "account",
        valid_account_attributes(%{name: "name1"}),
        com,
        admin
      )

      FullCircle.StdInterface.create(
        FullCircle.Accounting.Account,
        "account",
        valid_account_attributes(%{name: "name1"}),
        com1,
        admin
      )

      # user not in company should see nothing
      assert [] ==
               Enum.map(
                 FullCircle.StdInterface.filter(
                   FullCircle.Accounting.Account,
                   [:name, :account_type, :descriptions],
                   "na",
                   com,
                   user_fixture(),
                   page: 1,
                   per_page: 50
                 ),
                 fn x -> x.name end
               )

      # filter by "name" should include custom accounts and be scoped to company
      names_com =
        FullCircle.StdInterface.filter(
          FullCircle.Accounting.Account,
          [:name, :account_type, :descriptions],
          "name",
          com,
          admin,
          page: 1,
          per_page: 50
        )
        |> Enum.map(fn x -> x.name end)

      assert "name" in names_com
      assert "name1" in names_com

      names_com1 =
        FullCircle.StdInterface.filter(
          FullCircle.Accounting.Account,
          [:name, :account_type, :descriptions],
          "name",
          com1,
          admin,
          page: 1,
          per_page: 50
        )
        |> Enum.map(fn x -> x.name end)

      assert "name" in names_com1
      assert "name1" in names_com1

      # filter by "name1" should have name1 first (best match)
      names_name1 =
        FullCircle.StdInterface.filter(
          FullCircle.Accounting.Account,
          [:name, :account_type, :descriptions],
          "name1",
          com,
          admin,
          page: 1,
          per_page: 50
        )
        |> Enum.map(fn x -> x.name end)

      assert "name1" in names_name1
      assert "name" in names_name1
      assert hd(names_name1) == "name1"
    end
  end
end
