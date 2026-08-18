defmodule FullCircle.XeroImport.ImportInvoiceTest do
  use FullCircle.DataCase
  alias FullCircle.{Billing, Accounting, Repo}
  alias FullCircle.Accounting.{Transaction, TaxCode}
  import FullCircle.BillingFixtures

  setup do
    billing_setup()
  end

  test "keeps the supplied number and posts GL", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    sales = Accounting.get_account_by_name("General Sales", company, admin)

    no_stax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    attrs = invoice_attrs(contact, good, sales, no_stax) |> Map.put("invoice_no", "INV-000123")

    assert {:ok, %{create_invoice: inv}} = Billing.import_invoice(attrs, company, admin)
    assert inv.invoice_no == "INV-000123"

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "Invoice" and t.doc_no == "INV-000123")

    assert txns != []
  end

  test "does not increment the Invoice gapless counter", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    sales = Accounting.get_account_by_name("General Sales", company, admin)

    no_stax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    before =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == "Invoice",
          select: g.current
      )

    attrs = invoice_attrs(contact, good, sales, no_stax) |> Map.put("invoice_no", "INV-000123")
    assert {:ok, _} = Billing.import_invoice(attrs, company, admin)

    after_c =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == "Invoice",
          select: g.current
      )

    assert after_c == before
  end

  test "keeps the supplied pur invoice number and posts GL", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    purchases = Accounting.get_account_by_name("General Purchases", company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    attrs =
      pur_invoice_attrs(contact, good, purchases, no_ptax) |> Map.put("pur_invoice_no", "BILL-10")

    assert {:ok, %{create_pur_invoice: inv}} = Billing.import_pur_invoice(attrs, company, admin)
    assert inv.pur_invoice_no == "BILL-10"

    txns =
      Repo.all(from t in Transaction, where: t.doc_type == "PurInvoice" and t.doc_no == "BILL-10")

    assert txns != []
  end

  test "does not increment the PurInvoice gapless counter", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    purchases = Accounting.get_account_by_name("General Purchases", company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    before =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == "PurInvoice",
          select: g.current
      )

    attrs =
      pur_invoice_attrs(contact, good, purchases, no_ptax) |> Map.put("pur_invoice_no", "BILL-10")

    assert {:ok, _} = Billing.import_pur_invoice(attrs, company, admin)

    after_c =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == "PurInvoice",
          select: g.current
      )

    assert after_c == before
  end
end
