defmodule FullCircle.Trading.TripDropEmployee do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_trip_drop_employees" do
    belongs_to :trip_drop, FullCircle.Trading.TripDrop
    belongs_to :employee, FullCircle.HR.Employee

    # Form helpers
    field :employee_name, :string, virtual: true
    field :delete, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:trip_drop_id, :employee_id, :employee_name, :delete])
    |> validate_required([:employee_id])
    |> unique_constraint([:trip_drop_id, :employee_id])
    |> foreign_key_constraint(:trip_drop_id)
    |> foreign_key_constraint(:employee_id)
    |> maybe_mark_for_deletion()
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = cs), do: cs

  defp maybe_mark_for_deletion(cs) do
    if get_change(cs, :delete) do
      %{cs | action: :delete}
    else
      cs
    end
  end
end
