defmodule FullCircle.ReceiveFundTest do
  use FullCircle.DataCase

  alias FullCircle.ReceiveFund
  alias FullCircle.Accounting
  alias FullCircle.Accounting.{Transaction, TaxCode}

  import FullCircle.BillingFixtures
  import FullCircle.ReceiveFundFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION ---

  describe "receipt authorization" do
    test_authorise_to(
      :create_receipt,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )

    test_authorise_to(
      :update_receipt,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )
  end

  # --- CREATE RECEIPT ---

  describe "create_receipt/3" do
    test "creates receipt with valid attrs and gapless doc number", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)
      funds_acct = funds_account_fixture(company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        receipt_attrs_with_funds(contact, good, sales_acct, no_stax, funds_acct)

      assert {:ok, %{create_receipt: receipt}} =
               ReceiveFund.create_receipt(attrs, company, admin)

      assert receipt.receipt_no =~ ~r/^RC-\d{6}$/
      assert receipt.contact_id == contact.id
      assert receipt.company_id == company.id
      assert length(receipt.receipt_details) == 1
    end

    test "creates GL transactions: negated detail credit + funds debit", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)
      funds_acct = funds_account_fixture(company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        receipt_attrs_with_funds(contact, good, sales_acct, no_stax, funds_acct,
          quantity: "10",
          unit_price: "5.00",
          funds_amount: "50.00"
        )

      {:ok, %{create_receipt: receipt}} =
        ReceiveFund.create_receipt(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^receipt.id and t.doc_type == "Receipt"
        )

      # 0% tax: 1 negated detail line + 1 funds debit = 2 transactions
      assert length(txns) == 2

      # Detail line: negated (credit)
      line_txn = Enum.find(txns, fn t -> t.account_id == sales_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("-50.00"))

      # Funds account: positive (debit)
      funds_txn = Enum.find(txns, fn t -> t.account_id == funds_acct.id end)
      assert Decimal.eq?(funds_txn.amount, Decimal.new("50.00"))
    end

    test "with tax creates 3 GL transactions (detail + tax + funds)", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)
      sales_tc = sales_tax_code_fixture(company, admin, %{"rate" => "0.10"})
      funds_acct = funds_account_fixture(company, admin)

      attrs =
        receipt_attrs_with_funds(contact, good, sales_acct, sales_tc, funds_acct,
          quantity: "10",
          unit_price: "5.00",
          tax_rate: "0.10",
          funds_amount: "55.00"
        )

      {:ok, %{create_receipt: receipt}} =
        ReceiveFund.create_receipt(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^receipt.id and t.doc_type == "Receipt"
        )

      # good_amount=50, tax_amount=5 → 1 detail + 1 tax + 1 funds = 3
      assert length(txns) == 3

      line_txn = Enum.find(txns, fn t -> t.account_id == sales_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("-50.00"))

      tax_txn =
        Enum.find(txns, fn t ->
          t.account_id != sales_acct.id and t.account_id != funds_acct.id
        end)

      assert Decimal.eq?(tax_txn.amount, Decimal.new("-5.00"))

      funds_txn = Enum.find(txns, fn t -> t.account_id == funds_acct.id end)
      assert Decimal.eq?(funds_txn.amount, Decimal.new("55.00"))
    end

    test "with cheque creates PDC transaction", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      pdc_acct = Accounting.get_account_by_name("Post Dated Cheques", company, admin)

      attrs =
        receipt_attrs_with_cheque(contact, good, sales_acct, no_stax,
          quantity: "10",
          unit_price: "5.00",
          cheque_amount: "50.00"
        )

      {:ok, %{create_receipt: receipt}} =
        ReceiveFund.create_receipt(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^receipt.id and t.doc_type == "Receipt"
        )

      # 1 negated detail + 1 PDC cheque = 2 transactions
      assert length(txns) == 2

      pdc_txn = Enum.find(txns, fn t -> t.account_id == pdc_acct.id end)
      assert Decimal.eq?(pdc_txn.amount, Decimal.new("50.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)
      funds_acct = funds_account_fixture(company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = receipt_attrs_with_funds(contact, good, sales_acct, no_stax, funds_acct)
      assert :not_authorise = ReceiveFund.create_receipt(attrs, company, guest)
    end
  end

  # --- GET RECEIPT ---

  describe "get_receipt!/3" do
    test "returns receipt with computed virtual fields", %{admin: admin, company: company} do
      receipt =
        receipt_fixture(company, admin, quantity: "10", unit_price: "5.00", funds_amount: "50.00")

      loaded = ReceiveFund.get_receipt!(receipt.id, company, admin)

      assert loaded.contact_name != nil
      assert loaded.funds_account_name != nil
      assert Decimal.eq?(loaded.receipt_good_amount, Decimal.new("50.00"))
      assert Decimal.eq?(loaded.receipt_tax_amount, Decimal.new("0.00"))
    end

    test "returns receipt details with computed fields", %{admin: admin, company: company} do
      receipt =
        receipt_fixture(company, admin, quantity: "10", unit_price: "5.00", funds_amount: "50.00")

      loaded = ReceiveFund.get_receipt!(receipt.id, company, admin)

      detail = List.first(loaded.receipt_details)
      assert detail.good_name != nil
      assert detail.account_name != nil
      assert Decimal.eq?(detail.good_amount, Decimal.new("50.00"))
    end
  end

  # --- UPDATE RECEIPT ---

  describe "update_receipt/4" do
    test "updates receipt and re-creates transactions", %{admin: admin, company: company} do
      receipt =
        receipt_fixture(company, admin, quantity: "10", unit_price: "5.00", funds_amount: "50.00")

      loaded = ReceiveFund.get_receipt!(receipt.id, company, admin)
      detail = List.first(loaded.receipt_details)

      update_attrs = %{
        "receipt_no" => loaded.receipt_no,
        "receipt_date" => Date.to_string(loaded.receipt_date),
        "contact_name" => loaded.contact_name,
        "contact_id" => loaded.contact_id,
        "funds_account_name" => loaded.funds_account_name,
        "funds_account_id" => loaded.funds_account_id,
        "funds_amount" => "100.00",
        "receipt_details" => %{
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
        "received_cheques" => %{},
        "transaction_matchers" => %{}
      }

      assert {:ok, %{update_receipt: updated}} =
               ReceiveFund.update_receipt(loaded, update_attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^updated.id and t.doc_type == "Receipt"
        )

      # detail line + funds = 2
      assert length(txns) == 2

      line_txn = Enum.find(txns, fn t -> Decimal.negative?(t.amount) end)
      # 10 * 10.00 = 100.00, negated
      assert Decimal.eq?(line_txn.amount, Decimal.new("-100.00"))

      funds_txn = Enum.find(txns, fn t -> Decimal.positive?(t.amount) end)
      assert Decimal.eq?(funds_txn.amount, Decimal.new("100.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      receipt = receipt_fixture(company, admin)
      loaded = ReceiveFund.get_receipt!(receipt.id, company, admin)

      attrs = %{"receipt_no" => loaded.receipt_no}
      assert :not_authorise = ReceiveFund.update_receipt(loaded, attrs, company, guest)
    end
  end

  # --- INDEX QUERY ---

  describe "receipt_index_query/6" do
    test "returns receipts for empty search", %{admin: admin, company: company} do
      _receipt = receipt_fixture(company, admin)

      results =
        ReceiveFund.receipt_index_query("", "", company, admin, page: 1, per_page: 25)

      assert length(results) >= 1
    end
  end
end
