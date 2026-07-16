defmodule FullCircle.Tax.PersonalIncomeTest do
  use ExUnit.Case, async: true
  alias FullCircle.Tax.PersonalIncome

  defp d(n), do: Decimal.new("#{n}")

  describe "tax_on_income/1" do
    test "zero and negative return 0" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d(0)), d(0))
      assert Decimal.equal?(PersonalIncome.tax_on_income(d(-1)), d(0))
    end

    test "first RM5,000 is tax-free" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d(5000)), d(0))
    end

    test "RM 4,303,155.54 matches Kim Poh single-director fixture" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d("4303155.54")), d("1219346.66"))
    end

    test "RM 1,434,385.18 matches Kim Poh three-director split fixture" do
      assert Decimal.equal?(PersonalIncome.tax_on_income(d("1434385.18")), d("370027.85"))
    end
  end

  describe "tax_on_additional/2" do
    test "marginal tax on top of existing income" do
      base = PersonalIncome.tax_on_income(d(360_000))
      total = PersonalIncome.tax_on_income(d(860_000))
      extra = PersonalIncome.tax_on_additional(d(360_000), d(500_000))
      assert Decimal.equal?(extra, Decimal.sub(total, base))
    end
  end
end
