defmodule FullCircle.Reporting.CashForecast do
  @moduledoc """
  Rolling weekly cash forecast and fixed-deposit tenure ladder.
  Pure core (`build_forecast/3`, `fd_ladder/1`) plus DB query helpers.
  """

  # added in later tasks
  alias FullCircle.{QueryRepo, Accounting}
  alias FullCircle.Accounting.{Account, Transaction}
  import Ecto.Query, warn: false
  import FullCircle.Helpers, only: [exec_query_map: 3]
  # dump_uuid!/1 is not exported from FullCircle.Helpers; added in later tasks

  @zero Decimal.new(0)

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
