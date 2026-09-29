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
end
