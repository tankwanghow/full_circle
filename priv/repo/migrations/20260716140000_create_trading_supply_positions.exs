defmodule FullCircle.Repo.Migrations.CreateTradingSupplyPositions do
  use Ecto.Migration

  def change do
    create table(:trading_supply_positions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :reference_no, :string
      add :vessel_name, :string
      add :period, :string
      add :quantity, :decimal, null: false
      add :unit, :string
      add :unit_price, :decimal
      add :status, :string, null: false, default: "open"
      add :notes, :text
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :supplier_id, references(:contacts, type: :binary_id, on_delete: :restrict), null: false
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:trading_supply_positions, [:company_id])
    create index(:trading_supply_positions, [:company_id, :status])
    create index(:trading_supply_positions, [:supplier_id])
    create index(:trading_supply_positions, [:good_id])
  end
end
