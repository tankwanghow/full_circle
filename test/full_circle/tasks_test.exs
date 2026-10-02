defmodule FullCircle.TasksTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures

  alias FullCircle.Notes
  alias FullCircle.Tasks
  alias FullCircle.Tasks.CompanyTask

  setup do
    billing_setup()
  end

  describe "tasks authorization" do
    test_authorise_to(:view_tasks, [
      "admin",
      "manager",
      "supervisor",
      "cashier",
      "clerk",
      "auditor"
    ])

    test_authorise_to(:create_task, ["admin", "manager", "supervisor", "cashier", "clerk"])
    test_authorise_to(:edit_others_task, ["admin", "manager"])
  end

  describe "CompanyTask.changeset/2" do
    test "title is required and capped at 120" do
      cs = CompanyTask.changeset(%CompanyTask{}, %{"title" => ""})
      assert %{title: ["can't be blank"]} = errors_on(cs)

      cs = CompanyTask.changeset(%CompanyTask{}, %{"title" => String.duplicate("x", 121)})
      assert %{title: [_]} = errors_on(cs)
    end

    test "a repeat needs a unit from the list, every >= 1 and a due date" do
      cs = CompanyTask.changeset(%CompanyTask{}, %{"title" => "t", "recur_unit" => "month"})
      assert %{due_date: ["is needed to repeat"], recur_every: ["can't be blank"]} = errors_on(cs)

      cs =
        CompanyTask.changeset(%CompanyTask{}, %{
          "title" => "t",
          "recur_unit" => "fortnight",
          "recur_every" => "1",
          "due_date" => "2026-10-15"
        })

      assert %{recur_unit: ["is invalid"]} = errors_on(cs)

      cs =
        CompanyTask.changeset(%CompanyTask{}, %{
          "title" => "t",
          "recur_unit" => "month",
          "recur_every" => "0",
          "due_date" => "2026-10-15"
        })

      assert %{recur_every: [_]} = errors_on(cs)
    end

    test "no repeat clears a stray every (the form always sends one)" do
      cs =
        CompanyTask.changeset(%CompanyTask{}, %{
          "title" => "t",
          "recur_unit" => "",
          "recur_every" => "3"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :recur_every) == nil
    end

    test "reminder days cannot be negative" do
      cs =
        CompanyTask.changeset(%CompanyTask{}, %{"title" => "t", "reminder_before_days" => "-1"})

      assert %{reminder_before_days: [_]} = errors_on(cs)
    end

    test "visibility uses the notes values; [] is invalid" do
      cs = CompanyTask.changeset(%CompanyTask{}, %{"title" => "t", "visibility" => ["disable"]})
      assert %{visibility: ["has an invalid entry"]} = errors_on(cs)

      cs = CompanyTask.changeset(%CompanyTask{}, %{"title" => "t", "visibility" => []})
      assert %{visibility: ["use nil for everyone"]} = errors_on(cs)

      assert CompanyTask.changeset(%CompanyTask{}, %{"title" => "t", "visibility" => ["admin"]}).valid?
    end

    test "close_changeset stamps status, closed_at and closed_by", %{admin: admin} do
      cs = CompanyTask.close_changeset(%CompanyTask{status: "open"}, :skipped, admin)
      assert Ecto.Changeset.get_change(cs, :status) == "skipped"
      assert Ecto.Changeset.get_change(cs, :closed_by_id) == admin.id
      assert %DateTime{} = Ecto.Changeset.get_change(cs, :closed_at)
    end
  end

  describe "visible_to/3" do
    test "Everyone / listed role / unlisted role / admin / creator / assignee", %{
      company: company,
      admin: admin
    } do
      manager = user_with_role(company, admin, "manager")
      clerk = user_with_role(company, admin, "clerk")
      cashier = user_with_role(company, admin, "cashier")
      auditor = user_with_role(company, admin, "auditor")
      guest = user_with_role(company, admin, "guest")

      public = task_fixture(company, clerk, %{"title" => "public"})

      managers =
        task_fixture(company, clerk, %{"title" => "managers", "visibility" => ["manager"]})

      private = task_fixture(company, manager, %{"title" => "private", "visibility" => ["admin"]})

      assigned =
        task_fixture(company, manager, %{
          "title" => "assigned",
          "visibility" => ["admin"],
          "assignee_id" => cashier.id
        })

      seen = fn user ->
        Tasks.visible_to(company, user) |> Repo.all() |> Enum.map(& &1.title) |> Enum.sort()
      end

      assert seen.(admin) == ~w(assigned managers private public)
      assert seen.(manager) == ~w(assigned managers private public)
      # creator of "managers" though not a manager
      assert seen.(clerk) == ~w(managers public)
      assert seen.(cashier) == ~w(assigned public)
      assert seen.(auditor) == ~w(public)
      assert seen.(guest) == []

      _ = {public, managers, private, assigned}
    end

    test "other companies' and deleted tasks are invisible", %{company: company, admin: admin} do
      t = task_fixture(company, admin)
      {:ok, _} = Tasks.delete_task(t, company, admin)
      assert Tasks.get_task(t.id, company, admin) == nil

      other = FullCircle.SysFixtures.company_fixture(admin, %{})
      o = task_fixture(other, admin)
      assert Tasks.get_task(o.id, company, admin) == nil
      assert Tasks.get_task("not-a-uuid", company, admin) == nil
    end
  end

  describe "create_task/3" do
    test "sets series_id to its own id, creator, Everyone by default", %{
      company: company,
      admin: admin
    } do
      t = task_fixture(company, admin, %{"visibility" => [""]})
      assert t.series_id == t.id
      assert t.creator_id == admin.id
      assert t.visibility == nil
      assert t.status == "open"
    end

    test "assignee must be a company user who can close tasks", %{company: company, admin: admin} do
      outsider = FullCircle.UserAccountsFixtures.user_fixture()
      auditor = user_with_role(company, admin, "auditor")

      for u <- [outsider, auditor] do
        assert {:error, cs} =
                 Tasks.create_task(%{"title" => "t", "assignee_id" => u.id}, company, admin)

        assert %{assignee_id: ["cannot be assigned tasks"]} = errors_on(cs)
      end
    end

    test "auditor cannot create", %{company: company, admin: admin} do
      auditor = user_with_role(company, admin, "auditor")
      assert Tasks.create_task(%{"title" => "t"}, company, auditor) == :not_authorise
    end

    test "links are validated and saved", %{company: company, admin: admin} do
      contact = contact_fixture(company, admin)

      t =
        task_fixture(company, admin, %{"links" => [%{"type" => "Contact", "id" => contact.id}]})

      assert [%{type: "Contact", id: id}] = Tasks.list_links(t, company, admin)
      assert id == contact.id

      assert {:error, {:link, :not_found}} =
               Tasks.create_task(
                 %{
                   "title" => "t",
                   "links" => [%{"type" => "Contact", "id" => Ecto.UUID.generate()}]
                 },
                 company,
                 admin
               )
    end

    test "broadcasts tasks_changed", %{company: company, admin: admin} do
      Phoenix.PubSub.subscribe(FullCircle.PubSub, Tasks.topic(company.id))
      task_fixture(company, admin)
      company_id = company.id
      assert_receive {:tasks_changed, ^company_id}
    end
  end

  describe "update_task/4 and delete_task/3" do
    test "creator edits; assignee cannot; manager can if visible", %{
      company: company,
      admin: admin
    } do
      clerk = user_with_role(company, admin, "clerk")
      cashier = user_with_role(company, admin, "cashier")
      manager = user_with_role(company, admin, "manager")
      t = task_fixture(company, clerk, %{"assignee_id" => cashier.id})

      assert {:ok, t} = Tasks.update_task(t, %{"title" => "by creator"}, company, clerk)
      assert Tasks.update_task(t, %{"title" => "x"}, company, cashier) == :not_authorise
      assert {:ok, t} = Tasks.update_task(t, %{"title" => "by manager"}, company, manager)
      assert t.title == "by manager"
      assert Tasks.delete_task(t, company, cashier) == :not_authorise
    end

    test "stale edit returns {:error, :stale}", %{company: company, admin: admin} do
      t = task_fixture(company, admin)
      {:ok, _} = Tasks.update_task(t, %{"title" => "first"}, company, admin)
      assert {:error, :stale} = Tasks.update_task(t, %{"title" => "second"}, company, admin)
    end

    test "a no-op edit keeps lock_version", %{company: company, admin: admin} do
      t = task_fixture(company, admin, %{"title" => "same"})
      assert {:ok, t2} = Tasks.update_task(t, %{"title" => "same"}, company, admin)
      assert t2.lock_version == 0
    end

    test "a closed task cannot be edited", %{company: company, admin: admin} do
      t = task_fixture(company, admin)
      {:ok, closed} = t |> CompanyTask.close_changeset(:done, admin) |> Repo.update()
      assert {:error, :closed} = Tasks.update_task(closed, %{"title" => "x"}, company, admin)
    end
  end

  describe "rights" do
    test "assignee may close but not edit or reopen", %{company: company, admin: admin} do
      clerk = user_with_role(company, admin, "clerk")
      cashier = user_with_role(company, admin, "cashier")
      t = task_fixture(company, clerk, %{"assignee_id" => cashier.id})
      r = Tasks.rights(company, cashier)

      assert Tasks.may_close?(t, cashier, r)
      refute Tasks.may_edit?(t, cashier, r)
      refute Tasks.may_reopen?(t, cashier, r)
      assert Tasks.may_reopen?(t, clerk, Tasks.rights(company, clerk))
    end

    test "auditor may not close", %{company: company, admin: admin} do
      auditor = user_with_role(company, admin, "auditor")
      t = task_fixture(company, admin)
      refute Tasks.may_close?(t, auditor, Tasks.rights(company, auditor))
    end
  end

  test "assignable_users lists closers only", %{company: company, admin: admin} do
    clerk = user_with_role(company, admin, "clerk")
    _auditor = user_with_role(company, admin, "auditor")
    ids = Tasks.assignable_users(company) |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([admin.id, clerk.id])
  end

  describe "next_due_date/3" do
    test "day and week" do
      assert Tasks.next_due_date(~D[2026-10-30], "day", 3) == ~D[2026-11-02]
      assert Tasks.next_due_date(~D[2026-10-30], "week", 2) == ~D[2026-11-13]
    end

    test "month clamps, and month-end stays month-end" do
      assert Tasks.next_due_date(~D[2026-01-31], "month", 1) == ~D[2026-02-28]
      assert Tasks.next_due_date(~D[2028-01-31], "month", 1) == ~D[2028-02-29]
      assert Tasks.next_due_date(~D[2026-02-28], "month", 1) == ~D[2026-03-31]
      assert Tasks.next_due_date(~D[2026-03-31], "month", 1) == ~D[2026-04-30]
      assert Tasks.next_due_date(~D[2026-10-15], "month", 3) == ~D[2027-01-15]
      assert Tasks.next_due_date(~D[2026-01-30], "month", 1) == ~D[2026-02-28]
    end

    test "year keeps the day; 29 Feb falls to 28 Feb" do
      assert Tasks.next_due_date(~D[2026-03-01], "year", 1) == ~D[2027-03-01]
      assert Tasks.next_due_date(~D[2028-02-29], "year", 1) == ~D[2029-02-28]
      assert Tasks.next_due_date(~D[2027-02-28], "year", 1) == ~D[2028-02-28]
    end
  end

  describe "close_task/5" do
    setup %{company: company, admin: admin} do
      cashier = user_with_role(company, admin, "cashier")
      contact = contact_fixture(company, admin)

      task =
        task_fixture(company, admin, %{
          "title" => "Road tax WXX 1234",
          "due_date" => "2026-10-15",
          "recur_unit" => "year",
          "recur_every" => "1",
          "reminder_before_days" => "30",
          "documents_needed" => "road tax receipt",
          "assignee_id" => cashier.id,
          "visibility" => ["manager"],
          "links" => [%{"type" => "Contact", "id" => contact.id}]
        })

      %{cashier: cashier, contact: contact, task: task}
    end

    test "Done spawns the next cycle with copied fields and links", ctx do
      %{company: company, cashier: cashier, task: task, contact: contact} = ctx

      assert {:ok, %{closed: closed, next: next}} =
               Tasks.close_task(task, :done, "paid, receipt attached", company, cashier)

      assert closed.status == "done" and closed.closed_by_id == cashier.id
      assert next.series_id == task.series_id
      assert next.due_date == ~D[2027-10-15]
      assert next.status == "open"

      assert {next.title, next.assignee_id, next.visibility, next.reminder_before_days,
              next.documents_needed, next.recur_unit, next.recur_every, next.creator_id} ==
               {task.title, task.assignee_id, task.visibility, task.reminder_before_days,
                task.documents_needed, task.recur_unit, task.recur_every, task.creator_id}

      assert [%{type: "Contact", id: id}] = Tasks.list_links(next, company, ctx.admin)
      assert id == contact.id

      assert [%{note: n}] = Notes.notes_for_record("Task", task.id, company, cashier)
      assert n.body == "paid, receipt attached"
      assert n.visibility == ["manager"]
    end

    test "changing visibility updates progress notes to match", ctx do
      %{company: company, admin: admin, task: task} = ctx

      assert {:ok, _} =
               Notes.create_note(
                 %{"body" => "started", "subject_type" => "Task", "subject_id" => task.id},
                 company,
                 admin
               )

      assert [%{note: %{visibility: ["manager"]}}] =
               Notes.notes_for_record("Task", task.id, company, admin)

      assert {:ok, _} = Tasks.update_task(task, %{"visibility" => ["clerk"]}, company, admin)

      assert [%{note: %{visibility: ["clerk"]}}] =
               Notes.notes_for_record("Task", task.id, company, admin)
    end

    test "visibility sync only touches this task's live notes", ctx do
      %{company: company, admin: admin, task: task} = ctx
      sibling = task_fixture(company, admin, %{"title" => "sibling", "visibility" => ["manager"]})
      mine = note_fixture(company, admin, %{"subject_type" => "Task", "subject_id" => task.id})
      gone = note_fixture(company, admin, %{"subject_type" => "Task", "subject_id" => task.id})
      {:ok, _} = Notes.delete_note(gone, company, admin)

      theirs =
        note_fixture(company, admin, %{"subject_type" => "Task", "subject_id" => sibling.id})

      other = FullCircle.SysFixtures.company_fixture(admin, %{})

      foreign =
        Repo.insert!(%Notes.Note{
          company_id: other.id,
          author_id: admin.id,
          updated_by_id: admin.id,
          body: "same id, other company",
          subject_type: "Task",
          subject_id: task.id,
          visibility: ["manager"]
        })

      assert {:ok, _} = Tasks.update_task(task, %{"visibility" => ["clerk"]}, company, admin)

      vis = fn n -> Repo.get!(Notes.Note, n.id).visibility end
      assert vis.(mine) == ["clerk"]
      assert vis.(gone) == ["manager"]
      assert vis.(theirs) == ["manager"]
      assert vis.(foreign) == ["manager"]
    end

    test "a failing note sync rolls the task update back", ctx do
      %{company: company, admin: admin, task: task} = ctx
      note_fixture(company, admin, %{"subject_type" => "Task", "subject_id" => task.id})

      Repo.query!("""
      CREATE FUNCTION fixes_c_fail_note_sync() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'note sync failed'; END $$
      """)

      Repo.query!("""
      CREATE TRIGGER fixes_c_fail_note_sync BEFORE UPDATE OF visibility ON notes
      FOR EACH ROW EXECUTE FUNCTION fixes_c_fail_note_sync()
      """)

      assert_raise Postgrex.Error, ~r/note sync failed/, fn ->
        Tasks.update_task(task, %{"visibility" => ["clerk"]}, company, admin)
      end

      assert Repo.get!(CompanyTask, task.id).visibility == ["manager"]
    end

    test "a task note's forged visibility is replaced by the task's, on create and update",
         ctx do
      %{company: company, admin: admin, task: task} = ctx

      assert {:ok, note} =
               Notes.create_note(
                 %{
                   "body" => "forged",
                   "subject_type" => "Task",
                   "subject_id" => task.id,
                   "visibility" => ["clerk"]
                 },
                 company,
                 admin
               )

      assert note.visibility == ["manager"]

      assert {:ok, note} =
               Notes.update_note(
                 note,
                 %{"body" => "edited", "visibility" => [""]},
                 company,
                 admin
               )

      assert note.body == "edited"
      assert note.visibility == ["manager"]

      # A visibility-only forgery is a no-op save: no version, no lock bump.
      assert {:ok, same} = Notes.update_note(note, %{"visibility" => ["clerk"]}, company, admin)
      assert same.visibility == ["manager"]
      assert same.lock_version == note.lock_version
    end

    test "Skip also spawns the next cycle; a blank note adds none", ctx do
      %{company: company, admin: admin, task: task} = ctx

      assert {:ok, %{closed: %{status: "skipped"}, next: %{}}} =
               Tasks.close_task(task, :skipped, "  ", company, admin)

      assert Notes.notes_for_record("Task", task.id, company, admin) == []
    end

    test "a one-off spawns nothing", %{company: company, admin: admin} do
      t = task_fixture(company, admin, %{"due_date" => "2026-10-15"})
      assert {:ok, %{next: nil}} = Tasks.close_task(t, :done, nil, company, admin)
    end

    test "closing twice is refused and spawns no second cycle", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, _} = Tasks.close_task(task, :done, nil, company, admin)
      assert {:error, :already_closed} = Tasks.close_task(task, :done, nil, company, admin)

      count =
        Repo.aggregate(from(t in CompanyTask, where: t.series_id == ^task.series_id), :count)

      assert count == 2
    end

    test "auditor cannot close", ctx do
      auditor = user_with_role(ctx.company, ctx.admin, "auditor")
      # ctx.task is restricted to managers, which an auditor cannot even see
      open = task_fixture(ctx.company, ctx.admin, %{"due_date" => "2026-10-15"})
      assert Tasks.close_task(open, :done, nil, ctx.company, auditor) == :not_authorise
    end
  end

  describe "reopen_task/3" do
    setup %{company: company, admin: admin} do
      task =
        task_fixture(company, admin, %{
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1"
        })

      {:ok, %{closed: closed, next: next}} = Tasks.close_task(task, :done, nil, company, admin)
      %{closed: closed, next: next}
    end

    test "untouched next cycle is removed", %{
      company: company,
      admin: admin,
      closed: closed,
      next: next
    } do
      assert {:ok, %{reopened: r, next_kept: false}} = Tasks.reopen_task(closed, company, admin)
      assert r.status == "open" and is_nil(r.closed_at)
      assert Repo.get(CompanyTask, next.id) == nil
    end

    test "next cycle with a note is kept", %{
      company: company,
      admin: admin,
      closed: closed,
      next: next
    } do
      note_fixture(company, admin, %{
        "body" => "started",
        "subject_type" => "Task",
        "subject_id" => next.id
      })

      assert {:ok, %{next_kept: true}} = Tasks.reopen_task(closed, company, admin)
      assert Repo.get(CompanyTask, next.id)
    end

    test "next cycle that was edited is kept", %{
      company: company,
      admin: admin,
      closed: closed,
      next: next
    } do
      {:ok, _} = Tasks.update_task(next, %{"title" => "changed"}, company, admin)
      assert {:ok, %{next_kept: true}} = Tasks.reopen_task(closed, company, admin)
    end

    test "only creator / admin / manager; an open task cannot be reopened", %{
      company: company,
      admin: admin,
      closed: closed
    } do
      clerk = user_with_role(company, admin, "clerk")
      assert Tasks.reopen_task(closed, company, clerk) == :not_authorise
      {:ok, %{reopened: r}} = Tasks.reopen_task(closed, company, admin)
      assert {:error, :open} = Tasks.reopen_task(r, company, admin)
    end
  end

  test "series_cycles lists the other cycles", %{company: company, admin: admin} do
    t =
      task_fixture(company, admin, %{
        "due_date" => "2026-10-15",
        "recur_unit" => "month",
        "recur_every" => "1"
      })

    {:ok, %{next: n1}} = Tasks.close_task(t, :done, nil, company, admin)
    {:ok, %{next: n2}} = Tasks.close_task(n1, :skipped, nil, company, admin)

    assert Enum.map(Tasks.series_cycles(n2, company, admin), & &1.id) == [n1.id, t.id]
  end

  describe "controller rulings" do
    setup %{company: company, admin: admin} do
      task =
        task_fixture(company, admin, %{
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1"
        })

      {:ok, %{closed: closed, next: next}} = Tasks.close_task(task, :done, nil, company, admin)
      %{closed: closed, next: next}
    end

    test "next cycle with a hand-added link is kept", ctx do
      %{company: company, admin: admin, closed: closed, next: next} = ctx
      contact = contact_fixture(company, admin)
      Process.sleep(1100)
      {:ok, _} = Tasks.add_link(next, "Contact", contact.id, company, admin)

      assert {:ok, %{next_kept: true}} = Tasks.reopen_task(closed, company, admin)
      assert Repo.get(CompanyTask, next.id)
    end

    test "links of a closed task cannot change", ctx do
      %{company: company, admin: admin, closed: closed} = ctx
      contact = contact_fixture(company, admin)
      assert {:error, :closed} = Tasks.add_link(closed, "Contact", contact.id, company, admin)

      open =
        task_fixture(company, admin, %{"links" => [%{"type" => "Contact", "id" => contact.id}]})

      [%{link_id: link_id}] = Tasks.list_links(open, company, admin)
      {:ok, _} = Tasks.close_task(open, :done, nil, company, admin)
      assert {:error, :closed} = Tasks.remove_link(open, link_id, company, admin)
    end

    test "a demoted creator cannot reopen", %{company: company, admin: admin} do
      clerk = user_with_role(company, admin, "clerk")
      t = task_fixture(company, clerk, %{"due_date" => "2026-10-15"})
      {:ok, %{closed: closed}} = Tasks.close_task(t, :done, nil, company, clerk)

      from(cu in FullCircle.Sys.CompanyUser,
        where: cu.company_id == ^company.id and cu.user_id == ^clerk.id
      )
      |> Repo.update_all(set: [role: "auditor"])

      assert Tasks.reopen_task(closed, company, clerk) == :not_authorise
    end
  end

  describe "fix round 1" do
    test "copied links share the next cycle's inserted_at; untouched linked cycle is removed",
         %{company: company, admin: admin} do
      contact = contact_fixture(company, admin)

      task =
        task_fixture(company, admin, %{
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1",
          "links" => [%{"type" => "Contact", "id" => contact.id}]
        })

      {:ok, %{closed: closed, next: next}} = Tasks.close_task(task, :done, nil, company, admin)

      links =
        Repo.all(from(l in FullCircle.Linkable.RecordLink, where: l.from_id == ^next.id))

      assert [%{inserted_at: at}] = links
      assert at == next.inserted_at

      assert {:ok, %{next_kept: false}} = Tasks.reopen_task(closed, company, admin)
      assert Repo.get(CompanyTask, next.id) == nil
    end

    test "reopening the same closed struct twice errors, never raises",
         %{company: company, admin: admin} do
      task =
        task_fixture(company, admin, %{
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1"
        })

      {:ok, %{closed: closed}} = Tasks.close_task(task, :done, nil, company, admin)
      assert {:ok, _} = Tasks.reopen_task(closed, company, admin)
      assert {:error, :open} = Tasks.reopen_task(closed, company, admin)
    end

    test "close, touch next, reopen, close again reuses the open cycle",
         %{company: company, admin: admin} do
      task =
        task_fixture(company, admin, %{
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1"
        })

      {:ok, %{closed: closed, next: next}} = Tasks.close_task(task, :done, nil, company, admin)

      note_fixture(company, admin, %{
        "body" => "started",
        "subject_type" => "Task",
        "subject_id" => next.id
      })

      assert {:ok, %{reopened: r, next_kept: true}} = Tasks.reopen_task(closed, company, admin)
      assert {:ok, %{next: again}} = Tasks.close_task(r, :done, nil, company, admin)
      assert again.id == next.id

      open =
        Repo.aggregate(
          from(t in CompanyTask, where: t.series_id == ^task.series_id and t.status == "open"),
          :count
        )

      assert open == 1
    end
  end

  describe "final review fixes" do
    setup %{company: company, admin: admin} do
      task =
        task_fixture(company, admin, %{
          "due_date" => "2026-10-15",
          "recur_unit" => "month",
          "recur_every" => "1"
        })

      %{task: task}
    end

    defp open_cycles(series_id) do
      from(t in CompanyTask,
        where: t.series_id == ^series_id and t.status == "open" and is_nil(t.deleted_at),
        select: t.due_date,
        order_by: t.due_date
      )
      |> Repo.all()
    end

    # A cycle created long before the close that later reuses it.
    defp backdate(%CompanyTask{id: id}) do
      at = DateTime.add(DateTime.utc_now(:second), -3600)
      Repo.update_all(from(t in CompanyTask, where: t.id == ^id), set: [inserted_at: at])
    end

    test "re-closing a reopened old cycle reuses the later open cycle (scenario A)", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, %{closed: oct, next: nov}} = Tasks.close_task(task, :done, nil, company, admin)
      {:ok, %{next: dec}} = Tasks.close_task(nov, :done, nil, company, admin)
      assert dec.due_date == ~D[2026-12-15]

      assert {:ok, %{reopened: oct, next_kept: true}} = Tasks.reopen_task(oct, company, admin)
      assert {:ok, %{next: next}} = Tasks.close_task(oct, :done, nil, company, admin)

      assert next.id == dec.id
      assert open_cycles(task.series_id) == [~D[2026-12-15]]
    end

    test "re-closing with an edited due date reuses the kept next cycle (scenario B)", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, %{closed: oct, next: nov}} = Tasks.close_task(task, :done, nil, company, admin)

      note_fixture(company, admin, %{
        "body" => "started",
        "subject_type" => "Task",
        "subject_id" => nov.id
      })

      assert {:ok, %{reopened: oct, next_kept: true}} = Tasks.reopen_task(oct, company, admin)
      {:ok, oct} = Tasks.update_task(oct, %{"due_date" => "2026-10-20"}, company, admin)
      assert {:ok, %{next: next}} = Tasks.close_task(oct, :done, nil, company, admin)

      assert next.id == nov.id
      assert open_cycles(task.series_id) == [~D[2026-11-15]]
    end

    test "a later closed cycle with no later open one spawns nothing", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, %{closed: oct, next: nov}} = Tasks.close_task(task, :done, nil, company, admin)

      note_fixture(company, admin, %{
        "body" => "started",
        "subject_type" => "Task",
        "subject_id" => nov.id
      })

      {:ok, %{reopened: oct}} = Tasks.reopen_task(oct, company, admin)
      # Nov is closed by hand without spawning (as if it were the last cycle)
      {:ok, _} = nov |> CompanyTask.close_changeset(:done, admin) |> Repo.update()

      assert {:ok, %{next: nil}} = Tasks.close_task(oct, :done, nil, company, admin)
      assert open_cycles(task.series_id) == []
    end

    test "reopen after a reused cycle reports it kept and leaves it", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, %{closed: oct, next: nov}} = Tasks.close_task(task, :done, nil, company, admin)

      note_fixture(company, admin, %{
        "body" => "started",
        "subject_type" => "Task",
        "subject_id" => nov.id
      })

      {:ok, %{reopened: oct, next_kept: true}} = Tasks.reopen_task(oct, company, admin)
      backdate(nov)
      {:ok, %{closed: oct, next: again}} = Tasks.close_task(oct, :done, nil, company, admin)
      assert again.id == nov.id

      assert {:ok, %{next_kept: true}} = Tasks.reopen_task(oct, company, admin)
      assert Repo.get(CompanyTask, nov.id)
    end

    test "a reused cycle is never deleted on reopen, even when untouched", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, %{closed: oct, next: nov}} = Tasks.close_task(task, :done, nil, company, admin)

      note =
        note_fixture(company, admin, %{
          "body" => "started",
          "subject_type" => "Task",
          "subject_id" => nov.id
        })

      {:ok, %{reopened: oct, next_kept: true}} = Tasks.reopen_task(oct, company, admin)
      backdate(nov)
      {:ok, %{closed: oct, next: again}} = Tasks.close_task(oct, :done, nil, company, admin)
      assert again.id == nov.id

      # The only touch goes away: Nov is untouched again, but this close did not create it.
      Repo.update_all(from(n in FullCircle.Notes.Note, where: n.id == ^note.id),
        set: [deleted_at: DateTime.utc_now(:second)]
      )

      assert {:ok, %{next_kept: true}} = Tasks.reopen_task(oct, company, admin)
      assert Repo.get(CompanyTask, nov.id)
    end

    test "a closed cycle cannot be deleted", ctx do
      %{company: company, admin: admin, task: task} = ctx
      {:ok, %{closed: oct, next: nov}} = Tasks.close_task(task, :done, nil, company, admin)

      assert {:error, :closed} = Tasks.delete_task(oct, company, admin)
      assert is_nil(Repo.get(CompanyTask, oct.id).deleted_at)
      assert {:ok, _} = Tasks.delete_task(nov, company, admin)
    end
  end

  describe "group_of/2" do
    test "classifies by due date and reminder window" do
      today = ~D[2026-10-15]
      t = %CompanyTask{status: "open"}
      assert Tasks.group_of(%{t | due_date: ~D[2026-10-14]}, today) == :overdue
      assert Tasks.group_of(%{t | due_date: today}, today) == :due_soon

      assert Tasks.group_of(%{t | due_date: ~D[2026-11-14], reminder_before_days: 30}, today) ==
               :due_soon

      assert Tasks.group_of(%{t | due_date: ~D[2026-11-15], reminder_before_days: 30}, today) ==
               :upcoming

      assert Tasks.group_of(%{t | due_date: ~D[2026-10-16]}, today) == :upcoming
      assert Tasks.group_of(%{t | due_date: nil}, today) == :someday
      assert Tasks.group_of(%{t | status: "done", due_date: ~D[2026-10-01]}, today) == :closed
    end
  end

  describe "list_tasks/4" do
    setup %{company: company, admin: admin} do
      clerk = user_with_role(company, admin, "clerk")
      today = ~D[2026-10-15]

      mk = fn title, attrs -> task_fixture(company, admin, Map.put(attrs, "title", title)) end
      someday = mk.("someday", %{})
      upcoming = mk.("upcoming", %{"due_date" => "2026-12-01"})
      soon = mk.("soon", %{"due_date" => "2026-10-20", "reminder_before_days" => "7"})
      overdue = mk.("overdue", %{"due_date" => "2026-10-01"})
      for_clerk = mk.("for clerk", %{"due_date" => "2026-10-02", "assignee_id" => clerk.id})

      %{
        clerk: clerk,
        today: today,
        someday: someday,
        upcoming: upcoming,
        soon: soon,
        overdue: overdue,
        for_clerk: for_clerk
      }
    end

    defp rows(ctx, user, filters, extra \\ []) do
      Tasks.list_tasks(
        ctx.company,
        user,
        filters,
        Keyword.merge([page: 1, per_page: 50, today: ctx.today], extra)
      )
    end

    test "open, all: grouped order overdue, due soon, upcoming, someday", ctx do
      rows = rows(ctx, ctx.admin, %{"scope" => "all"})

      assert Enum.map(rows, & &1.task.title) ==
               ["overdue", "for clerk", "soon", "upcoming", "someday"]

      assert Enum.map(rows, & &1.group) == [:overdue, :overdue, :due_soon, :upcoming, :someday]
    end

    test "mine = assigned to me, or unassigned and created by me", ctx do
      titles = fn user -> rows(ctx, user, %{"scope" => "mine"}) |> Enum.map(& &1.task.title) end

      assert titles.(ctx.clerk) == ["for clerk"]
      refute "for clerk" in titles.(ctx.admin)
    end

    test "closed state orders by closed_at desc", ctx do
      {:ok, _} = Tasks.close_task(ctx.upcoming, :done, nil, ctx.company, ctx.admin)
      rows = rows(ctx, ctx.admin, %{"scope" => "all", "state" => "closed"})
      assert [%{task: %{title: "upcoming"}, group: :closed}] = rows
    end

    test "terms search title, descriptions and assignee email; % is literal", ctx do
      rows = rows(ctx, ctx.admin, %{"scope" => "all", "terms" => ctx.clerk.email})
      assert Enum.map(rows, & &1.task.title) == ["for clerk"]

      assert rows(ctx, ctx.admin, %{"scope" => "all", "terms" => "%"}) == []
    end

    test "rows carry the latest visible note and the note count", ctx do
      first =
        note_fixture(ctx.company, ctx.admin, %{
          "body" => "first",
          "subject_type" => "Task",
          "subject_id" => ctx.soon.id
        })

      FullCircle.Repo.update_all(
        from(n in FullCircle.Notes.Note, where: n.id == ^first.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3600)]
      )

      note_fixture(ctx.company, ctx.admin, %{
        "body" => "waiting for agent",
        "subject_type" => "Task",
        "subject_id" => ctx.soon.id
      })

      row =
        rows(ctx, ctx.admin, %{"scope" => "all"})
        |> Enum.find(&(&1.task.id == ctx.soon.id))

      assert row.latest_note.body == "waiting for agent"
      assert row.note_count == 2
    end

    test "rows carry how many records the task links", ctx do
      contact = contact_fixture(ctx.company, ctx.admin)
      {:ok, _} = Tasks.add_link(ctx.soon, "Contact", contact.id, ctx.company, ctx.admin)

      rows = rows(ctx, ctx.admin, %{"scope" => "all"})
      assert Enum.find(rows, &(&1.task.id == ctx.soon.id)).link_count == 1
      assert Enum.find(rows, &(&1.task.id == ctx.someday.id)).link_count == 0
    end

    test "pages", ctx do
      page1 = rows(ctx, ctx.admin, %{"scope" => "all"}, per_page: 2)
      page3 = rows(ctx, ctx.admin, %{"scope" => "all"}, page: 3, per_page: 2)
      assert length(page1) == 2 and length(page3) == 1
    end
  end

  describe "badge_count/3" do
    test "mine, open, overdue or due soon; undated never counts", %{
      company: company,
      admin: admin
    } do
      clerk = user_with_role(company, admin, "clerk")
      today = ~D[2026-10-15]
      task_fixture(company, admin, %{"due_date" => "2026-10-10"})
      task_fixture(company, admin, %{"due_date" => "2026-10-15"})
      task_fixture(company, admin, %{"due_date" => "2026-10-25", "reminder_before_days" => "10"})
      task_fixture(company, admin, %{"due_date" => "2026-10-26", "reminder_before_days" => "10"})
      task_fixture(company, admin, %{})
      task_fixture(company, admin, %{"due_date" => "2026-10-01", "assignee_id" => clerk.id})

      assert Tasks.badge_count(company, admin, today) == 3
      assert Tasks.badge_count(company, clerk, today) == 1
    end

    test "today is the company's local date", %{company: company} do
      assert Tasks.today(%{company | timezone: "Asia/Kuala_Lumpur"}) ==
               DateTime.now!("Asia/Kuala_Lumpur") |> DateTime.to_date()
    end
  end

  describe "for_record/4" do
    test "visible tasks linked to the record, open and dated first", %{
      company: company,
      admin: admin
    } do
      contact = contact_fixture(company, admin, %{"name" => "Ah Seng"})
      other = contact_fixture(company, admin, %{"name" => "Other"})
      clerk = user_with_role(company, admin, "clerk")

      task_fixture(company, admin, %{
        "title" => "Someday",
        "links" => [%{"type" => "Contact", "id" => contact.id}]
      })

      task_fixture(company, admin, %{
        "title" => "Call",
        "due_date" => "2026-04-01",
        "links" => [%{"type" => "Contact", "id" => contact.id}]
      })

      task_fixture(company, admin, %{
        "title" => "Elsewhere",
        "links" => [%{"type" => "Contact", "id" => other.id}]
      })

      task_fixture(company, admin, %{"title" => "Unlinked"})

      task_fixture(company, admin, %{
        "title" => "Secret",
        "visibility" => ["admin"],
        "links" => [%{"type" => "Contact", "id" => contact.id}]
      })

      assert Tasks.for_record("Contact", contact.id, company, admin)
             |> Enum.map(& &1.title) == ["Call", "Secret", "Someday"]

      assert Tasks.for_record("Contact", contact.id, company, clerk) |> Enum.map(& &1.title) == [
               "Call",
               "Someday"
             ]
    end
  end
end
