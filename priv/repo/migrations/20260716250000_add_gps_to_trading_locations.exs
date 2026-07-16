defmodule FullCircle.Repo.Migrations.AddGpsToTradingLocations do
  use Ecto.Migration

  # Safe if create_trading_locations already includes latitude/longitude (fresh install).
  def up do
    execute("ALTER TABLE trading_locations ADD COLUMN IF NOT EXISTS latitude numeric")
    execute("ALTER TABLE trading_locations ADD COLUMN IF NOT EXISTS longitude numeric")
  end

  def down do
    execute("ALTER TABLE trading_locations DROP COLUMN IF EXISTS latitude")
    execute("ALTER TABLE trading_locations DROP COLUMN IF EXISTS longitude")
  end
end
