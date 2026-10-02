defmodule FullCircleWeb.TasksPanelLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.TasksFixtures

  alias FullCircle.Tasks

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    contact = contact_fixture(comp, admin, %{"name" => "Ah Seng"})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp, contact: contact}
  end

  test "a record page shows tasks linked to it, on the right of notes", %{
    conn: conn,
    admin: admin,
    comp: comp,
    contact: c
  } do
    task =
      task_fixture(comp, admin, %{
        "title" => "Call Ah Seng",
        "links" => [%{"type" => "Contact", "id" => c.id}]
      })

    task_fixture(comp, admin, %{"title" => "Not this contact"})

    {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")

    assert html =~ ~s(id="record-aside-Contact")
    assert html =~ "@4xl:flex-row"
    assert has_element?(lv, "#tasks-panel", "Call Ah Seng")
    refute has_element?(lv, "#tasks-panel", "Not this contact")

    assert has_element?(
             lv,
             ~s(#tasks-panel-task-#{task.id}[target="_blank"][href="/companies/#{comp.id}/tasks/#{task.id}"])
           )
  end

  test "quick-add creates a task linked to the record", %{
    conn: conn,
    admin: admin,
    comp: comp,
    contact: c
  } do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    lv |> element("#tasks-panel-new") |> render_click()

    lv
    |> form("#tasks-panel-form", %{"title" => "Chase payment"})
    |> render_submit()

    assert has_element?(lv, "#tasks-panel", "Chase payment")
    task = FullCircle.Repo.one!(FullCircle.Tasks.CompanyTask)
    assert [%{type: "Contact", id: id}] = Tasks.list_links(task, comp, admin)
    assert id == c.id
  end

  test "the full form opens with this record already linked", %{
    conn: conn,
    comp: comp,
    contact: c
  } do
    {:ok, lv, _} =
      live(conn, ~p"/companies/#{comp.id}/tasks/new?link_type=Contact&link_id=#{c.id}")

    assert has_element?(lv, "#task-form", "Ah Seng")
  end
end
