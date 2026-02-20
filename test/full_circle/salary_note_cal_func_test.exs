defmodule FullCircle.SalaryNoteCalFuncTest do
  use FullCircle.DataCase

  alias FullCircle.SalaryNoteCalFunc
  alias FullCircle.HR.PaySlip

  # Build a PaySlip changeset with the required virtual fields for calculation
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

  defp make_employee(opts \\ %{}) do
    %{
      id: Ecto.UUID.generate(),
      dob: opts[:dob] || ~D[1990-01-15],
      nationality: opts[:nationality] || "Malaysian",
      marital_status: opts[:marital_status] || "Single",
      partner_working: opts[:partner_working] || "No",
      children: opts[:children] || 0
    }
  end

  describe "EPF employee calculations" do
    test "Malaysian, age < 60: 11% of (addition + bonus)" do
      emp = make_employee(dob: ~D[1990-01-15])
      cs = make_pay_slip_changeset("3000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employee, emp, cs)

      # 3000 * 0.11 = 330, ceiling = 330
      assert Decimal.eq?(result, Decimal.from_float(330.0))
    end

    test "Malaysian, age < 60 with bonus included" do
      emp = make_employee(dob: ~D[1990-01-15])
      cs = make_pay_slip_changeset("3000", "1000", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employee, emp, cs)

      # 4000 * 0.11 = 440
      assert Decimal.eq?(result, Decimal.from_float(440.0))
    end

    test "Malaysian, age >= 60: 0%" do
      emp = make_employee(dob: ~D[1960-01-15])
      cs = make_pay_slip_changeset("3000", "0", 6, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.0))
    end

    test "non-Malaysian: 2%" do
      emp = make_employee(nationality: "Indonesian")
      cs = make_pay_slip_changeset("3000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employee, emp, cs)

      # 3000 * 0.02 = 60
      assert Decimal.eq?(result, Decimal.from_float(60.0))
    end

    test "income <= 10: 0" do
      emp = make_employee()
      cs = make_pay_slip_changeset("10", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.0))
    end
  end

  describe "EPF employer calculations" do
    test "Malaysian, age < 60, income <= 5000: 13%" do
      emp = make_employee(dob: ~D[1990-01-15])
      cs = make_pay_slip_changeset("3000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employer, emp, cs)

      # 3000 * 0.13 = 390
      assert Decimal.eq?(result, Decimal.from_float(390.0))
    end

    test "Malaysian, age < 60, income > 5000: 12%" do
      emp = make_employee(dob: ~D[1990-01-15])
      cs = make_pay_slip_changeset("6000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employer, emp, cs)

      # 6000 * 0.12 = 720
      assert Decimal.eq?(result, Decimal.from_float(720.0))
    end

    test "Malaysian, age >= 60: 4%" do
      emp = make_employee(dob: ~D[1960-01-15])
      cs = make_pay_slip_changeset("3000", "0", 6, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employer, emp, cs)

      # 3000 * 0.04 = 120
      assert Decimal.eq?(result, Decimal.from_float(120.0))
    end

    test "non-Malaysian: 2%" do
      emp = make_employee(nationality: "Bangladeshi")
      cs = make_pay_slip_changeset("3000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employer, emp, cs)

      # 3000 * 0.02 = 60
      assert Decimal.eq?(result, Decimal.from_float(60.0))
    end

    test "income <= 10: 0" do
      emp = make_employee()
      cs = make_pay_slip_changeset("5", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.0))
    end
  end

  describe "SOCSO employee calculations" do
    test "age <= 60: table lookup by income bracket" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 1500, table row [1400, 1500, 25.35, 7.25, 18.1] -> empe = 7.25
      cs = make_pay_slip_changeset("1500", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(7.25))
    end

    test "age > 60: 0" do
      emp = make_employee(dob: ~D[1960-01-15])
      cs = make_pay_slip_changeset("1500", "0", 6, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.0))
    end

    test "low income bracket" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 50, table row [30, 50, 0.7, 0.2, 0.5] -> empe = 0.2
      cs = make_pay_slip_changeset("50", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.2))
    end
  end

  describe "SOCSO employer calculations" do
    test "age <= 60: table lookup empr column" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 1500, table row [1400, 1500, 25.35, 7.25, 18.1] -> empr = 25.35
      cs = make_pay_slip_changeset("1500", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(25.35))
    end

    test "age > 60: table lookup empro column" do
      emp = make_employee(dob: ~D[1960-01-15])
      # Income 1500, table row [1400, 1500, 25.35, 7.25, 18.1] -> empro = 18.1
      cs = make_pay_slip_changeset("1500", "0", 6, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(18.1))
    end
  end

  describe "SOCSO employer only calculations" do
    test "always returns empro column regardless of age" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 1500, table row [1400, 1500, 25.35, 7.25, 18.1] -> empro = 18.1
      cs = make_pay_slip_changeset("1500", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employer_only, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(18.1))
    end
  end

  describe "EIS employee calculations" do
    test "age < 60: table lookup" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 1500, table row [1400, 1500, 2.90, 2.90, 5.80] -> empe = 2.90
      cs = make_pay_slip_changeset("1500", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:eis_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(2.9))
    end

    test "age >= 60: 0" do
      emp = make_employee(dob: ~D[1960-01-15])
      cs = make_pay_slip_changeset("1500", "0", 6, 2025)

      result = SalaryNoteCalFunc.calculate_value(:eis_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.0))
    end
  end

  describe "EIS employer calculations" do
    test "age < 60: table lookup" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 1500, table row [1400, 1500, 2.90, 2.90, 5.80] -> empr = 2.90
      cs = make_pay_slip_changeset("1500", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:eis_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(2.9))
    end

    test "age >= 60: 0" do
      emp = make_employee(dob: ~D[1960-01-15])
      cs = make_pay_slip_changeset("1500", "0", 6, 2025)

      result = SalaryNoteCalFunc.calculate_value(:eis_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(0.0))
    end
  end

  describe "edge cases" do
    test "high income bracket for SOCSO" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 6000+, table row [6000, 999_999, 104.15, 29.75, 74.40]
      cs = make_pay_slip_changeset("7000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:socso_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(104.15))
    end

    test "high income bracket for EIS" do
      emp = make_employee(dob: ~D[1990-01-15])
      # Income 6000+, table row [6000, 999_999, 11.90, 11.90, 23.80]
      cs = make_pay_slip_changeset("7000", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:eis_employer, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(11.9))
    end

    test "EPF ceiling applies for fractional income" do
      emp = make_employee(dob: ~D[1990-01-15])
      # 3333.33 * 0.11 = 366.6663, ceiling = 367
      cs = make_pay_slip_changeset("3333.33", "0", 1, 2025)

      result = SalaryNoteCalFunc.calculate_value(:epf_employee, emp, cs)
      assert Decimal.eq?(result, Decimal.from_float(367.0))
    end
  end
end
