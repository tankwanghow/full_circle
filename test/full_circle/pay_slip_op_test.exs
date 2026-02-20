defmodule FullCircle.PaySlipOpTest do
  use FullCircle.DataCase

  alias FullCircle.PaySlipOp
  alias FullCircle.HR
  alias FullCircle.Accounting

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.HRFixtures

  defp setup_payroll(_context) do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    employee = employee_fixture(%{}, com, admin)

    db_ac = Accounting.get_account_by_name("Salaries and Wages", com, admin)
    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

    funds_ac =
      account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)

    # Use the default "Monthly Salary" salary type that was seeded with the company
    salary_type = HR.get_salary_type_by_name("Monthly Salary", com, admin)

    # Create an "Employee PCB" salary type (required by generate_new_changeset_for)
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

    %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type,
      funds_ac: funds_ac,
      db_ac: db_ac,
      cr_ac: cr_ac
    }
  end

  describe "get_uncount_salary_notes" do
    setup :setup_payroll

    test "returns salary notes not yet assigned to a pay slip", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type
    } do
      today = Date.utc_today()

      attrs = %{
        "note_date" => today,
        "quantity" => "1",
        "unit_price" => "3000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "monthly salary"
      }

      {:ok, _} = HR.create_salary_note(attrs, com, admin)

      notes = PaySlipOp.get_uncount_salary_notes(employee.id, today.month, today.year, com)
      assert length(notes) >= 1
      assert Enum.all?(notes, fn n -> is_nil(n.pay_slip_id) end)
    end

    test "returns empty when no notes exist for employee/period", %{
      com: com,
      employee: employee
    } do
      notes = PaySlipOp.get_uncount_salary_notes(employee.id, 1, 2099, com)
      assert notes == []
    end
  end

  describe "get_uncount_advances" do
    setup :setup_payroll

    test "returns advances not yet assigned to a pay slip", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      today = Date.utc_today()

      attrs = %{
        "slip_date" => today,
        "amount" => "500",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "advance"
      }

      {:ok, _} = HR.create_advance(attrs, com, admin)

      advances = PaySlipOp.get_uncount_advances(employee.id, today.month, today.year, com)
      assert length(advances) >= 1
    end

    test "returns empty when no advances exist", %{com: com, employee: employee} do
      advances = PaySlipOp.get_uncount_advances(employee.id, 1, 2099, com)
      assert advances == []
    end
  end

  describe "get_pay_slip!" do
    setup :setup_payroll

    test "returns pay slip with preloaded associations", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type,
      funds_ac: funds_ac
    } do
      today = Date.utc_today()

      # Create a salary note first
      sn_attrs = %{
        "note_date" => today,
        "quantity" => "1",
        "unit_price" => "3000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "monthly salary"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(sn_attrs, com, admin)

      # Create pay slip with the salary note as addition
      ps_attrs = %{
        "slip_date" => to_string(today),
        "pay_month" => to_string(today.month),
        "pay_year" => to_string(today.year),
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "pay_slip_amount" => "3000",
        "additions" => %{
          "0" => %{
            "_id" => sn.id,
            "note_no" => sn.note_no,
            "note_date" => to_string(today),
            "quantity" => "1",
            "unit_price" => "3000",
            "amount" => "3000",
            "salary_type_name" => salary_type.name,
            "salary_type_id" => salary_type.id,
            "employee_id" => employee.id,
            "descriptions" => "monthly salary"
          }
        }
      }

      {:ok, %{create_pay_slip: ps}} = PaySlipOp.create_pay_slip(ps_attrs, com, admin)

      loaded_ps = PaySlipOp.get_pay_slip!(ps.id, com)
      assert loaded_ps.slip_no =~ "PS-"
      assert loaded_ps.employee_name == employee.name
      assert loaded_ps.funds_account_name == funds_ac.name
    end
  end

  describe "create_pay_slip" do
    setup :setup_payroll

    test "authorization check - unauthorized user", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, guest, "guest", admin)

      today = Date.utc_today()

      attrs = %{
        "slip_date" => to_string(today),
        "pay_month" => to_string(today.month),
        "pay_year" => to_string(today.year),
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "pay_slip_amount" => "0",
        "additions" => %{},
        "deductions" => %{},
        "contributions" => %{},
        "bonuses" => %{},
        "leaves" => %{},
        "advances" => %{}
      }

      assert :not_authorise == PaySlipOp.create_pay_slip(attrs, com, guest)
    end
  end
end
