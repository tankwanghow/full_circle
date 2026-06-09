defmodule FullCircle.Reporting.CashForecast do
  @moduledoc """
  Rolling cash forecast and fixed-deposit tenure ladder over fixed-length periods
  (a configurable number of days per bucket).

  Model: a **run-rate backbone** (per-period average of the company's actual liquid
  cash churn, from trailing history) plus a **known-items overlay** (in-hand
  post-dated cheques and already-posted future-dated transactions placed on their
  own dates). A backtest against real data showed a pure document-by-due-date
  forecast misses ongoing new business and reads far too pessimistic; the run-rate
  tracks reality, with the overlay adding the genuinely-known dated lumps.

  Pure core: `build_forecast/3`, `fd_ladder/2`.
  """

  alias FullCircle.Repo
  alias FullCircle.Accounting.{Account, Transaction}
  import Ecto.Query, warn: false

  @zero Decimal.new(0)

  # Fixed-deposit ladder tenures, expressed in days (~1, 3, 6, 12 months).
  @tenure_days [{:"1mo", 30}, {:"3mo", 90}, {:"6mo", 180}, {:"12mo", 365}]

  @liquid_types ["Cash or Equivalent", "Bank"]

  # Balance-sheet ASSET account types used to detect treasury transfers. A document
  # whose every leg is one of these and which carries no contact is the company
  # moving its own money (cash <-> FD, cash <-> investment, bank <-> bank) — not
  # operating cash flow — so it is excluded from the run-rate. Receipts/payments
  # carry a contact, and payroll/tax settlements hit a liability or P&L leg, so
  # those are kept.
  #
  # NOTE: "Post Dated Cheques" is deliberately EXCLUDED from this list — a cheque
  # clearing (Dr Bank / Cr Post Dated Cheques) is real operating cash arriving in
  # the bank, not a treasury transfer, so it must stay in the run-rate.
  @asset_types [
    "Cash or Equivalent",
    "Bank",
    "Current Asset",
    "Fixed Asset",
    "Inventory",
    "Non-current Asset",
    "Prepayment",
    "Intangible Asset"
  ]

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
  Per-period run-rate in/out: the company's average liquid cash churn over the
  trailing `trailing_days` ending the day before `start_date`, scaled to a
  `period_days` bucket. This is the forecast backbone — it captures the ongoing
  business (new and existing), which a document-by-due-date model cannot see.
  Restricted to `contact_id IS NULL` rows (the bank-side of every cash movement),
  which is the full liquid throughput. Returns `{runrate_in, runrate_out}`.
  """
  def run_rate_flows(account_ids, start_date, trailing_days, period_days, com) do
    window_start = Date.add(start_date, -trailing_days)

    rows =
      from(t in Transaction,
        where:
          t.company_id == ^com.id and t.account_id in ^account_ids and
            is_nil(t.contact_id) and
            t.doc_date >= ^window_start and t.doc_date < ^start_date and
            (is_nil(t.doc_id) or
               fragment(
                 "exists (select 1 from transactions x join accounts xa on xa.id = x.account_id where x.doc_id = ? and x.company_id = ? and (x.contact_id is not null or xa.account_type <> all(?)))",
                 t.doc_id,
                 t.company_id,
                 ^@asset_types
               )),
        select: %{
          ins: sum(fragment("case when ? > 0 then ? else 0 end", t.amount, t.amount)),
          outs: sum(fragment("case when ? < 0 then -? else 0 end", t.amount, t.amount))
        }
      )
      |> Repo.one()

    factor = Decimal.div(Decimal.new("#{period_days}"), Decimal.new("#{trailing_days}"))
    {Decimal.mult(to_decimal(rows && rows.ins), factor),
     Decimal.mult(to_decimal(rows && rows.outs), factor)}
  end

  @doc "Clamp a due date to the forecast start (past-due items become due immediately)."
  def clamp_due(due_date, start_date) do
    if Date.compare(due_date, start_date) == :lt, do: start_date, else: due_date
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
    {rr_in, rr_out} = run_rate_flows(ids, start_date, trailing_days, period_days, com)

    # Known dated items not yet realised in the run-rate's history.
    events =
      posted_future_flows(ids, start_date, end_date, com) ++
        known_inflow_cheques(start_date, end_date, com)

    build_forecast(
      %{opening: opening, baseline_in: rr_in, baseline_out: rr_out, events: events},
      start_date,
      period_days: period_days, periods_count: periods_count, buffer_periods: buffer_periods
    )
    |> Map.put(:trailing_days, trailing_days)
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")

  @doc """
  Build the forecast from already-fetched raw inputs.

  `raw` is `%{opening, baseline_in, baseline_out, events}` where `baseline_*` is the
  per-period run-rate and events is a list of `%{date, in, out, kind}` known items.
  `opts` carries `:period_days`, `:periods_count`, `:buffer_periods`.
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

  # Buffer = the projected NET cash drain over the next buffer_periods periods
  # (outflow minus inflow, floored at 0). With a gross run-rate, holding a full
  # period of gross outflow liquid is wrong — a self-funding business covers most
  # outflow from its own inflow; only the net shortfall must stay liquid.
  # free_cash[p] = max(0, closing - buffer)
  defp apply_buffer(rows, buffer_periods) do
    nets = Enum.map(rows, fn r -> Decimal.sub(r.total_out, r.total_in) end)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      drain =
        nets
        |> Enum.slice((i + 1)..(i + buffer_periods))
        |> Enum.reduce(@zero, &Decimal.add(&2, &1))

      buffer = nonneg(drain)
      free = nonneg(Decimal.sub(row.closing, buffer))
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

    locks = Map.new(@tenure_days, fn {key, days} -> {key, min_slice(frees, k.(days))} end)

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
