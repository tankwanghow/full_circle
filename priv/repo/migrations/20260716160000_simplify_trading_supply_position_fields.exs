defmodule FullCircle.Repo.Migrations.SimplifyTradingSupplyPositionFields do
  use Ecto.Migration

  def change do
    alter table(:trading_supply_positions) do
      remove :reference_no, :string
      remove :vessel_name, :string
      remove :period, :string
      add :available_from, :date
    end

    create index(:trading_supply_positions, [:company_id, :available_from])
  end
end
