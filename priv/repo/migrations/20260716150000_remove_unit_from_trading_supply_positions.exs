defmodule FullCircle.Repo.Migrations.RemoveUnitFromTradingSupplyPositions do
  use Ecto.Migration

  def change do
    alter table(:trading_supply_positions) do
      remove :unit, :string
    end
  end
end
