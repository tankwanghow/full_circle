defmodule FullCircle.HR.ShiftInstance do
  @moduledoc """
  One occurrence of a shift: the punches inside it, and everything derived from
  them.

  Nothing here is stored. Punches carry their grouping (`work_shift_id` +
  `work_shift_date`); hours, pay date and anomaly are computed from that
  grouping on every read, so a clerk editing a punch cannot leave a stale total
  behind — the failure mode `rebuild_day_flags/3` has today.

  `worked` is `nil`, never `0.0`, when the instance is anomalous. A real
  zero-hour day must stay distinguishable from "we cannot say", because
  `holiday_pay_days/2` reads `wh == 0.0` as a genuine absence.
  """

  alias FullCircle.HR.WorkShift

  defstruct [
    :employee_id,
    :work_shift_id,
    :work_shift_date,
    :punches,
    :worked,
    :span_hours,
    :pay_date,
    :anomaly
  ]

  @doc """
  Builds an instance from the punches grouped under it.

  `punches` need not be sorted. `timezone` is the company timezone and is used
  only to place the pay date, which is the local date of the **last** punch —
  the day the shift ended.
  """
  def build([], _shift, _timezone), do: nil

  def build(punches, %WorkShift{} = shift, timezone) do
    punches = Enum.sort_by(punches, & &1.punch_time, DateTime)
    first = hd(punches)
    last = List.last(punches)
    span = DateTime.diff(last.punch_time, first.punch_time) / 3600
    anomaly = anomaly_for(length(punches), span, shift)

    %__MODULE__{
      employee_id: first.employee_id,
      work_shift_id: shift.id,
      work_shift_date: first.work_shift_date,
      punches: punches,
      span_hours: span,
      anomaly: anomaly,
      worked: if(is_nil(anomaly), do: worked_hours(punches), else: nil),
      pay_date: last.punch_time |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    }
  end

  # Exactly two anomalies. A punch is never anomalous merely for falling
  # outside the shift's nominal window: 34.5% of real punches do.
  defp anomaly_for(count, span, %WorkShift{max_hour: max_hour}) do
    cond do
      rem(count, 2) == 1 -> :missing_punch
      span > Decimal.to_float(max_hour) -> :too_long
      true -> nil
    end
  end

  # Only reached when the count is even, so every chunk is a full pair.
  defp worked_hours(punches) do
    punches
    |> Enum.chunk_every(2)
    |> Enum.reduce(0.0, fn [in_p, out_p], acc ->
      acc + DateTime.diff(out_p.punch_time, in_p.punch_time) / 3600
    end)
  end

  @doc "Punch kind by 1-based position within the instance."
  def punch_kind(index) when rem(index, 2) == 1, do: "IN"
  def punch_kind(_index), do: "OUT"

  @doc """
  The legacy display label by 1-based position, with no ceiling at three pairs.
  Kept so existing rows and reports still read sensibly; it is no longer the
  pairing key.
  """
  def flag(index) do
    pair = div(index + 1, 2)
    "#{pair}_#{punch_kind(index)}_#{pair}"
  end
end
