defmodule FullCircle.Trading.TripDropEmployee do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_trip_drop_employees" do
    belongs_to :trip_drop, FullCircle.Trading.TripDrop
    belongs_to :employee, FullCircle.HR.Employee

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:trip_drop_id, :employee_id])
    |> validate_required([:employee_id])
    |> unique_constraint([:trip_drop_id, :employee_id])
    |> foreign_key_constraint(:trip_drop_id)
    |> foreign_key_constraint(:employee_id)
  end
end
