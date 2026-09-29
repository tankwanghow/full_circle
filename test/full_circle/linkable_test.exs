defmodule FullCircle.LinkableTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.Linkable

  setup do
    %{admin: admin, company: company} = billing_setup()
    contact = contact_fixture(company, admin, %{"name" => "Syarikat Ah Seng"})
    %{admin: admin, company: company, contact: contact}
  end

  test "types covers records, notes and the palette documents" do
    assert Linkable.types() ==
             ~w(Employee Contact Good Note Invoice PurInvoice Receipt Payment CreditNote DebitNote Journal Deposit ReturnCheque)

    assert Linkable.type?("Invoice")
    refute Linkable.type?("Transaction")
  end

  test "resolve a contact in the company", %{admin: admin, company: company, contact: c} do
    assert {:ok, %{type: "Contact", title: "Syarikat Ah Seng", url: url}} =
             Linkable.resolve("Contact", c.id, company, admin)

    assert url == "/companies/#{company.id}/contacts/#{c.id}/edit"
  end

  test "a contact from another company is not found", %{admin: admin, contact: c} do
    other = FullCircle.SysFixtures.company_fixture(admin, %{})
    assert {:error, :not_found} = Linkable.resolve("Contact", c.id, other, admin)
  end

  test "unknown type, malformed id and missing id are not found", %{
    admin: admin,
    company: company
  } do
    assert {:error, :not_found} =
             Linkable.resolve("Transaction", Ecto.UUID.generate(), company, admin)

    assert {:error, :not_found} = Linkable.resolve("Contact", "not-a-uuid", company, admin)

    assert {:error, :not_found} =
             Linkable.resolve("Contact", Ecto.UUID.generate(), company, admin)
  end

  test "resolve an invoice by its transactions", %{admin: admin, company: company} do
    inv = invoice_fixture(company, admin)

    assert {:ok, %{type: "Invoice", title: title, url: url}} =
             Linkable.resolve("Invoice", inv.id, company, admin)

    assert title == inv.invoice_no
    assert url == "/companies/#{company.id}/Invoice/#{inv.id}/edit"
  end

  # Document pages are open to every company member; the update_* permission
  # is about editing, so it must not decide whether a note can be about one.
  test "a role that can open but not edit a document still resolves it",
       %{admin: admin, company: company} do
    inv = invoice_fixture(company, admin)

    for role <- ~w(cashier auditor) do
      u = user_with_role(company, admin, role)
      assert {:ok, %{id: id}} = Linkable.resolve("Invoice", inv.id, company, u)
      assert id == inv.id
    end

    clerk = user_with_role(company, admin, "clerk")
    refute FullCircle.Authorization.can?(clerk, :update_journal, company)
    assert Linkable.can_view_type?("Journal", company, clerk)
  end

  test "a note is restricted for a role without view_notes", %{admin: admin, company: company} do
    {:ok, note} = FullCircle.Notes.create_note(%{"body" => "x"}, company, admin)
    guest = user_with_role(company, admin, "guest")
    assert {:error, :restricted} = Linkable.resolve("Note", note.id, company, guest)
  end

  test "resolve_many batches per type", %{admin: admin, company: company, contact: c} do
    missing = Ecto.UUID.generate()
    result = Linkable.resolve_many([{"Contact", c.id}, {"Contact", missing}], company, admin)
    assert {:ok, %{title: "Syarikat Ah Seng"}} = result[{"Contact", c.id}]
    assert {:error, :not_found} = result[{"Contact", missing}]
  end

  test "search contacts escapes LIKE metacharacters", %{admin: admin, company: company} do
    contact_fixture(company, admin, %{"name" => "100% Feed"})
    contact_fixture(company, admin, %{"name" => "1000 Feed"})
    assert [%{title: "100% Feed"}] = Linkable.search("Contact", "100%", company, admin)
  end

  test "search invoices by number", %{admin: admin, company: company} do
    inv = invoice_fixture(company, admin)

    assert Enum.any?(
             Linkable.search("Invoice", inv.invoice_no, company, admin),
             &(&1.id == inv.id)
           )
  end
end
