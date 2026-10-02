defmodule FullCircleWeb.NoteLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp}
  end

  describe "index" do
    test "lists visible notes and searches", %{conn: conn, admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"title" => "Welding", "body" => "Ali welds"})
      note_fixture(comp, admin, %{"body" => "Ah Seng pays late"})

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes")
      assert html =~ "Welding"
      assert html =~ "Ah Seng pays late"

      lv |> form("#search-form", %{"search" => %{"terms" => "weld"}}) |> render_submit()
      assert_patch(lv)
      html = render(lv)
      assert html =~ "Welding"
      refute html =~ "Ah Seng pays late"
    end

    test "restricted notes are not listed for a clerk", %{admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"body" => "manager only", "visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, _lv, html} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes")
      refute html =~ "manager only"
    end

    test "feed chips open records in a new tab; the post opens in the same tab",
         %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      note =
        note_fixture(comp, admin, %{
          "body" => "visit",
          "subject_type" => "Contact",
          "subject_id" => c.id
        })

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")

      assert has_element?(
               lv,
               ~s(#notes-#{note.id} a[target="_blank"][href="/companies/#{comp.id}/contacts/#{c.id}/edit"])
             )

      refute has_element?(
               lv,
               ~s(#notes-#{note.id} a[target="_blank"][href="/companies/#{comp.id}/notes/#{note.id}"])
             )

      assert has_element?(
               lv,
               ~s(#notes-#{note.id} a[href="/companies/#{comp.id}/notes/#{note.id}"])
             )
    end

    test "a private note's badge says Private", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "p", "visibility" => ["admin"]})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")
      assert has_element?(lv, "#notes-#{note.id}", "Private")
      refute has_element?(lv, "#notes-#{note.id}", "🔒 admin")
    end

    test "a title shows in bold above the text", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"title" => "Year-end stock count", "body" => "Steps..."})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")
      assert has_element?(lv, "#notes-#{note.id} .note-title", "Year-end stock count")
    end

    test "the post box creates a note at the top of the feed", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")

      lv
      |> form("#compose-form", %{"note" => %{"body" => "Gate 2 lock is broken"}})
      |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      assert has_element?(lv, "#notes-#{note.id}", "Gate 2 lock is broken")
      # The box is cleared for the next note.
      refute has_element?(lv, "#compose-form textarea", "Gate 2 lock is broken")
    end

    test "the post box can set what the note is about", %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")

      lv |> element("#compose-open-picker") |> render_click()

      lv
      |> form("#compose-picker form", %{"type" => "Contact", "terms" => "Mei"})
      |> render_change()

      lv |> element("#compose-picker-pick-#{c.id}") |> render_click()
      assert render(lv) =~ "Kedai Mei"

      lv
      |> form("#compose-form", %{"note" => %{"body" => "orders every Monday"}})
      |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      assert {note.subject_type, note.subject_id} == {"Contact", c.id}
    end

    test "each post shows replies, links and files counts", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      c = contact_fixture(comp, admin)

      note =
        note_fixture(comp, admin, %{
          "body" => "root",
          "links" => [%{"type" => "Contact", "id" => c.id}]
        })

      note_fixture(comp, admin, %{
        "body" => "follow-up",
        "subject_type" => "Note",
        "subject_id" => note.id
      })

      {:ok, _} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "a.jpg"},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")
      assert has_element?(lv, "#notes-#{note.id} .note-replies", "1")
      assert has_element?(lv, "#notes-#{note.id} .note-links", "1")
      assert has_element?(lv, "#notes-#{note.id} .note-files", "1")
    end

    test "a post shows at most 4 file thumbnails, PDFs included, then +n more",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "five files"})

      for {path, name} <- [
            {jpeg_file(), "1.jpg"},
            {pdf_file(), "2.pdf"},
            {jpeg_file(), "3.jpg"},
            {pdf_file(), "4.pdf"},
            {jpeg_file(), "5.jpg"}
          ] do
        {:ok, _} =
          FullCircle.Notes.Attachments.attach(note, %{path: path, file_name: name}, comp, admin)
      end

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes")

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#notes-#{note.id} .note-thumb")
             |> Enum.count() == 4

      assert has_element?(lv, "#notes-#{note.id}", "1 more file")
    end

    test "the Written by me tab shows only my notes", %{conn: conn, admin: admin, comp: comp} do
      clerk = user_with_role(comp, admin, "clerk")
      note_fixture(comp, admin, %{"body" => "mine"})
      note_fixture(comp, clerk, %{"body" => "the clerk's"})

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")
      lv |> element("#tab-mine") |> render_click()
      html = render(lv)
      assert html =~ "mine"
      refute html =~ "the clerk&#39;s"
    end

    test "an auditor reads the feed but gets no post box", %{admin: admin, comp: comp} do
      note_fixture(comp, admin, %{"body" => "for everyone"})
      auditor = user_with_role(comp, admin, "auditor")
      {:ok, lv, html} = live(log_in_user(build_conn(), auditor), ~p"/companies/#{comp.id}/notes")
      assert html =~ "for everyone"
      refute has_element?(lv, "#compose-form")
    end

    test "a guest is sent back to the dashboard", %{admin: admin, comp: comp} do
      guest = user_with_role(comp, admin, "guest")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), guest), ~p"/companies/#{comp.id}/notes")

      assert to == "/companies/#{comp.id}/dashboard"
    end
  end

  # The edit page doubles as the note's page (there is no separate show page).
  describe "note page" do
    defp pick(lv, type, terms, id) do
      lv |> element("#open-picker") |> render_click()
      lv |> form("#record-picker form", %{"type" => type, "terms" => terms}) |> render_change()
      lv |> element("#record-picker-pick-#{id}") |> render_click()
      # The pick reaches the form via send/2; read the page after it lands.
      render(lv)
    end

    defp edit_path(comp, note), do: ~p"/companies/#{comp.id}/notes/#{note.id}/edit"

    test "new note: first pick sets the subject, later picks queue links",
         %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")

      html = pick(lv, "Contact", "Ali", ali.id)
      # Once a subject is set, the same ＋ chip offers links instead.
      assert html =~ "link a record"
      assert lv |> element("#open-picker") |> render_click() =~ "Link other records"
      lv |> element("#open-picker") |> render_click()

      pick(lv, "Contact", "Mei", mei.id)
      # Picking the subject again does not also make it a link.
      pick(lv, "Contact", "Ali", ali.id)

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#note-form", %{"note" => %{"body" => "welded the gate"}}) |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      # Saving a new note lands on its page, where files can be attached.
      assert to == edit_path(comp, note)
      assert note.subject_id == ali.id
      assert [%{id: id}] = FullCircle.Notes.list_links(note, comp, admin)
      assert id == mei.id
    end

    test "clearing the subject turns the picker back into the subject picker",
         %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")
      pick(lv, "Contact", "Ali", ali.id)
      lv |> element("#clear-subject") |> render_click()
      html = lv |> element("#open-picker") |> render_click()
      assert html =~ "Set what this note is about"
    end

    test "on a saved note, links are added and removed straight away",
         %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})

      note =
        note_fixture(comp, admin, %{
          "body" => "b",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      {:ok, lv, _} = live(conn, edit_path(comp, note))
      assert pick(lv, "Contact", "Mei", mei.id) =~ "Kedai Mei"
      assert [link] = FullCircle.Notes.list_links(note, comp, admin)

      html = lv |> element("#remove-link-#{link.link_id}") |> render_click()
      refute html =~ "Kedai Mei"
      assert [] = FullCircle.Notes.list_links(note, comp, admin)
    end

    test "about & link chips are capped at 20rem with the full title on hover",
         %{conn: conn, admin: admin, comp: comp} do
      long =
        "Stainless steel Waste water screen might need to align correctly in order to be effective."

      parent = note_fixture(comp, admin, %{"body" => long})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})

      note =
        note_fixture(comp, admin, %{
          "body" => "child",
          "subject_type" => "Note",
          "subject_id" => parent.id,
          "links" => [%{"type" => "Contact", "id" => mei.id}]
        })

      {:ok, lv, _} = live(conn, edit_path(comp, note))

      # subject chip: capped, full text in the tooltip, remove button outside the cut text
      assert has_element?(lv, ~s{span.max-w-xs[title="Note · #{long}"]})
      assert has_element?(lv, ~s{span.max-w-xs[title="Note · #{long}"] #clear-subject})
      # link chip uses the same capped chip
      [link] = FullCircle.Notes.list_links(note, comp, admin)

      assert has_element?(
               lv,
               ~s{span.max-w-xs[title="Contact · Kedai Mei"] #remove-link-#{link.link_id}}
             )
    end

    test "linking a note to itself says so", %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})

      note =
        note_fixture(comp, admin, %{
          "body" => "selfish note",
          "subject_type" => "Contact",
          "subject_id" => ali.id
        })

      {:ok, lv, _} = live(conn, edit_path(comp, note))
      html = pick(lv, "Note", "selfish", note.id)
      assert html =~ "cannot link to itself"
    end

    test "creates a note about a contact with restricted visibility",
         %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      {:ok, lv, html} =
        live(conn, ~p"/companies/#{comp.id}/notes/new?subject_type=Contact&subject_id=#{c.id}")

      assert html =~ "Ah Seng"

      lv
      |> form("#note-form", %{"note" => %{"body" => "pays late", "visibility" => ["manager"]}})
      |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      assert note.subject_id == c.id
      assert note.visibility == ["manager"]
    end

    test "ticked roles are marked selected by the server, not only by CSS",
         %{conn: conn, admin: admin, comp: comp} do
      # The dark theme's unlayered remaps (.dark .bg-white, .dark .border-gray-300)
      # beat Tailwind's has-checked: variants, so the selected look must come from
      # the server-rendered class.
      note = note_fixture(comp, admin, %{"body" => "b", "visibility" => ["manager"]})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      assert has_element?(lv, "label.role-chip[data-selected]", "manager")
      refute has_element?(lv, "label.role-chip[data-selected]", "clerk")

      lv
      |> form("#note-form", %{"note" => %{"visibility" => ["manager", "clerk"]}})
      |> render_change()

      assert has_element?(lv, "label.role-chip[data-selected]", "clerk")
    end

    test "the About and link chips open their records in a new tab",
         %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})

      note =
        note_fixture(comp, admin, %{
          "body" => "b",
          "subject_type" => "Contact",
          "subject_id" => ali.id,
          "links" => [%{"type" => "Contact", "id" => mei.id}]
        })

      {:ok, lv, _} = live(conn, edit_path(comp, note))

      for c <- [ali, mei] do
        href = "/companies/#{comp.id}/contacts/#{c.id}/edit"
        assert has_element?(lv, ~s(a[target="_blank"][href="#{href}"]))
      end
    end

    test "chips offer Everyone, Private and the real roles — no admin, no guest",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "b"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      refute has_element?(lv, "label.role-chip", "admin")
      refute has_element?(lv, "label.role-chip", "guest")
      assert has_element?(lv, "label.role-chip", "manager")
      assert has_element?(lv, "#visibility-private")
    end

    test "Private makes the note admins-and-writer only; a role then replaces it",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "b"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))

      lv |> element("#visibility-private") |> render_click()
      assert has_element?(lv, "#visibility-private[data-selected]")
      lv |> form("#note-form") |> render_submit()
      assert FullCircle.Repo.get!(FullCircle.Notes.Note, note.id).visibility == ["admin"]

      # Ticking a role while Private is on switches to that role.
      lv
      |> form("#note-form", %{"note" => %{"visibility" => ["admin", "clerk"]}})
      |> render_change()

      refute has_element?(lv, "#visibility-private[data-selected]")
      assert has_element?(lv, "label.role-chip[data-selected]", "clerk")
    end

    test "the Everyone chip clears the role list", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "b", "visibility" => ["manager"]})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      lv |> element("#visibility-everyone") |> render_click()
      lv |> form("#note-form") |> render_submit()
      assert FullCircle.Repo.get!(FullCircle.Notes.Note, note.id).visibility == nil
    end

    test "blank body shows an error", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")
      html = lv |> form("#note-form", %{"note" => %{"body" => ""}}) |> render_change()
      assert html =~ "can&#39;t be blank"
    end

    test "saving an edit stays on the page and keeps a version",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      html = lv |> form("#note-form", %{"note" => %{"body" => "v2"}}) |> render_submit()
      assert html =~ "Note saved."
      assert [%{body: "v1"}] = FullCircle.Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "a stale save keeps the typed text and warns", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)

      html = lv |> form("#note-form", %{"note" => %{"body" => "my text"}}) |> render_submit()
      assert html =~ "someone else changed this note"
      assert html =~ "my text"
    end

    test "shows files, links, notes linking here and history",
         %{conn: conn, admin: admin, comp: comp} do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      note =
        note_fixture(comp, admin, %{
          "body" => "v1",
          "links" => [%{"type" => "Contact", "id" => c.id}]
        })

      {:ok, note} = FullCircle.Notes.update_note(note, %{"body" => "v2"}, comp, admin)
      other = note_fixture(comp, admin, %{"body" => "points here"})
      {:ok, _} = FullCircle.Notes.add_link(other, "Note", note.id, comp, admin)

      {:ok, att} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "cert.jpg"},
          comp,
          admin
        )

      {:ok, lv, html} = live(conn, edit_path(comp, note))
      assert html =~ "v2"
      assert html =~ "Ah Seng"
      assert html =~ "points here"
      assert html =~ "cert.jpg"

      html = lv |> element("#toggle-history") |> render_click()
      assert html =~ "v1"

      html = lv |> element("#att-#{att.id} button") |> render_click()
      refute html =~ "cert.jpg"
    end

    test "a note can be written about this note from its page",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "Company closed down"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))

      lv |> element("#notes-panel-new") |> render_click()

      _ =
        lv
        |> form("#notes-panel-form", %{"note" => %{"body" => "confirmed with SSM search"}})
        |> render_submit()

      assert render(lv) =~ "confirmed with SSM search"

      follow_up =
        FullCircle.Repo.get_by!(FullCircle.Notes.Note, body: "confirmed with SSM search")

      assert {follow_up.subject_type, follow_up.subject_id} == {"Note", note.id}
    end

    test "the note page shows a thumbnail tile for every file", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      note = note_fixture(comp, admin, %{"body" => "five files"})

      for {path, name} <- [
            {jpeg_file(), "1.jpg"},
            {pdf_file(), "2.pdf"},
            {jpeg_file(), "3.jpg"},
            {pdf_file(), "4.pdf"},
            {jpeg_file(), "5.jpg"}
          ] do
        {:ok, _} =
          FullCircle.Notes.Attachments.attach(note, %{path: path, file_name: name}, comp, admin)
      end

      {:ok, _lv, html} = live(conn, edit_path(comp, note))
      doc = LazyHTML.from_document(html)
      assert doc |> LazyHTML.query(".att-tile") |> Enum.count() == 5
      # Images preview themselves; PDFs preview their rendered first page.
      assert doc |> LazyHTML.query(".att-tile img") |> Enum.count() == 5
      assert doc |> LazyHTML.query(~s(.att-tile img[src$="?variant=thumb"])) |> Enum.count() == 2
    end

    test "delete returns to the index", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin)
      {:ok, lv, _} = live(conn, edit_path(comp, note))

      assert {:error, {:live_redirect, %{to: to}}} =
               lv |> element("#delete-note") |> render_click()

      assert to == "/companies/#{comp.id}/notes"
    end

    test "someone who can read but not edit gets the page read-only",
         %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "admin wrote this"})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, lv, html} = live(log_in_user(build_conn(), clerk), edit_path(comp, note))

      assert html =~ "admin wrote this"
      assert has_element?(lv, "textarea[disabled]")
      refute has_element?(lv, "#note-form button", "Save")
      refute has_element?(lv, "#delete-note")
      refute has_element?(lv, "#open-picker")
    end

    test "a restricted note is not found for an outsider", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), clerk), edit_path(comp, note))

      assert to == "/companies/#{comp.id}/notes"
    end

    test "the old /notes/:id address opens the same page", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "old link"})
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert html =~ "old link"
      assert has_element?(lv, "#note-form")
    end
  end
end
