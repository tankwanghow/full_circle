defmodule FullCircle.TasksTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

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
end
