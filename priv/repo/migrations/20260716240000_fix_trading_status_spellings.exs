defmodule FullCircle.Repo.Migrations.FixTradingStatusSpellings do
  use Ecto.Migration

  def up do
    # Revert misspellings: close → closed, canceled → cancelled
    execute("UPDATE trading_supply_positions SET status = 'closed' WHERE status = 'close'")
    execute("UPDATE trading_sales_positions SET status = 'cancelled' WHERE status = 'canceled'")
  end

  def down do
    execute("UPDATE trading_supply_positions SET status = 'close' WHERE status = 'closed'")
    execute("UPDATE trading_sales_positions SET status = 'canceled' WHERE status = 'cancelled'")
  end
end
