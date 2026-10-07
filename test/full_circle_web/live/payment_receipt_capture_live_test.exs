defmodule FullCircleWeb.PaymentReceiptCaptureLiveTest do
  use FullCircleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.{Accounting, Billing, Repo, Sys}
  alias FullCircle.Notes.{Attachments, Note, Trays}

  @reply %{
    "recognized" => true,
    "summary" => "Hardware receipt",
    "supplier" => %{"name" => "Kedai Ali Hardware", "tin" => "C2345678901"},
    "doc_no" => "A12345",
    "date" => Date.to_iso8601(Date.utc_today()),
    "lines" => [
      %{"description" => "PVC PIPE", "quantity" => 4, "unit_price" => 12.5, "amount" => 50}
    ],
    "tax_total" => nil,
    "rounding" => nil,
    "total" => 50,
    "payment_method" => "cash"
  }

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})

    {:ok, company} =
      Sys.update_company_settings(company, "llm_receipt", %{
        "llm-provider" => "claude",
        "llm-api-key" => "k"
      })

    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp stub(reply) do
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn _u, _h, _b, _t ->
      send(test_pid, :llm_called)

      {:ok,
       %{
         "content" => [%{"text" => Jason.encode!(reply)}],
         "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
       }}
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
  end

  defp tray_id(lv) do
    [_, id] = Regex.run(~r/id="receipt-box"[^>]*data-tray-id="([^"]+)"/, render(lv))
    id
  end

  defp drop_photo(lv, company, user) do
    id = tray_id(lv)
    {:ok, _} = Trays.open(id, company, user)

    {:ok, _} =
      Attachments.attach_to_tray(
        id,
        %{path: real_jpeg_file(:rgb), file_name: "r.jpg"},
        company,
        user
      )

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

  test "a photo is read and fills the empty fields", %{conn: conn, user: u, company: c} do
    stub(@reply)
    contact = contact_fixture(c, u, %{"name" => "Kedai Ali Hdw", "tax_id" => "C2345678901"})
    cash = account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")

    html = drop_photo(lv, c, u)

    assert html =~ "Kedai Ali Hardware"
    assert value(lv, "payment_contact_id") == contact.id
    assert value(lv, "payment_funds_account_id") == cash.id
    assert value(lv, "payment_funds_amount") =~ "50"
    assert value(lv, "payment_descriptions") == "Kedai Ali Hardware #A12345"
    assert html =~ "PVC PIPE"
  end

  test "typed values survive; a second file does not re-read", %{conn: conn, user: u, company: c} do
    stub(@reply)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    lv |> form("#object-form", payment: %{"descriptions" => "petty cash Oct"}) |> render_change()

    drop_photo(lv, c, u)
    assert value(lv, "payment_descriptions") == "petty cash Oct"
    assert_received :llm_called

    {:ok, _} =
      Attachments.attach_to_tray(
        tray_id(lv),
        %{path: real_jpeg_file(:gray), file_name: "b.jpg"},
        c,
        u
      )

    render(lv)
    render_async(lv)
    refute_received :llm_called
  end

  test "↻ Read again keeps keyed lines", %{conn: conn, user: u, company: c} do
    stub(@reply)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    drop_photo(lv, c, u)

    lv
    |> form("#object-form",
      payment: %{
        "payment_details" => %{
          "0" => %{"descriptions" => "EDITED", "quantity" => "4", "unit_price" => "12.5"}
        }
      }
    )
    |> render_change()

    lv |> element("#receipt-read-again") |> render_click()
    html = render_async(lv)
    assert html =~ "EDITED"
  end

  test "not recognised: summary into descriptions", %{conn: conn, user: u, company: c} do
    stub(%{"recognized" => false, "summary" => "Photo of a cheque"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    html = drop_photo(lv, c, u)
    assert value(lv, "payment_descriptions") == "Photo of a cheque"
    assert html =~ "Not recognised"
  end

  test "AI off: the file still attaches, strip says so", %{conn: conn, user: u, company: c} do
    {:ok, _} = Sys.update_company_settings(c, "llm_receipt", %{"llm-provider" => "none"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    html = drop_photo(lv, c, u)
    assert html =~ "AI reading off"
    assert html =~ "r.jpg"
  end

  test "save attaches the receipt as a note on the payment", %{conn: conn, user: u, company: c} do
    stub(@reply)
    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)
    good = good_fixture(c, u, %{"name" => "PVC Pipe"})
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

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    drop_photo(lv, c, u)

    {:ok, _, _} = lv |> form("#object-form") |> render_submit() |> follow_redirect(conn)

    note = Repo.one!(from n in Note, where: n.subject_type == "Payment", preload: :attachments)
    assert note.title == "🧾 Receipt"
    assert [_] = note.attachments
  end

  test "a closed-period save keeps the tray for a re-save", %{conn: conn, user: u, company: c} do
    stub(%{@reply | "date" => Date.to_iso8601(Date.add(Date.utc_today(), -10))})
    {:ok, _} = Sys.close_period_through(c, Date.add(Date.utc_today(), -1), u)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    html = drop_photo(lv, c, u)
    assert html =~ "closed accounting period"

    lv |> form("#object-form") |> render_submit()
    assert Trays.has_files?(tray_id(lv), c, u)
    assert Repo.aggregate(Note, :count) == 0
  end

  test "changing the supplier re-checks duplicates", %{conn: conn, user: u, company: c} do
    stub(@reply)
    other = contact_fixture(c, u)
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^c.id and t.code == "NoPTax"
      )

    {:ok, %{create_payment: pv}} =
      FullCircle.BillPay.create_payment(
        FullCircle.BillPayFixtures.payment_attrs(
          other,
          good,
          pur_acct,
          tc,
          FullCircle.BillPayFixtures.pay_funds_account_fixture(c, u),
          tax_rate: "0",
          quantity: "1",
          unit_price: "50.00",
          funds_amount: "50.00"
        ),
        c,
        u
      )

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    refute drop_photo(lv, c, u) =~ "Possible duplicate"

    html =
      render_change(lv, "validate", %{
        "payment" => %{
          "contact_name" => other.name,
          "contact_id" => other.id,
          "payment_date" => Date.to_iso8601(Date.utc_today()),
          "funds_amount" => "50.00"
        }
      })

    assert html =~ "Possible duplicate"
    assert html =~ pv.payment_no
  end

  test "duplicate is checked against the clerk's contact after the read merges", %{
    conn: conn,
    user: u,
    company: c
  } do
    stub(%{@reply | "supplier" => %{"name" => "Unknown Shop", "tin" => "C000"}})
    picked = contact_fixture(c, u)
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^c.id and t.code == "NoPTax"
      )

    {:ok, %{create_payment: pv}} =
      FullCircle.BillPay.create_payment(
        FullCircle.BillPayFixtures.payment_attrs(
          picked,
          good,
          pur_acct,
          tc,
          FullCircle.BillPayFixtures.pay_funds_account_fixture(c, u),
          tax_rate: "0",
          quantity: "1",
          unit_price: "50.00",
          funds_amount: "50.00"
        ),
        c,
        u
      )

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")

    render_change(lv, "validate", %{
      "payment" => %{"contact_name" => picked.name, "contact_id" => picked.id}
    })

    html = drop_photo(lv, c, u)
    assert value(lv, "payment_contact_id") == picked.id
    assert html =~ pv.payment_no
  end
end
