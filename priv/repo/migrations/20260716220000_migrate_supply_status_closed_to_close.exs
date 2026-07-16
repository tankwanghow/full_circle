defmodule FullCircle.Repo.Migrations.MigrateSupplyStatusClosedToClose do
  use Ecto.Migration

  def up do
    # Legacy two-state "closed" → new four-state "close"
    execute("UPDATE trading_supply_positions SET status = 'close' WHERE status = 'closed'")
  end

  def down do
    execute("UPDATE trading_supply_positions SET status = 'closed' WHERE status = 'close'")
  end
end
