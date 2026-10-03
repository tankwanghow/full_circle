defmodule FullCircleWeb.TaskLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures
  import FullCircle.BillingFixtures, only: [contact_fixture: 2]

  alias FullCircle.Tasks

  setup %{conn: conn} do
    admin = user_fixture()
    comp = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, comp: comp}
  end

  # Relative to the company's own "today", so the expected "3d late" holds in any timezone.
  defp past(comp, days), do: comp |> Tasks.today() |> Date.add(-days) |> Date.to_iso8601()

  describe "index" do
    test "groups open tasks and shows the latest progress note", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      late = task_fixture(comp, admin, %{"title" => "EPF September", "due_date" => past(comp, 3)})
      task_fixture(comp, admin, %{"title" => "Fix house 3 fan"})

      note_fixture(comp, admin, %{
        "body" => "paid at bank",
        "subject_type" => "Task",
        "subject_id" => late.id
      })

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tasks")

      assert html =~ "Overdue"
      assert html =~ "Someday"
      assert has_element?(lv, "#tasks-#{late.id}", "EPF September")
      assert has_element?(lv, "#tasks-#{late.id}", "3d late")
      assert has_element?(lv, "#tasks-#{late.id}", "paid at bank")
      assert has_element?(lv, "a#new_task")
    end

    test "Mine hides tasks assigned to others; All shows them", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      clerk = user_with_role(comp, admin, "clerk")
      t = task_fixture(comp, admin, %{"title" => "Clerk job", "assignee_id" => clerk.id})

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks?search[scope]=mine")
      refute has_element?(lv, "#tasks-#{t.id}")

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks?search[scope]=all")
      assert has_element?(lv, "#tasks-#{t.id}")
    end

    test "opens on All: a clerk sees an unassigned task the admin made", %{
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"title" => "Shared job"})
      clerk = user_with_role(comp, admin, "clerk")

      {:ok, lv, _} = live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/tasks")

      assert has_element?(lv, "#tab-all.shadow-\\[inset_0_-3px_0_\\#f59e0b\\]")
      assert has_element?(lv, "#tasks-#{t.id}")
    end

    test "Done from the list: dialog shows documents needed and next date, then closes", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t =
        task_fixture(comp, admin, %{
          "title" => "Road tax",
          "due_date" => "2026-10-15",
          "recur_unit" => "year",
          "recur_every" => "1",
          "documents_needed" => "road tax receipt"
        })

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks?search[scope]=all")
      lv |> element("#tasks-#{t.id} button[phx-value-kind=done]") |> render_click()

      assert has_element?(lv, "#close-dialog", "road tax receipt")
      assert has_element?(lv, "#close-dialog", "15-10-2027")

      lv |> form("#close-form", %{"close" => %{"note" => "renewed online"}}) |> render_submit()

      refute has_element?(lv, "#close-dialog")
      refute has_element?(lv, "#tasks-#{t.id}")

      assert [%{note: %{body: "renewed online"}}] =
               FullCircle.Notes.notes_for_record("Task", t.id, comp, admin)
    end

    test "a repeated confirm_close after the dialog closed does not crash", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"title" => "Once only"})

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks?search[scope]=all")
      lv |> element("#tasks-#{t.id} button[phx-value-kind=done]") |> render_click()
      lv |> form("#close-form", %{"close" => %{"note" => ""}}) |> render_submit()

      render_hook(lv, "confirm_close", %{"close" => %{"note" => ""}})
      assert Process.alive?(lv.pid)
      refute has_element?(lv, "#close-dialog")
    end

    test "auditor sees no Done/Skip and no New", %{admin: admin, comp: comp} do
      t = task_fixture(comp, admin, %{"title" => "Public task"})
      auditor = user_with_role(comp, admin, "auditor")

      {:ok, lv, _} =
        live(
          log_in_user(build_conn(), auditor),
          ~p"/companies/#{comp.id}/tasks?search[scope]=all"
        )

      assert has_element?(lv, "#tasks-#{t.id}")
      refute has_element?(lv, "#tasks-#{t.id} button[phx-value-kind=done]")
      refute has_element?(lv, "a#new_task")
      refute has_element?(lv, "#task-compose")
    end

    test "quick-add creates a task from the title", %{conn: conn, admin: admin, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks")

      lv |> form("#task-compose", %{"compose" => %{"title" => "Order bags"}}) |> render_submit()

      assert has_element?(lv, "#tasks_list", "Order bags")

      assert [%{task: %{title: "Order bags", visibility: nil, due_date: nil}}] =
               Tasks.list_tasks(comp, admin, %{"scope" => "mine"}, page: 1, per_page: 10)
    end

    test "quick-add shows the changeset's error", %{conn: conn, comp: comp} do
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks")

      html =
        lv
        |> form("#task-compose", %{"compose" => %{"title" => String.duplicate("x", 121)}})
        |> render_submit()

      assert html =~ "should be at most 120 character"
      refute html =~ "Could not save the task."
    end

    test "guest is turned away", %{admin: admin, comp: comp} do
      guest = user_with_role(comp, admin, "guest")

      assert {:error, {:live_redirect, %{flash: %{"warn" => _}}}} =
               live(log_in_user(build_conn(), guest), ~p"/companies/#{comp.id}/tasks")
    end
  end

  describe "task page" do
    test "creates a repeating task with a link and Everyone by default", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      clerk = user_with_role(comp, admin, "clerk")
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/new")

      lv
      |> form("#task-form", %{
        "task" => %{
          "title" => "Permit – Rahim",
          "due_date" => "2026-12-01",
          "recur_unit" => "year",
          "recur_every" => "1",
          "reminder_before_days" => "60",
          "assignee_id" => clerk.id
        }
      })
      |> render_submit()

      # The write box tells the page, which then navigates to the new task.
      {to, _flash} = assert_redirect(lv)

      [_, id] = Regex.run(~r{/tasks/([0-9a-f-]+)$}, to)
      task = Tasks.get_task(id, comp, admin)
      assert task.title == "Permit – Rahim"
      assert task.visibility == nil
      assert task.assignee_id == clerk.id
    end

    test "a malformed remove_link id is ignored", %{conn: conn, admin: admin, comp: comp} do
      contact = contact_fixture(comp, admin)
      task = task_fixture(comp, admin, %{"links" => [%{"type" => "Contact", "id" => contact.id}]})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{task.id}")

      assert render_hook(lv, "remove_link", %{"id" => "not-a-uuid"}) =~ "task-post"
      assert [_] = Tasks.list_links(task, comp, admin)
    end

    test "Done and Skip sit apart from Save, Copy, Back and Delete", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"title" => "File EPF"})
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")

      assert html =~ "gap-7"
      assert html =~ "rounded-full border px-3 py-0.5 text-sm"
      refute html =~ "button slim"
      {delete_at, _} = :binary.match(html, "id=\"delete-task\"")
      {done_at, _} = :binary.match(html, "id=\"done-task\"")
      assert delete_at < done_at
    end

    test "assignee sees fields read-only with Done and Skip; creator edits", %{
      admin: admin,
      comp: comp
    } do
      clerk = user_with_role(comp, admin, "clerk")
      t = task_fixture(comp, admin, %{"title" => "Service genset", "assignee_id" => clerk.id})

      {:ok, lv, _} =
        live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/tasks/#{t.id}")

      assert has_element?(lv, "#task-post", "Service genset")
      assert has_element?(lv, "#done-task")
      refute has_element?(lv, "#edit-task")
      refute has_element?(lv, "#task-form")
      refute has_element?(lv, "#delete-task")

      {:ok, lv, _} =
        live(log_in_user(build_conn(), admin), ~p"/companies/#{comp.id}/tasks/#{t.id}")

      assert has_element?(lv, "#done-task")
      assert has_element?(lv, "#skip-task")
      assert has_element?(lv, "#copy-task")
      assert has_element?(lv, "#back-task")
      assert has_element?(lv, "#delete-task")
      lv |> element("#edit-task") |> render_click()
      refute has_element?(lv, "#done-task")
      refute has_element?(lv, "#skip-task")
      refute has_element?(lv, "#copy-task")
      refute has_element?(lv, "#back-task")
      refute has_element?(lv, "#delete-task")

      lv
      |> form("#task-form", %{"task" => %{"title" => "Service genset (3-monthly)"}})
      |> render_submit()

      assert Tasks.get_task(t.id, comp, admin).title == "Service genset (3-monthly)"
    end

    test "Done moves to the next cycle; past cycles list the done one; Reopen removes it", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t =
        task_fixture(comp, admin, %{
          "title" => "SOCSO",
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1"
        })

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      lv |> element("#done-task") |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#close-form", %{"close" => %{"note" => ""}}) |> render_submit()

      {:ok, lv, html} = live(conn, to)
      # the post shows the due date in the company format
      assert html =~ "15-11-2026"
      assert has_element?(lv, "#past-cycles", "15-10-2026")

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      lv |> element("#reopen-task") |> render_click()
      assert Tasks.get_task(t.id, comp, admin).status == "open"
      assert Tasks.series_cycles(t, comp, admin) == []
    end

    test "a repeated confirm_close after the dialog closed does not crash", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"title" => "Once only"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      lv |> element("#done-task") |> render_click()
      lv |> form("#close-form", %{"close" => %{"note" => ""}}) |> render_submit()

      render_hook(lv, "confirm_close", %{"close" => %{"note" => ""}})
      assert Process.alive?(lv.pid)
      refute has_element?(lv, "#close-dialog")
    end

    test "a hidden task is not found", %{admin: admin, comp: comp} do
      t = task_fixture(comp, admin, %{"visibility" => ["admin"]})
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{flash: %{"warn" => _}}}} =
               live(log_in_user(build_conn(), clerk), ~p"/companies/#{comp.id}/tasks/#{t.id}")
    end
  end

  describe "final review fixes" do
    defp monthly(comp, admin, title) do
      task_fixture(comp, admin, %{
        "title" => title,
        "due_date" => "2026-10-15",
        "recur_unit" => "month",
        "recur_every" => "1"
      })
    end

    test "a task note takes the task's visibility and offers no role chips", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"visibility" => ["clerk"]})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      lv |> element("#task-notes-new") |> render_click()

      refute has_element?(lv, "#task-notes-visibility-everyone")
      refute has_element?(lv, "#task-notes-visibility-private")
      refute has_element?(lv, "#task-notes-form input[value=manager]")

      lv
      |> form("#task-notes-form", %{"note" => %{"body" => "paid at the counter"}})
      |> render_submit()

      assert [%{note: note}] = FullCircle.Notes.notes_for_record("Task", t.id, comp, admin)
      assert note.visibility == ["clerk"]
    end

    test "a progress note edits in place, keeping the task and its 🔒 tag", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"visibility" => ["admin"]})

      {:ok, note} =
        FullCircle.Notes.create_note(
          %{"body" => "paid at bank", "subject_type" => "Task", "subject_id" => t.id},
          comp,
          admin
        )

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      lv |> element("#task-notes-edit-#{note.id}") |> render_click()

      # The task is the note's fixed subject: no chip to clear it, links still open.
      refute has_element?(lv, "#task-notes-edit-clear-subject")
      assert has_element?(lv, "#task-notes-edit-open-picker")
      # No role chips for a task note, so the header keeps saying who can see it.
      assert has_element?(lv, "#task-notes-editing", "Private")

      lv
      |> form("#task-notes-edit-form", %{"note" => %{"body" => "paid at bank, receipt filed"}})
      |> render_submit()

      assert has_element?(lv, "#task-notes-note-#{note.id}", "receipt filed")
      saved = FullCircle.Repo.get!(FullCircle.Notes.Note, note.id)
      assert {saved.subject_type, saved.subject_id} == {"Task", t.id}
    end

    test "other cycles show their note count", %{conn: conn, admin: admin, comp: comp} do
      t = monthly(comp, admin, "SOCSO")
      {:ok, %{next: next}} = Tasks.close_task(t, :done, "paid", comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{next.id}")
      assert has_element?(lv, "#cycle-#{t.id}", "📝 1")
    end

    test "Done & skipped rows show Done/Skipped and the closed date", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      done = task_fixture(comp, admin, %{"title" => "Paid EPF"})
      skipped = task_fixture(comp, admin, %{"title" => "No SST"})
      {:ok, _} = Tasks.close_task(done, :done, nil, comp, admin)
      {:ok, _} = Tasks.close_task(skipped, :skipped, nil, comp, admin)
      today = comp |> Tasks.today() |> FullCircleWeb.Helpers.format_date()

      {:ok, lv, _} =
        live(conn, ~p"/companies/#{comp.id}/tasks?search[scope]=all&search[state]=closed")

      assert has_element?(lv, "#tasks-#{done.id}", "Done")
      assert has_element?(lv, "#tasks-#{done.id}", today)
      assert has_element?(lv, "#tasks-#{skipped.id}", "Skipped")
      assert has_element?(lv, "#tasks-#{skipped.id}", today)
    end

    test "a demoted assignee stays assigned when the task is saved", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      clerk = user_with_role(comp, admin, "clerk")
      t = task_fixture(comp, admin, %{"title" => "Genset", "assignee_id" => clerk.id})

      FullCircle.Repo.get_by!(FullCircle.Sys.CompanyUser, company_id: comp.id, user_id: clerk.id)
      |> Ecto.Changeset.change(role: "auditor")
      |> FullCircle.Repo.update!()

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      lv |> element("#edit-task") |> render_click()
      assert has_element?(lv, "#task-form option[value='#{clerk.id}'][selected]")

      lv |> form("#task-form", %{"task" => %{"title" => "Genset service"}}) |> render_submit()

      t = Tasks.get_task(t.id, comp, admin)
      assert t.title == "Genset service"
      assert t.assignee_id == clerk.id
    end

    test "deleting a task someone closed meanwhile is refused", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"title" => "Once"})
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      {:ok, _} = Tasks.close_task(t, :done, nil, comp, admin)

      html = lv |> element("#delete-task") |> render_click()
      assert html =~ "A closed task cannot be edited"
      assert Tasks.get_task(t.id, comp, admin)
    end

    test "reopening a task someone reopened meanwhile says so and reloads", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"title" => "Once"})
      {:ok, %{closed: closed}} = Tasks.close_task(t, :done, nil, comp, admin)
      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      {:ok, _} = Tasks.reopen_task(closed, comp, admin)

      html = lv |> element("#reopen-task") |> render_click()
      assert html =~ "This task is already open."
      assert has_element?(lv, "#done-task")
    end
  end

  describe "copy" do
    test "copies the fields but not links; the copy is its own series", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      clerk = user_with_role(comp, admin, "clerk")
      contact = contact_fixture(comp, admin)

      src =
        task_fixture(comp, admin, %{
          "title" => "Road tax – WXY 1",
          "descriptions" => "renew at JPJ",
          "due_date" => "2026-12-01",
          "recur_unit" => "year",
          "recur_every" => "1",
          "reminder_before_days" => "30",
          "documents_needed" => "insurance cover note",
          "assignee_id" => clerk.id,
          "visibility" => ["manager"],
          "links" => [%{"type" => "Contact", "id" => contact.id}]
        })

      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/tasks/#{src.id}")
      assert has_element?(lv, "#copy-task")
      assert html =~ "Road tax – WXY 1"

      {:ok, lv, html} =
        lv |> element("#copy-task") |> render_click() |> follow_redirect(conn)

      assert html =~ "Copy Task"
      assert has_element?(lv, "#task-form input[name='task[title]'][value='Road tax – WXY 1']")
      assert has_element?(lv, "#task-form input[name='task[due_date]'][value='2026-12-01']")
      assert has_element?(lv, "#task-form option[value=year][selected]")
      assert has_element?(lv, "#task-form input[name='task[recur_every]'][value='1']")
      assert has_element?(lv, "#task-form input[name='task[reminder_before_days]'][value='30']")

      assert has_element?(
               lv,
               "#task-form input[name='task[documents_needed]'][value='insurance cover note']"
             )

      assert has_element?(lv, "#task-form", "renew at JPJ")
      assert has_element?(lv, "#task-form option[value='#{clerk.id}'][selected]")
      assert has_element?(lv, "#task-form input[name='task[visibility][]'][value=manager]")
      refute html =~ "Contact ·"
      refute has_element?(lv, "#past-cycles")
      refute has_element?(lv, "#task-notes")

      lv |> form("#task-form", %{"task" => %{"title" => "Road tax – WXY 2"}}) |> render_submit()
      {to, _flash} = assert_redirect(lv)

      [_, id] = Regex.run(~r{/tasks/([0-9a-f-]+)$}, to)
      copy = Tasks.get_task(id, comp, admin)
      assert copy.title == "Road tax – WXY 2"
      assert copy.series_id == copy.id
      assert copy.series_id != src.series_id
      assert copy.creator_id == admin.id
      assert copy.status == "open"
      assert Tasks.list_links(copy, comp, admin) == []

      src2 = Tasks.get_task(src.id, comp, admin)
      assert src2.title == "Road tax – WXY 1"
      assert length(Tasks.list_links(src2, comp, admin)) == 1
    end

    test "copying a closed cycle gives an open task", %{conn: conn, admin: admin, comp: comp} do
      src = task_fixture(comp, admin, %{"title" => "Permit"})
      {:ok, %{closed: closed}} = Tasks.close_task(src, :done, nil, comp, admin)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{closed.id}")
      assert has_element?(lv, "#copy-task")
      {:ok, lv, _} = lv |> element("#copy-task") |> render_click() |> follow_redirect(conn)

      lv |> form("#task-form") |> render_submit()
      {to, _flash} = assert_redirect(lv)
      [_, id] = Regex.run(~r{/tasks/([0-9a-f-]+)$}, to)
      copy = Tasks.get_task(id, comp, admin)
      assert copy.status == "open"
      assert copy.id != closed.id
    end

    test "an unassignable assignee is dropped from the copy", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      clerk = user_with_role(comp, admin, "clerk")
      src = task_fixture(comp, admin, %{"title" => "Genset", "assignee_id" => clerk.id})

      FullCircle.Repo.get_by!(FullCircle.Sys.CompanyUser, company_id: comp.id, user_id: clerk.id)
      |> Ecto.Changeset.change(role: "auditor")
      |> FullCircle.Repo.update!()

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{src.id}/copy")
      refute has_element?(lv, "#task-form option[value='#{clerk.id}']")

      lv |> form("#task-form") |> render_submit()
      {to, _flash} = assert_redirect(lv)
      [_, id] = Regex.run(~r{/tasks/([0-9a-f-]+)$}, to)
      assert Tasks.get_task(id, comp, admin).assignee_id == nil
    end

    test "an auditor has no Copy button and is turned away from /copy", %{
      admin: admin,
      comp: comp
    } do
      auditor = user_with_role(comp, admin, "auditor")
      t = task_fixture(comp, admin, %{"title" => "Open to all"})
      conn = log_in_user(build_conn(), auditor)

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
      refute has_element?(lv, "#copy-task")

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}/copy")

      assert to == "/companies/#{comp.id}/tasks"
      assert flash["warn"] =~ "cannot create"
    end

    test "copying a task the user cannot see is refused", %{admin: admin, comp: comp} do
      t = task_fixture(comp, admin, %{"title" => "Secret", "visibility" => ["admin"]})
      clerk = user_with_role(comp, admin, "clerk")

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(
                 log_in_user(build_conn(), clerk),
                 ~p"/companies/#{comp.id}/tasks/#{t.id}/copy"
               )

      assert flash["warn"] =~ "not found"
    end
  end

  describe "nav badge" do
    test "the nav carries the badge link for users who can view tasks", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/dashboard")
      assert html =~ ~s{id="full_circle_tasks"}

      guest = user_with_role(comp, admin, "guest")

      {:ok, _lv, html} =
        live(log_in_user(build_conn(), guest), ~p"/companies/#{comp.id}/dashboard")

      refute html =~ ~s{id="full_circle_tasks"}
    end

    test "counts my due tasks and updates when one is closed", %{
      conn: conn,
      admin: admin,
      comp: comp
    } do
      t = task_fixture(comp, admin, %{"due_date" => past(comp, 1)})

      {:ok, lv, _} =
        live_isolated(conn, FullCircleWeb.TaskLive.NavBadge, session: %{"company_id" => comp.id})

      assert has_element?(lv, "#task-badge-count", "1")

      {:ok, _} = Tasks.close_task(t, :done, nil, comp, admin)
      refute has_element?(lv, "#task-badge-count")
    end
  end

  test "task page link chips are capped at 10rem with the full title on hover",
       %{conn: conn, admin: admin, comp: comp} do
    long =
      "Stainless steel Waste water screen might need to align correctly in order to be effective."

    target = note_fixture(comp, admin, %{"body" => long})
    t = task_fixture(comp, admin, %{"links" => [%{"type" => "Note", "id" => target.id}]})

    {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks/#{t.id}")
    [link] = Tasks.list_links(t, comp, admin)

    assert has_element?(
             lv,
             ~s{span.max-w-40[title="Note · #{long}"] #remove-link-#{link.link_id}}
           )
  end
end
