defmodule FullCircle.Reporting.CashForecast do
  @moduledoc """
  Rolling weekly cash forecast and fixed-deposit tenure ladder.
  Pure core (`build_forecast/3`, `fd_ladder/1`) plus DB query helpers.
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
  Average weekly in/out from contact-null liquid txns over the `weeks`-long
  window ending the day before `start_date`. Returns `{baseline_in, baseline_out}`.
  """
  def baseline_flows(account_ids, start_date, weeks, com) do
    window_start = Date.add(start_date, -weeks * 7)

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

    ins = to_decimal(rows && rows.ins)
    outs = to_decimal(rows && rows.outs)
    wk = Decimal.new("#{weeks}")
    {Decimal.div(ins, wk), Decimal.div(outs, wk)}
  end

  @doc "Clamp a due date to the forecast start (past-due items become due immediately)."
  def clamp_due(due_date, start_date) do
    if Date.compare(due_date, start_date) == :lt, do: start_date, else: due_date
  end

  @doc "Unpaid sales-invoice balances as inflow events on their (clamped) due_date."
  def outstanding_ar_events(start_date, end_date, com),
    do: outstanding_invoice_events(:ar, start_date, end_date, com)

  @doc "Unpaid purchase-invoice balances as outflow events on their (clamped) due_date."
  def outstanding_ap_events(start_date, end_date, com),
    do: outstanding_invoice_events(:ap, start_date, end_date, com)

  # direction: :ar -> sales invoices, inflow; :ap -> purchase invoices, outflow
  defp outstanding_invoice_events(direction, start_date, end_date, com) do
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
      %{date: clamp_due(due, start_date), balance: Decimal.abs(to_decimal(bal))}
    end)
    |> Enum.reject(&(Date.compare(&1.date, end_date) == :gt))
    |> Enum.map(fn %{date: due, balance: bal} ->
      case direction do
        :ar -> %{date: due, in: bal, out: @zero, kind: :known}
        :ap -> %{date: due, in: @zero, out: bal, kind: :known}
      end
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
  Full forecast. `opts` is a map with `:start_date`, `:weeks_count` (default 13),
  `:buffer_weeks` (default 2), `:trailing_weeks` (default 52), `:account_ids`
  (`:all` or list).
  """
  def cash_forecast(opts, com) do
    start_date = Map.fetch!(opts, :start_date)
    weeks_count = Map.get(opts, :weeks_count, 13)
    buffer_weeks = Map.get(opts, :buffer_weeks, 2)
    trailing_weeks = Map.get(opts, :trailing_weeks, 52)
    account_sel = Map.get(opts, :account_ids, :all)

    end_date = Date.add(start_date, weeks_count * 7 - 1)
    ids = liquid_account_ids(com, account_sel)

    opening = opening_liquid_balance(ids, start_date, com)
    {bin, bout} = baseline_flows(ids, start_date, trailing_weeks, com)

    events =
      posted_future_flows(ids, start_date, end_date, com) ++
        known_inflow_cheques(start_date, end_date, com) ++
        outstanding_ar_events(start_date, end_date, com) ++
        outstanding_ap_events(start_date, end_date, com)

    build_forecast(
      %{opening: opening, baseline_in: bin, baseline_out: bout, events: events},
      start_date,
      weeks_count: weeks_count, buffer_weeks: buffer_weeks
    )
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")

  @doc """
  Build the forecast from already-fetched raw inputs.

  `raw` is `%{opening, baseline_in, baseline_out, events}` where events is a list
  of `%{date, in, out, kind}`. Returns the forecast result map (see plan header).
  """
  def build_forecast(raw, start_date, opts) do
    weeks_count = Keyword.fetch!(opts, :weeks_count)
    buffer_weeks = Keyword.fetch!(opts, :buffer_weeks)

    bounds = week_bounds(start_date, weeks_count)
    known = bucket_events(raw.events, bounds)

    weeks =
      bounds
      |> Enum.with_index(1)
      |> roll_forward(known, raw.opening, raw.baseline_in, raw.baseline_out)
      |> apply_buffer(buffer_weeks)

    %{
      start_date: start_date,
      weeks_count: weeks_count,
      buffer_weeks: buffer_weeks,
      opening: raw.opening,
      baseline_in: raw.baseline_in,
      baseline_out: raw.baseline_out,
      weeks: weeks,
      ladder: fd_ladder(weeks)
    }
  end

  # List of {week_start, week_end} for n consecutive 7-day windows.
  defp week_bounds(start_date, n) do
    for i <- 0..(n - 1) do
      ws = Date.add(start_date, i * 7)
      {ws, Date.add(ws, 6)}
    end
  end

  # Returns %{week_index => %{in: Decimal, out: Decimal}} for events inside the horizon.
  # Events before start_date land in week 1; events after the horizon are dropped.
  defp bucket_events(events, bounds) do
    {first_start, _} = hd(bounds)
    {_, last_end} = List.last(bounds)

    Enum.reduce(events, %{}, fn ev, acc ->
      cond do
        Date.compare(ev.date, last_end) == :gt ->
          acc

        true ->
          idx = week_index_for(ev.date, first_start, length(bounds))
          cur = Map.get(acc, idx, %{in: @zero, out: @zero})
          Map.put(acc, idx, %{in: Decimal.add(cur.in, ev.in), out: Decimal.add(cur.out, ev.out)})
      end
    end)
  end

  defp week_index_for(date, first_start, n) do
    days = Date.diff(date, first_start)
    cond do
      days < 0 -> 1
      true -> min(div(days, 7) + 1, n)
    end
  end

  defp roll_forward(indexed_bounds, known, opening, baseline_in, baseline_out) do
    {rows, _} =
      Enum.map_reduce(indexed_bounds, opening, fn {{ws, we}, idx}, open ->
        k = Map.get(known, idx, %{in: @zero, out: @zero})
        total_in = Decimal.add(k.in, baseline_in)
        total_out = Decimal.add(k.out, baseline_out)
        closing = open |> Decimal.add(total_in) |> Decimal.sub(total_out)

        row = %{
          n: idx, week_start: ws, week_end: we,
          opening: open, known_in: k.in, baseline_in: baseline_in,
          known_out: k.out, baseline_out: baseline_out,
          total_in: total_in, total_out: total_out,
          closing: closing, buffer: @zero, free_cash: @zero
        }

        {row, closing}
      end)

    rows
  end

  # buffer[w] = sum of total_out over weeks w+1 .. w+buffer_weeks
  # free_cash[w] = max(0, closing - buffer)
  defp apply_buffer(rows, buffer_weeks) do
    outs = Enum.map(rows, & &1.total_out)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      buffer =
        outs
        |> Enum.slice((i + 1)..(i + buffer_weeks))
        |> Enum.reduce(@zero, &Decimal.add(&2, &1))

      free = Decimal.sub(row.closing, buffer)
      free = if Decimal.compare(free, @zero) == :lt, do: @zero, else: free
      %{row | buffer: buffer, free_cash: free}
    end)
  end

  @doc """
  Sustainable lock-up amount per tenure = rolling minimum of free cash:
  ~1mo = min(weeks 1-4), ~2mo = min(weeks 1-8), ~3mo = min(weeks 1-13).
  Placement increments are non-negative differences (longest tenure first).
  """
  def fd_ladder(weeks) do
    frees = weeks |> Enum.sort_by(& &1.n) |> Enum.map(& &1.free_cash)

    l1 = min_slice(frees, 4)
    l2 = min_slice(frees, 8)
    l3 = min_slice(frees, 13)

    %{
      lockable_1mo: l1,
      lockable_2mo: l2,
      lockable_3mo: l3,
      place_3mo: l3,
      place_2mo: nonneg(Decimal.sub(l2, l3)),
      place_1mo: nonneg(Decimal.sub(l1, l2)),
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
