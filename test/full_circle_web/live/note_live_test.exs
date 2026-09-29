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

    test "a guest is sent back to the dashboard", %{admin: admin, comp: comp} do
      guest = user_with_role(comp, admin, "guest")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(log_in_user(build_conn(), guest), ~p"/companies/#{comp.id}/notes")

      assert to == "/companies/#{comp.id}/dashboard"
    end
  end

  describe "form" do
    test "creates a note about a contact with restricted visibility", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      c = contact_fixture(comp, admin, %{"name" => "Ah Seng"})

      {:ok, lv, html} =
        live(conn, ~p"/companies/#{comp.id}/notes/new?subject_type=Contact&subject_id=#{c.id}")

      assert html =~ "Ah Seng"

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> form("#note-form", %{"note" => %{"body" => "pays late", "visibility" => ["manager"]}})
        |> render_submit()

      [note] = FullCircle.Repo.all(FullCircle.Notes.Note)
      assert to == "/companies/#{comp.id}/notes/#{note.id}"
      assert note.subject_id == c.id
      assert note.visibility == ["manager"]
    end

    test "blank body shows an error", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/new")
      html = lv |> form("#note-form", %{"note" => %{"body" => ""}}) |> render_change()
      assert html =~ "can&#39;t be blank"
    end

    test "edits and keeps a version", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}/edit")
      lv |> form("#note-form", %{"note" => %{"body" => "v2"}}) |> render_submit()
      assert [%{body: "v1"}] = FullCircle.Repo.all(FullCircle.Notes.NoteVersion)
    end

    test "a stale save keeps the typed text and warns", %{conn: conn, admin: admin, comp: comp} do
      note = note_fixture(comp, admin, %{"body" => "v1"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/notes/#{note.id}/edit")
      {:ok, _} = FullCircle.Notes.update_note(note, %{"body" => "someone else"}, comp, admin)

      html = lv |> form("#note-form", %{"note" => %{"body" => "my text"}}) |> render_submit()
      assert html =~ "someone else changed this note"
      assert html =~ "my text"
    end

    test "a clerk cannot open another user's note for edit", %{admin: admin, comp: comp} do
      note = note_fixture(comp, admin)
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 log_in_user(build_conn(), clerk),
                 ~p"/companies/#{comp.id}/notes/#{note.id}/edit"
               )

      assert to == "/companies/#{comp.id}/notes"
    end
  end
end
