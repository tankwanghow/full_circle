defmodule FullCircle.Repo.Migrations.WarehouseMovementIndexes do
  @moduledoc """
  Composite indexes for own-warehouse recent movement queries
  (location_id + good_id on loads/drops).
  """
  use Ecto.Migration

  def change do
    create_if_not_exists index(:trading_trip_loads, [:location_id, :good_id],
      name: :trading_trip_loads_location_good_index
    )

    create_if_not_exists index(:trading_trip_drops, [:location_id, :good_id],
      name: :trading_trip_drops_location_good_index
    )
  end
end
