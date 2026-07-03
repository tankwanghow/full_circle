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

  # LHDN allows CP204 revision (Form CP204A) in the 6th, 9th and — permanently
  # from YA 2024 (s.107C amendment) — 11th month of the basis period.
  @revision_months [6, 9, 11]

  @doc "FY basis-period months in which LHDN allows a CP204 revision (Form CP204A)."
  def revision_months, do: @revision_months

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

  defdelegate estimate_position(forecast_tax, chosen_estimate, tolerance_pct),
    to: FullCircle.Tax.Remedy

  defdelegate penalty_analysis(forecast_tax, chosen_estimate, tolerance_pct, corp_rate),
    to: FullCircle.Tax.Remedy

  defdelegate under_remedy_comparison(analysis, corp_rate, director_count, existing_income),
    to: FullCircle.Tax.Remedy

  defdelegate over_analysis(forecast_tax, chosen_estimate, tolerance_pct, instalments_paid),
    to: FullCircle.Tax.Remedy

  defdelegate over_remedy_comparison(analysis), to: FullCircle.Tax.Remedy

  @doc """
  Build the 12-month instalment schedule. `month_bounds` is the list of 12
  `{start, end}` tuples; `paid_by_month` is `%{month_no => Decimal}`;
  `revisions` is `%{revision_month => revised annual estimate}` (see
  `revisions_by_month/1`). The original `estimate` spreads evenly from
  `estimate_month`; at each revision month the instalment re-spreads as
  `(revised estimate - payable so far) / remaining months`, where payable =
  paid before `estimate_month` + scheduled instalments since. A month with
  tax already paid is settled — its displayed due is 0, but its scheduled
  instalment still counts toward payable. `balance` and `estimate_in_force`
  track the estimate in force each month.
  """
  def build_schedule(month_bounds, paid_by_month, estimate, estimate_month, revisions \\ %{}) do
    paid_to_date =
      Enum.reduce(1..(estimate_month - 1)//1, @zero, fn m, acc ->
        Decimal.add(acc, Map.get(paid_by_month, m, @zero))
      end)

    remaining = 12 - estimate_month + 1
    forward = Decimal.div(max_zero(Decimal.sub(estimate, paid_to_date)), Decimal.new(remaining))

    init = %{forward: forward, in_force: estimate, payable: paid_to_date}

    {months, _} =
      Enum.map_reduce(1..12, init, fn m, acc ->
        acc =
          case Map.fetch(revisions, m) do
            {:ok, revised} when m >= estimate_month ->
              new_forward =
                Decimal.div(
                  max_zero(Decimal.sub(revised, acc.payable)),
                  Decimal.new(12 - m + 1)
                )

              %{acc | forward: new_forward, in_force: revised}

            _ ->
              acc
          end

        scheduled = if m >= estimate_month, do: acc.forward, else: @zero

        {%{scheduled: scheduled, in_force: acc.in_force},
         %{acc | payable: Decimal.add(acc.payable, scheduled)}}
      end)

    {rows, _cum_paid} =
      month_bounds
      |> Enum.zip(months)
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {{{ps, pe}, month}, m}, cum_paid ->
        paid = Map.get(paid_by_month, m, @zero)

        due =
          if Decimal.compare(paid, @zero) == :gt,
            do: @zero,
            else: month.scheduled

        cum_paid2 = Decimal.add(cum_paid, paid)

        row = %{
          month_no: m,
          period_start: ps,
          period_end: pe,
          instalment_due: due,
          paid: paid,
          estimate_in_force: month.in_force,
          balance: Decimal.sub(month.in_force, cum_paid2)
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

  @doc """
  `%{month_no => Decimal}` paid amounts from the plan's manual overrides.
  Non-month keys (e.g. LiveView's `_unused_*` form-tracking keys) are dropped.
  """
  def paid_by_month(%InstalmentPlan{} = plan) do
    Enum.reduce(plan.paid_overrides || %{}, %{}, fn {k, v}, acc ->
      case to_month(k) do
        nil -> acc
        m -> Map.put(acc, m, to_decimal(v))
      end
    end)
  end

  @doc """
  `%{revision_month => Decimal}` CP204A revised annual estimates from the plan.
  Only months 6/9/11 are honoured; blank/unparseable values are dropped
  (blank means "not revised"); an explicit 0 is a valid revision.
  """
  def revisions_by_month(%InstalmentPlan{} = plan) do
    Enum.reduce(plan.revisions || %{}, %{}, fn {k, v}, acc ->
      m = to_month(k)

      case if(m in @revision_months, do: parse_decimal(v)) do
        %Decimal{} = dec -> Map.put(acc, m, dec)
        _ -> acc
      end
    end)
  end

  @doc "The estimate in force at year end: latest revision (11 -> 9 -> 6) or the original."
  def latest_estimate(%InstalmentPlan{} = plan) do
    rev = revisions_by_month(plan)
    rev[11] || rev[9] || rev[6] || plan.estimate || @zero
  end

  @doc "Full schedule for the plan: pure `build_schedule/5` fed with manual paid data and CP204A revisions."
  def schedule(%InstalmentPlan{} = plan, com) do
    bounds = PLF.fy_month_bounds(com, plan.fy_year)

    build_schedule(
      bounds,
      paid_by_month(plan),
      plan.estimate || @zero,
      plan.estimate_month || 1,
      revisions_by_month(plan)
    )
  end

  def get_plan(com, fy_year) do
    Repo.one(from p in InstalmentPlan, where: p.company_id == ^com.id and p.fy_year == ^fy_year)
  end

  @doc "Create or update the (company, fy_year) singleton plan, with an audit log entry."
  def create_or_update_plan(attrs, com, user) do
    fy_year = attrs["fy_year"] || attrs[:fy_year]
    plan = get_plan(com, fy_year) || %InstalmentPlan{}

    attrs =
      attrs
      |> Map.put("company_id", com.id)
      |> Map.replace_lazy("paid_overrides", &sanitize_overrides/1)
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

  # Keep only real month keys — form params carry `_unused_*` tracking keys.
  defp sanitize_overrides(m) when is_map(m) do
    for {k, v} <- m, to_month(k) != nil, into: %{}, do: {k, v}
  end

  defp sanitize_overrides(other), do: other

  defp to_month(m) when is_integer(m), do: m

  defp to_month(s) when is_binary(s) do
    case Integer.parse(s) do
      {m, ""} -> m
      _ -> nil
    end
  end

  defp to_month(_), do: nil
  # Unlike to_decimal/1, returns nil (not 0) for blank/junk — a revision
  # value must distinguish "not revised" from "revised to 0".
  defp parse_decimal(%Decimal{} = dec), do: dec
  defp parse_decimal(n) when is_integer(n) or is_float(n), do: Decimal.new("#{n}")

  defp parse_decimal(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {dec, _} -> dec
      :error -> nil
    end
  end

  defp parse_decimal(_), do: nil

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d

  # Form values arrive as strings and may be blank/garbage mid-edit.
  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {d, _} -> d
      :error -> @zero
    end
  end

  defp to_decimal(n), do: Decimal.new("#{n}")
end
