defmodule FullCircle.StatutoryParityTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.{PaySlipOp, SalaryNoteCalFunc, StatutoryConfig}
  alias FullCircle.HR.{PaySlip, SalaryNote, StatutoryCalc}
  alias FullCircle.Repo

  import Ecto.Query
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.HRFixtures

  @grid_wages [10.0, 29.5, 30.0, 2950.0, 3000.0, 4999.0, 5000.0, 5001.0, 5999.0, 6000.0, 8000.0]
  @grid_ages [35, 59, 60, 61]
  @grid_bonus [0.0, 500.0]

  @grid_codes [
    {"epf_employer", :epf_employer},
    {"epf_employee", :epf_employee},
    {"socso_employer", :socso_employer},
    {"socso_employee", :socso_employee},
    {"socso_employer_only", :socso_employer_only},
    {"socso_24hour", :socso_24hour},
    {"eis_employer", :eis_employer},
    {"eis_employee", :eis_employee}
  ]

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{com: com, admin: admin}
  end

  defp make_pay_slip_changeset(addition, bonus, pay_month, pay_year) do
    addition = if(is_float(addition), do: Float.to_string(addition), else: addition)
    bonus = if(is_float(bonus), do: Float.to_string(bonus), else: bonus)

    %PaySlip{
      addition_amount: Decimal.new(addition),
      bonus_amount: Decimal.new(bonus),
      deduction_amount: Decimal.new("0"),
      advance_amount: Decimal.new("0"),
      pay_slip_amount: Decimal.new("0")
    }
    |> Ecto.Changeset.change(%{
      pay_month: pay_month,
      pay_year: pay_year,
      addition_amount: Decimal.new(addition),
      bonus_amount: Decimal.new(bonus)
    })
  end

  defp make_employee(com, opts) do
    age = Keyword.fetch!(opts, :age)
    pay_year = Keyword.get(opts, :pay_year, 2026)
    pay_month = Keyword.get(opts, :pay_month, 6)
    eom = Timex.end_of_month(pay_year, pay_month)
    dob = Timex.shift(eom, years: -age)

    employee_fixture(
      %{
        dob: dob,
        nationality: if(Keyword.get(opts, :malaysian, true), do: "Malaysian", else: "Indonesian"),
        marital_status: Keyword.get(opts, :marital_status, "Single"),
        partner_working: Keyword.get(opts, :partner_working, "No"),
        children: Keyword.get(opts, :children, 0)
      },
      com,
      Keyword.fetch!(opts, :admin)
    )
  end

  defp assert_parity(code, legacy_atom, emp, cs) do
    {:ok, payscript} = StatutoryConfig.calculate(code, emp, cs)
    legacy = legacy_decimal(SalaryNoteCalFunc.calculate_value(legacy_atom, emp, cs))

    assert Decimal.equal?(payscript, legacy),
           "code #{code} wages=#{Decimal.to_string(fetch!(cs, :addition_amount))} " <>
             "bonus=#{Decimal.to_string(fetch!(cs, :bonus_amount))}: " <>
             "payscript=#{Decimal.to_string(payscript)} legacy=#{Decimal.to_string(legacy)}"
  end

  defp fetch!(cs, field), do: Ecto.Changeset.get_field(cs, field)

  defp legacy_decimal(%Decimal{} = d), do: d
  defp legacy_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp legacy_decimal(n) when is_integer(n), do: Decimal.new(n)

  describe "golden parity grid" do
    test "StatutoryConfig.calculate matches legacy for every grid cell", %{com: com, admin: admin} do
      for wages <- @grid_wages,
          age <- @grid_ages,
          malaysian <- [true, false],
          bonus <- @grid_bonus,
          {code, legacy_atom} <- @grid_codes do
        emp = make_employee(com, age: age, malaysian: malaysian, admin: admin)
        cs = make_pay_slip_changeset(wages, bonus, 6, 2026)

        if code == "socso_24hour" do
          # Template effective 2026-06-01 — June slip uses DB path
          assert_parity(code, legacy_atom, emp, cs)
        else
          assert_parity(code, legacy_atom, emp, cs)
        end
      end
    end
  end

  describe "PCB parity" do
    setup %{com: com, admin: admin} do
      emp =
        make_employee(com,
          age: 35,
          malaysian: true,
          marital_status: "Married",
          partner_working: "No",
          children: 2,
          admin: admin
        )

      %{emp: emp}
    end

    defp ensure_salary_type(com, admin, name, type) do
      case FullCircle.HR.get_salary_type_by_name(name, com, admin) do
        nil ->
          cr = FullCircle.Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

          salary_type_fixture(
            %{
              name: name,
              type: type,
              db_ac_name: cr.name,
              db_ac_id: cr.id,
              cr_ac_name: cr.name,
              cr_ac_id: cr.id
            },
            com,
            admin
          )

        st ->
          st
      end
    end

    defp insert_prior_note(emp, com, month, year, salary_type, amount) do
      Repo.insert!(%SalaryNote{
        company_id: com.id,
        employee_id: emp.id,
        salary_type_id: salary_type.id,
        note_date: Date.new!(year, month, 15),
        quantity: Decimal.new(1),
        unit_price: Decimal.new(amount),
        note_no: "YTD-#{System.unique_integer([:positive])}"
      })
    end

    test "mid-year married with 2 children", %{com: com, admin: admin, emp: emp} do
      salary = ensure_salary_type(com, admin, "Monthly Salary", "Addition")
      epf = ensure_salary_type(com, admin, "EPF By Employee", "Deduction")
      pcb = ensure_salary_type(com, admin, "Employee PCB", "Deduction")

      for month <- 1..5 do
        insert_prior_note(emp, com, month, 2026, salary, 5000)
        insert_prior_note(emp, com, month, 2026, epf, 550)
        insert_prior_note(emp, com, month, 2026, pcb, 80)
      end

      cs = make_pay_slip_changeset(5000, 0, 6, 2026)
      assert_parity("pcb_employee", :pcb_employee, emp, cs)
    end

    test "single employee", %{com: com, admin: admin} do
      emp = make_employee(com, age: 35, marital_status: "Single", children: 0, admin: admin)
      salary = ensure_salary_type(com, admin, "Monthly Salary", "Addition")
      epf = ensure_salary_type(com, admin, "EPF By Employee", "Deduction")

      for month <- 1..5 do
        insert_prior_note(emp, com, month, 2026, salary, 5000)
        insert_prior_note(emp, com, month, 2026, epf, 550)
      end

      cs = make_pay_slip_changeset(5000, 0, 6, 2026)
      assert_parity("pcb_employee", :pcb_employee, emp, cs)
    end

    test "December pay month", %{com: com, admin: admin, emp: emp} do
      salary = ensure_salary_type(com, admin, "Monthly Salary", "Addition")
      epf = ensure_salary_type(com, admin, "EPF By Employee", "Deduction")

      for month <- 1..11 do
        insert_prior_note(emp, com, month, 2026, salary, 5000)
        insert_prior_note(emp, com, month, 2026, epf, 550)
      end

      cs = make_pay_slip_changeset(5000, 0, 12, 2026)
      assert_parity("pcb_employee", :pcb_employee, emp, cs)
    end

    test "EPF relief cap saturated YTD", %{com: com, admin: admin, emp: emp} do
      salary = ensure_salary_type(com, admin, "Monthly Salary", "Addition")
      epf = ensure_salary_type(com, admin, "EPF By Employee", "Deduction")

      for month <- 1..5 do
        insert_prior_note(emp, com, month, 2026, salary, 5000)
        insert_prior_note(emp, com, month, 2026, epf, 800)
      end

      cs = make_pay_slip_changeset(5000, 0, 6, 2026)
      assert_parity("pcb_employee", :pcb_employee, emp, cs)
    end
  end

  describe "effective dating" do
    test "socso_24hour :not_effective in May 2026, ok in June", %{com: com, admin: admin} do
      emp = make_employee(com, age: 35, admin: admin)
      cs_may = make_pay_slip_changeset(3000, 0, 5, 2026)
      cs_june = make_pay_slip_changeset(3000, 0, 6, 2026)

      # the registry knows the code, it just does not apply yet — must NOT
      # fall back to legacy (which has no date gate and would compute SKBBK)
      assert :not_effective = StatutoryConfig.calculate("socso_24hour", emp, cs_may)

      assert_parity("socso_24hour", :socso_24hour, emp, cs_june)
    end

    test "calculate_pay zeroes a not-yet-effective statutory line", %{com: com, admin: admin} do
      emp = make_employee(com, age: 35, admin: admin)

      cs =
        make_pay_slip_changeset(3000, 0, 5, 2026)
        |> Ecto.Changeset.put_assoc(:deductions, [
          SalaryNote.changeset_on_payslip(%SalaryNote{}, %{
            note_date: ~D[2026-05-31],
            quantity: 1,
            unit_price: 10,
            salary_type_name: "SOCSO 24 Hour",
            salary_type_type: "Deduction",
            cal_func: "socso_24hour"
          })
        ])

      cs = PaySlipOp.calculate_pay(cs, emp)

      note =
        Enum.find(
          Ecto.Changeset.get_field(cs, :deductions),
          &(&1.cal_func == "socso_24hour")
        )

      assert note
      assert Decimal.equal?(note.amount, Decimal.new(0))
    end
  end

  describe "calculate_pay dispatch" do
    test "falls back to legacy when epf_employee calc is deleted", %{com: com, admin: admin} do
      emp = make_employee(com, age: 35, admin: admin)

      cs =
        make_pay_slip_changeset(3000, 0, 6, 2026)
        |> Ecto.Changeset.put_assoc(:deductions, [
          SalaryNote.changeset_on_payslip(%SalaryNote{}, %{
            note_date: ~D[2026-06-30],
            quantity: 1,
            unit_price: 0,
            salary_type_name: "EPF By Employee",
            salary_type_type: "Deduction",
            cal_func: "epf_employee"
          })
        ])

      cs_seeded = PaySlipOp.calculate_pay(cs, emp)

      from(c in StatutoryCalc, where: c.company_id == ^com.id and c.code == "epf_employee")
      |> Repo.delete_all()

      # delete_all bypasses the context, so drop the cached versions too —
      # otherwise the second calculate_pay still sees the calc and never
      # exercises the legacy fallback
      FullCircle.StatutoryConfig.Cache.invalidate(com.id)

      cs_fallback = PaySlipOp.calculate_pay(cs, emp)

      epf_seeded =
        Enum.find(Ecto.Changeset.get_field(cs_seeded, :deductions), &(&1.cal_func == "epf_employee"))

      epf_fallback =
        Enum.find(Ecto.Changeset.get_field(cs_fallback, :deductions), &(&1.cal_func == "epf_employee"))

      assert epf_seeded
      assert epf_fallback
      assert Decimal.equal?(epf_seeded.amount, epf_fallback.amount)
    end
  end
end