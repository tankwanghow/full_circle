defmodule FullCircle.TasksTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures
  import FullCircle.TasksFixtures

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
end
