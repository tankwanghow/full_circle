defmodule FullCircle.Trading.TripLoad do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_trip_loads" do
    field :planned_mt, :decimal
    field :actual_mt, :decimal
    field :location_note, :string

    # UI / form helpers
    field :location_name, :string, virtual: true
    field :supply_title, :string, virtual: true
    field :delete, :boolean, virtual: true, default: false

    belongs_to :trip, FullCircle.Trading.Trip
    belongs_to :supply_position, FullCircle.Trading.SupplyPosition
    belongs_to :location, FullCircle.Trading.Location

    has_many :trip_load_employees, FullCircle.Trading.TripLoadEmployee,
      on_replace: :delete,
      on_delete: :delete_all

    has_many :employees, through: [:trip_load_employees, :employee]

    timestamps(type: :utc_datetime)
  end

  def changeset(load, attrs) do
    load
    |> cast(blank_to_nil(attrs, ["supply_position_id", "location_id"]), [
      :planned_mt,
      :actual_mt,
      :location_note,
      :trip_id,
      :supply_position_id,
      :location_id,
      :location_name,
      :supply_title,
      :delete
    ])
    |> cast_assoc(:trip_load_employees, with: &FullCircle.Trading.TripLoadEmployee.changeset/2)
    |> validate_required([:location_id])
    |> validate_number(:planned_mt, greater_than_or_equal_to: 0)
    |> validate_number(:actual_mt, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:trip_id)
    |> foreign_key_constraint(:supply_position_id)
    |> foreign_key_constraint(:location_id)
    |> maybe_mark_for_deletion()
  end

  defp blank_to_nil(attrs, keys) when is_map(attrs) do
    Enum.reduce(keys, attrs, fn key, acc ->
      cond do
        Map.has_key?(acc, key) and acc[key] in ["", nil] ->
          Map.put(acc, key, nil)

        Map.has_key?(acc, String.to_atom(key)) and acc[String.to_atom(key)] in ["", nil] ->
          Map.put(acc, String.to_atom(key), nil)

        true ->
          acc
      end
    end)
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
