defmodule FullCircle.Reporting.CashForecast do
  @moduledoc """
  Rolling cash forecast and fixed-deposit tenure ladder over fixed-length periods
  (a configurable number of days per bucket). Pure core (`build_forecast/3`,
  `fd_ladder/2`, `distribute_outstanding/4`) plus DB query helpers.
  """

  alias FullCircle.Repo
  alias FullCircle.Accounting.{Account, Transaction}
  import Ecto.Query, warn: false
  import FullCircle.Helpers, only: [exec_query_map: 3]

  defp dump_uuid!(<<_::binary-size(16)>> = bin), do: bin

  defp dump_uuid!(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, bin} -> bin
      :error -> raise ArgumentError, "invalid UUID: #{inspect(uuid)}"
    end
  end

  @zero Decimal.new(0)

  # Fixed-deposit ladder tenures, expressed in days (~1, 3, 6, 12 months).
  @tenure_days [{:"1mo", 30}, {:"3mo", 90}, {:"6mo", 180}, {:"12mo", 365}]

  @liquid_types ["Cash or Equivalent", "Bank"]

  def liquid_account_types, do: @liquid_types

  @doc "Account ids of liquid type for the company. `:all` or a list of ids to restrict."
  def liquid_account_ids(com, :all) do
    from(a in Account,
      where: a.company_id == ^com.id and a.account_type in ^@liquid_types,
      select: a.id
    )
    |> Repo.all()
  end

  def liquid_account_ids(com, ids) when is_list(ids) do
    from(a in Account,
      where:
        a.company_id == ^com.id and a.account_type in ^@liquid_types and a.id in ^ids,
      select: a.id
    )
    |> Repo.all()
  end

  @doc "Balance of liquid accounts strictly before `start_date`."
  def opening_liquid_balance(account_ids, start_date, com) do
    from(t in Transaction,
      where:
        t.company_id == ^com.id and t.account_id in ^account_ids and
          t.doc_date < ^start_date,
      select: coalesce(sum(t.amount), 0)
    )
    |> Repo.one()
    |> to_decimal()
  end

  @doc "Already-posted liquid transactions dated on/after start within the horizon."
  def posted_future_flows(account_ids, start_date, end_date, com) do
    from(t in Transaction,
      where:
        t.company_id == ^com.id and t.account_id in ^account_ids and
          t.doc_date >= ^start_date and t.doc_date <= ^end_date,
      select: %{date: t.doc_date, amount: t.amount}
    )
    |> Repo.all()
    |> Enum.map(fn %{date: date, amount: amt} ->
      amt = to_decimal(amt)
      if Decimal.compare(amt, @zero) == :lt do
        %{date: date, in: @zero, out: Decimal.abs(amt), kind: :posted}
      else
        %{date: date, in: amt, out: @zero, kind: :posted}
      end
    end)
  end

  @doc """
  Per-period average in/out from contact-null liquid txns over the trailing
  `trailing_days` ending the day before `start_date`, scaled to a `period_days`
  bucket. Returns `{baseline_in, baseline_out}`.
  """
  def baseline_flows(account_ids, start_date, trailing_days, period_days, com) do
    window_start = Date.add(start_date, -trailing_days)

    rows =
      from(t in Transaction,
        where:
          t.company_id == ^com.id and t.account_id in ^account_ids and
            is_nil(t.contact_id) and
            t.doc_date >= ^window_start and t.doc_date < ^start_date,
        select: %{
          ins: sum(fragment("case when ? > 0 then ? else 0 end", t.amount, t.amount)),
          outs: sum(fragment("case when ? < 0 then -? else 0 end", t.amount, t.amount))
        }
      )
      |> Repo.one()

    # daily rate over the window, scaled up to one period
    factor = Decimal.div(Decimal.new("#{period_days}"), Decimal.new("#{trailing_days}"))
    {Decimal.mult(to_decimal(rows && rows.ins), factor),
     Decimal.mult(to_decimal(rows && rows.outs), factor)}
  end

  @doc "Clamp a due date to the forecast start (past-due items become due immediately)."
  def clamp_due(due_date, start_date) do
    if Date.compare(due_date, start_date) == :lt, do: start_date, else: due_date
  end

  @doc "Open sales-invoice balances grouped by due_date: `[%{due_date, amount}]` (amount >= 0)."
  def outstanding_ar_by_due(com), do: outstanding_by_due(:ar, com)

  @doc "Open purchase-invoice balances grouped by due_date: `[%{due_date, amount}]` (amount >= 0)."
  def outstanding_ap_by_due(com), do: outstanding_by_due(:ap, com)

  # direction: :ar -> sales invoices; :ap -> purchase invoices
  defp outstanding_by_due(direction, com) do
    {doc_type, inv_table, date_col} =
      case direction do
        :ar -> {"Invoice", "invoices", "due_date"}
        :ap -> {"PurInvoice", "pur_invoices", "due_date"}
      end

    com_id_bin = dump_uuid!(com.id)

    # An invoice posts BOTH a receivable/payable line (contact set) and contra
    # revenue/cost lines (contact_id nil) that net the document to zero. Only the
    # contact-bearing line is money owed — `contact_id is not null` filters out
    # the contra lines (without it, AR/AP outstanding is massively overstated).
    sql = """
      with outstanding as (
        select t.doc_id,
               t.amount
                 + coalesce(sum(stm.match_amount), 0)
                 + coalesce(sum(tm.match_amount), 0) as balance
          from transactions t
          left outer join seed_transaction_matchers stm on stm.transaction_id = t.id
          left outer join transaction_matchers tm on tm.transaction_id = t.id
         where t.company_id = $1
           and t.doc_type = $2
           and t.doc_id is not null
           and t.contact_id is not null
         group by t.id
        having t.amount
                 + coalesce(sum(stm.match_amount), 0)
                 + coalesce(sum(tm.match_amount), 0) <> 0
      )
      select inv.#{date_col} as due_date, sum(o.balance) as balance
        from outstanding o
        join #{inv_table} inv on inv.id = o.doc_id
       group by inv.#{date_col}
      having sum(o.balance) <> 0
    """

    exec_query_map(sql, [com_id_bin, doc_type], FullCircle.Repo)
    |> Enum.map(fn %{due_date: due, balance: bal} ->
      %{due_date: due, amount: Decimal.abs(to_decimal(bal))}
    end)
  end

  @doc """
  Empirical payment-lag profile from the trailing `trailing_days` of matching
  history: `%{period_lag => fraction_of_value}`, where `period_lag` is the number
  of whole `period_days`-length periods between an invoice's due_date and when it
  was actually paid (negative = paid early). Falls back to `%{0 => 1}` (pay in the
  due period) when there is no history. Company-scoped.
  """
  def payment_lag_profile(direction, com, period_days, trailing_days \\ 365) do
    {doc_type, inv_table, date_col} =
      case direction do
        :ar -> {"Invoice", "invoices", "due_date"}
        :ap -> {"PurInvoice", "pur_invoices", "due_date"}
      end

    com_id_bin = dump_uuid!(com.id)
    cutoff = Date.add(Date.utc_today(), -trailing_days)

    # Matchers attach to the invoice's contact line via transaction_id; tm.doc_date
    # is the actual settlement date. Lag is whole periods from the due_date.
    sql = """
      select floor((tm.doc_date - inv.#{date_col})::numeric / $4)::int as lag,
             sum(abs(tm.match_amount)) as amt
        from transaction_matchers tm
        join transactions t on t.id = tm.transaction_id
        join #{inv_table} inv on inv.id = t.doc_id
       where t.company_id = $1
         and t.doc_type = $2
         and t.contact_id is not null
         and tm.doc_date >= $3
       group by 1
    """

    rows = exec_query_map(sql, [com_id_bin, doc_type, cutoff, period_days], FullCircle.Repo)
    total = Enum.reduce(rows, @zero, fn r, a -> Decimal.add(a, to_decimal(r.amt)) end)

    if Decimal.compare(total, @zero) == :gt do
      Map.new(rows, fn r -> {r.lag, Decimal.div(to_decimal(r.amt), total)} end)
    else
      %{0 => Decimal.new(1)}
    end
  end

  @doc """
  Spread each open document's outstanding across the forecast periods using the lag
  `profile`. `open` is `[%{due_date, amount}]`; `period_starts` the ordered list of
  period-start dates; `period_days` the bucket length. Returns per-period totals
  (same length as `period_starts`).

  A document's payment lands in period `due_period + lag`. Lag buckets that fall
  before the first period (already elapsed, for overdue invoices) or after the last
  period (the slow tail) are simply not placed — a conservative, non-renormalized
  estimate.
  """
  def distribute_outstanding(open, profile, period_starts, period_days) do
    start = hd(period_starts)
    zeros = List.duplicate(@zero, length(period_starts))

    Enum.reduce(open, zeros, fn %{due_date: due, amount: amt}, acc ->
      due_idx = Integer.floor_div(Date.diff(due, start), period_days)

      acc
      |> Enum.with_index()
      |> Enum.map(fn {period_total, p} ->
        frac = Map.get(profile, p - due_idx, @zero)
        Decimal.add(period_total, Decimal.mult(amt, frac))
      end)
    end)
  end

  @doc "In-hand received cheques (not deposited, not returned) as inflow on due_date."
  def known_inflow_cheques(start_date, end_date, com) do
    FullCircle.Reporting.post_dated_cheques("", "In-Hand", "", Date.to_iso8601(end_date), com)
    |> Enum.filter(fn c -> c.due_date && Date.compare(c.due_date, end_date) != :gt end)
    |> Enum.map(fn c ->
      %{date: clamp_due(c.due_date, start_date), in: to_decimal(c.amount), out: @zero, kind: :known}
    end)
  end

  @doc """
  Full forecast. `opts` is a map with `:start_date`, `:period_days` (default 30),
  `:periods_count` (default 12), `:buffer_periods` (default 1), `:trailing_days`
  (default 365), `:account_ids` (`:all` or list).
  """
  def cash_forecast(opts, com) do
    start_date = Map.fetch!(opts, :start_date)
    period_days = Map.get(opts, :period_days, 30)
    periods_count = Map.get(opts, :periods_count, 12)
    buffer_periods = Map.get(opts, :buffer_periods, 1)
    trailing_days = Map.get(opts, :trailing_days, 365)
    account_sel = Map.get(opts, :account_ids, :all)

    end_date = Date.add(start_date, period_days * periods_count - 1)
    ids = liquid_account_ids(com, account_sel)

    opening = opening_liquid_balance(ids, start_date, com)
    {bin, bout} = baseline_flows(ids, start_date, trailing_days, period_days, com)

    period_starts = for i <- 0..(periods_count - 1), do: Date.add(start_date, i * period_days)

    ar_periodly =
      distribute_outstanding(
        outstanding_ar_by_due(com),
        payment_lag_profile(:ar, com, period_days, trailing_days),
        period_starts,
        period_days
      )

    ap_periodly =
      distribute_outstanding(
        outstanding_ap_by_due(com),
        payment_lag_profile(:ap, com, period_days, trailing_days),
        period_starts,
        period_days
      )

    spread_events =
      Enum.map(Enum.zip(ar_periodly, period_starts), fn {amt, ps} ->
        %{date: ps, in: amt, out: @zero, kind: :known}
      end) ++
        Enum.map(Enum.zip(ap_periodly, period_starts), fn {amt, ps} ->
          %{date: ps, in: @zero, out: amt, kind: :known}
        end)

    events =
      posted_future_flows(ids, start_date, end_date, com) ++
        known_inflow_cheques(start_date, end_date, com) ++
        spread_events

    build_forecast(
      %{opening: opening, baseline_in: bin, baseline_out: bout, events: events},
      start_date,
      period_days: period_days, periods_count: periods_count, buffer_periods: buffer_periods
    )
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")

  @doc """
  Build the forecast from already-fetched raw inputs.

  `raw` is `%{opening, baseline_in, baseline_out, events}` where events is a list
  of `%{date, in, out, kind}`. `opts` carries `:period_days`, `:periods_count`,
  `:buffer_periods`. Returns the forecast result map.
  """
  def build_forecast(raw, start_date, opts) do
    period_days = Keyword.fetch!(opts, :period_days)
    periods_count = Keyword.fetch!(opts, :periods_count)
    buffer_periods = Keyword.fetch!(opts, :buffer_periods)

    bounds = period_bounds(start_date, period_days, periods_count)
    known = bucket_events(raw.events, start_date, period_days, periods_count)

    periods =
      bounds
      |> Enum.with_index(1)
      |> roll_forward(known, raw.opening, raw.baseline_in, raw.baseline_out)
      |> apply_buffer(buffer_periods)

    %{
      start_date: start_date,
      period_days: period_days,
      periods_count: periods_count,
      buffer_periods: buffer_periods,
      opening: raw.opening,
      baseline_in: raw.baseline_in,
      baseline_out: raw.baseline_out,
      periods: periods,
      ladder: fd_ladder(periods, period_days)
    }
  end

  # List of {period_start, period_end} for n consecutive period_days-length windows.
  defp period_bounds(start_date, period_days, n) do
    for i <- 0..(n - 1) do
      ps = Date.add(start_date, i * period_days)
      {ps, Date.add(ps, period_days - 1)}
    end
  end

  # %{period_index(1-based) => %{in, out}} for events inside the horizon.
  # Events before start land in period 1; events after the horizon are dropped.
  defp bucket_events(events, start_date, period_days, n) do
    last_end = Date.add(start_date, period_days * n - 1)

    Enum.reduce(events, %{}, fn ev, acc ->
      if Date.compare(ev.date, last_end) == :gt do
        acc
      else
        i = Integer.floor_div(Date.diff(ev.date, start_date), period_days)
        idx = (i + 1) |> max(1) |> min(n)
        cur = Map.get(acc, idx, %{in: @zero, out: @zero})
        Map.put(acc, idx, %{in: Decimal.add(cur.in, ev.in), out: Decimal.add(cur.out, ev.out)})
      end
    end)
  end

  defp roll_forward(indexed_bounds, known, opening, baseline_in, baseline_out) do
    {rows, _} =
      Enum.map_reduce(indexed_bounds, opening, fn {{ps, pe}, idx}, open ->
        k = Map.get(known, idx, %{in: @zero, out: @zero})
        total_in = Decimal.add(k.in, baseline_in)
        total_out = Decimal.add(k.out, baseline_out)
        closing = open |> Decimal.add(total_in) |> Decimal.sub(total_out)

        row = %{
          n: idx, period_start: ps, period_end: pe,
          opening: open, known_in: k.in, baseline_in: baseline_in,
          known_out: k.out, baseline_out: baseline_out,
          total_in: total_in, total_out: total_out,
          closing: closing, buffer: @zero, free_cash: @zero
        }

        {row, closing}
      end)

    rows
  end

  # buffer[p] = sum of total_out over periods p+1 .. p+buffer_periods
  # free_cash[p] = max(0, closing - buffer)
  defp apply_buffer(rows, buffer_periods) do
    outs = Enum.map(rows, & &1.total_out)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      buffer =
        outs
        |> Enum.slice((i + 1)..(i + buffer_periods))
        |> Enum.reduce(@zero, &Decimal.add(&2, &1))

      free = Decimal.sub(row.closing, buffer)
      free = if Decimal.compare(free, @zero) == :lt, do: @zero, else: free
      %{row | buffer: buffer, free_cash: free}
    end)
  end

  @doc """
  Sustainable lock-up amount per tenure = rolling minimum of free cash. Tenures are
  ~1/3/6/12 months (30/90/180/365 days), each covering the first
  `ceil(tenure_days / period_days)` periods (capped at the horizon). Placement
  increments are non-negative differences (longest tenure first).
  """
  def fd_ladder(periods, period_days) do
    frees = periods |> Enum.sort_by(& &1.n) |> Enum.map(& &1.free_cash)
    n = length(frees)

    k = fn tenure_days -> min(n, max(1, ceil(tenure_days / period_days))) end

    locks =
      Map.new(@tenure_days, fn {key, days} -> {key, min_slice(frees, k.(days))} end)

    l1 = locks[:"1mo"]
    l3 = locks[:"3mo"]
    l6 = locks[:"6mo"]
    l12 = locks[:"12mo"]

    %{
      lockable_1mo: l1,
      lockable_3mo: l3,
      lockable_6mo: l6,
      lockable_12mo: l12,
      place_12mo: l12,
      place_6mo: nonneg(Decimal.sub(l6, l12)),
      place_3mo: nonneg(Decimal.sub(l3, l6)),
      place_1mo: nonneg(Decimal.sub(l1, l3)),
      on_call: @zero
    }
  end

  defp min_slice([], _n), do: @zero
  defp min_slice(list, n) do
    list
    |> Enum.take(n)
    |> Enum.reduce(nil, fn x, acc ->
      cond do
        is_nil(acc) -> x
        Decimal.compare(x, acc) == :lt -> x
        true -> acc
      end
    end) || @zero
  end

  defp nonneg(dec) do
    if Decimal.compare(dec, @zero) == :lt, do: @zero, else: dec
  end
end
