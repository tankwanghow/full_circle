defmodule FullCircle.Tax do
  @moduledoc """
  CP204 income-tax instalment planning. Pure computation (estimate, schedule
  re-spread, under-estimation check) plus DB/integration helpers that pull the
  forecast tax and GL-paid amounts. A planning aid, not a filed tax computation.
  """

  alias FullCircle.Reporting.ProfitLossForecast, as: PLF

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  # ---- pure computation ----

  @doc "Safe minimum CP204 estimate = forecast_tax / (1 + tolerance/100). 0 when forecast <= 0."
  def suggested_estimate(forecast_tax, tolerance_pct) do
    if Decimal.compare(forecast_tax, @zero) != :gt do
      @zero
    else
      divisor = Decimal.add(@hundred, tolerance_pct)
      Decimal.div(Decimal.mult(forecast_tax, @hundred), divisor)
    end
  end

  @doc "True when the chosen estimate is below the penalty-free floor (= suggested_estimate)."
  def under_estimated?(estimate, forecast_tax, tolerance_pct) do
    Decimal.compare(estimate, suggested_estimate(forecast_tax, tolerance_pct)) == :lt
  end

  @doc """
  Build the 12-month instalment schedule. `month_bounds` is the list of 12
  `{start, end}` tuples; `paid_by_month` is `%{month_no => Decimal}`. The whole
  schedule reflects only the current `estimate`, re-spread from `estimate_month`.
  """
  def build_schedule(month_bounds, paid_by_month, estimate, estimate_month) do
    paid_to_date =
      Enum.reduce(1..(estimate_month - 1)//1, @zero, fn m, acc ->
        Decimal.add(acc, Map.get(paid_by_month, m, @zero))
      end)

    remaining = 12 - estimate_month + 1
    forward = Decimal.div(max_zero(Decimal.sub(estimate, paid_to_date)), Decimal.new(remaining))

    {rows, _cum_paid} =
      month_bounds
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {{ps, pe}, m}, cum_paid ->
        due = if m >= estimate_month, do: forward, else: @zero
        paid = Map.get(paid_by_month, m, @zero)
        cum_paid2 = Decimal.add(cum_paid, paid)

        row = %{
          month_no: m,
          period_start: ps,
          period_end: pe,
          instalment_due: due,
          paid: paid,
          balance: Decimal.sub(estimate, cum_paid2)
        }

        {row, cum_paid2}
      end)

    rows
  end

  @doc "FY month index (1..12) containing `as_of`, clamped to the range."
  def current_fy_month(com, fy_year, as_of) do
    bounds = PLF.fy_month_bounds(com, fy_year)

    cond do
      Date.compare(as_of, elem(hd(bounds), 0)) == :lt -> 1
      Date.compare(as_of, elem(List.last(bounds), 1)) == :gt -> 12
      true ->
        bounds
        |> Enum.with_index(1)
        |> Enum.find_value(1, fn {{ps, pe}, m} ->
          if Date.compare(as_of, ps) != :lt and Date.compare(as_of, pe) != :gt, do: m
        end)
    end
  end

  defp max_zero(d), do: if(Decimal.compare(d, @zero) == :lt, do: @zero, else: d)
end
