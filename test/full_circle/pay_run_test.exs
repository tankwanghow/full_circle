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

  alias FullCircle.{PaySlipOp, Accounting}
  import FullCircle.AccountingFixtures

  defp setup_payroll(_context) do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    employee = employee_fixture(%{}, com, admin)

    funds_ac =
      account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)

    salary_type = HR.get_salary_type_by_name("Monthly Salary", com, admin)
    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

    salary_type_fixture(
      %{
        name: "Employee PCB",
        type: "Deduction",
        cal_func: "pcb_employee",
        db_ac_name: cr_ac.name,
        db_ac_id: cr_ac.id,
        cr_ac_name: cr_ac.name,
        cr_ac_id: cr_ac.id
      },
      com,
      admin
    )

    %{admin: admin, com: com, employee: employee, funds_ac: funds_ac, salary_type: salary_type}
  end

  # Creates an addition salary note dated `date` for `emp` and returns it.
  defp addition_note(emp, date, qty, price, %{salary_type: st} = ctx) do
    salary_note_fixture(
      %{
        "note_date" => to_string(date),
        "quantity" => to_string(qty),
        "unit_price" => to_string(price),
        "employee_name" => emp.name,
        "employee_id" => emp.id,
        "salary_type_name" => st.name,
        "salary_type_id" => st.id,
        "descriptions" => "salary"
      },
      ctx.com,
      ctx.admin
    )
  end

  # Builds a pay slip for `emp` in (mth/yr) with a single addition note of `amount`.
  defp pay_slip_with_addition(emp, mth, yr, amount, ctx) do
    date = Timex.end_of_month(yr, mth)
    sn = addition_note(emp, date, 1, amount, ctx)

    ps_attrs = %{
      "slip_date" => to_string(date),
      "pay_month" => to_string(mth),
      "pay_year" => to_string(yr),
      "employee_name" => emp.name,
      "employee_id" => emp.id,
      "funds_account_name" => ctx.funds_ac.name,
      "funds_account_id" => ctx.funds_ac.id,
      "pay_slip_amount" => to_string(amount),
      "additions" => %{
        "0" => %{
          "_id" => sn.id,
          "note_no" => sn.note_no,
          "note_date" => to_string(date),
          "quantity" => "1",
          "unit_price" => to_string(amount),
          "amount" => to_string(amount),
          "salary_type_name" => ctx.salary_type.name,
          "salary_type_id" => ctx.salary_type.id,
          "employee_id" => emp.id,
          "descriptions" => "salary"
        }
      }
    }

    {:ok, %{create_pay_slip: ps}} = PaySlipOp.create_pay_slip(ps_attrs, ctx.com, ctx.admin)
    ps
  end

  defp find_row(rows, emp), do: Enum.find(rows, fn r -> r.id == emp.id end)

  defp month_cell(row, yr, mth),
    do: Enum.find(row.pay_list, fn p -> p.year == yr and p.month == mth end)

  describe "pay_run_index" do
    setup :setup_payroll

    test "returns a 3-month window, latest month first", ctx do
      base = ~D[2026-05-15]
      rows = PayRun.pay_run_index(base.month, base.year, ctx.com)
      row = find_row(rows, ctx.employee)

      assert length(row.pay_list) == 3
      [first, second, third] = row.pay_list
      assert {first.year, first.month} == {2026, 5}
      assert {second.year, second.month} == {2026, 4}
      assert {third.year, third.month} == {2026, 3}
    end

    test "reports net pay for a processed pay slip", ctx do
      pay_slip_with_addition(ctx.employee, 5, 2026, "3000", ctx)

      rows = PayRun.pay_run_index(5, 2026, ctx.com)
      cell = ctx.employee |> then(&find_row(rows, &1)) |> month_cell(2026, 5)

      refute is_nil(cell.slip_no)
      assert Decimal.eq?(cell.net_pay, Decimal.new("3000"))
    end

    test "reports unprocessed note and advance counts/sums for a pending employee", ctx do
      emp = employee_fixture(%{}, ctx.com, ctx.admin)
      addition_note(emp, ~D[2026-05-10], 2, 100, ctx)

      advance_fixture(
        %{
          "slip_date" => "2026-05-12",
          "amount" => "500",
          "employee_name" => emp.name,
          "employee_id" => emp.id,
          "funds_account_name" => ctx.funds_ac.name,
          "funds_account_id" => ctx.funds_ac.id,
          "note" => "advance"
        },
        ctx.com,
        ctx.admin
      )

      rows = PayRun.pay_run_index(5, 2026, ctx.com)
      cell = find_row(rows, emp) |> month_cell(2026, 5)

      assert is_nil(cell.slip_no)
      assert cell.unproc_note_count == 1
      assert Decimal.eq?(cell.unproc_note_sum, Decimal.new("200"))
      assert cell.unproc_adv_count == 1
      assert Decimal.eq?(cell.unproc_adv_sum, Decimal.new("500"))
    end

    test "includes a resigned employee that has activity in the window", ctx do
      resigned = employee_fixture(%{status: "Resigned"}, ctx.com, ctx.admin)
      addition_note(resigned, ~D[2026-05-08], 1, 250, ctx)

      rows = PayRun.pay_run_index(5, 2026, ctx.com)

      assert find_row(rows, resigned)
      assert find_row(rows, resigned).status == "Resigned"
    end

    test "excludes a resigned employee with no activity in the window", ctx do
      resigned = employee_fixture(%{status: "Resigned"}, ctx.com, ctx.admin)

      rows = PayRun.pay_run_index(5, 2026, ctx.com)

      assert is_nil(find_row(rows, resigned))
    end
  end

  describe "cell_state/2" do
    defp cell(attrs) do
      Map.merge(
        %{slip_no: nil, unproc_note_count: 0, unproc_adv_count: 0},
        Map.new(attrs)
      )
    end

    test "done when a slip exists" do
      assert PayRun.cell_state("Active", cell(slip_no: "PS-1")) == :done
      assert PayRun.cell_state("Resigned", cell(slip_no: "PS-1")) == :done
    end

    test "pending when active with no slip" do
      assert PayRun.cell_state("Active", cell([])) == :pending
    end

    test "pending when resigned but has unprocessed items" do
      assert PayRun.cell_state("Resigned", cell(unproc_note_count: 1)) == :pending
      assert PayRun.cell_state("Resigned", cell(unproc_adv_count: 2)) == :pending
    end

    test "na when resigned, no slip, no unprocessed items" do
      assert PayRun.cell_state("Resigned", cell([])) == :na
    end
  end

  describe "pay_run_totals/1" do
    test "aggregates done/pending counts and payroll per month" do
      objects = [
        %{
          status: "Active",
          pay_list: [
            %{
              year: 2026,
              month: 5,
              slip_no: "PS-1",
              net_pay: Decimal.new("3000"),
              unproc_note_count: 0,
              unproc_adv_count: 0
            },
            %{
              year: 2026,
              month: 4,
              slip_no: nil,
              net_pay: nil,
              unproc_note_count: 1,
              unproc_adv_count: 0
            }
          ]
        },
        %{
          status: "Active",
          pay_list: [
            %{
              year: 2026,
              month: 5,
              slip_no: nil,
              net_pay: nil,
              unproc_note_count: 0,
              unproc_adv_count: 0
            },
            %{
              year: 2026,
              month: 4,
              slip_no: "PS-2",
              net_pay: Decimal.new("2000"),
              unproc_note_count: 0,
              unproc_adv_count: 0
            }
          ]
        }
      ]

      totals = PayRun.pay_run_totals(objects)

      assert totals[{2026, 5}].done == 1
      assert totals[{2026, 5}].pending == 1
      assert Decimal.eq?(totals[{2026, 5}].payroll, Decimal.new("3000"))
      assert totals[{2026, 4}].done == 1
      assert totals[{2026, 4}].pending == 1
      assert Decimal.eq?(totals[{2026, 4}].payroll, Decimal.new("2000"))
    end
  end
end
