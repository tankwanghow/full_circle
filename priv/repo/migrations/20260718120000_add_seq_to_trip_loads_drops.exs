defmodule FullCircle.Repo.Migrations.AddSeqToTripLoadsDrops do
  use Ecto.Migration

  def up do
    alter table(:trading_trip_loads) do
      add :seq, :integer, null: false, default: 0
    end

    alter table(:trading_trip_drops) do
      add :seq, :integer, null: false, default: 0
    end

    # Backfill load order by insert time within each trip
    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY trip_id ORDER BY inserted_at, id) AS rn
      FROM trading_trip_loads
    )
    UPDATE trading_trip_loads t
    SET seq = ranked.rn
    FROM ranked
    WHERE t.id = ranked.id
    """)

    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY trip_id ORDER BY inserted_at, id) AS rn
      FROM trading_trip_drops
    )
    UPDATE trading_trip_drops t
    SET seq = ranked.rn
    FROM ranked
    WHERE t.id = ranked.id
    """)

    create index(:trading_trip_loads, [:trip_id, :seq])
    create index(:trading_trip_drops, [:trip_id, :seq])
  end

  def down do
    drop_if_exists index(:trading_trip_drops, [:trip_id, :seq])
    drop_if_exists index(:trading_trip_loads, [:trip_id, :seq])

    alter table(:trading_trip_loads) do
      remove :seq
    end

    alter table(:trading_trip_drops) do
      remove :seq
    end
  end
end
