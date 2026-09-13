defmodule FullCircle.HR.WorkShift do
  @moduledoc """
  A shift definition: when it nominally starts, how long it nominally runs, and
  how long it is allowed to run before we stop believing it.

  `normal_hour` is **display only** — `start_time + normal_hour` is the
  human-readable end (08:00 + 9 = 17:00). It is never an operand in pay;
  overtime keeps reading `Employee.work_hours_per_day`.

  `max_hour` is a tolerance, not a duration. It is deliberately looser than
  `normal_hour` because 57% of real employee-days already span more than nine
  hours. It does two jobs: it is the anomaly threshold, and it derives the
  cutover.

  There is no `end_time`: it is derivable and nothing needs it stored.
  """
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "work_shifts" do
    field(:name, :string)
    field(:start_time, :time)
    field(:normal_hour, :decimal)
    field(:max_hour, :decimal)
    field(:is_default, :boolean, default: false)

    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  @doc """
  The time of day that separates one instance of this shift from the next.

  Midpoint between the latest possible end (`start_time + max_hour`) and the
  next day's `start_time`, which puts it in the deadest part of the off-period:

      cutover = (start_time + (24 + max_hour) / 2) mod 24

  General 08:00/12 gives 02:00; Night 17:00/12 gives 11:00.
  """
  def cutover_time(%__MODULE__{start_time: start_time, max_hour: max_hour}) do
    shift_by(start_time, (24 + Decimal.to_float(max_hour)) / 2)
  end

  @doc "Human-readable end of the shift. Display only — never used in pay."
  def nominal_end(%__MODULE__{start_time: start_time, normal_hour: normal_hour}) do
    shift_by(start_time, Decimal.to_float(normal_hour))
  end

  defp shift_by(%Time{} = t, hours) do
    total = Integer.mod(t.hour * 60 + t.minute + round(hours * 60), 24 * 60)
    Time.new!(div(total, 60), rem(total, 60), 0)
  end

  def changeset(st, attrs) do
    st
    |> cast(attrs, [:name, :start_time, :normal_hour, :max_hour, :is_default, :company_id])
    |> validate_required([:name, :start_time, :normal_hour, :max_hour, :company_id])
    |> validate_number(:normal_hour, greater_than: 0, less_than_or_equal_to: 24)
    |> validate_number(:max_hour, greater_than: 0, less_than: 24)
    |> validate_max_not_below_normal()
    |> unique_constraint(:name,
      name: :work_shifts_company_id_name_index,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:is_default,
      name: :work_shifts_one_default_per_company,
      message: gettext("there is already a default shift")
    )
  end

  defp validate_max_not_below_normal(cs) do
    normal = get_field(cs, :normal_hour)
    max = get_field(cs, :max_hour)

    if normal && max && Decimal.compare(max, normal) == :lt do
      add_error(cs, :max_hour, gettext("must not be less than normal hour"))
    else
      cs
    end
  end
end
