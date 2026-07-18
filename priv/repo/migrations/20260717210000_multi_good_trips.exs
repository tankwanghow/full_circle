defmodule FullCircle.Repo.Migrations.MultiGoodTrips do
  use Ecto.Migration

  def up do
    alter table(:trading_trip_loads) do
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict)
    end

    alter table(:trading_trip_drops) do
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict)
    end

    # Backfill from linked positions or legacy trip.good_id
    execute("""
    UPDATE trading_trip_loads AS l
    SET good_id = COALESCE(
      (SELECT s.good_id FROM trading_supply_positions s WHERE s.id = l.supply_position_id),
      (SELECT t.good_id FROM trading_trips t WHERE t.id = l.trip_id)
    )
    """)

    execute("""
    UPDATE trading_trip_drops AS d
    SET good_id = COALESCE(
      (SELECT s.good_id FROM trading_sales_positions s WHERE s.id = d.sales_position_id),
      (SELECT sp.good_id FROM trading_supply_positions sp WHERE sp.id = d.supply_position_id),
      (SELECT t.good_id FROM trading_trips t WHERE t.id = d.trip_id)
    )
    """)

    execute("DELETE FROM trading_trip_loads WHERE good_id IS NULL")
    execute("DELETE FROM trading_trip_drops WHERE good_id IS NULL")

    execute("ALTER TABLE trading_trip_loads ALTER COLUMN good_id SET NOT NULL")
    execute("ALTER TABLE trading_trip_drops ALTER COLUMN good_id SET NOT NULL")

    create index(:trading_trip_loads, [:good_id])
    create index(:trading_trip_drops, [:good_id])

    drop_if_exists index(:trading_trips, [:good_id])

    alter table(:trading_trips) do
      remove :good_id
    end
  end

  def down do
    alter table(:trading_trips) do
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict)
    end

    execute("""
    UPDATE trading_trips AS t
    SET good_id = (
      SELECT l.good_id FROM trading_trip_loads l
      WHERE l.trip_id = t.id
      ORDER BY l.inserted_at
      LIMIT 1
    )
    """)

    execute("""
    UPDATE trading_trips AS t
    SET good_id = (
      SELECT d.good_id FROM trading_trip_drops d
      WHERE d.trip_id = t.id
      ORDER BY d.inserted_at
      LIMIT 1
    )
    WHERE t.good_id IS NULL
    """)

    # Cannot restore trips with no lines; leave null if any
    create index(:trading_trips, [:good_id])

    drop_if_exists index(:trading_trip_loads, [:good_id])
    drop_if_exists index(:trading_trip_drops, [:good_id])

    alter table(:trading_trip_loads) do
      remove :good_id
    end

    alter table(:trading_trip_drops) do
      remove :good_id
    end
  end
end
