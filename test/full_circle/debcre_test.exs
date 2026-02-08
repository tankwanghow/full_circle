defmodule FullCircle.DebCreTest do
  use FullCircle.DataCase

  alias FullCircle.DebCre
  alias FullCircle.Accounting
  alias FullCircle.Accounting.{Transaction, TaxCode}

  import FullCircle.BillingFixtures
  import FullCircle.DebCreFixtures
  import FullCircle.UserAccountsFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION ---

  describe "debcre authorization" do
    test_authorise_to(
      :create_credit_note,
      ["admin", "manager", "supervisor", "clerk", "disable", "punch_camera"]
    )

    test_authorise_to(
      :update_credit_note,
      ["admin", "manager", "supervisor", "clerk", "disable", "punch_camera"]
    )

    test_authorise_to(
      :create_debit_note,
      ["admin", "manager", "supervisor", "clerk", "disable", "punch_camera"]
    )

    test_authorise_to(
      :update_debit_note,
      ["admin", "manager", "supervisor", "clerk", "disable", "punch_camera"]
    )
  end

  # --- CREDIT NOTE CREATE ---

  describe "create_credit_note/3" do
    test "creates credit note with gapless doc number", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = credit_note_attrs(contact, sales_acct, no_stax)

      assert {:ok, %{create_credit_note: cn}} =
               DebCre.create_credit_note(attrs, company, admin)

      assert cn.note_no =~ ~r/^CN-\d{6}$/
      assert cn.contact_id == contact.id
    end

    test "creates GL transactions: positive detail + negated AR header", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        credit_note_attrs(contact, sales_acct, no_stax,
          quantity: "10",
          unit_price: "5.00"
        )

      {:ok, %{create_credit_note: cn}} =
        DebCre.create_credit_note(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^cn.id and t.doc_type == "CreditNote"
        )

      # 0% tax: 1 detail + 1 AR header = 2
      assert length(txns) == 2

      # Detail: positive (debit expense)
      line_txn = Enum.find(txns, fn t -> t.account_id == sales_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("50.00"))

      # AR header: negated
      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      assert Decimal.eq?(header_txn.amount, Decimal.new("-50.00"))
    end

    test "with tax creates 3 GL transactions", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)
      sales_tc = sales_tax_code_fixture(company, admin, %{"rate" => "0.10"})

      attrs =
        credit_note_attrs(contact, sales_acct, sales_tc,
          quantity: "10",
          unit_price: "5.00",
          tax_rate: "0.10"
        )

      {:ok, %{create_credit_note: cn}} =
        DebCre.create_credit_note(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^cn.id and t.doc_type == "CreditNote"
        )

      assert length(txns) == 3

      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      # note_balance = 55.00, negated = -55.00
      assert Decimal.eq?(header_txn.amount, Decimal.new("-55.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      contact = contact_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs = credit_note_attrs(contact, sales_acct, no_stax)
      assert :not_authorise = DebCre.create_credit_note(attrs, company, guest)
    end
  end

  # --- CREDIT NOTE GET ---

  describe "get_credit_note!/3" do
    test "returns credit note with computed fields", %{admin: admin, company: company} do
      cn = credit_note_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = DebCre.get_credit_note!(cn.id, company, admin)

      assert loaded.contact_name != nil
      assert Decimal.eq?(loaded.note_desc_amount, Decimal.new("50.00"))
      assert Decimal.eq?(loaded.note_tax_amount, Decimal.new("0.00"))
      assert Decimal.eq?(loaded.note_amount, Decimal.new("50.00"))
    end
  end

  # --- CREDIT NOTE UPDATE ---

  describe "update_credit_note/4" do
    test "updates credit note and re-creates transactions", %{
      admin: admin,
      company: company
    } do
      cn = credit_note_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = DebCre.get_credit_note!(cn.id, company, admin)
      detail = List.first(loaded.credit_note_details)

      update_attrs = %{
        "note_no" => loaded.note_no,
        "note_date" => Date.to_string(loaded.note_date),
        "contact_name" => loaded.contact_name,
        "contact_id" => loaded.contact_id,
        "credit_note_details" => %{
          "0" => %{
            "id" => detail.id,
            "descriptions" => detail.descriptions,
            "account_id" => detail.account_id,
            "account_name" => detail.account_name,
            "tax_code_id" => detail.tax_code_id,
            "tax_code_name" => detail.tax_code_name,
            "quantity" => "10",
            "unit_price" => "10.00",
            "tax_rate" => "0",
            "_persistent_id" => "1"
          }
        },
        "transaction_matchers" => %{}
      }

      assert {:ok, %{update_credit_note: updated}} =
               DebCre.update_credit_note(loaded, update_attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^updated.id and t.doc_type == "CreditNote"
        )

      ar_acct = Accounting.get_account_by_name("Account Receivables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ar_acct.id end)
      # 10 * 10.00 = 100.00, negated
      assert Decimal.eq?(header_txn.amount, Decimal.new("-100.00"))
    end
  end

  # --- CREDIT NOTE INDEX ---

  describe "credit_note_index_query/6" do
    test "returns credit notes for empty search", %{admin: admin, company: company} do
      _cn = credit_note_fixture(company, admin)

      results =
        DebCre.credit_note_index_query("", "", company, admin, page: 1, per_page: 25)

      assert length(results) >= 1
    end
  end

  # --- DEBIT NOTE CREATE ---

  describe "create_debit_note/3" do
    test "creates debit note with gapless doc number", %{admin: admin, company: company} do
      contact = contact_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs = debit_note_attrs(contact, pur_acct, no_ptax)

      assert {:ok, %{create_debit_note: dn}} =
               DebCre.create_debit_note(attrs, company, admin)

      assert dn.note_no =~ ~r/^DN-\d{6}$/
      assert dn.contact_id == contact.id
    end

    test "creates GL transactions: negated detail + positive AP header", %{
      admin: admin,
      company: company
    } do
      contact = contact_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs =
        debit_note_attrs(contact, pur_acct, no_ptax,
          quantity: "10",
          unit_price: "5.00"
        )

      {:ok, %{create_debit_note: dn}} =
        DebCre.create_debit_note(attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^dn.id and t.doc_type == "DebitNote"
        )

      # 1 detail + 1 AP header = 2
      assert length(txns) == 2

      # Detail: negated (credit expense)
      line_txn = Enum.find(txns, fn t -> t.account_id == pur_acct.id end)
      assert Decimal.eq?(line_txn.amount, Decimal.new("-50.00"))

      # AP header: positive (debit payables)
      ap_acct = Accounting.get_account_by_name("Account Payables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ap_acct.id end)
      assert Decimal.eq?(header_txn.amount, Decimal.new("50.00"))
    end

    test "returns :not_authorise for guest user", %{admin: admin, company: company} do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, guest, "guest", admin)

      contact = contact_fixture(company, admin)
      pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

      no_ptax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoPTax"
        )

      attrs = debit_note_attrs(contact, pur_acct, no_ptax)
      assert :not_authorise = DebCre.create_debit_note(attrs, company, guest)
    end
  end

  # --- DEBIT NOTE GET ---

  describe "get_debit_note!/3" do
    test "returns debit note with computed fields", %{admin: admin, company: company} do
      dn = debit_note_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = DebCre.get_debit_note!(dn.id, company, admin)

      assert loaded.contact_name != nil
      assert Decimal.eq?(loaded.note_desc_amount, Decimal.new("50.00"))
      assert Decimal.eq?(loaded.note_amount, Decimal.new("50.00"))
    end
  end

  # --- DEBIT NOTE UPDATE ---

  describe "update_debit_note/4" do
    test "updates debit note and re-creates transactions", %{
      admin: admin,
      company: company
    } do
      dn = debit_note_fixture(company, admin, quantity: "10", unit_price: "5.00")
      loaded = DebCre.get_debit_note!(dn.id, company, admin)
      detail = List.first(loaded.debit_note_details)

      update_attrs = %{
        "note_no" => loaded.note_no,
        "note_date" => Date.to_string(loaded.note_date),
        "contact_name" => loaded.contact_name,
        "contact_id" => loaded.contact_id,
        "debit_note_details" => %{
          "0" => %{
            "id" => detail.id,
            "descriptions" => detail.descriptions,
            "account_id" => detail.account_id,
            "account_name" => detail.account_name,
            "tax_code_id" => detail.tax_code_id,
            "tax_code_name" => detail.tax_code_name,
            "quantity" => "10",
            "unit_price" => "10.00",
            "tax_rate" => "0",
            "_persistent_id" => "1"
          }
        },
        "transaction_matchers" => %{}
      }

      assert {:ok, %{update_debit_note: updated}} =
               DebCre.update_debit_note(loaded, update_attrs, company, admin)

      txns =
        Repo.all(
          from t in Transaction,
            where: t.doc_id == ^updated.id and t.doc_type == "DebitNote"
        )

      ap_acct = Accounting.get_account_by_name("Account Payables", company, admin)
      header_txn = Enum.find(txns, fn t -> t.account_id == ap_acct.id end)
      # 10 * 10.00 = 100.00, positive (debit payables)
      assert Decimal.eq?(header_txn.amount, Decimal.new("100.00"))
    end
  end

  # --- DEBIT NOTE INDEX ---

  describe "debit_note_index_query/6" do
    test "returns debit notes for empty search", %{admin: admin, company: company} do
      _dn = debit_note_fixture(company, admin)

      results =
        DebCre.debit_note_index_query("", "", company, admin, page: 1, per_page: 25)

      assert length(results) >= 1
    end
  end
end
