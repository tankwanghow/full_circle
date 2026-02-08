defmodule FullCircle.BillPayTest do
  use FullCircle.DataCase

  alias FullCircle.BillPay
  alias FullCircle.Accounting
  alias FullCircle.Accounting.{Transaction, TaxCode}

  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION ---

  describe "payment authorization" do
    test_authorise_to(
      :create_payment,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )

    test_authorise_to(
      :update_payment,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )
  end

  # --- CREATE PAYMENT ---

  describe "create_payment/3" do
    test "creates payment with valid attrs and gapless doc number", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      funds_acct = pay_funds_account_fixture(company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs = payment_attrs(contact, good, pur_acct, no_ptax, funds_acct)

      assert {:ok, %{create_payment: payment}} =
               BillPay.create_payment(attrs, company, admin)

      assert payment.payment_no =~ ~r/^PV-\d{6}$/
      assert payment.contact_id == contact.id
      assert payment.company_id == company.id
      assert length(payment.payment_details) == 1
    end

    test "creates GL transactions: positive detail debit + negated funds credit", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      funds_acct = pay_funds_account_fixture(company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs =
        payment_attrs(contact, good, pur_acct, no_ptax, funds_acct,
          quantity: "10",
          unit_price: "5.00",
          funds_amount: "50.00"
        )

      {:ok, %{create_payment: payment}} =
        BillPay.create_payment(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^payment.id and t.doc_type == "Payment"
        )

      # 0% tax: 1 detail debit + 1 funds credit = 2 transactions
      assert length(txns) == 2

      # Detail line: positive (debit expense)
      line_txn = Enum.find(txns, fn t -> t.account_id == pur_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("50.00"))

      # Funds account: negated (credit cash)
      funds_txn = Enum.find(txns, fn t -> t.account_id == funds_acct.id end)
      assert Decimal.eq?(funds_txn.amount, Decimal.new("-50.00"))
    end

    test "with tax creates 3 GL transactions", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      pur_tc = purchase_tax_code_fixture(company, admin, %{"rate" => "0.10"})
      funds_acct = pay_funds_account_fixture(company, admin)

      attrs =
        payment_attrs(contact, good, pur_acct, pur_tc, funds_acct,
          quantity: "10",
          unit_price: "5.00",
          tax_rate: "0.10",
          funds_amount: "55.00"
        )

      {:ok, %{create_payment: payment}} =
        BillPay.create_payment(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^payment.id and t.doc_type == "Payment"
        )

      assert length(txns) == 3

      line_txn = Enum.find(txns, fn t -> t.account_id == pur_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("50.00"))

      tax_txn =
        Enum.find(txns, fn t ->
          t.account_id != pur_acct.id and t.account_id != funds_acct.id
        end)

      assert Decimal.eq?(tax_txn.amount, Decimal.new("5.00"))

      funds_txn = Enum.find(txns, fn t -> t.account_id == funds_acct.id end)
      assert Decimal.eq?(funds_txn.amount, Decimal.new("-55.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      funds_acct = pay_funds_account_fixture(company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs = payment_attrs(contact, good, pur_acct, no_ptax, funds_acct)
      assert :not_authorise = BillPay.create_payment(attrs, company, guest)
    end
  end

  # --- GET PAYMENT ---

  describe "get_payment!/3" do
    test "returns payment with computed virtual fields", %{admin: admin, company: company} do
      payment = payment_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = BillPay.get_payment!(payment.id, company, admin)

      assert loaded.contact_name != nil
      assert loaded.funds_account_name != nil
      assert Decimal.eq?(loaded.payment_good_amount, Decimal.new("50.00"))
      assert Decimal.eq?(loaded.payment_tax_amount, Decimal.new("0.00"))
    end
  end

  # --- UPDATE PAYMENT ---

  describe "update_payment/4" do
    test "updates payment and re-creates transactions", %{admin: admin, company: company} do
      payment = payment_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = BillPay.get_payment!(payment.id, company, admin)
      detail = List.first(loaded.payment_details)

      update_attrs = %{
        "payment_no" => loaded.payment_no,
        "payment_date" => Date.to_string(loaded.payment_date),
        "contact_name" => loaded.contact_name,
        "contact_id" => loaded.contact_id,
        "funds_account_name" => loaded.funds_account_name,
        "funds_account_id" => loaded.funds_account_id,
        "funds_amount" => "100.00",
        "payment_details" => %{
          "0" => %{
            "id" => detail.id,
            "good_id" => detail.good_id,
            "good_name" => detail.good_name,
            "account_id" => detail.account_id,
            "account_name" => detail.account_name,
            "tax_code_id" => detail.tax_code_id,
            "tax_code_name" => detail.tax_code_name,
            "package_id" => detail.package_id,
            "package_name" => detail.package_name,
            "quantity" => "10",
            "unit_price" => "10.00",
            "discount" => "0",
            "tax_rate" => "0",
            "unit_multiplier" => "0",
            "_persistent_id" => "1"
          }
        },
        "transaction_matchers" => %{}
      }

      assert {:ok, %{update_payment: updated}} =
               BillPay.update_payment(loaded, update_attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^updated.id and t.doc_type == "Payment"
        )

      assert length(txns) == 2

      line_txn = Enum.find(txns, fn t -> Decimal.positive?(t.amount) end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("100.00"))

      funds_txn = Enum.find(txns, fn t -> Decimal.negative?(t.amount) end)
      assert Decimal.eq?(funds_txn.amount, Decimal.new("-100.00"))
    end
  end

  # --- INDEX QUERY ---

  describe "payment_index_query/6" do
    test "returns payments for empty search", %{admin: admin, company: company} do
      _payment = payment_fixture(company, admin)

      results =
        BillPay.payment_index_query("", "", company, admin, page: 1, per_page: 25)

      assert length(results) >= 1
    end
  end
end
