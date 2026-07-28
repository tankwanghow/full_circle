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

  describe "resolve_e_invoice_contact/4" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      %{admin: admin, com: com}
    end

    test "matches on tax_id even when the names share nothing", %{admin: admin, com: com} do
      contact =
        FullCircle.BillingFixtures.contact_fixture(com, admin, %{
          "name" => "Ct Square Marketing",
          "tax_id" => "IG3543553041"
        })

      assert {%{id: id}, :tax_id} =
               Accounting.resolve_e_invoice_contact("IG3543553041", nil, "KHOR CHAI THING", com)
      assert id == contact.id
    end

    test "falls back to name ignoring case and punctuation", %{admin: admin, com: com} do
      contact =
        FullCircle.BillingFixtures.contact_fixture(com, admin, %{
          "name" => "Syarikat Kamparly Auto & Hardwares Sdn. Bhd.",
          "tax_id" => ""
        })

      assert {%{id: id}, :name} =
               Accounting.resolve_e_invoice_contact(
                 "C2853053050",
                 nil,
                 "SYARIKAT KAMPARLY AUTO & HARDWARES SDN BHD",
                 com
               )

      assert id == contact.id
    end

    test "matches on reg_no ignoring formatting, before falling back to name", %{
      admin: admin,
      com: com
    } do
      contact =
        FullCircle.BillingFixtures.contact_fixture(com, admin, %{
          "name" => "Renamed Entity Sdn Bhd",
          "tax_id" => "",
          "reg_no" => "1996-01020394"
        })

      assert {%{id: id}, :reg_no} =
               Accounting.resolve_e_invoice_contact(
                 "C5895805030",
                 "199601020394",
                 "GRAIN & PROTEIN TECHNOLOGIES ASIA SDN BHD",
                 com
               )

      assert id == contact.id
    end

    test "returns nil when neither tax_id nor name matches", %{com: com} do
      refute Accounting.resolve_e_invoice_contact("C999", "999999999999", "Nobody Sdn Bhd", com)
    end

    test "a blank tax_id does not match contacts with a blank tax_id", %{admin: admin, com: com} do
      FullCircle.BillingFixtures.contact_fixture(com, admin, %{
        "name" => "Some Other Supplier",
        "tax_id" => ""
      })

      refute Accounting.resolve_e_invoice_contact("", "", "Unrelated Name Sdn Bhd", com)
    end
  end

  describe "learn_contact_identifiers/5" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      %{admin: admin, com: com}
    end

    test "fills a blank tax_id so the supplier resolves next time", %{admin: admin, com: com} do
      contact =
        FullCircle.BillingFixtures.contact_fixture(com, admin, %{
          "name" => "Learnt Supplier Sdn Bhd",
          "tax_id" => ""
        })

      assert {:ok, _} =
               Accounting.learn_contact_identifiers(contact.id, "C123456789", "", com, admin)

      assert {%{id: id}, :tax_id} =
               Accounting.resolve_e_invoice_contact("C123456789", nil, "Totally Different", com)
      assert id == contact.id
    end

    test "never overwrites an existing tax_id", %{admin: admin, com: com} do
      contact =
        FullCircle.BillingFixtures.contact_fixture(com, admin, %{
          "name" => "Already Has Tin Sdn Bhd",
          "tax_id" => "C111"
        })

      assert {:ok, _} = Accounting.learn_contact_identifiers(contact.id, "C999", "", com, admin)

      assert FullCircle.Repo.get!(FullCircle.Accounting.Contact, contact.id).tax_id == "C111"
    end

    test "is a no-op without a contact or a tin", %{admin: admin, com: com} do
      assert :noop == Accounting.learn_contact_identifiers(nil, "C123", "", com, admin)
      assert :noop == Accounting.learn_contact_identifiers(Ecto.UUID.generate(), "", "", com, admin)
    end
  end
end
