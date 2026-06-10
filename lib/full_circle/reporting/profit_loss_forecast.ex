defmodule FullCircle.Reporting.ProfitLossForecast do
  @moduledoc """
  Accrual profit & loss forecast over fixed-length periods, mirroring the cash
  forecast's "actuals-to-date + run-rate" approach.

  Elapsed periods (end <= today) show the REAL per-category P&L from posted
  transactions; future periods project each category from its trailing-window
  run-rate (anchored at today). Income categories (Revenue, Other Income) are
  credit-normal in the ledger, so amounts are sign-flipped to positive income;
  expense categories stay positive. Accounts listed in the company's settings are
  excluded from the run-rate (one-off / discretionary items).
  """

  alias FullCircle.Repo
  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.Sys.Company
  import Ecto.Query, warn: false

  @zero Decimal.new(0)

  @income_types ["Revenue", "Other Income"]
  @expense_types ["Cost Of Goods Sold", "Direct Costs", "Overhead", "Expenses", "Depreciation"]
  @pl_types @income_types ++ @expense_types

  # Categories in display order, with their per-category trailing-days setting.
  @categories [
    "Revenue",
    "Cost Of Goods Sold",
    "Direct Costs",
    "Overhead",
    "Expenses",
    "Other Income",
    "Depreciation"
  ]

  @trailing_key "pl_forecast_trailing"
  @default_trailing 365

  # The category line keys that sum across periods for the Total column.
  @sum_keys [
    :revenue,
    :cogs,
    :gross_profit,
    :direct_costs,
    :overhead,
    :expenses,
    :operating_profit,
    :other_income,
    :depreciation,
    :net_profit
  ]

  def income_types, do: @income_types
  def expense_types, do: @expense_types
  def categories, do: @categories
  def default_trailing, do: @default_trailing

  # ---- company settings (per-category trailing days) ----

  @doc """
  Per-category trailing-days window for the run-rate, read from the company
  settings: `%{account_type => days}`, each category defaulting to 365.
  """
  def category_trailing(com) do
    saved = Map.get(com.settings || %{}, @trailing_key, %{})

    Map.new(@categories, fn type ->
      {type, to_pos_int(Map.get(saved, type), @default_trailing)}
    end)
  end

  @doc "Persist the per-category trailing-days map (`%{account_type => days}`) to settings."
  def save_category_trailing(com, map) do
    cleaned =
      Map.new(@categories, fn type ->
        {type, to_pos_int(Map.get(map, type), @default_trailing)}
      end)

    settings = Map.put(com.settings || %{}, @trailing_key, cleaned)
    com |> Ecto.Changeset.change(settings: settings) |> Repo.update()
  end

  @doc "Return `com` with settings re-read fresh from the DB."
  def company_with_settings(com) do
    settings = Repo.one(from c in Company, where: c.id == ^com.id, select: c.settings)
    %{com | settings: settings || %{}}
  end

  defp to_pos_int(v, default) do
    case v do
      n when is_integer(n) and n > 0 -> n
      s when is_binary(s) -> (Integer.parse(s) |> elem_or(default)) |> pos_or(default)
      _ -> default
    end
  end

  defp elem_or(:error, default), do: default
  defp elem_or({n, _}, _default), do: n
  defp pos_or(n, _default) when is_integer(n) and n > 0, do: n
  defp pos_or(_, default), do: default

  # ---- forecast ----

  @doc """
  Full P&L forecast. `opts`: `:fy_year` (required), `:granularity`
  (`:monthly` | `:quarterly`). Per-category trailing windows come from the company
  settings.
  """
  def pl_forecast(opts, com) do
    fy_year = Map.fetch!(opts, :fy_year)
    granularity = Map.get(opts, :granularity, :monthly)
    trailing = category_trailing(com)
    today = Date.utc_today()

    {period_months, periods_count} =
      case granularity do
        :quarterly -> {3, 4}
        _ -> {1, 12}
      end

    pc = prev_close(com, fy_year)
    fy_end = add_months(pc, period_months * periods_count)
    bounds = period_bounds(pc, period_months, periods_count)

    trailing_daily = run_rate_daily_by_type(trailing, today, com)

    # For a category whose trailing run-rate is zero (e.g. depreciation, booked once a
    # year at year-end), fall back to the PREVIOUS financial year's total spread evenly.
    # If the previous year is also zero, leave it at zero (do nothing).
    prev_start = Date.add(prev_close(com, fy_year - 1), 1)
    prev_totals = prev_fy_by_type(prev_start, pc, com)
    prev_days = Decimal.new("#{Date.diff(pc, prev_start) + 1}")

    {daily, estimated} =
      Enum.reduce(@categories, {%{}, []}, fn type, {d, est} ->
        tr = Map.get(trailing_daily, type, @zero)
        pf = Map.get(prev_totals, type, @zero)

        if Decimal.equal?(tr, @zero) and not Decimal.equal?(pf, @zero) do
          {Map.put(d, type, Decimal.div(pf, prev_days)), [type | est]}
        else
          {Map.put(d, type, tr), est}
        end
      end)

    estimated_set = MapSet.new(estimated)
    actuals = actuals_by_type(pc, period_months, today, fy_end, com)

    by_type =
      bounds
      |> Enum.with_index()
      |> Enum.map(fn {{ps, pe}, i} ->
        days = Decimal.new("#{Date.diff(pe, ps) + 1}")
        spread = Map.new(daily, fn {t, r} -> {t, Decimal.mult(r, days)} end)

        if Date.compare(pe, today) != :gt do
          # estimated categories override the (lumpy / absent) real actuals for the
          # whole row; everything else keeps its real posted figure.
          bt =
            Enum.reduce(estimated_set, Map.get(actuals, i, %{}), fn t, acc ->
              Map.put(acc, t, Map.get(spread, t, @zero))
            end)

          {bt, :actual}
        else
          {spread, :forecast}
        end
      end)

    periods = build_periods(bounds, by_type)

    %{
      fy_year: fy_year,
      granularity: granularity,
      start_date: Date.add(pc, 1),
      fy_end: fy_end,
      period_months: period_months,
      periods_count: periods_count,
      trailing: trailing,
      estimated_types: estimated,
      periods: periods,
      totals: totals(periods)
    }
  end

  @doc """
  The financial-year closing date one period before the FY that ENDS in `year` —
  i.e. the day before the FY starts. Uses the company's `closing_month` /
  `closing_day` (defaults to 31 December = calendar year). All period boundaries are
  anchored on this closing day.
  """
  def prev_close(com, year) do
    cm = com.closing_month || 12
    cd = com.closing_day || 31
    clamp_date(year - 1, cm, cd)
  end

  @doc "Build the per-period P&L line rows (with subtotals, margins, cumulative net) — pure."
  def build_periods(bounds, by_type) do
    {rows, _} =
      Enum.zip(bounds, by_type)
      |> Enum.with_index(1)
      |> Enum.map_reduce(@zero, fn {{{ps, pe}, {bt, src}}, idx}, cum ->
        l = lines(bt)
        cum2 = Decimal.add(cum, l.net_profit)

        row =
          Map.merge(l, %{
            n: idx,
            period_start: ps,
            period_end: pe,
            source: src,
            gross_margin: margin(l.gross_profit, l.revenue),
            net_margin: margin(l.net_profit, l.revenue),
            cumulative_net: cum2
          })

        {row, cum2}
      end)

    rows
  end

  @doc "The P&L transactions behind an actual period's category — for drill-down."
  def period_category_transactions(account_type, from_date, to_date, com) do
    income? = account_type in @income_types

    from(t in Transaction,
      join: a in Account,
      on: a.id == t.account_id,
      where:
        t.company_id == ^com.id and a.account_type == ^account_type and
          t.doc_date >= ^from_date and t.doc_date <= ^to_date,
      select: %{
        date: t.doc_date,
        doc_type: t.doc_type,
        doc_no: t.doc_no,
        account: a.name,
        particulars: t.particulars,
        amount: t.amount
      },
      order_by: [t.doc_date, t.doc_no]
    )
    |> Repo.all()
    |> Enum.map(fn r ->
      amt = to_decimal(r.amount)
      %{r | amount: if(income?, do: Decimal.negate(amt), else: amt)}
    end)
  end

  # ---- internals ----

  defp lines(bt) do
    g = fn t -> Map.get(bt, t, @zero) end

    revenue = g.("Revenue")
    cogs = g.("Cost Of Goods Sold")
    gross = Decimal.sub(revenue, cogs)

    direct = g.("Direct Costs")
    overhead = g.("Overhead")
    expenses = g.("Expenses")
    operating = gross |> Decimal.sub(direct) |> Decimal.sub(overhead) |> Decimal.sub(expenses)

    other = g.("Other Income")
    deprec = g.("Depreciation")
    net = operating |> Decimal.add(other) |> Decimal.sub(deprec)

    %{
      revenue: revenue,
      cogs: cogs,
      gross_profit: gross,
      direct_costs: direct,
      overhead: overhead,
      expenses: expenses,
      operating_profit: operating,
      other_income: other,
      depreciation: deprec,
      net_profit: net
    }
  end

  defp margin(num, revenue) do
    if Decimal.compare(revenue, @zero) == :eq do
      @zero
    else
      Decimal.round(Decimal.mult(Decimal.div(num, revenue), 100), 1)
    end
  end

  defp totals(periods) do
    base =
      Map.new(@sum_keys, fn k ->
        {k, Enum.reduce(periods, @zero, fn p, a -> Decimal.add(a, Map.get(p, k)) end)}
      end)

    base
    |> Map.put(:gross_margin, margin(base.gross_profit, base.revenue))
    |> Map.put(:net_margin, margin(base.net_profit, base.revenue))
  end

  defp normalize(type, raw) when type in @income_types, do: Decimal.negate(to_decimal(raw))
  defp normalize(_type, raw), do: to_decimal(raw)

  # Closing-day-anchored period bounds. `pc` is the day before the FY starts; each
  # period spans (pc + (i-1)*period_months .. pc + i*period_months], on the closing day.
  defp period_bounds(pc, period_months, n) do
    for i <- 1..n do
      {Date.add(add_months(pc, (i - 1) * period_months), 1), add_months(pc, i * period_months)}
    end
  end

  # %{period_index(0-based) => %{account_type => normalized value}} for elapsed periods.
  # Periods are closing-day anchored: a transaction's period is determined by how many
  # closing anchors after `pc` it falls (a day after the closing day rolls to next period).
  defp actuals_by_type(pc, period_months, today, fy_end, com) do
    upper = if Date.compare(today, fy_end) == :lt, do: today, else: fy_end
    fy_start = Date.add(pc, 1)

    if Date.compare(upper, fy_start) == :lt do
      %{}
    else
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where:
          t.company_id == ^com.id and a.account_type in ^@pl_types and
            t.doc_date >= ^fy_start and t.doc_date <= ^upper,
        select: %{
          idx:
            selected_as(
              fragment(
                "floor((((extract(year from ?) - extract(year from ?::date)) * 12 + (extract(month from ?) - extract(month from ?::date)) + (case when extract(day from ?) > extract(day from ?::date) then 1 else 0 end) - 1) / ?))::int",
                t.doc_date,
                ^pc,
                t.doc_date,
                ^pc,
                t.doc_date,
                ^pc,
                ^period_months
              ),
              :idx
            ),
          type: a.account_type,
          sum: sum(t.amount)
        },
        group_by: [selected_as(:idx), a.account_type]
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn r, acc ->
        Map.update(acc, r.idx, %{r.type => normalize(r.type, r.sum)}, fn m ->
          Map.put(m, r.type, normalize(r.type, r.sum))
        end)
      end)
    end
  end

  # %{account_type => normalized per-DAY run-rate value}. Each category uses its own
  # trailing window (`trailing` is `%{account_type => days}`). The caller multiplies
  # by each period's day-count.
  defp run_rate_daily_by_type(trailing, today, com) do
    Map.new(@categories, fn type ->
      days = Map.get(trailing, type, @default_trailing)
      window_start = Date.add(today, -days)

      sum =
        from(t in Transaction,
          join: a in Account,
          on: a.id == t.account_id,
          where:
            t.company_id == ^com.id and a.account_type == ^type and
              t.doc_date >= ^window_start and t.doc_date < ^today,
          select: coalesce(sum(t.amount), 0)
        )
        |> Repo.one()

      {type, normalize(type, Decimal.div(to_decimal(sum), Decimal.new("#{days}")))}
    end)
  end

  # %{account_type => normalized total} over the previous financial year [from..to].
  defp prev_fy_by_type(from_date, to_date, com) do
    from(t in Transaction,
      join: a in Account,
      on: a.id == t.account_id,
      where:
        t.company_id == ^com.id and a.account_type in ^@pl_types and
          t.doc_date >= ^from_date and t.doc_date <= ^to_date,
      select: %{type: a.account_type, sum: sum(t.amount)},
      group_by: a.account_type
    )
    |> Repo.all()
    |> Map.new(fn r -> {r.type, normalize(r.type, r.sum)} end)
  end

  # Shift `date` by `n` calendar months, clamping the day to the target month's length.
  defp add_months(date, n) do
    total = date.year * 12 + (date.month - 1) + n
    y = div(total, 12)
    m = rem(total, 12) + 1
    clamp_date(y, m, date.day)
  end

  defp clamp_date(y, m, d) do
    Date.new!(y, m, min(d, Date.days_in_month(Date.new!(y, m, 1))))
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
end
