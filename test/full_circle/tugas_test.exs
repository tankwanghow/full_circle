defmodule FullCircle.TugasTest do
  use FullCircle.DataCase

  alias FullCircle.Tugas

  import FullCircle.BillingFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  # --- AUTHORIZATION (allow-lists; `tasker` is deliberately not a role) ---

  describe "tugas authorization" do
    test_authorise_to(:view_tugas, [
      "admin",
      "manager",
      "supervisor",
      "clerk",
      "cashier",
      "auditor"
    ])

    test_authorise_to(:create_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:update_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])

    test_authorise_to(:create_duty_event, ["admin", "manager", "supervisor", "clerk", "cashier"])

    test_authorise_to(:create_duty_event_document, [
      "admin",
      "manager",
      "supervisor",
      "clerk",
      "cashier"
    ])

    test_authorise_to(:complete_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])
    test_authorise_to(:skip_duty, ["admin", "manager", "supervisor", "clerk", "cashier"])

    test_authorise_to(:link_duty_document, [
      "admin",
      "manager",
      "supervisor",
      "clerk",
      "cashier"
    ])

    test_authorise_to(:end_duty_series, ["admin", "manager", "supervisor"])
    test_authorise_to(:unlink_duty_document, ["admin", "manager", "supervisor"])
    test_authorise_to(:correct_others_duty_event, ["admin", "manager", "supervisor"])
    test_authorise_to(:delete_others_duty_event, ["admin", "manager", "supervisor"])
  end

  describe "create_duty/3" do
    test "creates an active one-off duty whose series is itself", %{
      admin: admin,
      company: company
    } do
      assert {:ok, duty} =
               Tugas.create_duty(
                 %{"title" => "Pay the electricity bill", "due_date" => "2026-09-30"},
                 company,
                 admin
               )

      assert duty.title == "Pay the electricity bill"
      assert duty.status == "active"
      assert duty.company_id == company.id
      assert {:ok, _} = Ecto.UUID.dump(duty.series_id)
      assert is_nil(duty.recur_unit)
      assert is_nil(duty.series_ended_at)
    end

    test "requires a title", %{admin: admin, company: company} do
      assert {:error, :create_duty, %Ecto.Changeset{} = cs, _} =
               Tugas.create_duty(%{"title" => ""}, company, admin)

      assert "can't be blank" in errors_on(cs).title
    end
  end
end
