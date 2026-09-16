defmodule FullCircle.Tugas.Duty do
  @moduledoc """
  One cycle of a duty.

  A duty is never edited in place to "become" the next occurrence. Closing a
  cycle (`done` or `skipped`) is what spawns the next one, so the history of a
  recurring duty is a chain of rows sharing a `series_id`, each with its own
  events and evidence.

  `series_ended_at` is stamped on the whole series and stops spawn-next from
  ever running again; it is not the same as closing the current cycle.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  @statuses ~w(active done skipped)
  @recur_units ~w(day week month year)

  def statuses, do: @statuses
  def recur_units, do: @recur_units

  schema "duties" do
    field(:title, :string)
    field(:descriptions, :string)
    field(:due_date, :date)
    field(:status, :string, default: "active")
    field(:series_id, Ecto.UUID)
    field(:series_ended_at, :utc_datetime)
    field(:recur_unit, :string)
    field(:recur_every, :integer)

    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  @castable ~w(title descriptions due_date status series_id series_ended_at
               recur_unit recur_every company_id)a

  def changeset(duty, attrs) do
    duty
    |> cast(attrs, @castable)
    |> validate_required([:title, :status, :series_id, :company_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:recur_unit, @recur_units)
    |> validate_recurrence()
    |> unique_constraint(:series_id, name: :duties_one_live_cycle_per_series)
    |> foreign_key_constraint(:company_id)
  end

  # recur_every without a unit is noise; a unit without an every has no
  # interval to add. The database carries the same pair rule.
  defp validate_recurrence(changeset) do
    unit = get_field(changeset, :recur_unit)
    every = get_field(changeset, :recur_every)

    cond do
      is_nil(unit) and not is_nil(every) ->
        add_error(changeset, :recur_every, "needs a recur unit")

      not is_nil(unit) and is_nil(every) ->
        add_error(changeset, :recur_every, "can't be blank")

      not is_nil(every) ->
        validate_number(changeset, :recur_every, greater_than_or_equal_to: 1)

      true ->
        changeset
    end
  end

  @doc """
  Adds one recurrence interval to `date`.

  Month and year arithmetic clamps to the end of the target month, so a duty
  due on the 31st recurring monthly lands on the 30th (or 28th/29th) rather
  than rolling into the following month.
  """
  def next_due_date(nil, _unit, _every), do: nil
  def next_due_date(_date, nil, _every), do: nil

  def next_due_date(%Date{} = date, "day", every), do: Date.add(date, every)
  def next_due_date(%Date{} = date, "week", every), do: Date.add(date, every * 7)
  def next_due_date(%Date{} = date, "month", every), do: shift_months(date, every)
  def next_due_date(%Date{} = date, "year", every), do: shift_months(date, every * 12)

  defp shift_months(%Date{} = date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    Date.new!(year, month, min(date.day, Date.days_in_month(Date.new!(year, month, 1))))
  end
end
