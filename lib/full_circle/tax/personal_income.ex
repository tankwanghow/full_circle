defmodule FullCircle.Tax.PersonalIncome do
  @moduledoc """
  Malaysia resident individual income tax (YA2025 schedule).
  Planning aid only — no reliefs, no non-resident rates.
  """

  @zero Decimal.new(0)

  @brackets [
    {5_000, "0.00"},
    {20_000, "0.01"},
    {35_000, "0.03"},
    {50_000, "0.06"},
    {70_000, "0.11"},
    {100_000, "0.19"},
    {400_000, "0.25"},
    {600_000, "0.26"},
    {2_000_000, "0.28"},
    {:infinity, "0.30"}
  ]

  def tax_on_income(income) do
    income = to_decimal(income)

    if Decimal.compare(income, @zero) != :gt do
      @zero
    else
      tax_in_band(income)
    end
  end

  def tax_on_additional(existing, additional) do
    Decimal.sub(
      tax_on_income(Decimal.add(existing, additional)),
      tax_on_income(existing)
    )
  end

  defp tax_in_band(income) do
    Enum.reduce(@brackets, {@zero, @zero}, fn {limit, rate_str}, {acc, prev_top} ->
      rate = Decimal.new(rate_str)

      top =
        case limit do
          :infinity -> income
          n -> Decimal.min(income, Decimal.new(n))
        end

      band = top |> Decimal.sub(prev_top) |> Decimal.max(@zero)
      {Decimal.add(acc, Decimal.mult(band, rate)), top}
    end)
    |> elem(0)
    |> Decimal.round(2)
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
end