defmodule FullCircle.Tax do
  @moduledoc """
  CP204 income-tax instalment planning. Pure computation (estimate, schedule
  re-spread, under-estimation check) plus DB/integration helpers that pull the
  forecast tax; instalment-paid amounts are entered manually. A planning aid,
  not a filed tax computation.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Tax.InstalmentPlan
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

  # ---- DB / integration ----

  @doc "The forecast's estimated annual tax for the FY, as of `as_of`."
  def forecast_annual_tax(com, fy_year, as_of) do
    PLF.pl_forecast(%{fy_year: fy_year, granularity: :monthly, as_of: as_of}, com).totals.estimated_tax
  end

  @doc "`%{month_no => Decimal}` paid amounts from the plan's manual overrides."
  def paid_by_month(%InstalmentPlan{} = plan) do
    for {k, v} <- plan.paid_overrides || %{}, into: %{} do
      {to_int(k), to_decimal(v)}
    end
  end

  @doc "Full schedule for the plan: pure `build_schedule/4` fed with manual paid data."
  def schedule(%InstalmentPlan{} = plan, com) do
    bounds = PLF.fy_month_bounds(com, plan.fy_year)
    build_schedule(bounds, paid_by_month(plan), plan.estimate || @zero, plan.estimate_month || 1)
  end

  def get_plan(com, fy_year) do
    Repo.one(from p in InstalmentPlan, where: p.company_id == ^com.id and p.fy_year == ^fy_year)
  end

  @doc "Create or update the (company, fy_year) singleton plan, with an audit log entry."
  def create_or_update_plan(attrs, com, user) do
    fy_year = attrs["fy_year"] || attrs[:fy_year]
    plan = get_plan(com, fy_year) || %InstalmentPlan{}
    attrs = Map.put(attrs, "company_id", com.id)
    name = :update_instalment_plan

    Multi.new()
    |> Multi.insert_or_update(name, InstalmentPlan.changeset(plan, attrs))
    |> Sys.insert_log_for(name, attrs, com, user)
    |> Repo.transaction()
    |> case do
      {:ok, %{^name => saved}} -> {:ok, saved}
      {:error, ^name, cs, _} -> {:error, cs}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
end
