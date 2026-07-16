defmodule FullCircle.Trading.TripDrop do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "trading_trip_drops" do
    field :planned_mt, :decimal
    field :actual_mt, :decimal
    field :location_note, :string
    field :variance_note, :string

    field :location_name, :string, virtual: true
    field :sales_title, :string, virtual: true
    field :supply_title, :string, virtual: true
    field :delete, :boolean, virtual: true, default: false

    belongs_to :trip, FullCircle.Trading.Trip
    belongs_to :sales_position, FullCircle.Trading.SalesPosition
    belongs_to :supply_position, FullCircle.Trading.SupplyPosition
    belongs_to :location, FullCircle.Trading.Location
    belongs_to :invoice, FullCircle.Billing.Invoice

    has_many :trip_drop_employees, FullCircle.Trading.TripDropEmployee,
      on_replace: :delete,
      on_delete: :delete_all

    has_many :employees, through: [:trip_drop_employees, :employee]

    timestamps(type: :utc_datetime)
  end

  def changeset(drop, attrs) do
    drop
    |> cast(
      blank_to_nil(attrs, ["sales_position_id", "supply_position_id", "location_id", "invoice_id"]),
      [
        :planned_mt,
        :actual_mt,
        :location_note,
        :variance_note,
        :trip_id,
        :sales_position_id,
        :supply_position_id,
        :location_id,
        :invoice_id,
        :location_name,
        :sales_title,
        :supply_title,
        :delete
      ]
    )
    |> cast_assoc(:trip_drop_employees, with: &FullCircle.Trading.TripDropEmployee.changeset/2)
    |> validate_required([:location_id])
    |> validate_number(:planned_mt, greater_than_or_equal_to: 0)
    |> validate_number(:actual_mt, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:trip_id)
    |> foreign_key_constraint(:sales_position_id)
    |> foreign_key_constraint(:supply_position_id)
    |> foreign_key_constraint(:location_id)
    |> foreign_key_constraint(:invoice_id)
    |> maybe_mark_for_deletion()
  end

  defp blank_to_nil(attrs, keys) when is_map(attrs) do
    Enum.reduce(keys, attrs, fn key, acc ->
      atom = String.to_atom(key)

      cond do
        Map.has_key?(acc, key) and acc[key] in ["", nil] -> Map.put(acc, key, nil)
        Map.has_key?(acc, atom) and acc[atom] in ["", nil] -> Map.put(acc, atom, nil)
        true -> acc
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
