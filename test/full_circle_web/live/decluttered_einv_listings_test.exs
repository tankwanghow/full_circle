defmodule FullCircleWeb.DeclutteredEInvListingsTest do
  # The five e-invoice document listings share the decluttered layout:
  # one line per document, an e-Invoice status chip, a details expander.
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest

  import FullCircle.BillingFixtures
  import FullCircle.ReceiveFundFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.DebCreFixtures

  setup %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    %{conn: log_in_user(conn, admin), admin: admin, company: company}
  end

  @pages [
    {"PurInvoice", :pur_invoice_no, "Not received"},
    {"Receipt", :receipt_no, "Not sent"},
    {"Payment", :payment_no, "Not sent"},
    {"CreditNote", :note_no, "Not sent"},
    {"DebitNote", :note_no, "Not sent"}
  ]

  defp make("PurInvoice", c, u), do: pur_invoice_fixture(c, u)
  defp make("Receipt", c, u), do: receipt_fixture(c, u)
  defp make("Payment", c, u), do: payment_fixture(c, u)
  defp make("CreditNote", c, u), do: credit_note_fixture(c, u)
  defp make("DebitNote", c, u), do: debit_note_fixture(c, u)

  for {route, no_field, none_label} <- @pages do
    @route route
    @no_field no_field
    @none_label none_label

    describe "#{route} listing" do
      test "one line per document with a status chip and details expander", %{
        conn: conn,
        admin: admin,
        company: company
      } do
        doc = make(@route, company, admin)
        row = "#objects-#{doc.id}"

        {:ok, lv, html} = live(conn, "/companies/#{company.id}/#{@route}")

        # Old split layout is gone
        refute html =~ "UUD/ InternalId"
        refute has_element?(lv, "[phx-viewport-bottom]")

        assert has_element?(lv, "#{row} a", Map.fetch!(doc, @no_field))
        assert has_element?(lv, row, @none_label)

        lv |> element("#{row} [phx-click=toggle_einv]") |> render_click()
        assert has_element?(lv, row, "No e-invoice found")
      end
    end
  end
end
