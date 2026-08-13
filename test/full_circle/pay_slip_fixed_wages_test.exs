defmodule FullCircle.PaySlipFixedWagesTest do
  use FullCircle.DataCase

  alias FullCircle.HR.{PaySlip, SalaryNote}

  defp note_cs(type, amount, attrs \\ %{}) do
    Ecto.Changeset.change(
      %SalaryNote{},
      Map.merge(
        %{salary_type_type: type, amount: Decimal.new(amount)},
        attrs
      )
    )
  end

  defp base_changeset(additions) do
    %PaySlip{}
    |> Ecto.Changeset.change(%{pay_month: 1, pay_year: 2026})
    |> Ecto.Changeset.put_assoc(:additions, additions)
    |> Ecto.Changeset.put_assoc(:bonuses, [])
    |> Ecto.Changeset.put_assoc(:deductions, [])
    |> Ecto.Changeset.put_assoc(:advances, [])
  end

  describe "compute_fields/1" do
    test "fixed_wage_amount sums only FixedWages notes; addition_amount sums all wage notes" do
      cs =
        base_changeset([
          note_cs("FixedWages", "2000"),
          note_cs("FixedWages", "150.50"),
          note_cs("Addition", "500")
        ])
        |> PaySlip.compute_fields()

      assert Decimal.eq?(
               Ecto.Changeset.fetch_field!(cs, :addition_amount),
               Decimal.new("2650.50")
             )

      assert Decimal.eq?(
               Ecto.Changeset.fetch_field!(cs, :fixed_wage_amount),
               Decimal.new("2150.50")
             )
    end

    test "a deleted FixedWages note is excluded from fixed_wage_amount" do
      cs =
        base_changeset([
          note_cs("FixedWages", "2000"),
          note_cs("FixedWages", "999", %{delete: true})
        ])
        |> PaySlip.compute_fields()

      assert Decimal.eq?(
               Ecto.Changeset.fetch_field!(cs, :fixed_wage_amount),
               Decimal.new("2000")
             )
    end
  end

  describe "compute_struct_fields/1" do
    test "fixed_wage_amount sums FixedWages notes on a loaded slip" do
      slip = %PaySlip{
        additions: [
          %SalaryNote{salary_type_type: "FixedWages", amount: Decimal.new("1800")},
          %SalaryNote{salary_type_type: "Addition", amount: Decimal.new("300")}
        ],
        bonuses: [],
        deductions: [],
        advances: []
      }

      slip = PaySlip.compute_struct_fields(slip)

      assert Decimal.eq?(slip.addition_amount, Decimal.new("2100"))
      assert Decimal.eq?(slip.fixed_wage_amount, Decimal.new("1800"))
    end

    test "not-loaded additions yield zero fixed_wage_amount" do
      slip = %PaySlip{bonuses: [], deductions: [], advances: []}

      slip = PaySlip.compute_struct_fields(slip)

      assert Decimal.eq?(slip.fixed_wage_amount, Decimal.new("0"))
    end
  end
end
