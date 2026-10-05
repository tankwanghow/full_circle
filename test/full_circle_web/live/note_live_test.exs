defmodule FullCircleWeb.NoteLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
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

    test "a reply in the feed is tagged with its root", %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"title" => "Genset", "body" => "broke down"})

      {:ok, r} =
        FullCircle.Notes.create_note(
          %{"body" => "tech Monday", "reply_to_id" => root.id},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")

      assert has_element?(
               lv,
               ~s(#notes-#{r.id} .note-reply-to a[href="/companies/#{comp.id}/notes/#{root.id}"]),
               "Genset"
             )

      refute has_element?(lv, "#notes-#{root.id} .note-reply-to")
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

      note_fixture(comp, admin, %{"body" => "follow-up", "reply_to_id" => note.id})

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

  # /notes/:id is the post view; /notes/:id/edit opens it in edit mode.
  test "progress on a task wears the Tasks amber in the feed, not on its own task",
       %{conn: conn, admin: admin, comp: comp} do
    task = FullCircle.TasksFixtures.task_fixture(comp, admin, %{"title" => "EPF September"})

    {:ok, progress} =
      FullCircle.Notes.create_note(
        %{"body" => "paid at bank", "subject_type" => "Task", "subject_id" => task.id},
        comp,
        admin
      )

    plain = note_fixture(comp, admin, %{"body" => "just a note"})

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes")
    assert has_element?(lv, "#notes-#{progress.id}.note-progress")
    # The amber bar says it; no ✅ tick (user, 2026-10-05).
    refute has_element?(lv, "#notes-#{progress.id}", "✅")
    refute has_element?(lv, "#notes-#{plain.id}.note-progress")

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{task.id}")
    refute has_element?(lv, "#task-notes .note-progress")
  end

  describe "note page" do
    defp pick(lv, type, terms, id) do
      lv |> element("#note-open-picker") |> render_click()
      lv |> form("#note-picker form", %{"type" => type, "terms" => terms}) |> render_change()
      lv |> element("#note-picker-pick-#{id}") |> render_click()
      # The pick reaches the composer via send_update; read the page after it lands.
      render(lv)
    end

    defp edit_path(comp, note), do: ~p"/companies/#{comp.id}/notes/#{note.id}/edit"

    test "forged note-only events on /notes/new are ignored", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")

      for {event, params} <- [
            {"delete", %{}},
            {"toggle_history", %{}},
            {"attachment_uploaded", %{}},
            {"remove_attachment", %{"id" => Ecto.UUID.generate()}}
          ] do
        assert render_hook(lv, event, params) =~ "note-form"
      end
    end

    test "new note: first pick sets the subject, later picks queue links",
         %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")

      html = pick(lv, "Contact", "Ali", ali.id)
      # Once a subject is set, the same ＋ chip offers links instead.
      assert html =~ "link a record"
      assert lv |> element("#note-open-picker") |> render_click() =~ "Link other records"
      lv |> element("#note-open-picker") |> render_click()

      pick(lv, "Contact", "Mei", mei.id)
      # Picking the subject again does not also make it a link.
      pick(lv, "Contact", "Ali", ali.id)

      lv |> form("#note-form", %{"note" => %{"body" => "welded the gate"}}) |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      # Saving a new note lands on its page, where files can be attached.
      assert_redirect(lv, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert note.subject_id == ali.id
      assert [%{id: id}] = FullCircle.Notes.list_links(note, comp, admin)
      assert id == mei.id
    end

    test "clearing the subject turns the picker back into the subject picker",
         %{conn: conn, admin: admin, comp: comp} do
      ali = contact_fixture(comp, admin, %{"name" => "Ali Welding"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")
      pick(lv, "Contact", "Ali", ali.id)
      lv |> element("#note-clear-subject") |> render_click()
      html = lv |> element("#note-open-picker") |> render_click()
      assert html =~ "What is this note about?"
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

    test "about & link chips are capped at 10rem with the full title on hover",
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
      assert has_element?(lv, ~s{span.max-w-40[title="Note · #{long}"]})
      assert has_element?(lv, ~s{span.max-w-40[title="Note · #{long}"] #note-clear-subject})
      # link chip uses the same capped chip
      [link] = FullCircle.Notes.list_links(note, comp, admin)

      assert has_element?(
               lv,
               ~s{span.max-w-40[title="Contact · Kedai Mei"] #remove-link-#{link.link_id}}
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
      assert has_element?(lv, "#note-visibility-private")
    end

    test "Private makes the note admins-and-writer only; a role then replaces it",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "b"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))

      lv |> element("#note-visibility-private") |> render_click()
      assert has_element?(lv, "#note-visibility-private[data-selected]")
      lv |> form("#note-form") |> render_submit()
      assert FullCircle.Repo.get!(FullCircle.Notes.Note, note.id).visibility == ["admin"]

      # Saving returns to the post view; edit again. Ticking a role while
      # Private is on switches to that role.
      lv |> element("#edit-note") |> render_click()

      lv
      |> form("#note-form", %{"note" => %{"visibility" => ["admin", "clerk"]}})
      |> render_change()

      refute has_element?(lv, "#note-visibility-private[data-selected]")
      assert has_element?(lv, "label.role-chip[data-selected]", "clerk")
    end

    test "the Everyone chip clears the role list", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "b", "visibility" => ["manager"]})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      lv |> element("#note-visibility-everyone") |> render_click()
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
      lv |> form("#note-form", %{"note" => %{"body" => "v2"}}) |> render_submit()
      assert render(lv) =~ "Note saved."
      assert has_element?(lv, "#note-post", "v2")
      refute has_element?(lv, "#note-form")
      assert [%{body: "v1"}] = FullCircle.Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "editing again right after a save starts from the saved note",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      lv |> form("#note-form", %{"note" => %{"body" => "v2"}}) |> render_submit()

      lv |> element("#edit-note") |> render_click()
      assert has_element?(lv, "#note-form textarea", "v2")
      lv |> form("#note-form", %{"note" => %{"body" => "v3"}}) |> render_submit()
      assert has_element?(lv, "#note-post", "v3")
      refute render(lv) =~ "someone else changed this note"
    end

    test "a stale save keeps the typed text and warns", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)

      lv |> form("#note-form", %{"note" => %{"body" => "my text"}}) |> render_submit()
      html = render(lv)
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
      assert has_element?(lv, "#linked-from", "points here")
      assert html =~ "cert.jpg"

      html = lv |> element("#toggle-history") |> render_click()
      assert html =~ "v1"

      html = lv |> element("#note-files #att-#{att.id} button") |> render_click()
      refute html =~ "cert.jpg"
    end

    test "replying from a note's page adds to its thread",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "Company closed down"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")

      lv
      |> form("#reply-form", %{"note" => %{"body" => "confirmed with SSM search"}})
      |> render_submit()

      assert render(lv) =~ "confirmed with SSM search"
      assert has_element?(lv, "#replies", "confirmed with SSM search")
      # The post's 💬 count follows the thread.
      assert has_element?(lv, "#note-post .note-replies", "1")

      follow_up =
        FullCircle.Repo.get_by!(FullCircle.Notes.Note, body: "confirmed with SSM search")

      assert follow_up.reply_to_id == note.id
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
      assert doc |> LazyHTML.query("#note-files .note-thumb") |> Enum.count() == 5
      # Images preview themselves; PDFs preview their rendered first page.
      assert doc |> LazyHTML.query("#note-files .note-thumb img") |> Enum.count() == 5

      assert doc
             |> LazyHTML.query(~s(#note-files .note-thumb img[src$="?variant=thumb"]))
             |> Enum.count() == 2
    end

    test "a video and a voice recording play in the note", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      alias FullCircle.Notes.Attachments
      note = note_fixture(comp, admin, %{"body" => "recordings"})

      {:ok, video} =
        Attachments.attach(
          note,
          %{path: mp4_file(), file_name: "Video 1.mp4", kind: "video"},
          comp,
          admin
        )

      {:ok, audio} =
        Attachments.attach(note, %{path: ogg_file(), file_name: "Audio 1.ogg"}, comp, admin)

      {:ok, lv, _} = live(conn, edit_path(comp, note))
      # #t=0.1 makes iPhone Safari show a first frame instead of black.
      v = ~s(#note-files video[src="#{Attachments.url(video)}#t=0.1"][controls][playsinline])
      assert has_element?(lv, v)
      assert has_element?(lv, ~s(#note-files audio[src="#{Attachments.url(audio)}"][controls]))
      assert has_element?(lv, "#note-files #att-#{audio.id}", "Audio 1.ogg")
      # Players, not viewer links; and a tap on one must not open the note.
      refute has_element?(lv, "#note-files a[data-viewer]")
      assert has_element?(lv, "#note-files #att-#{video.id} [data-no-post-open] video")

      lv |> element("#note-files #att-#{video.id} button") |> render_click()
      refute has_element?(lv, "#note-files video")
      assert has_element?(lv, "#note-files audio")
    end

    # Recording is the phone page's (📱); the desktop attaches media files
    # through 📎 / drop / paste, checked against the same per-kind limits.
    test "no recorder on the desktop; 📎 and the drop tray carry the media limits", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      note = note_fixture(comp, admin, %{"body" => "files here"})

      limits =
        ~s([data-max-video-bytes="15000000"][data-max-video-seconds="60"]) <>
          ~s([data-max-audio-bytes="5000000"][data-max-audio-seconds="180"])

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert has_element?(lv, "#attach-#{note.id}" <> limits)
      refute has_element?(lv, "[phx-hook=NoteRecord]")

      {:ok, lv, _} = live(conn, edit_path(comp, note))
      assert has_element?(lv, "#note-tray" <> limits)
      assert has_element?(lv, "#note-attach" <> limits)
      refute has_element?(lv, "[phx-hook=NoteRecord]")
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
      assert has_element?(lv, "#note-post", "admin wrote this")
      refute has_element?(lv, "#note-form")
      refute has_element?(lv, "#edit-note")
      refute has_element?(lv, "#delete-note")
    end

    test "a restricted note is not found for an outsider", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"visibility" => ["manager"]})
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), clerk), edit_path(comp, note))

      assert to == "/companies/#{comp.id}/notes"
    end

    test "the /notes/:id address opens the post view", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "old link"})
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert html =~ "old link"
      assert has_element?(lv, "#note-post")
      refute has_element?(lv, "#note-form")
    end

    test "Edit turns the post into the write box; Cancel brings the post back",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "Any note"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert has_element?(lv, "#note-post", "Any note")

      lv |> element("#edit-note") |> render_click()
      assert has_element?(lv, "#note-form textarea", "Any note")
      refute has_element?(lv, "#note-post")

      lv |> element("#note-cancel") |> render_click()
      assert has_element?(lv, "#note-post", "Any note")
    end

    test "a reader opening /edit gets the post view", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "read me"})
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, lv, _} = live(log_in_user(build_conn(), clerk), edit_path(comp, note))
      assert has_element?(lv, "#note-post", "read me")
      refute has_element?(lv, "#note-form")
      refute has_element?(lv, "#delete-note")
    end

    test "pick goes to the edit box only, not the reply box",
         %{conn: conn, admin: admin, comp: comp} do
      mei = contact_fixture(comp, admin, %{"name" => "Kedai Mei"})
      note = note_fixture(comp, admin, %{"body" => "b"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      pick(lv, "Contact", "Mei", mei.id)
      assert has_element?(lv, "#note-box", "Kedai Mei")
      refute has_element?(lv, "#notes-panel-form", "Kedai Mei")
    end

    test "attachment_uploaded refreshes tiles in edit mode",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "files"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      refute has_element?(lv, "#note-files", "late.jpg")

      {:ok, _} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "late.jpg"},
          comp,
          admin
        )

      render_hook(lv, "attachment_uploaded", %{})
      assert has_element?(lv, "#note-files", "late.jpg")
    end

    test "an upload from the edit box's 📎 button reaches the page",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "files"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      lv |> form("#note-form", %{"note" => %{"body" => "half typed"}}) |> render_change()

      # The edit box's 📎 uploads into its tray (the route opens it first).
      [_, tray] = Regex.run(~r/id="note-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))
      {:ok, _} = FullCircle.Notes.Trays.open(tray, comp, admin)

      {:ok, _} =
        FullCircle.Notes.Attachments.attach_to_tray(
          tray,
          %{path: jpeg_file(), file_name: "from-box.jpg"},
          comp,
          admin
        )

      # In the browser the 📎 hook pushes to the component it sits in: the box.
      lv |> with_target("#note-box") |> render_hook("attachment_uploaded", %{})
      assert has_element?(lv, "#note-tray-files", "from-box.jpg")
      assert has_element?(lv, "#note-form textarea", "half typed")
    end

    test "a file refresh mid-edit keeps the typed text and the stale guard",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, edit_path(comp, note))
      lv |> form("#note-form", %{"note" => %{"body" => "my text"}}) |> render_change()

      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)
      render_hook(lv, "attachment_uploaded", %{})
      assert has_element?(lv, "#note-form textarea", "my text")

      lv |> form("#note-form", %{"note" => %{"body" => "my text"}}) |> render_submit()
      assert render(lv) =~ "someone else changed this note"
      assert FullCircle.Repo.get!(FullCircle.Notes.Note, note.id).body == "someone else"
    end

    test "the post view shows every file, the full body and a History toggle",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, note} = FullCircle.Notes.update_note(note, %{"body" => "v2"}, comp, admin)

      for n <- 1..5 do
        {:ok, _} =
          FullCircle.Notes.Attachments.attach(
            note,
            %{path: jpeg_file(), file_name: "#{n}.jpg"},
            comp,
            admin
          )
      end

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")

      assert lv
             |> element("#note-post")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".note-thumb")
             |> Enum.count() == 5

      html = lv |> element("#toggle-history") |> render_click()
      assert html =~ "v1"
    end

    test "opening a reply shows its whole thread: the root on top, every reply below in order",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"title" => "Genset", "body" => "broke down"})

      {:ok, a} =
        FullCircle.Notes.create_note(%{"body" => "first", "reply_to_id" => root.id}, comp, admin)

      FullCircle.Repo.update_all(from(n in FullCircle.Notes.Note, where: n.id == ^a.id),
        set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
      )

      {:ok, b} =
        FullCircle.Notes.create_note(%{"body" => "second", "reply_to_id" => root.id}, comp, admin)

      {:ok, c} =
        FullCircle.Notes.create_note(%{"body" => "third", "reply_to_id" => root.id}, comp, admin)

      FullCircle.Repo.update_all(from(n in FullCircle.Notes.Note, where: n.id == ^c.id),
        set: [inserted_at: ~U[2099-01-01 00:00:00Z]]
      )

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/notes/#{b.id}")
      # The page is the root's: no separate "Replying to" box, no reply page.
      assert has_element?(lv, "#note-post", "broke down")
      refute has_element?(lv, "#replying-to")

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#replies [data-reply]")
        |> Enum.map(&(LazyHTML.attribute(&1, "id") |> hd()))

      assert ids == ["reply-#{a.id}", "reply-#{b.id}", "reply-#{c.id}"]
    end

    test "the opened reply is scrolled to and highlighted; a root's page scrolls nowhere",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "genset"})

      {:ok, reply} =
        FullCircle.Notes.create_note(%{"body" => "fixed", "reply_to_id" => root.id}, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{reply.id}")
      assert has_element?(lv, ~s(#reply-#{reply.id}[phx-hook="ScrollToNote"]))

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{root.id}")
      assert has_element?(lv, "#reply-#{reply.id}")
      refute has_element?(lv, ~s([phx-hook="ScrollToNote"]))
    end

    test "replies are compact: no record chip or reply-to tag repeated on each",
         %{conn: conn, admin: admin, comp: comp} do
      contact = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      root =
        note_fixture(comp, admin, %{
          "body" => "genset",
          "subject_type" => "Contact",
          "subject_id" => contact.id
        })

      {:ok, reply} =
        FullCircle.Notes.create_note(%{"body" => "fixed", "reply_to_id" => root.id}, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{root.id}")
      assert has_element?(lv, "#reply-#{reply.id}", "fixed")
      refute has_element?(lv, "#reply-#{reply.id} .note-reply-to")
      refute has_element?(lv, "#reply-#{reply.id}", "Ah Seng")
    end

    test "a reply that also links to its note shows once, in the thread",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "genset"})

      {:ok, reply} =
        FullCircle.Notes.create_note(%{"body" => "fixed", "reply_to_id" => root.id}, comp, admin)

      {:ok, _} = FullCircle.Notes.add_link(reply, "Note", root.id, comp, admin)
      other = note_fixture(comp, admin, %{"body" => "elsewhere"})
      {:ok, _} = FullCircle.Notes.add_link(other, "Note", root.id, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{root.id}")
      assert has_element?(lv, "#replies #reply-#{reply.id}")
      refute has_element?(lv, "#linked-#{reply.id}")
      assert has_element?(lv, "#linked-#{other.id}")
    end

    test "a reply edits in place in the thread; the root's history toggles without losing text",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, root} = FullCircle.Notes.update_note(root, %{"body" => "v2"}, comp, admin)

      {:ok, r} =
        FullCircle.Notes.create_note(
          %{"body" => "my reply", "reply_to_id" => root.id},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{root.id}")
      lv |> element("#edit-reply-#{r.id}") |> render_click()
      assert has_element?(lv, "#reply-#{r.id} #reply-edit-form")

      lv |> form("#reply-edit-form", %{"note" => %{"body" => "half typed"}}) |> render_change()
      html = lv |> element("#toggle-history") |> render_click()
      assert html =~ "v1"
      assert has_element?(lv, "#reply-edit-form textarea", "half typed")

      lv |> form("#reply-edit-form", %{"note" => %{"body" => "reworded"}}) |> render_submit()
      refute has_element?(lv, "#reply-edit-form")
      assert has_element?(lv, "#reply-#{r.id}", "reworded")
      assert has_element?(lv, "#note-post", "v2")
    end

    test "/notes/:reply/edit opens the thread with that reply in edit mode",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "genset"})

      {:ok, r} =
        FullCircle.Notes.create_note(%{"body" => "fixed", "reply_to_id" => root.id}, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{r.id}/edit")
      assert has_element?(lv, "#note-post", "genset")
      assert has_element?(lv, "#reply-#{r.id} #reply-edit-form")
      refute has_element?(lv, "#note-form")
    end

    test "a reply's history and delete live on the reply",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "genset"})

      {:ok, r} =
        FullCircle.Notes.create_note(%{"body" => "r v1", "reply_to_id" => root.id}, comp, admin)

      {:ok, _} = FullCircle.Notes.update_note(r, %{"body" => "r v2"}, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{root.id}")
      html = lv |> element("#toggle-reply-history-#{r.id}") |> render_click()
      assert html =~ "r v1"

      lv |> element("#delete-reply-#{r.id}") |> render_click()
      refute has_element?(lv, "#reply-#{r.id}")
      assert has_element?(lv, "#note-post", "genset")
    end

    test "a clerk sees no edit or delete on someone else's reply",
         %{admin: admin, comp: comp} do
      clerk = user_with_role(comp, admin, "clerk")
      root = note_fixture(comp, admin, %{"body" => "genset"})

      {:ok, r} =
        FullCircle.Notes.create_note(
          %{"body" => "admin's", "reply_to_id" => root.id},
          comp,
          admin
        )

      {:ok, lv, _} =
        live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes/#{root.id}")

      assert has_element?(lv, "#reply-#{r.id}", "admin's")
      refute has_element?(lv, "#edit-reply-#{r.id}")
      refute has_element?(lv, "#delete-reply-#{r.id}")
    end

    test "a reply whose root was deleted says so and offers no reply box",
         %{conn: conn, admin: admin, comp: comp} do
      root = note_fixture(comp, admin, %{"body" => "root"})

      {:ok, r} =
        FullCircle.Notes.create_note(%{"body" => "orphan", "reply_to_id" => root.id}, comp, admin)

      {:ok, _} = FullCircle.Notes.delete_note(root, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{r.id}")
      assert has_element?(lv, "#replying-to-gone", "deleted")
      assert has_element?(lv, "#note-post", "orphan")
      refute has_element?(lv, "#reply-form")
    end

    test "the reply's author who lost the root sees the reply, not the root",
         %{admin: admin, comp: comp} do
      clerk = user_with_role(comp, admin, "clerk")
      root = note_fixture(comp, admin, %{"body" => "secret root"})

      {:ok, r} =
        FullCircle.Notes.create_note(
          %{"body" => "clerk reply", "reply_to_id" => root.id},
          comp,
          clerk
        )

      {:ok, _} = FullCircle.Notes.update_note(root, %{"visibility" => ["manager"]}, comp, admin)

      {:ok, lv, html} =
        live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/notes/#{r.id}")

      assert has_element?(lv, "#note-post", "clerk reply")
      assert has_element?(lv, "#replying-to-gone")
      refute html =~ "secret root"
    end

    test "editing: new files wait for Save; existing ✕ still removes at once",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "edit me"})

      {:ok, old} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "old.jpg"},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, edit_path(comp, note))
      [_, tray] = Regex.run(~r/id="note-tray"[^>]*data-tray-id="([^"]+)"/, render(lv))
      # The tray route opens the tray before the first upload.
      {:ok, _} = FullCircle.Notes.Trays.open(tray, comp, admin)

      {:ok, _} =
        FullCircle.Notes.Attachments.attach_to_tray(
          tray,
          %{path: jpeg_file(), file_name: "new.jpg"},
          comp,
          admin
        )

      # The broadcast queues a send_update behind the first render.
      _ = render(lv)
      assert render(lv) =~ "new.jpg"

      assert [%{file_name: "old.jpg"}] =
               FullCircle.Notes.get_note(note.id, comp, admin).attachments

      lv |> element("#note-files #att-#{old.id} button") |> render_click()
      assert FullCircle.Notes.get_note(note.id, comp, admin).attachments == []

      lv |> form("#note-form", %{"note" => %{"body" => "edited"}}) |> render_submit()

      assert [%{file_name: "new.jpg"}] =
               FullCircle.Notes.get_note(note.id, comp, admin).attachments
    end

    test "the note page shows From phone and reloads when a file lands",
         %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "phone me"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}")
      assert has_element?(lv, "#note-phone-open")

      {:ok, _} =
        FullCircle.Notes.Attachments.attach(
          note,
          %{path: jpeg_file(), file_name: "p.jpg"},
          comp,
          admin
        )

      _ = render(lv)
      assert render(lv) =~ "p.jpg"
    end
  end
end
