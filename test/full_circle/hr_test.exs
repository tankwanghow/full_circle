defmodule FullCircle.HRTest do
  use FullCircle.DataCase

  alias FullCircle.HR
  alias FullCircle.Accounting

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.HRFixtures

  describe "salary_type_types" do
    test "returns expected list" do
      assert HR.salary_type_types() == [
               "Addition",
               "Deduction",
               "Contribution",
               "Bonus",
               "Recording",
               "LeaveTaken"
             ]
    end
  end

  describe "default_salary_types" do
    test "returns 14 default salary types for a company_id" do
      defaults = HR.default_salary_types("some-id")
      assert length(defaults) == 14
    end

    test "includes expected names" do
      names = HR.default_salary_types("x") |> Enum.map(& &1.name)
      assert "Monthly Salary" in names
      assert "EPF By Employee Current Year" in names
      assert "PCB Current Year" in names
      assert "Zakat Current Year" in names
      assert "Annual Leave Taken" in names
    end
  end

  describe "is_default_salary_type?" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      %{admin: admin, com: com}
    end

    test "returns true for default salary type name", %{com: com} do
      st = %{name: "Monthly Salary", company_id: com.id}
      assert HR.is_default_salary_type?(st)
    end

    test "returns false for custom salary type name", %{com: com} do
      st = %{name: "Custom Bonus XYZ", company_id: com.id}
      refute HR.is_default_salary_type?(st)
    end
  end

  describe "salary notes" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      employee = employee_fixture(%{}, com, admin)

      db_ac = Accounting.get_account_by_name("Salaries and Wages", com, admin)
      cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

      salary_type =
        salary_type_fixture(
          %{
            type: "Addition",
            db_ac_name: db_ac.name,
            db_ac_id: db_ac.id,
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
        db_ac: db_ac,
        cr_ac: cr_ac
      }
    end

    test "create_salary_note with valid attrs", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type
    } do
      attrs = %{
        "note_date" => Date.utc_today(),
        "quantity" => "1",
        "unit_price" => "3000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "test note"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(attrs, com, admin)

      assert sn.note_no =~ "SN-"
      assert Decimal.eq?(sn.amount, Decimal.new("3000"))
    end

    test "create_salary_note creates GL transactions", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type,
      db_ac: db_ac,
      cr_ac: cr_ac
    } do
      attrs = %{
        "note_date" => Date.utc_today(),
        "quantity" => "1",
        "unit_price" => "2000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "test"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(attrs, com, admin)

      txns =
        FullCircle.Repo.all(
          from(t in Accounting.Transaction,
            where: t.doc_type == "SalaryNote",
            where: t.doc_no == ^sn.note_no,
            where: t.company_id == ^com.id
          )
        )

      assert length(txns) == 2

      debit_txn = Enum.find(txns, &Decimal.positive?(&1.amount))
      credit_txn = Enum.find(txns, &(not Decimal.positive?(&1.amount)))

      assert debit_txn.account_id == db_ac.id
      assert credit_txn.account_id == cr_ac.id
      assert Decimal.eq?(debit_txn.amount, Decimal.new("2000"))
      assert Decimal.eq?(credit_txn.amount, Decimal.new("-2000"))
    end

    test "update_salary_note updates and recreates transactions", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type
    } do
      attrs = %{
        "note_date" => Date.utc_today(),
        "quantity" => "1",
        "unit_price" => "1000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "original"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(attrs, com, admin)

      sn = HR.get_salary_note!(sn.id, com, admin)

      update_attrs = %{
        "note_no" => sn.note_no,
        "note_date" => Date.utc_today(),
        "quantity" => "1",
        "unit_price" => "2500",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "updated"
      }

      {:ok, %{update_salary_note: updated_sn}} =
        HR.update_salary_note(sn, update_attrs, com, admin)

      assert Decimal.eq?(updated_sn.amount, Decimal.new("2500"))

      txns =
        FullCircle.Repo.all(
          from(t in Accounting.Transaction,
            where: t.doc_type == "SalaryNote",
            where: t.doc_no == ^sn.note_no,
            where: t.company_id == ^com.id
          )
        )

      debit_txn = Enum.find(txns, &Decimal.positive?(&1.amount))
      assert Decimal.eq?(debit_txn.amount, Decimal.new("2500"))
    end

    test "delete_salary_note removes note and transactions", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type
    } do
      attrs = %{
        "note_date" => Date.utc_today(),
        "quantity" => "1",
        "unit_price" => "1500",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "to delete"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(attrs, com, admin)
      sn = HR.get_salary_note!(sn.id, com, admin)

      {:ok, _} = HR.delete_salary_note(sn, com, admin)

      txns =
        FullCircle.Repo.all(
          from(t in Accounting.Transaction,
            where: t.doc_type == "SalaryNote",
            where: t.doc_no == ^sn.note_no,
            where: t.company_id == ^com.id
          )
        )

      assert txns == []
    end

    test "unauthorized user gets :not_authorise", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type
    } do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, guest, "guest", admin)

      attrs = %{
        "note_date" => Date.utc_today(),
        "quantity" => "1",
        "unit_price" => "1000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "test"
      }

      assert :not_authorise == HR.create_salary_note(attrs, com, guest)
    end

    test "get_salary_notes filters by employee, month, year", %{
      admin: admin,
      com: com,
      employee: employee,
      salary_type: salary_type
    } do
      today = Date.utc_today()

      attrs = %{
        "note_date" => today,
        "quantity" => "1",
        "unit_price" => "1000",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "salary_type_name" => salary_type.name,
        "salary_type_id" => salary_type.id,
        "descriptions" => "test"
      }

      {:ok, _} = HR.create_salary_note(attrs, com, admin)

      notes = HR.get_salary_notes(employee.id, today.month, today.year, com, admin)
      assert length(notes) >= 1

      notes_other = HR.get_salary_notes(employee.id, today.month + 1, today.year + 1, com, admin)
      assert notes_other == []
    end
  end

  describe "advances" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      employee = employee_fixture(%{}, com, admin)

      funds_ac =
        account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)

      %{admin: admin, com: com, employee: employee, funds_ac: funds_ac}
    end

    test "create_advance with valid attrs creates advance with gapless doc number", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      attrs = %{
        "slip_date" => Date.utc_today(),
        "amount" => "500",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "advance test"
      }

      {:ok, %{create_advance: adv}} = HR.create_advance(attrs, com, admin)

      assert adv.slip_no =~ "ADV-"
      assert Decimal.eq?(adv.amount, Decimal.new("500"))
    end

    test "create_advance creates GL transactions", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      attrs = %{
        "slip_date" => Date.utc_today(),
        "amount" => "300",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "test"
      }

      {:ok, %{create_advance: adv}} = HR.create_advance(attrs, com, admin)

      txns =
        FullCircle.Repo.all(
          from(t in Accounting.Transaction,
            where: t.doc_type == "Advance",
            where: t.doc_no == ^adv.slip_no,
            where: t.company_id == ^com.id
          )
        )

      assert length(txns) == 2

      debit_txn = Enum.find(txns, &Decimal.positive?(&1.amount))
      credit_txn = Enum.find(txns, &(not Decimal.positive?(&1.amount)))

      sal_payable = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)
      assert debit_txn.account_id == sal_payable.id
      assert credit_txn.account_id == funds_ac.id
    end

    test "update_advance updates and recreates transactions", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      attrs = %{
        "slip_date" => Date.utc_today(),
        "amount" => "400",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "original"
      }

      {:ok, %{create_advance: adv}} = HR.create_advance(attrs, com, admin)
      adv = HR.get_advance!(adv.id, com, admin)

      update_attrs = %{
        "slip_no" => adv.slip_no,
        "slip_date" => Date.utc_today(),
        "amount" => "600",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "updated"
      }

      {:ok, %{update_advance: updated}} = HR.update_advance(adv, update_attrs, com, admin)
      assert Decimal.eq?(updated.amount, Decimal.new("600"))
    end

    test "unauthorized user gets :not_authorise", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      guest = user_fixture()
      FullCircle.Sys.allow_user_to_access(com, guest, "guest", admin)

      attrs = %{
        "slip_date" => Date.utc_today(),
        "amount" => "100",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "test"
      }

      assert :not_authorise == HR.create_advance(attrs, com, guest)
    end

    test "get_advances filters by employee, month, year", %{
      admin: admin,
      com: com,
      employee: employee,
      funds_ac: funds_ac
    } do
      today = Date.utc_today()

      attrs = %{
        "slip_date" => today,
        "amount" => "200",
        "employee_name" => employee.name,
        "employee_id" => employee.id,
        "funds_account_name" => funds_ac.name,
        "funds_account_id" => funds_ac.id,
        "note" => "test"
      }

      {:ok, _} = HR.create_advance(attrs, com, admin)

      advances = HR.get_advances(employee.id, today.month, today.year, com, admin)
      assert length(advances) >= 1

      advances_none = HR.get_advances(employee.id, today.month + 1, today.year + 1, com, admin)
      assert advances_none == []
    end
  end

  describe "helper functions" do
    test "count_hours_work with nil returns 0.0" do
      assert HR.count_hours_work(nil) == 0.0
    end

    test "count_hours_work with time pairs calculates hours" do
      now = Timex.now()
      later = Timex.shift(now, hours: 4)

      result = HR.count_hours_work([[now, "id1", "ok", "IN"], [later, "id2", "ok", "OUT"]])
      assert result == [4.0]
    end

    test "count_hours_work with odd number of entries returns 0.0 for unmatched" do
      now = Timex.now()
      result = HR.count_hours_work([[now, "id1", "ok", "IN"]])
      assert result == [0.0]
    end

    test "wh with empty list returns 0.0" do
      assert HR.wh([]) == 0.0
    end

    test "nh returns min(wh, nwh)" do
      assert HR.nh(8.0, 7.5) == 8
      assert HR.nh(5.0, 7.5) == 5
    end

    test "ot returns max(wh - nwh, 0.0)" do
      assert HR.ot(10.0, 7.5) == 2.5
      assert HR.ot(5.0, 7.5) == 0.0
    end
  end
end
