defmodule FullCircle.Tax.Remedy do
  @moduledoc """
  CP204 remedy analysis: under-estimation (penalty vs director fee) and
  over-estimation (revise estimate down). Pure Decimal math.
  """

  alias FullCircle.Tax.PersonalIncome

  @zero Decimal.new(0)
  @hundred Decimal.new(100)
  @penalty_rate Decimal.new("0.10")
  @marginal_threshold Decimal.new(5000)

  def estimate_position(forecast_tax, chosen_estimate, tolerance_pct) do
    floor = suggested_floor(forecast_tax, tolerance_pct)
    ceiling = penalty_ceiling(chosen_estimate, tolerance_pct)

    cond do
      Decimal.compare(chosen_estimate, floor) == :lt and
          Decimal.compare(forecast_tax, ceiling) == :gt ->
        :under

      Decimal.compare(forecast_tax, chosen_estimate) == :lt ->
        :over

      true ->
        :within
    end
  end

  def penalty_analysis(forecast_tax, chosen_estimate, tolerance_pct, corp_rate) do
    position = estimate_position(forecast_tax, chosen_estimate, tolerance_pct)
    ceiling = penalty_ceiling(chosen_estimate, tolerance_pct)
    excess_tax = max_zero(Decimal.sub(forecast_tax, ceiling)) |> money()
    penalty = excess_tax |> Decimal.mult(@penalty_rate) |> money()
    rate = corp_rate_percent(corp_rate)

    director_fee_needed =
      if Decimal.compare(rate, @zero) == :gt do
        excess_tax |> Decimal.div(Decimal.div(rate, @hundred)) |> money()
      else
        @zero
      end

    %{
      position: position,
      forecast_tax: forecast_tax,
      chosen_estimate: chosen_estimate,
      suggested_floor: suggested_floor(forecast_tax, tolerance_pct),
      penalty_ceiling: ceiling,
      excess_tax: excess_tax,
      penalty: penalty,
      director_fee_needed: director_fee_needed,
      profit_ceiling:
        if(Decimal.compare(rate, @zero) == :gt,
          do: Decimal.div(Decimal.mult(ceiling, @hundred), rate) |> money(),
          else: @zero
        ),
      excess_profit:
        if(Decimal.compare(rate, @zero) == :gt,
          do: Decimal.div(Decimal.mult(excess_tax, @hundred), rate) |> money(),
          else: @zero
        )
    }
  end

  def under_remedy_comparison(analysis, corp_rate, director_count, existing_income_per_director) do
    forecast_tax = analysis.forecast_tax
    fee = analysis.director_fee_needed
    count = Kernel.max(director_count, 1)
    per_share = Decimal.div(fee, Decimal.new(count))

    personal_tax =
      Enum.reduce(1..count, @zero, fn _, acc ->
        Decimal.add(
          acc,
          PersonalIncome.tax_on_additional(existing_income_per_director, per_share)
        )
      end)

    pay_penalty = %{
      company_tax: money(forecast_tax),
      penalty: analysis.penalty,
      personal_tax: @zero,
      total: forecast_tax |> Decimal.add(analysis.penalty) |> money(),
      refund: @zero
    }

    company_tax_after = analysis.penalty_ceiling

    director_fee = %{
      company_tax: money(company_tax_after),
      penalty: @zero,
      personal_tax: personal_tax,
      total: company_tax_after |> Decimal.add(personal_tax) |> money(),
      fee_amount: fee,
      extra_cash_movement:
        Decimal.sub(fee, Decimal.add(analysis.excess_tax, analysis.penalty))
    }

    delta = Decimal.sub(director_fee.total, pay_penalty.total)

    breakeven_rate =
      if Decimal.compare(fee, @zero) == :gt do
        Decimal.add(
          corp_rate_percent(corp_rate),
          Decimal.mult(Decimal.div(analysis.penalty, fee), @hundred)
        )
      else
        @zero
      end

    recommendation =
      cond do
        Decimal.abs(delta) |> Decimal.compare(@marginal_threshold) != :gt -> :marginal
        Decimal.compare(delta, @zero) == :gt -> :pay_penalty
        true -> :director_fee
      end

    %{
      pay_penalty: pay_penalty,
      director_fee: director_fee,
      delta: delta,
      breakeven_effective_rate: breakeven_rate,
      recommendation: recommendation
    }
  end

  def over_analysis(forecast_tax, chosen_estimate, tolerance_pct, instalments_paid) do
    position = estimate_position(forecast_tax, chosen_estimate, tolerance_pct)
    overpayment_tax = max_zero(Decimal.sub(chosen_estimate, forecast_tax)) |> money()
    ceiling = penalty_ceiling(chosen_estimate, tolerance_pct)
    headroom_tax = max_zero(Decimal.sub(ceiling, forecast_tax))

    %{
      position: position,
      forecast_tax: forecast_tax,
      chosen_estimate: chosen_estimate,
      overpayment_tax: overpayment_tax,
      expected_refund: max_zero(Decimal.sub(instalments_paid, forecast_tax)) |> money(),
      headroom_tax: headroom_tax,
      suggested_revised_estimate: suggested_floor(forecast_tax, tolerance_pct) |> money(),
      instalments_paid: instalments_paid
    }
  end

  def over_remedy_comparison(analysis) do
    %{
      recommendation: :revise_estimate,
      revised_estimate: analysis.suggested_revised_estimate,
      overpayment_tax: analysis.overpayment_tax,
      expected_refund: analysis.expected_refund
    }
  end

  def suggested_floor(forecast_tax, tolerance_pct) do
    if Decimal.compare(forecast_tax, @zero) != :gt do
      @zero
    else
      divisor = Decimal.add(@hundred, tolerance_pct)
      Decimal.div(Decimal.mult(forecast_tax, @hundred), divisor)
    end
  end

  def penalty_ceiling(chosen_estimate, tolerance_pct) do
    multiplier = Decimal.add(@hundred, tolerance_pct) |> Decimal.div(@hundred)
    Decimal.mult(chosen_estimate, multiplier)
  end

  defp money(d), do: Decimal.round(d, 2)

  defp corp_rate_percent(%Decimal{} = r), do: r
  defp corp_rate_percent(n), do: Decimal.new("#{n}")
  defp max_zero(d), do: if(Decimal.compare(d, @zero) == :lt, do: @zero, else: d)
end