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
end
