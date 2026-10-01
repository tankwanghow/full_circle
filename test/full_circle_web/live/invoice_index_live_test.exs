defmodule FullCircleWeb.InvoiceIndexLiveTest do
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

  defp create_invoice!(company, user, opts \\ []) do
    contact =
      contact_fixture(company, user, %{"name" => Keyword.get(opts, :contact, "Swee Lee Farm")})

    good = good_fixture(company, user)
    sales_acct = Accounting.get_account_by_name("General Sales", company, user)

    no_stax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    attrs =
      invoice_attrs(contact, good, sales_acct, no_stax)
      |> Map.merge(Map.new(Keyword.get(opts, :attrs, %{})))

    {:ok, %{create_invoice: inv}} = Billing.create_invoice(attrs, company, user)
    inv
  end

  defp e_invoice!(company, inv, attrs \\ %{}) do
    Repo.insert!(
      struct(
        EInvoice,
        Map.merge(
          %{
            company_id: company.id,
            uuid: "UUID#{System.unique_integer([:positive])}",
            internalId: inv.invoice_no,
            status: "Valid",
            totalPayableAmount: Decimal.new("50.00"),
            totalNetAmount: Decimal.new("50.00"),
            buyerName: "Swee Lee Farm",
            buyerTIN: "C123",
            documentCurrency: "MYR",
            typeName: "Invoice",
            typeVersionName: "1.0",
            dateTimeReceived: DateTime.utc_now() |> DateTime.truncate(:second),
            dateTimeIssued: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )
    )
  end

  defp row(inv), do: "#objects-#{inv.id}"

  test "one line per invoice: number link, contact, amount, real due date", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    due = Date.add(Date.utc_today(), 30)
    inv = create_invoice!(company, admin, attrs: %{"due_date" => Date.to_string(due)})

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")

    assert has_element?(lv, "#{row(inv)} a", inv.invoice_no)
    # Not yet due → empty overdue cell
    refute has_element?(lv, "#{row(inv)} [data-col=overdue]", "d")
    assert has_element?(lv, row(inv), "Swee Lee Farm")
    assert has_element?(lv, row(inv), "50.00")
    # Due date comes from the invoice, not the invoice date again
    assert render(element(lv, row(inv))) =~ FullCircleWeb.Helpers.format_date(due)
  end

  test "overdue unpaid invoices are flagged", %{conn: conn, admin: admin, company: company} do
    inv =
      create_invoice!(company, admin,
        attrs: %{
          "invoice_date" => Date.to_string(Date.add(Date.utc_today(), -40)),
          "due_date" => Date.to_string(Date.add(Date.utc_today(), -10))
        }
      )

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")
    assert has_element?(lv, "#{row(inv)} [data-col=overdue]", "10d")
    assert render(element(lv, "#{row(inv)} [data-col=overdue]")) =~ "due "
  end

  test "no e-invoice → 'Not sent' link to the portal", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    inv = create_invoice!(company, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")

    assert has_element?(lv, "#{row(inv)} [phx-hook=copyAndOpen]", "Not sent")
  end

  test "a single unmatched candidate offers Match inline; matching turns it Valid", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    inv = create_invoice!(company, admin)
    einv = e_invoice!(company, inv)

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")

    lv |> element("#{row(inv)} [phx-click=match]") |> render_click()

    assert has_element?(lv, row(inv), "Valid")
    refute has_element?(lv, "#{row(inv)} [phx-click=match]")
    assert Repo.get!(FullCircle.Billing.Invoice, inv.id).e_inv_uuid == einv.uuid
  end

  test "matched invoice shows Valid; details and Remove Match live in the expander", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    inv = create_invoice!(company, admin)
    einv = e_invoice!(company, inv)

    FullCircle.EInvMetas.match(
      %{"uuid" => einv.uuid, "internalId" => einv.internalId},
      %{"doc_type" => "Invoice", "doc_id" => inv.id},
      company,
      admin
    )

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")

    assert has_element?(lv, row(inv), "Valid")
    refute has_element?(lv, row(inv), einv.uuid)
    refute has_element?(lv, "#{row(inv)} [phx-click=unmatch]")

    lv |> element("#{row(inv)} [phx-click=toggle_einv]") |> render_click()

    assert has_element?(lv, row(inv), einv.uuid)
    assert has_element?(lv, "#{row(inv)} [phx-click=unmatch]")

    lv |> element("#{row(inv)} [phx-click=unmatch]") |> render_click()
    assert Repo.get!(FullCircle.Billing.Invoice, inv.id).e_inv_uuid == nil
  end

  test "a cancelled matched e-invoice is shown as a problem", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    inv = create_invoice!(company, admin)
    einv = e_invoice!(company, inv, %{status: "Cancelled"})

    FullCircle.EInvMetas.match(
      %{"uuid" => einv.uuid, "internalId" => einv.internalId},
      %{"doc_type" => "Invoice", "doc_id" => inv.id},
      company,
      admin
    )

    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")
    assert has_element?(lv, row(inv), "Cancelled")
    refute has_element?(lv, row(inv), "✓ Valid")
  end

  test "Due Date From filters on the real due date", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    today = Date.utc_today()

    late =
      create_invoice!(company, admin,
        contact: "Late Due",
        attrs: %{"due_date" => Date.to_string(Date.add(today, 60))}
      )

    soon =
      create_invoice!(company, admin,
        contact: "Soon Due",
        attrs: %{"due_date" => Date.to_string(Date.add(today, 5))}
      )

    from = Date.to_string(Date.add(today, 30))
    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice?search[due_date]=#{from}")

    assert has_element?(lv, row(late))
    refute has_element?(lv, row(soon))
  end

  test "Print buttons show only while something is selected", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    inv = create_invoice!(company, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{company.id}/Invoice")

    refute has_element?(lv, "a", "Print(")

    lv |> element("#checkbox_invoice_#{inv.id}") |> render_click(%{"value" => "on"})
    assert has_element?(lv, "a", "Print(1)")

    lv |> element("#checkbox_invoice_#{inv.id}") |> render_click()
    refute has_element?(lv, "a", "Print(")
  end
end
