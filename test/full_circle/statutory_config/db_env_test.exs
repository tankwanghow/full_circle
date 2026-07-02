defmodule FullCircle.StatutoryConfig.DbEnvTest do
  use FullCircle.DataCase, async: false

  alias FullCircle.StatutoryConfig
  alias FullCircle.StatutoryConfig.DbEnv
  alias FullCircle.HR.PaySlip
  alias FullCircle.PayScript.Error

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.HRFixtures

  defp make_pay_slip_changeset(addition, bonus, pay_month, pay_year) do
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

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    emp = employee_fixture(%{dob: ~D[1990-01-15]}, com, admin)

    %{com: com, user: admin, emp: emp}
  end

  test "lookup finds bracket value", %{com: com, emp: emp} do
    state = env_state(com, emp, 6, 2026)

    assert {:ok, 14.75} = DbEnv.lookup(state, "socso", 2950.0, "employee")
    assert {:ok, 0.0} = DbEnv.lookup(state, "socso", 0.5, "employee")
  end

  test "lookup errors on missing table version", %{com: com, emp: emp} do
    state = env_state(com, emp, 6, 2026)
    assert {:error, msg} = DbEnv.lookup(state, "ghost", 100.0, "employee")
    assert msg =~ "no version of table 'ghost'"
  end

  test "calculate returns configured calc result", %{com: com, emp: emp} do
    cs = make_pay_slip_changeset("3000", "0", 6, 2026)

    assert {:ok, dec} = StatutoryConfig.calculate("epf_employee", emp, cs)
    assert Decimal.equal?(dec, Decimal.new("330"))
  end

  test "calculate returns :not_found for unseeded code", %{com: com, emp: emp} do
    cs = make_pay_slip_changeset("3000", "0", 6, 2026)
    assert :not_found = StatutoryConfig.calculate("nonexistent_calc", emp, cs)
  end

  test "calculate surfaces script runtime errors", %{com: com, user: admin, emp: emp} do
    {:ok, _} =
      StatutoryConfig.save_calc(
        %{
          code: "boom",
          name: "Boom",
          effective_from: ~D[2026-01-01],
          script: "result = 1 / 0"
        },
        com,
        admin
      )

    cs = make_pay_slip_changeset("3000", "0", 6, 2026)
    assert {:error, %Error{message: msg}} = StatutoryConfig.calculate("boom", emp, cs)
    assert msg =~ "division by zero"
  end

  defp env_state(com, emp, month, year) do
    cs = make_pay_slip_changeset("3000", "0", month, year)
    date = Timex.end_of_month(year, month)

    %{
      company_id: com.id,
      date: date,
      context: StatutoryConfig.script_context(emp, cs),
      employee_id: emp.id,
      pay_month: month,
      pay_year: year
    }
  end
end