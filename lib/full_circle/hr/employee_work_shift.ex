defmodule FullCircle.HR.EmployeeWorkShift do
  @moduledoc """
  Assigns an employee to a shift for a date range.

  Dated so that re-running an old month still sees that month's roster.
  An employee with **no effective row** resolves to the company's default
  (General) shift, so most staff never need a row here.
  """
  use FullCircle.Schema
  import Ecto.Changeset
  import Ecto.Query
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Repo

  schema "employee_work_shifts" do
    field(:effective_from, :date)
    field(:effective_to, :date)

    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:work_shift, FullCircle.HR.WorkShift)

    timestamps(type: :utc_datetime)
  end

  def changeset(st, attrs) do
    st
    |> cast(attrs, [:employee_id, :work_shift_id, :effective_from, :effective_to])
    |> validate_required([:employee_id, :work_shift_id, :effective_from])
    |> validate_to_after_from()
    |> validate_no_overlap()
  end

  defp validate_to_after_from(cs) do
    from = get_field(cs, :effective_from)
    to = get_field(cs, :effective_to)

    if from && to && Date.compare(to, from) == :lt do
      add_error(cs, :effective_to, gettext("must not be before effective from"))
    else
      cs
    end
  end

  # Two ranges overlap when each starts on or before the other ends. A nil
  # effective_to is an open end, so it overlaps everything after its start.
  defp validate_no_overlap(cs) do
    emp_id = get_field(cs, :employee_id)
    from = get_field(cs, :effective_from)
    to = get_field(cs, :effective_to)
    id = get_field(cs, :id)

    if emp_id && from do
      clash? =
        from(e in __MODULE__,
          where: e.employee_id == ^emp_id,
          where: is_nil(e.effective_to) or e.effective_to >= ^from
        )
        |> exclude_self(id)
        |> exclude_starting_after(to)
        |> Repo.exists?()

      if clash?,
        do: add_error(cs, :effective_from, gettext("overlaps an existing assignment")),
        else: cs
    else
      cs
    end
  end

  defp exclude_self(query, nil), do: query
  defp exclude_self(query, id), do: from(e in query, where: e.id != ^id)

  defp exclude_starting_after(query, nil), do: query
  defp exclude_starting_after(query, to), do: from(e in query, where: e.effective_from <= ^to)
end
