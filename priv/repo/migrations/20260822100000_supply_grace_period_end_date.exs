defmodule FullCircle.Repo.Migrations.SupplyGracePeriodEndDate do
  use Ecto.Migration

  # Supplier storage tracking: last free-storage day for a supply position.
  # Manually entered (any time, even after collection, for bill verification);
  # nil = no storage tracking for that supply.
  def change do
    alter table(:trading_supply_positions) do
      add :grace_period_end_date, :date
    end
  end
end
