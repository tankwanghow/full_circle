defmodule FullCircle.BillingTest do
  use FullCircle.DataCase

  alias FullCircle.Billing
  alias FullCircle.Accounting
  alias FullCircle.Accounting.{Transaction, TaxCode}

  import FullCircle.BillingFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION ---

  describe "billing authorization" do
    test_authorise_to(
      :create_invoice,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )

    test_authorise_to(
      :update_invoice,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )

    test_authorise_to(
      :create_pur_invoice,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )

    test_authorise_to(
      :update_pur_invoice,
      ["admin", "manager", "supervisor", "clerk", "cashier"]
    )
  end

  # --- INVOICE CREATE ---

  describe "create_invoice/3" do
    test "creates invoice with valid attrs and gapless doc number", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = invoice_attrs(contact, good, sales_acct, no_stax)

      assert {:ok, %{create_invoice: invoice}} =
               Billing.create_invoice(attrs, company, admin)

      assert invoice.invoice_no =~ ~r/^INV-\d{6}$/
      assert invoice.contact_id == contact.id
      assert invoice.company_id == company.id
      assert length(invoice.invoice_details) == 1
    end

    test "creates GL transactions with negated line and positive header", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        invoice_attrs(contact, good, sales_acct, no_stax, quantity: "10", unit_price: "5.00")

      {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^invoice.id and t.doc_type == "Invoice"
        )

      # 0% tax: 1 line + 1 header = 2 transactions
      assert length(txns) == 2

      line_txn = Enum.find(txns, fn t -> t.account_id == sales_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("-50.00"))

      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      assert Decimal.eq?(header_txn.amount, Decimal.new("50.00"))
    end

    test "with tax creates 3 GL transactions", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)
      sales_tc = sales_tax_code_fixture(company, admin, %{"rate" => "0.10"})

      attrs =
        invoice_attrs(contact, good, sales_acct, sales_tc,
          quantity: "10",
          unit_price: "5.00",
          tax_rate: "0.10"
        )

      {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^invoice.id and t.doc_type == "Invoice"
        )

      # good_amount=50, tax_amount=5, total=55
      assert length(txns) == 3

      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      assert Decimal.eq?(header_txn.amount, Decimal.new("55.00"))

      line_txn = Enum.find(txns, fn t -> t.account_id == sales_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("-50.00"))

      tax_txn =
        Enum.find(txns, fn t ->
          t.account_id != sales_acct.id and t.account_id != ar_acct.id
        end)

      assert Decimal.eq?(tax_txn.amount, Decimal.new("-5.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = invoice_attrs(contact, good, sales_acct, no_stax)
      assert :not_authorise = Billing.create_invoice(attrs, company, guest)
    end

    test "rejects invoice with no details", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)

      attrs = %{
        "invoice_date" => Date.to_string(Date.utc_today()),
        "due_date" => Date.to_string(Date.add(Date.utc_today(), 30)),
        "contact_name" => contact.name,
        "contact_id" => contact.id,
        "invoice_details" => %{}
      }

      assert {:error, :create_invoice, changeset, _} =
               Billing.create_invoice(attrs, company, admin)

      assert changeset.errors != []
    end
  end

  # --- INVOICE GET ---

  describe "get_invoice!/3" do
    test "returns invoice with computed virtual fields", %{admin: admin, company: company} do
      invoice = invoice_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = Billing.get_invoice!(invoice.id, company, admin)

      assert loaded.contact_name != nil
      assert Decimal.eq?(loaded.invoice_good_amount, Decimal.new("50.00"))
      assert Decimal.eq?(loaded.invoice_tax_amount, Decimal.new("0.00"))
      assert Decimal.eq?(loaded.invoice_amount, Decimal.new("50.00"))
    end

    test "returns invoice details with computed fields", %{admin: admin, company: company} do
      invoice = invoice_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = Billing.get_invoice!(invoice.id, company, admin)

      detail = List.first(loaded.invoice_details)
      assert detail.good_name != nil
      assert detail.account_name != nil
      assert Decimal.eq?(detail.good_amount, Decimal.new("50.00"))
    end
  end

  # --- INVOICE UPDATE ---

  describe "update_invoice/4" do
    test "updates invoice and re-creates transactions", %{admin: admin, company: company} do
      invoice = invoice_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = Billing.get_invoice!(invoice.id, company, admin)
      detail = List.first(loaded.invoice_details)

      update_attrs = %{
        "invoice_no" => loaded.invoice_no,
        "e_inv_internal_id" => loaded.e_inv_internal_id,
        "invoice_date" => Date.to_string(loaded.invoice_date),
        "due_date" => Date.to_string(loaded.due_date),
        "contact_name" => loaded.contact_name,
        "contact_id" => loaded.contact_id,
        "invoice_details" => %{
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
        }
      }

      assert {:ok, %{update_invoice: updated}} =
               Billing.update_invoice(loaded, update_attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^updated.id and t.doc_type == "Invoice"
        )

      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      # 10 * 10.00 = 100.00
      assert Decimal.eq?(header_txn.amount, Decimal.new("100.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      invoice = invoice_fixture(company, admin)
      loaded = Billing.get_invoice!(invoice.id, company, admin)

      attrs = %{
        "e_inv_internal_id" => loaded.e_inv_internal_id,
        "invoice_no" => loaded.invoice_no
      }

      assert :not_authorise = Billing.update_invoice(loaded, attrs, company, guest)
    end
  end

  # --- INVOICE INDEX QUERY ---

  describe "invoice_index_query/7" do
    test "returns invoices for empty search", %{admin: admin, company: company} do
      _invoice = invoice_fixture(company, admin)

      results =
        Billing.invoice_index_query("", "", "", "", company, admin, page: 1, per_page: 25)

      assert length(results) >= 1
    end

    test "filters by balance", %{admin: admin, company: company} do
      _invoice = invoice_fixture(company, admin)

      unpaid =
        Billing.invoice_index_query("", "", "", "Unpaid", company, admin, page: 1, per_page: 25)

      assert length(unpaid) >= 1

      paid =
        Billing.invoice_index_query("", "", "", "Paid", company, admin, page: 1, per_page: 25)

      assert Enum.empty?(paid)
    end
  end

  # --- PUR_INVOICE CREATE ---

  describe "create_pur_invoice/3" do
    test "creates pur_invoice with valid attrs and gapless doc number", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs = pur_invoice_attrs(contact, good, pur_acct, no_ptax)

      assert {:ok, %{create_pur_invoice: pur_invoice}} =
               Billing.create_pur_invoice(attrs, company, admin)

      assert pur_invoice.pur_invoice_no =~ ~r/^PINV-\d{6}$/
      assert pur_invoice.contact_id == contact.id
      assert pur_invoice.company_id == company.id
    end

    test "creates GL transactions with positive line and negated header", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs =
        pur_invoice_attrs(contact, good, pur_acct, no_ptax, quantity: "10", unit_price: "5.00")

      {:ok, %{create_pur_invoice: pur_invoice}} =
        Billing.create_pur_invoice(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^pur_invoice.id and t.doc_type == "PurInvoice"
        )

      assert length(txns) == 2

      # Line: positive (debit expense)
      line_txn = Enum.find(txns, fn t -> t.account_id == pur_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("50.00"))

      # Header: negated (credit payables)
      ap_acct = Accounting.get_account_by_name("Account Payables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ap_acct.id end)
      assert Decimal.eq?(header_txn.amount, Decimal.new("-50.00"))
    end

    test "with tax creates 3 GL transactions", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)
      pur_tc = purchase_tax_code_fixture(company, admin, %{"rate" => "0.10"})

      attrs =
        pur_invoice_attrs(contact, good, pur_acct, pur_tc,
          quantity: "10",
          unit_price: "5.00",
          tax_rate: "0.10"
        )

      {:ok, %{create_pur_invoice: pur_invoice}} =
        Billing.create_pur_invoice(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^pur_invoice.id and t.doc_type == "PurInvoice"
        )

      assert length(txns) == 3

      ap_acct = Accounting.get_account_by_name("Account Payables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ap_acct.id end)
      assert Decimal.eq?(header_txn.amount, Decimal.new("-55.00"))

      line_txn = Enum.find(txns, fn t -> t.account_id == pur_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("50.00"))

      tax_txn =
        Enum.find(txns, fn t ->
          t.account_id != pur_acct.id and t.account_id != ap_acct.id
        end)

      assert Decimal.eq?(tax_txn.amount, Decimal.new("5.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      contact = contact_fixture(company, admin)
      good = good_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs = pur_invoice_attrs(contact, good, pur_acct, no_ptax)
      assert :not_authorise = Billing.create_pur_invoice(attrs, company, guest)
    end
  end

  # --- PUR_INVOICE GET ---

  describe "get_pur_invoice!/3" do
    test "returns pur_invoice with computed virtual fields", %{
      admin: admin,
      company: company
    } do
      pur_invoice =
        pur_invoice_fixture(company, admin, quantity: "10", unit_price: "5.00")

      loaded = Billing.get_pur_invoice!(pur_invoice.id, company, admin)

      assert loaded.contact_name != nil
      assert Decimal.eq?(loaded.pur_invoice_good_amount, Decimal.new("50.00"))
      assert Decimal.eq?(loaded.pur_invoice_tax_amount, Decimal.new("0.00"))
      assert Decimal.eq?(loaded.pur_invoice_amount, Decimal.new("50.00"))
    end
  end

  # --- PUR_INVOICE UPDATE ---

  describe "update_pur_invoice/4" do
    test "updates pur_invoice and re-creates transactions", %{
      admin: admin,
      company: company
    } do
      pur_invoice =
        pur_invoice_fixture(company, admin, quantity: "10", unit_price: "5.00")

      loaded = Billing.get_pur_invoice!(pur_invoice.id, company, admin)
      detail = List.first(loaded.pur_invoice_details)

      update_attrs = %{
        "pur_invoice_no" => loaded.pur_invoice_no,
        "e_inv_internal_id" => loaded.e_inv_internal_id || "EINV-UPDATE",
        "pur_invoice_date" => Date.to_string(loaded.pur_invoice_date),
        "due_date" => Date.to_string(loaded.due_date),
        "contact_name" => loaded.contact_name,
        "contact_id" => loaded.contact_id,
        "pur_invoice_details" => %{
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
        }
      }

      assert {:ok, %{update_pur_invoice: updated}} =
               Billing.update_pur_invoice(loaded, update_attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^updated.id and t.doc_type == "PurInvoice"
        )

      ap_acct = Accounting.get_account_by_name("Account Payables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ap_acct.id end)
      # 10 * 10.00 = 100.00, header is negated
      assert Decimal.eq?(header_txn.amount, Decimal.new("-100.00"))
    end
  end

  # --- PUR_INVOICE INDEX QUERY ---

  describe "pur_invoice_index_query/7" do
    test "returns pur_invoices for empty search", %{admin: admin, company: company} do
      _pur_invoice = pur_invoice_fixture(company, admin)

      results =
        Billing.pur_invoice_index_query("", "", "", "", company, admin,
          page: 1,
          per_page: 25
        )

      assert length(results) >= 1
    end

    test "filters by balance", %{admin: admin, company: company} do
      _pur_invoice = pur_invoice_fixture(company, admin)

      unpaid =
        Billing.pur_invoice_index_query("", "", "", "Unpaid", company, admin,
          page: 1,
          per_page: 25
        )

      assert length(unpaid) >= 1

      paid =
        Billing.pur_invoice_index_query("", "", "", "Paid", company, admin,
          page: 1,
          per_page: 25
        )

      assert Enum.empty?(paid)
    end
  end

  # --- SHARED ---

  describe "get_matcher_by/2" do
    test "returns empty list when no matchers exist", %{admin: admin, company: company} do
      invoice = invoice_fixture(company, admin)
      assert Billing.get_matcher_by("Invoice", invoice.id) == []
    end
  end
end
