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
  `estimate_month`. A CP204A filed in window month `r` locks every
  instalment through `r` — the re-spread takes effect from `r + 1`:
  `(revised estimate - payable through r) / (12 - r)`, where payable
  accumulates, per month, the HIGHER of the scheduled instalment and the
  actual paid amount (LHDN's CP204A deducts payments made; scheduled covers
  future months not yet paid when planning ahead). A month with tax already
  paid is settled — its displayed due is 0. `balance` and `estimate_in_force`
  track the estimate in force each month (flipping from `r + 1`).
  """
  def build_schedule(month_bounds, paid_by_month, estimate, estimate_month, revisions \\ %{}) do
    paid_to_date =
      Enum.reduce(1..(estimate_month - 1)//1, @zero, fn m, acc ->
        Decimal.add(acc, Map.get(paid_by_month, m, @zero))
      end)

    remaining = 12 - estimate_month + 1
    forward = Decimal.div(max_zero(Decimal.sub(estimate, paid_to_date)), Decimal.new(remaining))

    init = %{forward: forward, in_force: estimate, payable: @zero}

    {months, _} =
      Enum.map_reduce(1..12, init, fn m, acc ->
        # A revision filed in window month r = m - 1 (instalments 1..r are
        # locked) re-spreads from this month over the 12 - r months left.
        acc =
          case Map.fetch(revisions, m - 1) do
            {:ok, revised} when m - 1 >= estimate_month ->
              new_forward =
                Decimal.div(
                  max_zero(Decimal.sub(revised, acc.payable)),
                  Decimal.new(12 - (m - 1))
                )

              %{acc | forward: new_forward, in_force: revised}

            _ ->
              acc
          end

        scheduled = if m >= estimate_month, do: acc.forward, else: @zero
        paid = Map.get(paid_by_month, m, @zero)

        {%{scheduled: scheduled, in_force: acc.in_force},
         %{acc | payable: Decimal.add(acc.payable, Decimal.max(scheduled, paid))}}
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
          scheduled: month.scheduled,
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
  Only months 6/9/11 are honoured; blank, zero or unparseable values are
  dropped — in a money input 0 reads as "not revised", not "revised to nil".
  """
  def revisions_by_month(%InstalmentPlan{} = plan) do
    Enum.reduce(plan.revisions || %{}, %{}, fn {k, v}, acc ->
      m = to_month(k)

      case if(m in @revision_months, do: parse_decimal(v)) do
        %Decimal{} = dec ->
          if Decimal.compare(dec, @zero) == :gt, do: Map.put(acc, m, dec), else: acc

        _ ->
          acc
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

  @doc """
  Suggest CP204A values for the open revision windows: the minimum-payment,
  penalty-free plan. A window is open when it is at/after `cur_month`, not
  before the plan started, and no tax has been paid for a month after it
  (instalments through the filing month are locked — s.107C). Passed windows
  keep their saved values; open middle windows are cleared. The earliest open
  window "parks" the estimate at the amount already payable through it
  (dropping later instalments to 0) and the last open window carries
  `floor_estimate` (the penalty-free minimum, forecast tax / 1.3). Returns
  `{:ok, revisions}` with string keys/values ready for the plan form, or
  `{:error, :no_window}`.
  """
  def suggest_revisions(%InstalmentPlan{} = plan, com, cur_month, floor_estimate) do
    paid = paid_by_month(plan)

    last_paid_month =
      paid
      |> Enum.filter(fn {_m, v} -> Decimal.compare(v, @zero) == :gt end)
      |> Enum.map(fn {m, _} -> m end)
      |> case do
        [] -> 0
        months -> Enum.max(months)
      end

    est_month = plan.estimate_month || 1

    open =
      Enum.filter(@revision_months, fn r ->
        r >= cur_month and r >= est_month and last_paid_month <= r
      end)

    case open do
      [] ->
        {:error, :no_window}

      [first | _] = windows ->
        last = List.last(windows)

        kept =
          for {k, v} <- plan.revisions || %{}, to_month(k) not in windows, into: %{}, do: {k, v}

        parking =
          if first != last do
            %{plan | revisions: kept}
            |> schedule(com)
            |> payable_through(first)
            |> Decimal.round(2)
          end

        preview = put_positive(kept, "#{first}", parking)
        rows = schedule(%{plan | revisions: preview}, com)

        {:ok, put_positive(preview, "#{last}", final_revision(rows, last, floor_estimate))}
    end
  end

  # The last-window revision is only worth filing when it protects against
  # the under-estimation penalty (estimate in force below the floor) or when
  # it actually cuts the instalments still due after that window. Filing a
  # DOWNWARD revision that changes nothing (dues already 0, estimate already
  # above the floor) just lowers the estimate in force for no benefit.
  defp final_revision(rows, last, floor_estimate) do
    if Decimal.compare(floor_estimate, @zero) == :gt do
      floor = Decimal.round(floor_estimate, 2, :ceiling)
      in_force = Enum.at(rows, last - 1).estimate_in_force

      # Compare at 2dp — rounding the parked value leaves sub-sen residues in
      # the raw schedule that must not count as "dues worth cutting".
      new_dues =
        Decimal.round(max_zero(Decimal.sub(floor, payable_through(rows, last))), 2)

      old_dues =
        rows
        |> Enum.filter(&(&1.month_no > last))
        |> Enum.reduce(@zero, fn r, acc -> Decimal.add(acc, r.scheduled) end)
        |> Decimal.round(2)

      if Decimal.compare(floor, in_force) == :gt or Decimal.compare(new_dues, old_dues) == :lt,
        do: floor
    end
  end

  @doc "Cumulative payable (per month, the higher of scheduled and paid) through `month_no`."
  def payable_through(rows, month_no) do
    rows
    |> Enum.filter(&(&1.month_no <= month_no))
    |> Enum.reduce(@zero, fn r, acc -> Decimal.add(acc, Decimal.max(r.scheduled, r.paid)) end)
  end

  defp put_positive(map, _key, nil), do: map

  defp put_positive(map, key, %Decimal{} = v) do
    if Decimal.compare(v, @zero) == :gt, do: Map.put(map, key, Decimal.to_string(v)), else: map
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
      |> Map.replace_lazy("revisions", &sanitize_revisions/1)
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

  # Keep only CP204A revision months with positive values (blank/0 = not revised).
  defp sanitize_revisions(m) when is_map(m) do
    for {k, v} <- m,
        to_month(k) in @revision_months,
        dec = parse_decimal(v),
        dec != nil and Decimal.compare(dec, @zero) == :gt,
        into: %{},
        do: {k, v}
  end

  defp sanitize_revisions(other), do: other

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
