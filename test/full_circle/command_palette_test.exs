defmodule FullCircle.CommandPaletteTest do
  use FullCircle.DataCase

  alias FullCircle.CommandPalette
  alias FullCircle.Billing
  alias FullCircle.Accounting
  alias FullCircle.Accounting.TaxCode
  alias FullCircle.Sys

  import FullCircle.BillingFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  defp create_invoice!(company, user) do
    contact = contact_fixture(company, user)
    good = good_fixture(company, user)
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)

    no_stax =
      Repo.one!(
        from tc in TaxCode,
          where: tc.company_id == ^company.id and tc.code == "NoSTax"
      )

    attrs = invoice_attrs(contact, good, sales_acct, no_stax)
    assert {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, user)
    {invoice, contact}
  end

  describe "search/3" do
    test "returns empty for terms shorter than 2 chars", %{admin: admin, company: company} do
      create_invoice!(company, admin)
      assert CommandPalette.search(company, admin, "") == []
      assert CommandPalette.search(company, admin, "I") == []
    end

    test "finds invoice by partial doc number", %{admin: admin, company: company} do
      {invoice, contact} = create_invoice!(company, admin)
      # INV-000001 style — search middle digits or prefix
      terms = String.slice(invoice.invoice_no, 0, 3)

      hits = CommandPalette.search(company, admin, terms)
      assert length(hits) >= 1

      hit = Enum.find(hits, &(&1.doc_id == invoice.id))
      assert hit
      assert hit.doc_type == "Invoice"
      assert hit.doc_no == invoice.invoice_no
      assert hit.label == "Invoice"
      assert hit.contact_name == contact.name
      assert hit.path == "/companies/#{company.id}/Invoice/#{invoice.id}/edit"
    end

    test "finds invoice by full doc number", %{admin: admin, company: company} do
      {invoice, _} = create_invoice!(company, admin)
      hits = CommandPalette.search(company, admin, invoice.invoice_no)
      assert Enum.any?(hits, &(&1.doc_id == invoice.id))
    end

    test "dedupes multi-line transaction postings to one hit", %{admin: admin, company: company} do
      {invoice, _} = create_invoice!(company, admin)

      txn_count =
        from(t in FullCircle.Accounting.Transaction,
          where: t.doc_type == "Invoice" and t.doc_id == ^invoice.id
        )
        |> Repo.aggregate(:count)

      assert txn_count >= 2

      hits = CommandPalette.search(company, admin, invoice.invoice_no)
      matches = Enum.filter(hits, &(&1.doc_id == invoice.id))
      assert length(matches) == 1
    end

    test "excludes documents from another company", %{admin: admin, company: company} do
      {invoice, _} = create_invoice!(company, admin)

      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})

      hits = CommandPalette.search(other_company, other_admin, invoice.invoice_no)
      refute Enum.any?(hits, &(&1.doc_id == invoice.id))
    end

    test "dispatch returns tagged hits", %{admin: admin, company: company} do
      {invoice, _} = create_invoice!(company, admin)
      assert {:hits, hits} = CommandPalette.dispatch(company, admin, invoice.invoice_no)
      assert Enum.any?(hits, &(&1.doc_id == invoice.id))
    end
  end

  describe "authorization" do
    test "guest role gets no invoice hits", %{admin: admin, company: company} do
      guest = user_fixture()
      assert {:ok, _} = Sys.add_user_to_company(company, guest.email, "guest", admin)

      {invoice, _} = create_invoice!(company, admin)
      hits = CommandPalette.search(company, guest, invoice.invoice_no)
      refute Enum.any?(hits, &(&1.doc_type == "Invoice"))
    end
  end
end
