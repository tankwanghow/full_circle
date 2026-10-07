defmodule FullCircleWeb.PurInvoiceReceiptCaptureLiveTest do
  use FullCircleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.{Accounting, Billing, Repo, Sys}
  alias FullCircle.Notes.{Attachments, Note, Trays}

  @reply %{
    "recognized" => true,
    "summary" => "Supplier bill",
    "supplier" => %{"name" => "Ansonfarm Engineering", "tin" => "C5550001112"},
    "doc_no" => "INV-778",
    "date" => Date.to_iso8601(Date.utc_today()),
    "lines" => [
      %{"description" => "MOTOR 2HP", "quantity" => 1, "unit_price" => 850, "amount" => 850}
    ],
    "total" => 850
  }

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})

    {:ok, company} =
      Sys.update_company_settings(company, "llm_receipt", %{
        "llm-provider" => "claude",
        "llm-api-key" => "k"
      })

    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn _u, _h, _b, _t ->
      send(test_pid, :llm_called)

      {:ok,
       %{
         "content" => [%{"text" => Jason.encode!(@reply)}],
         "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
       }}
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp drop_photo(lv, c, u) do
    [_, id] = Regex.run(~r/id="receipt-box"[^>]*data-tray-id="([^"]+)"/, render(lv))
    {:ok, _} = Trays.open(id, c, u)

    {:ok, _} =
      Attachments.attach_to_tray(id, %{path: real_jpeg_file(:rgb), file_name: "bill.jpg"}, c, u)

    render(lv)
    render_async(lv)
  end

  defp value(lv, id),
    do:
      lv
      |> element("##{id}")
      |> render()
      |> then(&Regex.run(~r/value="([^"]*)"/, &1))
      |> List.last()

  test "bill no goes to the supplier ref field, lines fill the blank line", %{
    conn: conn,
    user: u,
    company: c
  } do
    contact = contact_fixture(c, u, %{"tax_id" => "C5550001112"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/PurInvoice/new")
    html = drop_photo(lv, c, u)

    assert value(lv, "pur_invoice_contact_id") == contact.id
    assert value(lv, "pur_invoice_e_inv_internal_id") == "INV-778"
    assert value(lv, "pur_invoice_pur_invoice_no") == "...new..."
    assert html =~ "MOTOR 2HP"
  end

  test "save attaches the bill as a note on the purchase invoice", %{
    conn: conn,
    user: u,
    company: c
  } do
    contact = contact_fixture(c, u, %{"tax_id" => "C5550001112"})
    good = good_fixture(c, u, %{"name" => "Motor"})
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^c.id and t.code == "NoPTax"
      )

    {:ok, _} =
      Billing.create_pur_invoice(
        pur_invoice_attrs(contact, good, pur_acct, tc, tax_rate: "0"),
        c,
        u
      )

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/PurInvoice/new")
    drop_photo(lv, c, u)
    {:ok, _, _} = lv |> form("#object-form") |> render_submit() |> follow_redirect(conn)

    note = Repo.one!(from n in Note, where: n.subject_type == "PurInvoice", preload: :attachments)
    assert note.title == "🧾 Receipt"
    assert [%{file_name: "bill.jpg"}] = note.attachments
  end
end
