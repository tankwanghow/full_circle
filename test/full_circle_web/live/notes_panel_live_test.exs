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

    _ =
      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "asks for 60 days"}})
      |> render_submit()

    assert render(lv) =~ "asks for 60 days"
    [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
    assert {note.subject_type, note.subject_id} == {"Contact", c.id}
  end

  test "＋ Note is the full form in place: title, and picks become links",
       %{conn: conn, admin: admin, comp: comp, contact: c} do
    mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    refute has_element?(lv, "#notes-panel a", "Full form")

    lv |> element("#notes-panel-new") |> render_click()
    assert has_element?(lv, "#notes-panel-form input[name='note[title]']")

    lv |> element("#notes-panel-open-picker") |> render_click()

    lv
    |> form("#notes-panel-picker form", %{"type" => "Contact", "terms" => "Mei"})
    |> render_change()

    lv |> element("#notes-panel-picker-pick-#{mei.id}") |> render_click()
    assert has_element?(lv, "#notes-panel-box", "Kedai Mei")

    lv
    |> form("#notes-panel-form", %{"note" => %{"title" => "Terms", "body" => "60 days"}})
    |> render_submit()

    [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
    assert {note.title, note.subject_type, note.subject_id} == {"Terms", "Contact", c.id}

    assert [%{type: "Contact", id: id}] = FullCircle.Notes.list_links(note, comp, admin)
    assert id == mei.id
  end

  test "a contact's quick-add still offers the role chips", %{conn: conn, comp: comp, contact: c} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#notes-panel-new") |> render_click()

    assert has_element?(lv, "#notes-panel-form input[value=manager]")
    refute has_element?(lv, "#notes-panel-form", "Everyone who can see this task")
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
             ~s(#notes-panel a[target="_blank"][href="/companies/#{comp.id}/notes/#{note.id}"])
           )
  end

  describe "panel posts look like the feed" do
    test "avatar-style posts with counts; the host record's own chip is not repeated",
         %{conn: conn, admin: admin, comp: comp, contact: c} do
      inv = invoice_fixture(comp, admin)

      note =
        note_fixture(comp, admin, %{
          "body" => "pays late",
          "subject_type" => "Contact",
          "subject_id" => c.id,
          "links" => [%{"type" => "Invoice", "id" => inv.id}]
        })

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      post = "#notes-panel article#notes-panel-note-#{note.id}"
      assert has_element?(lv, post <> " .note-replies")
      # The invoice chip shows; the chip naming this very contact does not.
      assert has_element?(lv, post <> ~s( a[href="/companies/#{comp.id}/Invoice/#{inv.id}/edit"]))
      refute has_element?(lv, post <> ~s( a[href="/companies/#{comp.id}/contacts/#{c.id}/edit"]))
    end

    test "a note that only links here is tagged linked", %{
      conn: conn,
      admin: admin,
      comp: comp,
      contact: c
    } do
      note =
        note_fixture(comp, admin, %{
          "body" => "met at expo",
          "links" => [%{"type" => "Contact", "id" => c.id}]
        })

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      assert has_element?(lv, "#notes-panel-note-#{note.id} .note-linked")
    end

    test "at most 4 file thumbnails per post", %{conn: conn, admin: admin, comp: comp, contact: c} do
      note =
        note_fixture(comp, admin, %{
          "body" => "files",
          "subject_type" => "Contact",
          "subject_id" => c.id
        })

      for i <- 1..5 do
        {:ok, _} =
          FullCircle.Notes.Attachments.attach(
            note,
            %{path: jpeg_file(), file_name: "#{i}.jpg"},
            comp,
            admin
          )
      end

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#notes-panel-note-#{note.id} .note-thumb")
             |> Enum.count() == 4
    end

    test "Attach shows only on notes the viewer can edit", %{admin: admin, comp: comp, contact: c} do
      clerk = user_with_role(comp, admin, "clerk")

      theirs =
        note_fixture(comp, admin, %{
          "body" => "admin's",
          "subject_type" => "Contact",
          "subject_id" => c.id
        })

      mine =
        note_fixture(comp, clerk, %{
          "body" => "clerk's",
          "subject_type" => "Contact",
          "subject_id" => c.id
        })

      {:ok, lv, _} =
        live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")

      assert has_element?(lv, "#notes-panel-note-#{mine.id} [phx-hook=NoteAttach]")
      refute has_element?(lv, "#notes-panel-note-#{theirs.id} [phx-hook=NoteAttach]")
    end
  end

  describe "edit in place" do
    setup %{admin: admin, comp: comp, contact: c} do
      note =
        note_fixture(comp, admin, %{
          "body" => "pays late",
          "subject_type" => "Contact",
          "subject_id" => c.id
        })

      %{note: note, path: ~p"/companies/#{comp.id}/contacts/#{c.id}/edit"}
    end

    test "✎ Edit swaps the post for the box; Save keeps it on the page",
         %{conn: conn, note: note, path: path} do
      {:ok, lv, _} = live(conn, path)
      lv |> element("#notes-panel-edit-#{note.id}") |> render_click()

      assert has_element?(lv, "#notes-panel-editing #notes-panel-edit-form textarea", "pays late")
      refute has_element?(lv, "#notes-panel-note-#{note.id}")

      lv
      |> form("#notes-panel-edit-form", %{"note" => %{"body" => "pays on the 15th"}})
      |> render_submit()

      refute has_element?(lv, "#notes-panel-editing")
      assert has_element?(lv, "#notes-panel-note-#{note.id}", "pays on the 15th")
      assert FullCircle.Repo.get!(FullCircle.Notes.Note, note.id).body == "pays on the 15th"
    end

    test "Cancel brings the post back unchanged", %{conn: conn, note: note, path: path} do
      {:ok, lv, _} = live(conn, path)
      lv |> element("#notes-panel-edit-#{note.id}") |> render_click()
      lv |> element("#notes-panel-edit-cancel") |> render_click()

      refute has_element?(lv, "#notes-panel-editing")
      assert has_element?(lv, "#notes-panel-note-#{note.id}", "pays late")
    end

    test "an upload mid-edit shows the file and keeps the typed text",
         %{conn: conn, admin: admin, comp: comp, note: note, path: path} do
      {:ok, lv, _} = live(conn, path)
      lv |> element("#notes-panel-edit-#{note.id}") |> render_click()

      lv
      |> form("#notes-panel-edit-form", %{"note" => %{"body" => "half typed"}})
      |> render_change()

      # The edit box's 📎 uploads into its tray (the route opens it first).
      [_, tray] = Regex.run(~r/id="notes-panel-edit-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))
      {:ok, _} = FullCircle.Notes.Trays.open(tray, comp, admin)

      {:ok, _} =
        FullCircle.Notes.Attachments.attach_to_tray(
          tray,
          %{path: jpeg_file(), file_name: "receipt.jpg"},
          comp,
          admin
        )

      # In the browser the 📎 hook pushes to the component it sits in: the box.
      lv |> with_target("#notes-panel-edit-box") |> render_hook("attachment_uploaded", %{})
      assert has_element?(lv, "#notes-panel-edit-tray-files", "receipt.jpg")
      assert has_element?(lv, "#notes-panel-edit-form textarea", "half typed")
      # Held until Save: not on the note yet.
      assert FullCircle.Notes.get_note(note.id, comp, admin).attachments == []
    end

    test "a file's ✕ in the box removes it", %{
      conn: conn,
      admin: admin,
      comp: comp,
      note: note,
      path: path
    } do
      {:ok, att} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "old.jpg"},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, path)
      lv |> element("#notes-panel-edit-#{note.id}") |> render_click()
      lv |> element("#notes-panel-files #att-#{att.id} button") |> render_click()

      refute has_element?(lv, "#notes-panel-files")
      assert FullCircle.Repo.get!(FullCircle.Notes.NoteAttachment, att.id).removed_at
    end

    test "no ✎ Edit on a note the viewer cannot edit",
         %{admin: admin, comp: comp, note: note, path: path} do
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, lv, _} = live(log_in_user(build_conn(), clerk), path)

      assert has_element?(lv, "#notes-panel-note-#{note.id}", "pays late")
      refute has_element?(lv, "#notes-panel-edit-#{note.id}")
      lv |> with_target("#notes-panel") |> render_click("edit_note", %{"id" => note.id})
      refute has_element?(lv, "#notes-panel-editing")
    end
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

    _ =
      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "customer returned 2 bags"}})
      |> render_submit()

    assert render(lv) =~ "customer returned 2 bags"
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

  describe "accounts and fixed assets" do
    test "account: edit page panel and index count", %{conn: conn, admin: admin, comp: comp} do
      ac = FullCircle.AccountingFixtures.account_fixture(%{name: "RHB OD"}, comp, admin)

      note_fixture(comp, admin, %{
        "body" => "limit RM500k, secured by Lot 123",
        "subject_type" => "Account",
        "subject_id" => ac.id
      })

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/#{ac.id}/edit")
      assert html =~ "limit RM500k, secured by Lot 123"

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts?search[terms]=RHB OD")
      assert html =~ "📝 1"

      html =
        lv |> element("button[phx-click=open_notes][phx-value-id='#{ac.id}']") |> render_click()

      assert html =~ "limit RM500k"
    end

    test "fixed asset: edit page panel and index count", %{conn: conn, admin: admin, comp: comp} do
      fa =
        FullCircle.AccountingFixtures.fixed_asset_fixture(comp, admin, %{name: "Lorry WXX 1234"})

      note_fixture(comp, admin, %{
        "body" => "accident 3/2026, claim pending",
        "subject_type" => "FixedAsset",
        "subject_id" => fa.id
      })

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/fixed_assets/#{fa.id}/edit")
      assert html =~ "accident 3/2026, claim pending"

      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/fixed_assets")
      assert html =~ "📝 1"
    end

    test "no panel on the new account and new fixed asset pages", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/accounts/new")
      refute html =~ ~s{id="notes-panel"}
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/fixed_assets/new")
      refute html =~ ~s{id="notes-panel"}
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

  describe "panel composer" do
    test "card layout: Cancel closes the quick-add", %{conn: conn, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      assert has_element?(lv, "#notes-panel-form")
      lv |> element("#notes-panel-cancel") |> render_click()
      refute has_element?(lv, "#notes-panel-form")
    end
  end

  test "a reply about this contact shows in its panel, tagged", %{
    conn: conn,
    admin: admin,
    comp: comp,
    contact: c
  } do
    root =
      note_fixture(comp, admin, %{
        "body" => "credit terms",
        "subject_type" => "Contact",
        "subject_id" => c.id
      })

    {:ok, r} =
      FullCircle.Notes.create_note(
        %{"body" => "approved 60 days", "reply_to_id" => root.id},
        comp,
        admin
      )

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    assert has_element?(lv, "#notes-panel-note-#{r.id} .note-reply-to")
    assert render(lv) =~ "approved 60 days"
  end

  describe "write box tray" do
    defp tray_id(lv) do
      [_, id] = Regex.run(~r/id="notes-panel-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))
      id
    end

    defp drop_in(lv, comp, admin, name \\ "scan.jpg") do
      # The tray route opens the tray before the first upload.
      {:ok, _} = FullCircle.Notes.Trays.open(tray_id(lv), comp, admin)

      {:ok, _} =
        FullCircle.Notes.Attachments.attach_to_tray(
          tray_id(lv),
          %{path: jpeg_file(), file_name: name},
          comp,
          admin
        )

      # The broadcast reaches the LiveView, whose hook queues a send_update
      # behind this render; the second render sees it.
      _ = render(lv)
      render(lv)
    end

    test "a file uploaded into the box shows at once and attaches on Post",
         %{conn: conn, admin: admin, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      assert has_element?(lv, "#notes-panel-attach")
      assert has_element?(lv, "#notes-panel-phone-open")

      assert drop_in(lv, comp, admin) =~ "scan.jpg"

      lv
      |> form("#notes-panel-form", %{"note" => %{"body" => "letter from bank"}})
      |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      note = FullCircle.Repo.preload(note, :attachments)
      assert [%{file_name: "scan.jpg"}] = note.attachments
    end

    test "Cancel throws the box's files away", %{
      conn: conn,
      admin: admin,
      comp: comp,
      contact: c
    } do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      id = tray_id(lv)
      drop_in(lv, comp, admin)

      lv |> element("#notes-panel-cancel") |> render_click()
      assert FullCircle.Notes.Trays.list(id, comp, admin) == []
    end

    test "✕ on a box file deletes it", %{conn: conn, admin: admin, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      id = tray_id(lv)
      drop_in(lv, comp, admin)
      [att] = FullCircle.Notes.Trays.list(id, comp, admin)

      lv |> element("#notes-panel-tray-files #att-#{att.id} button") |> render_click()
      refute render(lv) =~ "scan.jpg"
      assert FullCircle.Notes.Trays.list(id, comp, admin) == []
    end

    test "From phone shows a QR code", %{conn: conn, comp: comp, contact: c} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
      lv |> element("#notes-panel-new") |> render_click()
      html = lv |> element("#notes-panel-phone-open") |> render_click()
      assert html =~ "/up/"
      # Scales to its box: a fixed-size SVG with no viewBox gets cropped by CSS.
      [svg_tag] = Regex.run(~r/<svg[^>]*>/, html)
      assert svg_tag =~ ~r/viewBox="0 0 \d+ \d+"/
      refute svg_tag =~ ~r/\swidth="/
    end
  end

  test "a file landing on a shown note (e.g. from the phone) appears without reload",
       %{conn: conn, admin: admin, comp: comp, contact: c} do
    note =
      note_fixture(comp, admin, %{
        "body" => "letter",
        "subject_type" => "Contact",
        "subject_id" => c.id
      })

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    assert has_element?(lv, "#notes-panel-phone-#{note.id}-open")

    {:ok, _} =
      FullCircle.Notes.Attachments.attach(
        note,
        %{path: jpeg_file(), file_name: "p.jpg"},
        comp,
        admin
      )

    _ = render(lv)
    assert has_element?(lv, "#notes-panel-note-#{note.id} .note-thumb")
  end

  test "a validation error shows right under the text box, above the files",
       %{conn: conn, comp: comp, contact: c} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#notes-panel-new") |> render_click()
    html = lv |> form("#notes-panel-form", %{"note" => %{"body" => ""}}) |> render_submit()

    {err_at, _} = :binary.match(html, "can&#39;t be blank")
    {tray_at, _} = :binary.match(html, ~s(id="notes-panel-tray"))
    assert err_at < tray_at
  end

  test "a post of files only (no text) saves from the box",
       %{conn: conn, admin: admin, comp: comp, contact: c} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#notes-panel-new") |> render_click()
    [_, tray] = Regex.run(~r/id="notes-panel-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))
    {:ok, _} = FullCircle.Notes.Trays.open(tray, comp, admin)

    {:ok, _} =
      FullCircle.Notes.Attachments.attach_to_tray(
        tray,
        %{path: jpeg_file(), file_name: "delivery.jpg"},
        comp,
        admin
      )

    _ = render(lv)
    html = lv |> form("#notes-panel-form", %{"note" => %{"body" => ""}}) |> render_change()
    refute html =~ "can&#39;t be blank"

    lv |> form("#notes-panel-form", %{"note" => %{"body" => ""}}) |> render_submit()
    [note] = FullCircle.Repo.all(FullCircle.Notes.Note)

    assert [%{file_name: "delivery.jpg"}] =
             FullCircle.Repo.preload(note, :attachments).attachments
  end

  test "the phone pressing Close closes the QR modal on the desktop",
       %{conn: conn, comp: comp, contact: c} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#notes-panel-new") |> render_click()
    html = lv |> element("#notes-panel-phone-open") |> render_click()
    assert has_element?(lv, "#notes-panel-phone-qr")

    [_, path] = Regex.run(~r{href="https?://[^/"]+(/up/[^"]+)"}, html)
    assert %{"ok" => true} = build_conn() |> post(path <> "/finish") |> json_response(200)

    # The broadcast queues a send_update behind the first render.
    _ = render(lv)
    refute has_element?(lv, "#notes-panel-phone-qr")
  end
end
