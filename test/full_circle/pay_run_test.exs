defmodule FullCircle.PayRunTest do
  use FullCircle.DataCase

  alias FullCircle.PayRun
  alias FullCircle.HR

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.HRFixtures

  describe "employee_leave_summary" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      employee = employee_fixture(%{}, com, admin)

      leave_type = HR.get_salary_type_by_name("Annual Leave Taken", com, admin)

      %{admin: admin, com: com, employee: employee, leave_type: leave_type}
    end

    test "returns aggregated leave amounts by type for employee in a year", %{
      admin: admin,
      com: com,
      employee: employee,
      leave_type: leave_type
    } do
      today = Date.utc_today()

      # Create a leave salary note
      attrs = %{
        "note_date" => today,
        "quantity" => "2",
        "unit_price" => "1",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => leave_type.name,
        "salary_type_id" => leave_type.id,
        "descriptions" => "annual leave"
      }

      {:ok, _} = HR.create_salary_note(attrs, com, admin)

      summary = PayRun.employee_leave_summary(employee.id, today.year, com)
      assert length(summary) == 1
      leave = hd(summary)
      assert leave.name == "Annual Leave Taken"
      assert Decimal.eq?(leave.amount, Decimal.new("2"))
    end

    test "returns empty list when no leave notes exist", %{com: com, employee: employee} do
      summary = PayRun.employee_leave_summary(employee.id, 2099, com)
      assert summary == []
    end

    test "aggregates multiple leave notes of same type", %{
      admin: admin,
      com: com,
      employee: employee,
      leave_type: leave_type
    } do
      today = Date.utc_today()

      for i <- 1..3 do
        attrs = %{
          "note_date" => Date.add(today, -i),
          "quantity" => "1",
          "unit_price" => "1",
          "employee_name" => employee.name,
          "employee_id" => employee.id,
          "salary_type_name" => leave_type.name,
          "salary_type_id" => leave_type.id,
          "descriptions" => "leave #{i}"
        }

        {:ok, _} = HR.create_salary_note(attrs, com, admin)
      end

      summary = PayRun.employee_leave_summary(employee.id, today.year, com)
      assert length(summary) == 1
      assert Decimal.eq?(hd(summary).amount, Decimal.new("3"))
    end
  end
end
