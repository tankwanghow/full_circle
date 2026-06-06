defmodule FullCircle.PayPrepTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.HR.PayPrep

  defp base(attrs) do
    PayPrep.changeset(%PayPrep{}, Map.merge(%{
      "company_id" => Ecto.UUID.generate(),
      "employee_id" => Ecto.UUID.generate(),
      "pay_month" => 5,
      "pay_year" => 2026
    }, attrs))
  end

  test "valid without verification" do
    assert base(%{}).valid?
  end

  test "verified=true requires a funds_account_id" do
    refute base(%{"verified" => true}).valid?
    assert base(%{"verified" => true, "funds_account_id" => Ecto.UUID.generate()}).valid?
  end

  test "requires period and scope" do
    refute PayPrep.changeset(%PayPrep{}, %{}).valid?
  end

  describe "pay_prep context" do
    import FullCircle.SysFixtures
    import FullCircle.UserAccountsFixtures
    import FullCircle.HRFixtures
    import FullCircle.AccountingFixtures
    alias FullCircle.HR

    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      emp = employee_fixture(%{}, com, admin)
      acct = account_fixture(%{}, com, admin)
      %{admin: admin, com: com, emp: emp, acct: acct}
    end

    test "get_or_init returns an unsaved struct when none exists", %{com: com, emp: emp} do
      pp = HR.get_or_init_pay_prep(emp.id, 5, 2026, com)
      assert pp.pay_month == 5 and pp.pay_year == 2026
      assert is_nil(pp.id)
      refute pp.verified
    end

    test "set account persists and round-trips", %{com: com, emp: emp, admin: admin, acct: acct} do
      {:ok, pp} = HR.set_pay_prep_account(emp.id, 5, 2026, acct.id, com, admin)
      assert pp.id
      assert HR.get_or_init_pay_prep(emp.id, 5, 2026, com).funds_account_id == pp.funds_account_id
    end

    test "set verified records audit; clear unsets", %{com: com, emp: emp, admin: admin, acct: acct} do
      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, acct.id, com, admin)
      {:ok, pp} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      assert pp.verified and pp.verified_by_id == admin.id and pp.verified_at

      HR.clear_pay_prep(com, emp.id, 5, 2026)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end

    test "creating/updating/deleting a salary note clears verified for that month", %{
      com: com, emp: emp, admin: admin
    } do
      st = HR.get_salary_type_by_name("Monthly Salary", com, admin)
      funds = FullCircle.AccountingFixtures.account_fixture(
        %{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)
      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, funds.id, com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)

      sn_attrs = %{
        "note_date" => "2026-05-15", "quantity" => "1", "unit_price" => "100",
        "employee_name" => emp.name, "employee_id" => emp.id,
        "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "x"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(sn_attrs, com, admin)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified

      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      upd_attrs = sn_attrs |> Map.put("unit_price", "200") |> Map.put("note_no", sn.note_no)
      {:ok, _} = HR.update_salary_note(sn, upd_attrs, com, admin)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified

      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      sn = HR.get_salary_note!(sn.id, com, admin)
      {:ok, _} = HR.delete_salary_note(sn, com, admin)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end

    test "note in a different month does not clear another month's prep", %{
      com: com, emp: emp, admin: admin
    } do
      st = HR.get_salary_type_by_name("Monthly Salary", com, admin)
      funds = FullCircle.AccountingFixtures.account_fixture(
        %{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)
      {:ok, _} = HR.set_pay_prep_account(emp.id, 6, 2026, funds.id, com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 6, 2026, true, com, admin)

      {:ok, _} =
        HR.create_salary_note(%{
          "note_date" => "2026-05-20", "quantity" => "1", "unit_price" => "100",
          "employee_name" => emp.name, "employee_id" => emp.id,
          "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "x"
        }, com, admin)

      assert HR.get_or_init_pay_prep(emp.id, 6, 2026, com).verified
    end

    test "paying (linking notes) does NOT clear verified", %{com: com, emp: emp, admin: admin} do
      alias FullCircle.{PaySlipOp, Accounting}
      cr = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)
      funds = FullCircle.AccountingFixtures.account_fixture(
        %{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)
      st = HR.get_salary_type_by_name("Monthly Salary", com, admin)

      FullCircle.HRFixtures.salary_type_fixture(%{name: "Employee PCB", type: "Deduction",
        cal_func: "pcb_employee", db_ac_name: cr.name, db_ac_id: cr.id,
        cr_ac_name: cr.name, cr_ac_id: cr.id}, com, admin)

      {:ok, %{create_salary_note: _}} =
        HR.create_salary_note(%{
          "note_date" => "2026-05-31", "quantity" => "1", "unit_price" => "3000",
          "employee_name" => emp.name, "employee_id" => emp.id,
          "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "salary"
        }, com, admin)

      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, funds.id, com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)

      {:ok, _} = PaySlipOp.pay(emp, 5, 2026, funds.id, com, admin)

      assert HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end
  end
end
