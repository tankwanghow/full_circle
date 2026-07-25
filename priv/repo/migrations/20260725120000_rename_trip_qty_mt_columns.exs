defmodule FullCircle.Repo.Migrations.RenameTripQtyMtColumns do
  use Ecto.Migration

  # Rename planned_mt/actual_mt → planned/actual on trip load/drop lines.
  # No-op when create_trading_module already used the new names.

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_loads'
          AND column_name = 'planned_mt'
      ) THEN
        ALTER TABLE trading_trip_loads RENAME COLUMN planned_mt TO planned;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_loads'
          AND column_name = 'actual_mt'
      ) THEN
        ALTER TABLE trading_trip_loads RENAME COLUMN actual_mt TO actual;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_drops'
          AND column_name = 'planned_mt'
      ) THEN
        ALTER TABLE trading_trip_drops RENAME COLUMN planned_mt TO planned;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_drops'
          AND column_name = 'actual_mt'
      ) THEN
        ALTER TABLE trading_trip_drops RENAME COLUMN actual_mt TO actual;
      END IF;
    END $$;
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_loads'
          AND column_name = 'planned'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_loads'
          AND column_name = 'planned_mt'
      ) THEN
        ALTER TABLE trading_trip_loads RENAME COLUMN planned TO planned_mt;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_loads'
          AND column_name = 'actual'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_loads'
          AND column_name = 'actual_mt'
      ) THEN
        ALTER TABLE trading_trip_loads RENAME COLUMN actual TO actual_mt;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_drops'
          AND column_name = 'planned'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_drops'
          AND column_name = 'planned_mt'
      ) THEN
        ALTER TABLE trading_trip_drops RENAME COLUMN planned TO planned_mt;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_drops'
          AND column_name = 'actual'
      ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'trading_trip_drops'
          AND column_name = 'actual_mt'
      ) THEN
        ALTER TABLE trading_trip_drops RENAME COLUMN actual TO actual_mt;
      END IF;
    END $$;
    """
  end
end
