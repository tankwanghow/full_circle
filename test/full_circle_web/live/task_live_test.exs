defmodule FullCircleWeb.TaskLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures

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

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks")
      refute has_element?(lv, "#tasks-#{t.id}")

      {:ok, lv, _} = live(conn, ~p"/companies/#{comp.id}/tasks?search[scope]=all")
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
    end

    test "guest is turned away", %{admin: admin, comp: comp} do
      guest = user_with_role(comp, admin, "guest")

      assert {:error, {:live_redirect, %{flash: %{"warn" => _}}}} =
               live(log_in_user(build_conn(), guest), ~p"/companies/#{comp.id}/tasks")
    end
  end
end
