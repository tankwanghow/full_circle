defmodule FullCircle.Trading.TripLoadEmployee do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_trip_load_employees" do
    belongs_to :trip_load, FullCircle.Trading.TripLoad
    belongs_to :employee, FullCircle.HR.Employee

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:trip_load_id, :employee_id])
    |> validate_required([:employee_id])
    |> unique_constraint([:trip_load_id, :employee_id])
    |> foreign_key_constraint(:trip_load_id)
    |> foreign_key_constraint(:employee_id)
  end
end
