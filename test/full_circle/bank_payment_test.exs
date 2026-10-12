defmodule FullCircle.BankPaymentTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Profile

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    billing_setup()
  end

  describe "templates" do
    test "both bundled templates load and validate" do
      assert [%{code: "pbb_ecp_payment"}, %{code: "rhb_bulk_pay"}] = BankPayment.templates()

      for code <- ["rhb_bulk_pay", "pbb_ecp_payment"] do
        assert {:ok, %{"spec" => spec}} = BankPayment.load_template(code)
        assert :ok = BankPayment.validate_spec(spec)
      end
    end

    test "unknown or unsafe template codes are refused" do
      assert {:error, _} = BankPayment.load_template("../../etc/passwd")
      assert {:error, _} = BankPayment.load_template("nope")
    end

    test "bank keys are validated" do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")

      assert {:error, msgs} =
               BankPayment.validate_spec(Map.put(spec, "our_account_no_digits", ["x"]))

      assert Enum.any?(msgs, &(&1 =~ "our_account_no_digits"))
    end
  end

  test "today/1 is the company's local date", %{company: company} do
    assert BankPayment.today(company) == DateTime.to_date(DateTime.now!(company.timezone))
  end

  describe "formats" do
    test "save, effective version by date, replace in place", %{company: company, admin: admin} do
      f = install_template!(company, admin, "rhb_bulk_pay")
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2026-10-12]).id == f.id
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2025-12-31]) == nil
      assert BankPayment.format_version_exists?(company.id, "rhb_bulk_pay", "2026-01-01")

      attrs = %{
        "code" => "rhb_bulk_pay",
        "name" => "Renamed",
        "effective_from" => "2026-01-01",
        "spec" => f.spec
      }

      assert {:error, cs} = BankPayment.save_format(attrs, company, admin)
      assert errors_on(cs).effective_from != []
      assert {:ok, f2} = BankPayment.save_format(attrs, company, admin, replace: true)
      assert {f2.id, f2.name} == {f.id, "Renamed"}
    end

    test "an invalid spec is refused", %{company: company, admin: admin} do
      attrs = %{
        "code" => "bad",
        "name" => "Bad",
        "effective_from" => "2026-01-01",
        "spec" => %{"renderer" => "text"}
      }

      assert {:error, cs} = BankPayment.save_format(attrs, company, admin)
      assert errors_on(cs).spec != []
    end
  end

  describe "profiles" do
    test "must point at a Bank-type account", %{company: company, admin: admin} do
      cash = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)

      assert {:error, cs} =
               BankPayment.save_profile(
                 %Profile{},
                 %{
                   "account_id" => cash.id,
                   "format_code" => "rhb_bulk_pay",
                   "our_account_no" => "1",
                   "start_date" => "2026-01-01"
                 },
                 company,
                 admin
               )

      assert "must be a Bank account of this company" in errors_on(cs).account_id
    end

    test "warnings list missing params and a wrong account length", %{
      company: company,
      admin: admin
    } do
      bank = bank_gl_account_fixture(company, admin)

      p =
        profile_fixture(company, admin, bank, %{
          "params" => %{"corporate_id" => "123456"},
          "our_account_no" => "123"
        })

      assert BankPayment.profile_warnings(p, company) == :no_format
      install_template!(company, admin, "rhb_bulk_pay")
      assert [w1, w2] = BankPayment.profile_warnings(p, company)
      assert w1 =~ "corporate_name"
      assert w2 =~ "14 digits"
      assert [%Profile{account_name: name}] = BankPayment.list_profiles(company)
      assert name == bank.name
    end

    test "only admins may configure", %{company: company, admin: admin} do
      mgr = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, mgr, "manager", admin)
      assert :not_authorise = BankPayment.save_profile(%Profile{}, %{}, company, mgr)
      assert :not_authorise = BankPayment.save_format(%{}, company, mgr)
    end
  end
end
