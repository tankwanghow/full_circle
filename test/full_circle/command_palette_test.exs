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

    test "finds documents by contact name", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "Swee Heng Trading #{System.unique_integer([:positive])}"
        })

      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        invoice_attrs(contact, good, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      assert {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, admin)

      # Partial name — not a document number
      hits = CommandPalette.search(company, admin, "Swee Heng")
      hit = Enum.find(hits, &(&1.doc_id == invoice.id))
      assert hit
      assert hit.contact_name == contact.name
      assert hit.path == "/companies/#{company.id}/Invoice/#{invoice.id}/edit"
    end

    test "contact name search does not leak other companies", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "UniqueContactXYZ #{System.unique_integer([:positive])}"
        })

      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        invoice_attrs(contact, good, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      assert {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, admin)

      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})

      hits = CommandPalette.search(other_company, other_admin, "UniqueContactXYZ")
      refute Enum.any?(hits, &(&1.doc_id == invoice.id))
    end

    test "merges doc-number and contact hits without duplicates", %{
      admin: admin,
      company: company
    } do
      contact =
        contact_fixture(company, admin, %{
          "name" => "MergeCo #{System.unique_integer([:positive])}"
        })

      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        invoice_attrs(contact, good, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      assert {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, admin)

      # Full doc no also appears under contact search if we used a shared fragment —
      # for merge test, search by number only yields one hit.
      hits = CommandPalette.search(company, admin, invoice.invoice_no)
      assert Enum.count(hits, &(&1.doc_id == invoice.id)) == 1
    end

    test "contact name + type keyword filters to invoices", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "Swee Heng Filter #{System.unique_integer([:positive])}"
        })

      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      inv_attrs =
        invoice_attrs(contact, good, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      assert {:ok, %{create_invoice: invoice}} = Billing.create_invoice(inv_attrs, company, admin)

      # Type keyword at end
      hits = CommandPalette.search(company, admin, "Swee Heng Filter inv")
      docs = Enum.filter(hits, &(&1.kind == :document))
      assert Enum.any?(docs, &(&1.doc_id == invoice.id))
      assert Enum.all?(docs, &(&1.doc_type == "Invoice"))

      # Type keyword at start
      hits2 = CommandPalette.search(company, admin, "invoice Swee Heng Filter")
      docs2 = Enum.filter(hits2, &(&1.kind == :document))
      assert Enum.any?(docs2, &(&1.doc_id == invoice.id))
      assert Enum.all?(docs2, &(&1.doc_type == "Invoice"))

      # Wrong type keyword → no invoice hits for this contact path
      hits3 = CommandPalette.search(company, admin, "Swee Heng Filter receipt")
      refute Enum.any?(hits3, &(&1.kind == :document and &1.doc_id == invoice.id))
    end
  end

  describe "Query.parse/1" do
    alias FullCircle.CommandPalette.Query

    test "strips type keywords from contact terms" do
      q = Query.parse("swee heng inv")
      assert q.contact_terms == "swee heng"
      assert q.doc_types == ["Invoice"]

      q2 = Query.parse("inv swee heng")
      assert q2.contact_terms == "swee heng"
      assert q2.doc_types == ["Invoice"]
    end

    test "leaves pure doc numbers alone" do
      q = Query.parse("INV-000012")
      assert q.contact_terms == "INV-000012"
      assert q.doc_types == nil
      assert q.date_mode == :none
    end

    test "parses single date as on_or_before" do
      q = Query.parse("swee heng inv 5/2/2026")
      assert q.contact_terms == "swee heng"
      assert q.doc_types == ["Invoice"]
      assert q.date_mode == :on_or_before
      assert q.date_to == ~D[2026-02-05]
      assert q.date_from == nil
    end

    test "parses date range inclusive" do
      q = Query.parse("swee 1/2/2026 - 14/2/2026")
      assert q.contact_terms == "swee"
      assert q.date_mode == :range
      assert q.date_from == ~D[2026-02-01]
      assert q.date_to == ~D[2026-02-14]
    end

    test "swaps inverted range" do
      q = Query.parse("14/2/2026 1/2/2026")
      assert q.date_mode == :range
      assert q.date_from == ~D[2026-02-01]
      assert q.date_to == ~D[2026-02-14]
    end
  end

  describe "date filters" do
    defp invoice_on!(company, user, contact, date) do
      good = good_fixture(company, user)
      sales_acct = Accounting.get_account_by_name("General Sales", company, user)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        invoice_attrs(contact, good, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)
        |> Map.put("invoice_date", Date.to_string(date))
        |> Map.put("due_date", Date.to_string(Date.add(date, 30)))

      assert {:ok, %{create_invoice: invoice}} = Billing.create_invoice(attrs, company, user)
      invoice
    end

    test "single date keeps on or before only", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "DateFilter Co #{System.unique_integer([:positive])}"
        })

      older = invoice_on!(company, admin, contact, ~D[2026-01-10])
      on_day = invoice_on!(company, admin, contact, ~D[2026-02-05])
      newer = invoice_on!(company, admin, contact, ~D[2026-02-20])

      hits = CommandPalette.search(company, admin, "#{contact.name} inv 5/2/2026")
      ids = Enum.map(hits, & &1.doc_id)

      assert older.id in ids
      assert on_day.id in ids
      refute newer.id in ids
    end

    test "date range is inclusive", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "RangeFilter Co #{System.unique_integer([:positive])}"
        })

      before = invoice_on!(company, admin, contact, ~D[2026-01-31])
      start_d = invoice_on!(company, admin, contact, ~D[2026-02-01])
      mid = invoice_on!(company, admin, contact, ~D[2026-02-10])
      end_d = invoice_on!(company, admin, contact, ~D[2026-02-14])
      after_d = invoice_on!(company, admin, contact, ~D[2026-02-15])

      hits = CommandPalette.search(company, admin, "#{contact.name} 1/2/2026 - 14/2/2026")
      ids = Enum.map(hits, & &1.doc_id)

      refute before.id in ids
      assert start_d.id in ids
      assert mid.id in ids
      assert end_d.id in ids
      refute after_d.id in ids
    end
  end

  describe "contact master" do
    test "name search includes contact edit hit", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "MasterJump #{System.unique_integer([:positive])}"
        })

      hits = CommandPalette.search(company, admin, "MasterJump")
      hit = Enum.find(hits, &(&1.kind == :contact and &1.doc_id == contact.id))
      assert hit
      assert hit.path == "/companies/#{company.id}/contacts/#{contact.id}/edit"
    end
  end

  describe "good line filter" do
    test "explicit good separator filters invoices by good name", %{
      admin: admin,
      company: company
    } do
      contact =
        contact_fixture(company, admin, %{
          "name" => "GoodFilter Co #{System.unique_integer([:positive])}"
        })

      good_a =
        good_fixture(company, admin, %{"name" => "Egg Grade A #{System.unique_integer([:positive])}"})

      good_e =
        good_fixture(company, admin, %{"name" => "Egg Grade E #{System.unique_integer([:positive])}"})

      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs_a =
        invoice_attrs(contact, good_a, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      attrs_e =
        invoice_attrs(contact, good_e, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      assert {:ok, %{create_invoice: inv_a}} = Billing.create_invoice(attrs_a, company, admin)
      assert {:ok, %{create_invoice: inv_e}} = Billing.create_invoice(attrs_e, company, admin)

      hits =
        CommandPalette.search(
          company,
          admin,
          "#{contact.name} inv good #{good_e.name}"
        )

      doc_ids =
        hits
        |> Enum.filter(&(&1.kind == :document))
        |> Enum.map(& &1.doc_id)

      assert inv_e.id in doc_ids
      refute inv_a.id in doc_ids

      hit_e = Enum.find(hits, &(&1.kind == :document and &1.doc_id == inv_e.id))
      assert hit_e.good_name
      assert hit_e.good_name =~ good_e.name
    end
  end

  describe "deposit bank search" do
    test "parses bank separator", %{admin: _admin, company: _company} do
      alias FullCircle.CommandPalette.Query
      q = Query.parse("dep bank maybank")
      assert q.doc_types == ["Deposit"]
      assert q.bank_terms == "maybank"
      assert q.contact_terms == ""
    end

    test "dep + free text is available as bank/no match terms" do
      alias FullCircle.CommandPalette.Query
      q = Query.parse("dep public bank")
      assert q.doc_types == ["Deposit"]
      assert q.contact_terms == "public bank"
    end
  end

  describe "groups" do
    test "groups contacts and documents separately", %{admin: admin, company: company} do
      contact =
        contact_fixture(company, admin, %{
          "name" => "GroupCo #{System.unique_integer([:positive])}"
        })

      good = good_fixture(company, admin)
      sales_acct = Accounting.get_account_by_name("General Sales", company, admin)

      no_stax =
        Repo.one!(
          from tc in TaxCode,
            where: tc.company_id == ^company.id and tc.code == "NoSTax"
        )

      attrs =
        invoice_attrs(contact, good, sales_acct, no_stax)
        |> Map.put("contact_name", contact.name)
        |> Map.put("contact_id", contact.id)

      assert {:ok, %{create_invoice: _}} = Billing.create_invoice(attrs, company, admin)

      hits = CommandPalette.search(company, admin, contact.name)
      groups = CommandPalette.group_hits(hits)
      sections = Enum.map(groups, &elem(&1, 0))
      assert :contacts in sections
      assert :documents in sections
    end
  end

  describe "create actions" do
    test "newinv opens invoice create path", %{admin: admin, company: company} do
      hits = CommandPalette.search(company, admin, "newinv")
      assert Enum.any?(hits, &(&1.kind == :action and &1.doc_type == "Invoice"))
      hit = Enum.find(hits, &(&1.kind == :action and &1.doc_type == "Invoice"))
      assert hit.path == "/companies/#{company.id}/Invoice/new"
    end

    test "newpur and aliases", %{admin: admin, company: company} do
      for term <- ~w(newpur newpinv newpurchase) do
        hits = CommandPalette.search(company, admin, term)
        assert Enum.any?(hits, &(&1.kind == :action and &1.doc_type == "PurInvoice"))
        assert Enum.any?(hits, &(&1.path == "/companies/#{company.id}/PurInvoice/new"))
      end
    end

    test "all finance create tokens", %{admin: admin, company: company} do
      expected = %{
        "newrc" => {"Receipt", "Receipt"},
        "newpv" => {"Payment", "Payment"},
        "newcn" => {"CreditNote", "CreditNote"},
        "newdn" => {"DebitNote", "DebitNote"},
        "newjs" => {"Journal", "Journal"},
        "newdebitnote" => {"DebitNote", "DebitNote"},
        "newcreditnote" => {"CreditNote", "CreditNote"},
        "newdep" => {"Deposit", "Deposit"},
        "newdeposit" => {"Deposit", "Deposit"}
      }

      for {term, {doc_type, route}} <- expected do
        hits = CommandPalette.search(company, admin, term)
        hit = Enum.find(hits, &(&1.kind == :action and &1.doc_type == doc_type))
        assert hit, "expected action for #{term}"
        assert hit.path == "/companies/#{company.id}/#{route}/new"
      end
    end

    test "prefix new lists create actions", %{admin: admin, company: company} do
      hits = CommandPalette.search(company, admin, "new")
      assert Enum.all?(hits, &(&1.kind == :action))
      assert length(hits) >= 8
    end

    test "empty_hits returns create actions", %{admin: admin, company: company} do
      hits = CommandPalette.empty_hits(company, admin)
      assert Enum.all?(hits, &(&1.kind == :action))
      assert Enum.any?(hits, &(&1.doc_type == "Deposit"))
    end

    test "spaced input is never an action (contact-safe)", %{admin: admin, company: company} do
      hits = CommandPalette.search(company, admin, "new inv")
      refute Enum.any?(hits, &(&1.kind == :action))
    end

    test "guest cannot create invoice action", %{admin: admin, company: company} do
      guest = user_fixture()
      assert {:ok, _} = Sys.add_user_to_company(company, guest.email, "guest", admin)
      hits = CommandPalette.search(company, guest, "newinv")
      refute Enum.any?(hits, &(&1.kind == :action and &1.doc_type == "Invoice"))
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
