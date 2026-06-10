defmodule FullCircle.Reporting.CashForecast do
  @moduledoc """
  Rolling cash forecast and fixed-deposit tenure ladder over fixed-length periods
  (a configurable number of days per bucket).

  Model: elapsed periods show the company's REAL liquid cash flow; future periods
  use a **run-rate backbone** (per-period average of operating liquid churn from the
  trailing window, treasury transfers excluded). Accounts the company marks as
  discretionary (director fees, dividends, …) can also be excluded from the run-rate
  via the company's settings.

  Pure core: `build_forecast/3`, `fd_ladder/2`.
  """

  alias FullCircle.Repo
  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.Sys.Company
  import Ecto.Query, warn: false

  @zero Decimal.new(0)

  # Company-settings key holding the list of account ids excluded from the run-rate.
  @exclude_key "cash_forecast_exclude_accounts"

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

  @doc "Account ids excluded from the run-rate (read from the company's settings)."
  def excluded_account_ids(com), do: Map.get(com.settings || %{}, @exclude_key, [])

  @doc "Persist the run-rate exclusion account-id list to the company settings."
  def save_excluded_account_ids(com, ids) when is_list(ids) do
    settings = Map.put(com.settings || %{}, @exclude_key, ids)
    com |> Ecto.Changeset.change(settings: settings) |> Repo.update()
  end

  @doc "Return `com` with its settings re-read fresh from the DB (avoids stale session data)."
  def company_with_settings(com) do
    settings = Repo.one(from c in Company, where: c.id == ^com.id, select: c.settings)
    %{com | settings: settings || %{}}
  end

  @doc "All accounts for the company, for the exclusion picker."
  def list_accounts(com) do
    from(a in Account,
      where: a.company_id == ^com.id,
      order_by: [a.account_type, a.name],
      select: %{id: a.id, name: a.name, account_type: a.account_type}
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

  @doc """
  Per-period run-rate in/out: the company's average liquid cash churn over the
  trailing `trailing_days` ending the day before `start_date`, scaled to a
  `period_days` bucket. This is the forecast backbone — it captures the ongoing
  business (new and existing), which a document-by-due-date model cannot see.
  Restricted to `contact_id IS NULL` rows (the bank-side of every cash movement),
  which is the full liquid throughput. Returns `{runrate_in, runrate_out}`.
  """
  def run_rate_flows(account_ids, start_date, trailing_days, period_days, com, excluded_ids \\ []) do
    window_start = Date.add(start_date, -trailing_days)

    rows =
      from(t in Transaction,
        where:
          t.company_id == ^com.id and t.account_id in ^account_ids and
            t.doc_date >= ^window_start and t.doc_date < ^start_date,
        select: %{
          ins: sum(fragment("case when ? > 0 then ? else 0 end", t.amount, t.amount)),
          outs: sum(fragment("case when ? < 0 then -? else 0 end", t.amount, t.amount))
        }
      )
      |> where(^operating_only(excluded_ids))
      |> Repo.one()

    factor = Decimal.div(Decimal.new("#{period_days}"), Decimal.new("#{trailing_days}"))
    {Decimal.mult(to_decimal(rows && rows.ins), factor),
     Decimal.mult(to_decimal(rows && rows.outs), factor)}
  end

  # Run-rate operating filter: contact-null liquid lines, excluding pure treasury
  # transfers (no contact + all-asset legs), and excluding any document that touches
  # a user-listed `excluded_ids` account (director fees, dividends, …).
  defp operating_only(excluded_ids) do
    base =
      dynamic(
        [t],
        is_nil(t.contact_id) and
          (is_nil(t.doc_id) or
             fragment(
               "exists (select 1 from transactions x join accounts xa on xa.id = x.account_id where x.doc_id = ? and x.company_id = ? and (x.contact_id is not null or xa.account_type <> all(?)))",
               t.doc_id,
               t.company_id,
               ^@asset_types
             ))
      )

    if excluded_ids == [] do
      base
    else
      dynamic(
        [t],
        ^base and
          fragment(
            "not exists (select 1 from transactions x where x.doc_id = ? and x.company_id = ? and x.account_id::text = any(?))",
            t.doc_id,
            t.company_id,
            ^excluded_ids
          )
      )
    end
  end

  @doc """
  Full forecast. `opts` is a map with `:start_date`, `:period_days` (default 30),
  `:periods_count` (default 12), `:buffer_periods` (default 1), `:trailing_days`
  (default 365), `:account_ids` (`:all` or list).

  Elapsed periods (end <= today) show real actual liquid cash flow; the rest use
  the run-rate anchored at today.
  """
  def cash_forecast(opts, com) do
    start_date = Map.fetch!(opts, :start_date)
    period_days = Map.get(opts, :period_days, 30)
    periods_count = Map.get(opts, :periods_count, 12)
    buffer_periods = Map.get(opts, :buffer_periods, 1)
    trailing_days = Map.get(opts, :trailing_days, 365)
    account_sel = Map.get(opts, :account_ids, :all)
    # "today" / as-of date: anchors the trailing window and the actual/forecast split.
    today = Map.get(opts, :as_of) || Date.utc_today()

    ids = liquid_account_ids(com, account_sel)
    bounds = period_bounds(start_date, period_days, periods_count)

    opening = opening_liquid_balance(ids, start_date, com)

    # Forecast periods use the run-rate anchored at TODAY (freshest trailing window),
    # excluding treasury transfers and any user-listed discretionary accounts.
    {rr_in, rr_out} =
      run_rate_flows(ids, today, trailing_days, period_days, com, excluded_account_ids(com))

    # Elapsed periods (end <= today) use their REAL total liquid cash flow.
    actuals = period_actuals(ids, start_date, period_days, periods_count, today, com)

    {base_in, base_out, sources} =
      bounds
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {{_ps, pe}, i}, {bi, bo, ss} ->
        if Date.compare(pe, today) != :gt do
          a = Map.get(actuals, i, %{in: @zero, out: @zero})
          {[a.in | bi], [a.out | bo], [:actual | ss]}
        else
          {[rr_in | bi], [rr_out | bo], [:forecast | ss]}
        end
      end)
      |> then(fn {bi, bo, ss} -> {Enum.reverse(bi), Enum.reverse(bo), Enum.reverse(ss)} end)

    result =
      build_forecast(
        %{opening: opening, base_in: base_in, base_out: base_out, sources: sources},
        start_date,
        period_days: period_days, periods_count: periods_count, buffer_periods: buffer_periods
      )
      |> Map.put(:trailing_days, trailing_days)
      |> Map.put(:as_of, today)

    arap = arap_per_period(com, bounds, today, trailing_days, period_days)

    periods =
      Enum.zip(result.periods, arap)
      |> Enum.map(fn {p, {recv, pay}} -> Map.merge(p, %{receivable: recv, payable: pay}) end)

    %{result | periods: periods}
  end

  # Total outstanding receivable (customers owing) and payable (owed to suppliers) from
  # contact balances as of `at_date`.
  @doc "Receivable / payable totals from contact balances as of `at_date` -> {recv, pay}."
  def ar_ap_balance(com, at_date) do
    per_contact =
      from(t in Transaction,
        where:
          t.company_id == ^com.id and not is_nil(t.contact_id) and t.doc_date <= ^at_date,
        group_by: t.contact_id,
        select: %{bal: sum(t.amount)}
      )

    row =
      from(s in subquery(per_contact),
        select: %{
          recv: sum(fragment("case when ? > 0 then ? else 0 end", s.bal, s.bal)),
          pay: sum(fragment("case when ? < 0 then -? else 0 end", s.bal, s.bal))
        }
      )
      |> Repo.one()

    {to_decimal(row && row.recv), to_decimal(row && row.pay)}
  end

  # Receivable/payable per period: real balance for elapsed periods, and a trailing
  # run-rate trend (avg change per period) projected forward for forecast periods.
  defp arap_per_period(com, bounds, today, trailing_days, period_days) do
    {recv_now, pay_now} = ar_ap_balance(com, today)
    {recv_then, pay_then} = ar_ap_balance(com, Date.add(today, -trailing_days))
    n_window = Decimal.div(Decimal.new("#{trailing_days}"), Decimal.new("#{period_days}"))
    recv_rate = Decimal.div(Decimal.sub(recv_now, recv_then), n_window)
    pay_rate = Decimal.div(Decimal.sub(pay_now, pay_then), n_window)
    n_actual = Enum.count(bounds, fn {_ps, pe} -> Date.compare(pe, today) != :gt end)

    bounds
    |> Enum.with_index(1)
    |> Enum.map(fn {{_ps, pe}, i} ->
      if Date.compare(pe, today) != :gt do
        ar_ap_balance(com, pe)
      else
        offset = Decimal.new("#{i - n_actual}")
        {nonneg(Decimal.add(recv_now, Decimal.mult(recv_rate, offset))),
         nonneg(Decimal.add(pay_now, Decimal.mult(pay_rate, offset)))}
      end
    end)
  end

  # Real total liquid cash in/out (every movement, no filters) per period, for the
  # periods between `start_date` and `today` — the elapsed portion of the horizon.
  # Returns `%{period_index(0-based) => %{in, out}}`.
  defp period_actuals(account_ids, start_date, period_days, periods_count, today, com) do
    horizon_end = Date.add(start_date, period_days * periods_count)
    upper = if Date.compare(today, horizon_end) == :lt, do: today, else: horizon_end

    if Date.compare(upper, start_date) != :gt do
      %{}
    else
      from(t in Transaction,
        where:
          t.company_id == ^com.id and t.account_id in ^account_ids and
            t.doc_date >= ^start_date and t.doc_date < ^upper,
        select: %{
          idx: selected_as(fragment("(? - ?) / ?", t.doc_date, ^start_date, ^period_days), :idx),
          ins: sum(fragment("case when ? > 0 then ? else 0 end", t.amount, t.amount)),
          outs: sum(fragment("case when ? < 0 then -? else 0 end", t.amount, t.amount))
        },
        group_by: selected_as(:idx)
      )
      |> Repo.all()
      |> Map.new(fn r -> {r.idx, %{in: to_decimal(r.ins), out: to_decimal(r.outs)}} end)
    end
  end

  @doc """
  The individual liquid transactions making up an actual period's cash in (`:in`)
  or out (`:out`) — for the Base In / Base Out drill-down. Returns
  `[%{date, doc_type, doc_no, account, particulars, amount}]` (amount as a positive
  magnitude), ordered by date.
  """
  def period_liquid_transactions(account_ids, from_date, to_date, direction, com) do
    base =
      from(t in Transaction,
        join: a in Account,
        on: a.id == t.account_id,
        where:
          t.company_id == ^com.id and t.account_id in ^account_ids and
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

    query =
      case direction do
        :in -> where(base, [t], t.amount > 0)
        :out -> where(base, [t], t.amount < 0)
      end

    query
    |> Repo.all()
    |> Enum.map(fn r -> %{r | amount: Decimal.abs(to_decimal(r.amount))} end)
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")

  @doc """
  Build the forecast from already-fetched raw inputs.

  `raw` is `%{opening, base_in, base_out, sources}` where `base_in`/`base_out` are
  per-period lists (the actual flow for elapsed periods, the run-rate for future
  ones) and `sources` a per-period list of `:actual | :forecast`. `opts` carries
  `:period_days`, `:periods_count`, `:buffer_periods`.
  """
  def build_forecast(raw, start_date, opts) do
    period_days = Keyword.fetch!(opts, :period_days)
    periods_count = Keyword.fetch!(opts, :periods_count)
    buffer_periods = Keyword.fetch!(opts, :buffer_periods)

    bounds = period_bounds(start_date, period_days, periods_count)

    periods =
      bounds
      |> Enum.with_index(1)
      |> roll_forward(raw.opening, raw.base_in, raw.base_out, raw.sources)
      |> apply_buffer(buffer_periods)

    # The FD ladder is forward-looking: only the forecast periods can be locked.
    forecast = Enum.filter(periods, &(&1.source == :forecast))
    ladder_input = if forecast == [], do: periods, else: forecast

    %{
      start_date: start_date,
      period_days: period_days,
      periods_count: periods_count,
      buffer_periods: buffer_periods,
      opening: raw.opening,
      periods: periods,
      ladder: fd_ladder(ladder_input, period_days)
    }
  end

  # List of {period_start, period_end} for n consecutive period_days-length windows.
  defp period_bounds(start_date, period_days, n) do
    for i <- 0..(n - 1) do
      ps = Date.add(start_date, i * period_days)
      {ps, Date.add(ps, period_days - 1)}
    end
  end

  defp roll_forward(indexed_bounds, opening, base_in_list, base_out_list, sources) do
    {rows, _} =
      Enum.map_reduce(indexed_bounds, opening, fn {{ps, pe}, idx}, open ->
        base_in = Enum.at(base_in_list, idx - 1)
        base_out = Enum.at(base_out_list, idx - 1)
        source = Enum.at(sources, idx - 1)
        closing = open |> Decimal.add(base_in) |> Decimal.sub(base_out)

        row = %{
          n: idx, period_start: ps, period_end: pe, source: source,
          opening: open, baseline_in: base_in, baseline_out: base_out,
          total_in: base_in, total_out: base_out,
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
