defmodule FullCircle.Repo.Migrations.MigrateSalesStatusCancelledToCanceled do
  use Ecto.Migration

  def up do
    execute("UPDATE trading_sales_positions SET status = 'canceled' WHERE status = 'cancelled'")
  end

  def down do
    execute("UPDATE trading_sales_positions SET status = 'cancelled' WHERE status = 'canceled'")
  end
end
