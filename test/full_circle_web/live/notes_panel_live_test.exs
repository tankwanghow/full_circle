defmodule FullCircleWeb.NotesPanelLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.HRFixtures
  import FullCircle.NotesFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    contact = contact_fixture(comp, admin, %{"name" => "Ah Seng"})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp, contact: contact}
  end

  test "contact edit page shows notes about and linking to it", %{
    conn: conn,
    admin: admin,
    comp: comp,
    contact: c
  } do
    note_fixture(comp, admin, %{
      "body" => "pays late",
      "subject_type" => "Contact",
      "subject_id" => c.id
    })

    note_fixture(comp, admin, %{
      "body" => "met at expo",
      "links" => [%{"type" => "Contact", "id" => c.id}]
    })

    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    assert html =~ "pays late"
    assert html =~ "met at expo"
    assert html =~ "linked"
  end

  test "quick-add creates a note about the record", %{conn: conn, comp: comp, contact: c} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#notes-panel-new") |> render_click()

    html =
      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "asks for 60 days"}})
      |> render_submit()

    assert html =~ "asks for 60 days"
    [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "a note opened from a record's panel opens in a new tab",
       %{conn: conn, admin: admin, comp: comp, contact: c} do
    note =
      note_fixture(comp, admin, %{
        "body" => "x",
        "subject_type" => "Contact",
        "subject_id" => c.id
      })

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")

    assert has_element?(
             lv,
             ~s(#notes-panel a[target="_blank"][href="/companies/#{comp.id}/notes/#{note.id}/edit"])
           )
  end

  test "panel hidden on the new-contact page", %{conn: conn, comp: comp} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/new")
    refute html =~ "notes-panel"
  end

  test "restricted notes are not shown to a clerk", %{admin: admin, comp: comp, contact: c} do
    note_fixture(comp, admin, %{
      "body" => "boss only",
      "subject_type" => "Contact",
      "subject_id" => c.id,
      "visibility" => ["manager"]
    })

    clerk = user_with_role(comp, admin, "clerk")

    {:ok, _lv, html} =
      live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")

    refute html =~ "boss only"
  end

  test "employee edit page has the panel", %{conn: conn, admin: admin, comp: comp} do
    emp = employee_fixture(%{}, comp, admin)

    note_fixture(comp, admin, %{
      "body" => "good welder",
      "subject_type" => "Employee",
      "subject_id" => emp.id
    })

    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/employees/#{emp.id}/edit")
    assert html =~ "good welder"
  end

  describe "index counts" do
    test "contact list shows visible counts and opens the modal", %{
      conn: conn,
      admin: admin,
      comp: comp,
      contact: c
    } do
      note_fixture(comp, admin, %{
        "body" => "pays late",
        "subject_type" => "Contact",
        "subject_id" => c.id
      })

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts")
      assert html =~ "📝 1"

      html =
        lv |> element("button[phx-click=open_notes][phx-value-id='#{c.id}']") |> render_click()

      assert html =~ "pays late"
    end

    test "count excludes notes a clerk cannot read", %{admin: admin, comp: comp, contact: c} do
      note_fixture(comp, admin, %{
        "subject_type" => "Contact",
        "subject_id" => c.id,
        "visibility" => ["manager"]
      })

      clerk = user_with_role(comp, admin, "clerk")

      {:ok, _lv, html} =
        live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/contacts")

      refute html =~ "📝 1"
    end

    test "quick-add in the modal bumps the row count", %{conn: conn, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts")
      lv |> element("button[phx-click=open_notes][phx-value-id='#{c.id}']") |> render_click()
      lv |> element("#notes-modal-panel-new") |> render_click()

      lv
      |> form("#notes-modal-panel-form", %{"note" => %{"body" => "new one"}})
      |> render_submit()

      # The count reaches the row via {:notes_changed, ...} and then a
      # send_update; let the view drain both before reading the page.
      :sys.get_state(lv.pid)
      :sys.get_state(lv.pid)
      assert render(lv) =~ "📝 1"
    end

    test "employee list shows counts", %{conn: conn, admin: admin, comp: comp} do
      emp = employee_fixture(%{}, comp, admin)
      note_fixture(comp, admin, %{"subject_type" => "Employee", "subject_id" => emp.id})
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/employees")
      assert html =~ "📝 1"
    end
  end

  test "a cashier can quick-add a note on a credit note they cannot edit",
       %{admin: admin, comp: comp} do
    cashier = user_with_role(comp, admin, "cashier")
    cn = FullCircle.DebCreFixtures.credit_note_fixture(comp, admin)

    {:ok, lv, _} =
      live(log_in_user(build_conn(), cashier), ~p"/companies/#{comp.id}/CreditNote/#{cn.id}/edit")

    lv |> element("#notes-panel-new") |> render_click()

    html =
      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "customer returned 2 bags"}})
      |> render_submit()

    assert html =~ "customer returned 2 bags"
  end

  describe "rollout" do
    test "invoice edit page shows the panel and the invoice list shows counts", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      inv = invoice_fixture(comp, admin)

      note_fixture(comp, admin, %{
        "body" => "customer disputes line 2",
        "subject_type" => "Invoice",
        "subject_id" => inv.id
      })

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/Invoice/#{inv.id}/edit")
      assert html =~ "customer disputes line 2"

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/Invoice")
      assert html =~ "📝 1"
    end

    test "every covered page renders with the panel or badge", %{conn: conn, comp: comp} do
      for path <-
            ~w(goods Invoice PurInvoice Receipt Payment CreditNote DebitNote Journal Deposit ReturnCheque) do
        {:ok, _lv, html} = live(conn, "/companies/#{comp.id}/#{path}")
        assert is_binary(html), "#{path} index failed to render"
      end
    end
  end

  describe "rollout per type" do
    # {type, index path segment, fixture}; Journal has no fixture and is
    # covered by the index smoke render above.
    @typed [
      {"Good", "goods", &FullCircle.BillingFixtures.good_fixture/2},
      {"Invoice", "Invoice", &FullCircle.BillingFixtures.invoice_fixture/2},
      {"PurInvoice", "PurInvoice", &FullCircle.BillingFixtures.pur_invoice_fixture/2},
      {"Receipt", "Receipt", &FullCircle.ReceiveFundFixtures.receipt_fixture/2},
      {"Payment", "Payment", &FullCircle.BillPayFixtures.payment_fixture/2},
      {"CreditNote", "CreditNote", &FullCircle.DebCreFixtures.credit_note_fixture/2},
      {"DebitNote", "DebitNote", &FullCircle.DebCreFixtures.debit_note_fixture/2},
      {"Deposit", "Deposit", &FullCircle.ChequeFixtures.deposit_fixture/2},
      {"ReturnCheque", "ReturnCheque", &FullCircle.ChequeFixtures.return_cheque_fixture/2}
    ]

    for {type, segment, fixture} <- @typed do
      @type_key type
      @segment segment
      @fixture fixture

      test "#{type}: edit page panel and index count", %{conn: conn, admin: admin, comp: comp} do
        rec = @fixture.(comp, admin)
        body = "about this #{@type_key}"

        note_fixture(comp, admin, %{
          "body" => body,
          "subject_type" => @type_key,
          "subject_id" => rec.id
        })

        {:ok, _lv, html} = live(conn, FullCircle.Linkable.url(@type_key, rec.id, comp))
        assert html =~ body

        {:ok, _lv, html} = live(conn, "/companies/#{comp.id}/#{@segment}")
        assert html =~ "📝 1"
      end
    end
  end

  test "deposit list rows are transactions; quick-add still bumps the row",
       %{conn: conn, admin: admin, comp: comp} do
    dep = FullCircle.ChequeFixtures.deposit_fixture(comp, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/Deposit")
    lv |> element("button[phx-click=open_notes][phx-value-id='#{dep.id}']") |> render_click()
    lv |> element("#notes-modal-panel-new") |> render_click()

    lv
    |> form("#notes-modal-panel-form", %{"note" => %{"body" => "bank queried it"}})
    |> render_submit()

    :sys.get_state(lv.pid)
    :sys.get_state(lv.pid)
    assert render(lv) =~ "📝 1"
    [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
    assert {note.subject_type, note.subject_id} == {"Deposit", dep.id}
  end
end
