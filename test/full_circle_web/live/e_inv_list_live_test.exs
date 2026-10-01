defmodule FullCircleWeb.EInvListLiveTest do
  # E-Invoices listing: one line per LHDN document, its Full Circle
  # document (or "+ New …" links) in the last column.
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.BillingFixtures

  alias FullCircle.{Accounting, Billing, Repo}
  alias FullCircle.Accounting.TaxCode
  alias FullCircle.EInvMetas.EInvoice
  import Ecto.Query

  setup %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    %{conn: log_in_user(conn, admin), admin: admin, company: company}
  end

  defp e_invoice!(company, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(
      struct(
        EInvoice,
        Map.merge(
          %{
            company_id: company.id,
            uuid: "UUID#{System.unique_integer([:positive])}",
            internalId: "SUPINV-1",
            status: "Valid",
            totalPayableAmount: Decimal.new("50.00"),
            totalNetAmount: Decimal.new("50.00"),
            issuerTIN: "C999",
            supplierName: "Darul Angkasa Sdn Bhd",
            supplierTIN: "C999",
            buyerName: "Us",
            buyerTIN: company.tax_id,
            documentCurrency: "MYR",
            typeName: "Invoice",
            typeVersionName: "1.1",
            dateTimeReceived: DateTime.add(now, -3600),
            dateTimeIssued: DateTime.add(now, -3600)
          },
          attrs
        )
      )
    )
  end

  defp create_invoice!(company, user) do
    contact = contact_fixture(company, user, %{"name" => "Swee Lee Farm"})
    good = good_fixture(company, user)
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)

    no_stax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    {:ok, %{create_invoice: inv}} =
      Billing.create_invoice(invoice_attrs(contact, good, sales_acct, no_stax), company, user)

    inv
  end

  defp list_path(company, direction \\ "Received"),
    do: "/companies/#{company.id}/e_invoices?search[direction]=#{direction}"

  test "received e-invoice with no document: one line with + New links", %{
    conn: conn,
    company: company
  } do
    einv = e_invoice!(company, %{})
    row = "##{einv.uuid}"

    {:ok, lv, html} = live(conn, list_path(company))

    refute html =~ "UUID / InternalId / Direction / Type"
    refute html =~ "Click here to Sync"
    assert has_element?(lv, "#sync", "Sync")
    assert has_element?(lv, "#{row} a[href$='/documents/#{einv.uuid}']", "SUPINV-1")
    assert has_element?(lv, row, "Darul Angkasa Sdn Bhd")
    assert has_element?(lv, row, "50.00")
    assert has_element?(lv, "#{row} a[href*='/PurInvoice/new?obj=']", "+ Pur Invoice")
    assert has_element?(lv, "#{row} a[href*='/Payment/new?obj=']", "+ Payment")
  end

  test "cancelled e-invoice shows a status chip and no + New links", %{
    conn: conn,
    company: company
  } do
    einv = e_invoice!(company, %{status: "Cancelled"})
    {:ok, lv, _html} = live(conn, list_path(company))

    assert has_element?(lv, "##{einv.uuid}", "Cancelled")
    refute has_element?(lv, "##{einv.uuid} a[href*='/new']")
  end

  test "sent e-invoice: match, then remove match, its invoice", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    inv = create_invoice!(company, admin)

    einv =
      e_invoice!(company, %{
        internalId: inv.invoice_no,
        issuerTIN: company.tax_id,
        buyerName: "Swee Lee Farm",
        buyerTIN: "TAX001"
      })

    row = "##{einv.uuid}"
    {:ok, lv, _html} = live(conn, list_path(company, "Sent"))

    assert has_element?(lv, "#{row} [data-col=fc] a", inv.invoice_no)
    assert has_element?(lv, row, "Swee Lee Farm")

    lv |> element("#{row} [phx-click=match]") |> render_click()
    assert has_element?(lv, "#{row} [phx-click=unmatch]", "remove")
    assert Repo.reload!(inv).e_inv_uuid == einv.uuid

    lv |> element("#{row} [phx-click=unmatch]") |> render_click()
    assert has_element?(lv, "#{row} [phx-click=match]", "Match")
  end

  test "empty period shows an empty-state line", %{conn: conn, company: company} do
    {:ok, lv, _html} = live(conn, list_path(company))
    assert has_element?(lv, "#objects_empty", "No e-invoices in this period.")
  end
end
