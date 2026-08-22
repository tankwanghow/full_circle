defmodule FullCircle.Trading.Storage do
  @moduledoc """
  Supplier storage (grace period) tracking for supply positions.

  `grace_period_end_date` on a supply is the last free-storage day; per-ton-
  per-day charges start the day after. No rate is stored — this module
  produces the duration × tonnage evidence (ton·days) used to verify the
  supplier's storage bill; the rate is negotiated when the bill arrives.
  The date is manually entered and may be set retroactively (even on a
  closed supply) purely to check a late bill — everything here derives
  from stored completed-trip loads, so timing of entry never matters.

  Conventions (pinned by `storage_test.exs`):
  - First chargeable day is the day **after** `grace_period_end_date`.
  - A day is charged on its start-of-day balance: a load on day *e* stops
    charging from *e + 1* (the goods sat there that morning).
  - The accrual window ends at the earliest of: the zero-crossing day
    (cumulative loads reach quantity — over-collection residue ignored),
    the last load date when the supply is `closed` (the clerk's "stock
    finished" absorbs a tiny short residue), or today.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Authorization
  alias FullCircle.Trading.{SupplyPosition, Trip, TripLoad}

  @zero Decimal.new(0)

  @doc """
  Chip state for the desk board — pure; `remaining` comes from board data.

  `:none` | `{:grace, days_left}` | `{:accruing, days}` | `:ended`
  """
  def chip_state(supply, remaining, today)

  def chip_state(%SupplyPosition{grace_period_end_date: nil}, _remaining, _today), do: :none

  def chip_state(%SupplyPosition{} = s, remaining, %Date{} = today) do
    grace_end = s.grace_period_end_date

    cond do
      Date.compare(today, grace_end) != :gt -> {:grace, Date.diff(grace_end, today)}
      s.status == "closed" -> :ended
      Decimal.compare(remaining || @zero, @zero) != :gt -> :ended
      true -> {:accruing, Date.diff(today, grace_end)}
    end
  end

  @doc """
  Duration × tonnage breakdown for verifying a supplier's storage bill.

  Returns `:none` when the supply has no grace date (or the caller may not
  view trading); otherwise a map with `first_charge_date`, `end_date`,
  `end_reason` (`:exhausted | :closed | :running`), `periods`
  (`from/to/days/remaining/ton_days`, split at load dates), `total_days`,
  `total_ton_days`, and `leftover_remaining` (uncollected residue, ≥ 0).
  """
  def breakdown(supply, company, user, today \\ Date.utc_today())

  def breakdown(%SupplyPosition{grace_period_end_date: nil}, _company, _user, _today), do: :none

  def breakdown(%SupplyPosition{} = s, company, user, %Date{} = today) do
    if s.company_id == company.id and Authorization.can?(user, :view_trading, company) do
      compute(s, load_events(s.id, company), today)
    else
      :none
    end
  end

  def breakdown(_, _, _, _), do: :none

  # Completed-trip loads for the supply, summed per trip date, ascending.
  defp load_events(supply_id, company) do
    from(l in TripLoad,
      join: t in Trip,
      on: t.id == l.trip_id,
      where: l.supply_position_id == ^supply_id,
      where: t.company_id == ^company.id,
      where: t.status == "completed",
      group_by: t.date,
      order_by: t.date,
      select: {t.date, sum(coalesce(l.actual, 0))}
    )
    |> Repo.all()
  end

  defp compute(s, events, today) do
    qty = s.quantity || @zero
    first = Date.add(s.grace_period_end_date, 1)

    total_loaded = Enum.reduce(events, @zero, fn {_, q}, acc -> Decimal.add(acc, q) end)
    leftover = Decimal.max(Decimal.sub(qty, total_loaded), @zero)

    last_load_date =
      case List.last(events) do
        {d, _} -> d
        nil -> nil
      end

    closed_end = if s.status == "closed", do: last_load_date

    {end_date, end_reason} =
      [{exhaustion_end(qty, events), :exhausted}, {closed_end, :closed}, {today, :running}]
      |> Enum.reject(fn {d, _} -> is_nil(d) end)
      |> Enum.min_by(fn {d, _} -> Date.to_erl(d) end)

    periods = build_periods(qty, events, first, end_date)

    %{
      first_charge_date: first,
      end_date: end_date,
      end_reason: end_reason,
      periods: periods,
      total_days: Enum.sum(Enum.map(periods, & &1.days)),
      total_ton_days: Enum.reduce(periods, @zero, fn p, acc -> Decimal.add(acc, p.ton_days) end),
      leftover_remaining: leftover
    }
  end

  # Last chargeable day before the zero-crossing: the load event that brings
  # cumulative loads to >= quantity still charges its own day; nil if the
  # quantity is never reached.
  defp exhaustion_end(qty, events) do
    events
    |> Enum.reduce_while(@zero, fn {date, q}, acc ->
      acc = Decimal.add(acc, q)

      if Decimal.compare(acc, qty) != :lt do
        {:halt, {:done, date}}
      else
        {:cont, acc}
      end
    end)
    |> case do
      {:done, date} -> date
      _ -> nil
    end
  end

  # Constant-remaining periods over [first, end_date]; a load on day e starts
  # a new period at e + 1 (start-of-day balance convention).
  defp build_periods(qty, events, first, end_date) do
    if Date.compare(first, end_date) == :gt do
      []
    else
      boundaries =
        events
        |> Enum.map(fn {e, _} -> Date.add(e, 1) end)
        |> Enum.filter(fn d ->
          Date.compare(d, first) == :gt and Date.compare(d, end_date) != :gt
        end)
        |> then(&[first | &1])
        |> Enum.uniq()
        |> Enum.sort(Date)

      boundaries
      |> Enum.with_index()
      |> Enum.map(fn {from, i} ->
        to =
          case Enum.at(boundaries, i + 1) do
            nil -> end_date
            next -> Date.add(next, -1)
          end

        loaded_before =
          events
          |> Enum.filter(fn {e, _} -> Date.compare(e, from) == :lt end)
          |> Enum.reduce(@zero, fn {_, q}, acc -> Decimal.add(acc, q) end)

        remaining = Decimal.max(Decimal.sub(qty, loaded_before), @zero)
        days = Date.diff(to, from) + 1

        %{
          from: from,
          to: to,
          days: days,
          remaining: remaining,
          ton_days: Decimal.mult(remaining, days)
        }
      end)
    end
  end
end
