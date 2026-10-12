defmodule FullCircle.ContactBankTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, Repo, StdInterface}
  alias FullCircle.Accounting.Contact
  alias FullCircle.BankPayment.Banks
  alias FullCircle.Sys.Log

  import FullCircle.BillingFixtures
  import Ecto.Query

  setup do
    billing_setup()
  end

  describe "authorization" do
    test_authorise_to(:manage_contact_bank, ["admin", "manager"])
    test_authorise_to(:manage_bank_payment_config, ["admin"])
    test_authorise_to(:create_bank_payment_batch, ["admin", "manager"])
    test_authorise_to(:admin_bank_payment_batch, ["admin"])
  end

  test "Banks lists Maybank, Ryt Bank and Public Bank's own BICs" do
    assert %{name: "Malayan Banking Berhad (Maybank)", lengths: [12]} = Banks.get("MBBEMYKL")
    assert Banks.get("SCCHMYKL")
    assert Banks.get("PBBEMYKL")
    assert Banks.get("PIBEMYK1")
    assert Banks.get("NOPE") == nil
    assert {"RHB Bank Berhad", "RHBBMYKL"} in Banks.options()
  end

  defp bank_logs(c),
    do:
      Repo.all(
        from l in Log,
          where: l.entity == "contact_bank" and l.entity_id == ^c.id,
          order_by: l.inserted_at
      )

  describe "save_contact_bank/4" do
    test "strips non-digits, trims the name, stamps the change and logs under contact_bank", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      assert {:ok, c} =
               Accounting.save_contact_bank(
                 c,
                 %{
                   "bank_code" => "MBBEMYKL",
                   "bank_account_no" => "1122-3344 5566",
                   "bank_account_name" => " Tan Sdn Bhd "
                 },
                 company,
                 admin
               )

      assert c.bank_account_no == "112233445566"
      assert c.bank_account_name == "Tan Sdn Bhd"
      assert c.bank_details_changed_at
      assert [%Log{action: "update_contact_bank"}] = bank_logs(c)

      assert Repo.all(
               from l in Log,
                 where:
                   l.entity == "contacts" and l.entity_id == ^c.id and
                     l.action == "update_contact_bank"
             ) == []
    end

    test "clearing details saves and logs (cleared)", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)

      {:ok, c} =
        Accounting.save_contact_bank(
          c,
          %{
            "bank_code" => "MBBEMYKL",
            "bank_account_no" => "112233445566",
            "bank_account_name" => "Tan"
          },
          company,
          admin
        )

      assert {:ok, c} =
               Accounting.save_contact_bank(
                 c,
                 %{"bank_code" => "", "bank_account_no" => "", "bank_account_name" => ""},
                 company,
                 admin
               )

      assert c.bank_code == nil
      assert [_, %Log{delta: delta}] = bank_logs(c)
      assert delta =~ "(cleared)"
    end

    test "saving nothing on a blank contact is fine and logs nothing", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      assert {:ok, _} =
               Accounting.save_contact_bank(
                 c,
                 %{"bank_code" => "", "bank_account_no" => "", "bank_account_name" => ""},
                 company,
                 admin
               )

      assert bank_logs(c) == []
    end

    test "all three together", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)

      assert {:error, cs} =
               Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL"}, company, admin)

      assert "required when bank details are filled" in errors_on(cs).bank_account_no
    end

    test "account length must suit the bank; name at most 120", %{
      company: company,
      admin: admin
    } do
      c = contact_fixture(company, admin)

      assert {:error, cs} =
               Accounting.save_contact_bank(
                 c,
                 %{
                   "bank_code" => "RHBBMYKL",
                   "bank_account_no" => "12345",
                   "bank_account_name" => String.duplicate("x", 121)
                 },
                 company,
                 admin
               )

      assert [msg] = errors_on(cs).bank_account_no
      assert msg =~ "must be 14 digits for RHB Bank Berhad"
      assert errors_on(cs).bank_account_name != []
    end

    test "clerks may not; another company's contact may not", %{company: company, admin: admin} do
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)
      c = contact_fixture(company, admin)

      assert :not_authorise =
               Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL"}, company, clerk)

      %{company: other, admin: other_admin} = billing_setup()
      theirs = contact_fixture(other, other_admin)
      assert :not_authorise = Accounting.save_contact_bank(theirs, %{}, company, admin)
    end
  end

  test "the ordinary contact changeset never writes bank fields", %{
    company: company,
    admin: admin
  } do
    c = contact_fixture(company, admin)

    {:ok, c} =
      StdInterface.update(
        Contact,
        "contact",
        c,
        %{"name" => c.name, "bank_account_no" => "999999999999", "bank_code" => "MBBEMYKL"},
        company,
        admin
      )

    assert c.bank_account_no == nil
    assert c.bank_code == nil
  end
end
