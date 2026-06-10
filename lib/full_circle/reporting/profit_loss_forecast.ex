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

  @exclude_key "pl_forecast_exclude_accounts"

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

  # ---- company settings (exclusion list) ----

  @doc "Account ids excluded from the P&L run-rate (from the company's settings)."
  def excluded_account_ids(com), do: Map.get(com.settings || %{}, @exclude_key, [])

  @doc "Persist the P&L run-rate exclusion account-id list to the company settings."
  def save_excluded_account_ids(com, ids) when is_list(ids) do
    settings = Map.put(com.settings || %{}, @exclude_key, ids)
    com |> Ecto.Changeset.change(settings: settings) |> Repo.update()
  end

  @doc "Return `com` with settings re-read fresh from the DB."
  def company_with_settings(com) do
    settings = Repo.one(from c in Company, where: c.id == ^com.id, select: c.settings)
    %{com | settings: settings || %{}}
  end

  @doc "P&L accounts for the company, for the exclusion picker."
  def list_pl_accounts(com) do
    from(a in Account,
      where: a.company_id == ^com.id and a.account_type in ^@pl_types,
      order_by: [a.account_type, a.name],
      select: %{id: a.id, name: a.name, account_type: a.account_type}
    )
    |> Repo.all()
  end

  # ---- forecast ----

  @doc """
  Full P&L forecast. `opts`: `:start_date`, `:period_days` (default 30),
  `:periods_count` (default 12), `:trailing_days` (default 365).
  """
  def pl_forecast(opts, com) do
    start_date = Map.fetch!(opts, :start_date)
    period_days = Map.get(opts, :period_days, 30)
    periods_count = Map.get(opts, :periods_count, 12)
    trailing_days = Map.get(opts, :trailing_days, 365)
    today = Date.utc_today()

    bounds = period_bounds(start_date, period_days, periods_count)
    excluded = excluded_account_ids(com)

    run_rate = run_rate_by_type(trailing_days, period_days, today, com, excluded)
    actuals = actuals_by_type(start_date, period_days, periods_count, today, com)

    by_type =
      bounds
      |> Enum.with_index()
      |> Enum.map(fn {{_ps, pe}, i} ->
        if Date.compare(pe, today) != :gt do
          {Map.get(actuals, i, %{}), :actual}
        else
          {run_rate, :forecast}
        end
      end)

    periods = build_periods(bounds, by_type)

    %{
      start_date: start_date,
      period_days: period_days,
      periods_count: periods_count,
      trailing_days: trailing_days,
      periods: periods,
      totals: totals(periods)
    }
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

  # %{period_index(0-based) => %{account_type => normalized value}} for elapsed periods.
  defp actuals_by_type(start_date, period_days, periods_count, today, com) do
    horizon_end = Date.add(start_date, period_days * periods_count)
    upper = if Date.compare(today, horizon_end) == :lt, do: today, else: horizon_end

    if Date.compare(upper, start_date) != :gt do
      %{}
    else
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where:
          t.company_id == ^com.id and a.account_type in ^@pl_types and
            t.doc_date >= ^start_date and t.doc_date < ^upper,
        select: %{
          idx: selected_as(fragment("(? - ?) / ?", t.doc_date, ^start_date, ^period_days), :idx),
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

  # %{account_type => normalized per-period run-rate value}, anchored at today.
  defp run_rate_by_type(trailing_days, period_days, today, com, excluded_ids) do
    window_start = Date.add(today, -trailing_days)

    base =
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where:
          t.company_id == ^com.id and a.account_type in ^@pl_types and
            t.doc_date >= ^window_start and t.doc_date < ^today,
        select: %{type: a.account_type, sum: sum(t.amount)},
        group_by: a.account_type
      )

    query =
      if excluded_ids == [],
        do: base,
        else: from([t, _a] in base, where: t.account_id not in ^excluded_ids)

    factor = Decimal.div(Decimal.new("#{period_days}"), Decimal.new("#{trailing_days}"))

    query
    |> Repo.all()
    |> Map.new(fn r -> {r.type, normalize(r.type, Decimal.mult(to_decimal(r.sum), factor))} end)
  end

  defp period_bounds(start_date, period_days, n) do
    for i <- 0..(n - 1) do
      ps = Date.add(start_date, i * period_days)
      {ps, Date.add(ps, period_days - 1)}
    end
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
end
