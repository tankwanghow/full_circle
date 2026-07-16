defmodule FullCircle.Repo.Migrations.CreateTradingSalesPositions do
  use Ecto.Migration

  def change do
    create table(:trading_sales_positions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # draft | open | hold | fulfilled | cancelled
      add :title, :string, null: false
      add :available_from, :date
      add :quantity, :decimal, null: false
      add :unit_price, :decimal
      add :status, :string, null: false, default: "draft"
      add :notes, :text
      add :fulfilled_note, :text

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :customer_id, references(:contacts, type: :binary_id, on_delete: :restrict), null: false
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

      add :preferred_supply_id,
          references(:trading_supply_positions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_sales_positions, [:company_id])
    create index(:trading_sales_positions, [:company_id, :status])
    create index(:trading_sales_positions, [:company_id, :available_from])
    create index(:trading_sales_positions, [:customer_id])
    create index(:trading_sales_positions, [:good_id])
    create index(:trading_sales_positions, [:preferred_supply_id])
  end
end
