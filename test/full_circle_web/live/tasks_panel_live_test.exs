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
             ~s(#tasks-panel-task-#{task.id} a[target="_blank"][href="/companies/#{comp.id}/tasks/#{task.id}"])
           )

    # The Tasks list's row: due tile, people line, rhythm and counts.
    assert has_element?(lv, "#tasks-panel-task-#{task.id}", "Repeat never")
    assert has_element?(lv, "#tasks-panel-task-#{task.id}", "📝 0")
  end

  test "notes and tasks keep their own heights", %{conn: conn, comp: comp, contact: c} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    doc = LazyHTML.from_document(html)

    # The row is inside the @container: a container query cannot size the
    # element that declares it.
    assert doc
           |> LazyHTML.query("#record-aside-Contact.\\@container > .\\@4xl\\:items-start")
           |> Enum.count() == 1

    # flex-1 in a stacked column would split the height; it only applies side by side.
    for id <- ~w(notes-panel tasks-panel) do
      [class] = doc |> LazyHTML.query("##{id}") |> LazyHTML.attribute("class")
      assert class =~ "@4xl:flex-1"
      refute class =~ ~r/(^|\s)flex-1(\s|$)/
    end
  end

  test "＋ Task is the full task form in place, always linked to the record", %{
    conn: conn,
    admin: admin,
    comp: comp,
    contact: c
  } do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    refute has_element?(lv, "#tasks-panel a", "Full form")
    lv |> element("#tasks-panel-new") |> render_click()

    form = "#tasks-panel-new-task-form"
    assert has_element?(lv, "#{form} input[name='task[due_date]']")
    assert has_element?(lv, "#{form} select[name='task[recur_unit]']")
    # The record's own chip is not offered: the task is linked to it anyway.
    refute has_element?(lv, form, "Ah Seng")

    lv
    |> form(form, %{
      "task" => %{"title" => "Chase payment", "due_date" => "2026-12-01", "recur_unit" => "month"}
    })
    |> render_submit()

    refute has_element?(lv, form)
    assert has_element?(lv, "#tasks-panel", "Chase payment")
    task = FullCircle.Repo.one!(FullCircle.Tasks.CompanyTask)
    assert {task.due_date, task.recur_unit} == {~D[2026-12-01], "month"}
    assert [%{type: "Contact", id: id}] = Tasks.list_links(task, comp, admin)
    assert id == c.id
  end

  describe "✎ Edit in place" do
    setup %{admin: admin, comp: comp, contact: c} do
      task =
        task_fixture(comp, admin, %{
          "title" => "Call Ah Seng",
          "links" => [%{"type" => "Contact", "id" => c.id}]
        })

      %{task: task, path: ~p"/companies/#{comp.id}/contacts/#{c.id}/edit"}
    end

    test "swaps the row for the form; Save keeps it on the page",
         %{conn: conn, admin: admin, comp: comp, task: task, path: path} do
      {:ok, lv, _} = live(conn, path)
      lv |> element("#tasks-panel-edit-#{task.id}") |> render_click()

      assert has_element?(
               lv,
               "#tasks-panel-editing #tasks-panel-edit-form input[name='task[title]'][value='Call Ah Seng']"
             )

      refute has_element?(lv, "#tasks-panel-task-#{task.id}")

      lv
      |> form("#tasks-panel-edit-form", %{"task" => %{"title" => "Call Ah Seng again"}})
      |> render_submit()

      refute has_element?(lv, "#tasks-panel-editing")
      assert has_element?(lv, "#tasks-panel-task-#{task.id}", "Call Ah Seng again")
      assert Tasks.get_task(task.id, comp, admin).title == "Call Ah Seng again"
    end

    test "Cancel brings the row back", %{conn: conn, task: task, path: path} do
      {:ok, lv, _} = live(conn, path)
      lv |> element("#tasks-panel-edit-#{task.id}") |> render_click()
      lv |> element("#tasks-panel-edit-cancel") |> render_click()

      refute has_element?(lv, "#tasks-panel-editing")
      assert has_element?(lv, "#tasks-panel-task-#{task.id}", "Call Ah Seng")
    end

    test "a stale save says so and keeps the other edit",
         %{conn: conn, admin: admin, comp: comp, task: task, path: path} do
      {:ok, lv, _} = live(conn, path)
      lv |> element("#tasks-panel-edit-#{task.id}") |> render_click()
      {:ok, _} = Tasks.update_task(task, %{"title" => "Theirs"}, comp, admin)

      lv
      |> form("#tasks-panel-edit-form", %{"task" => %{"title" => "Mine"}})
      |> render_submit()

      assert has_element?(lv, "#tasks-panel-edit-error", "someone else changed this task")
      assert Tasks.get_task(task.id, comp, admin).title == "Theirs"
    end

    test "Done asks for progress, closes the task and keeps the row as Done",
         %{conn: conn, admin: admin, comp: comp, task: task, path: path} do
      {:ok, lv, _} = live(conn, path)

      lv
      |> element(~s(#tasks-panel-task-#{task.id} button[phx-value-kind="done"]))
      |> render_click()

      assert has_element?(lv, "#close-dialog", "Call Ah Seng")

      lv
      |> form("#close-form", %{"close" => %{"note" => "called, will pay Friday"}})
      |> render_submit()

      refute has_element?(lv, "#close-dialog")
      assert Tasks.get_task(task.id, comp, admin).status == "done"
      assert has_element?(lv, "#tasks-panel-task-#{task.id}", "Done")
      refute has_element?(lv, ~s(#tasks-panel-task-#{task.id} button[phx-value-kind="done"]))

      assert [%{note: n}] = FullCircle.Notes.notes_for_record("Task", task.id, comp, admin)
      assert n.body == "called, will pay Friday"
    end

    test "Skip's Cancel leaves the task open", %{
      conn: conn,
      admin: admin,
      comp: comp,
      task: task,
      path: path
    } do
      {:ok, lv, _} = live(conn, path)

      lv
      |> element(~s(#tasks-panel-task-#{task.id} button[phx-value-kind="skip"]))
      |> render_click()

      lv |> element("#close-dialog button", "Cancel") |> render_click()
      refute has_element?(lv, "#close-dialog")
      assert Tasks.get_task(task.id, comp, admin).status == "open"
    end

    test "no ✎ Edit on a closed task", %{
      admin: admin,
      comp: comp,
      conn: conn,
      path: path,
      task: task
    } do
      {:ok, _} = Tasks.close_task(task, :done, nil, comp, admin)
      {:ok, lv, _} = live(conn, path)

      assert has_element?(lv, "#tasks-panel-task-#{task.id}")
      refute has_element?(lv, "#tasks-panel-edit-#{task.id}")
    end
  end

  test "a task created elsewhere appears without a reload", %{
    conn: conn,
    admin: admin,
    comp: comp,
    contact: c
  } do
    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/contacts/#{c.id}/edit")
    refute has_element?(lv, "#tasks-panel", "Made in another tab")

    # Another tab or user: create_task broadcasts {:tasks_changed, company_id}.
    task_fixture(comp, admin, %{
      "title" => "Made in another tab",
      "links" => [%{"type" => "Contact", "id" => c.id}]
    })

    # The host's handle_info sends the panel an update; a first render lets
    # the broadcast through, so the update is queued ahead of the second.
    render(lv)
    assert has_element?(lv, "#tasks-panel", "Made in another tab")
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
