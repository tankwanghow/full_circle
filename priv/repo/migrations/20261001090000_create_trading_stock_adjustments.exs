defmodule FullCircle.Repo.Migrations.CreateTradingStockAdjustments do
  use Ecto.Migration

  # Stocktake corrections to own-warehouse on-hand (physical only, immutable).
  def up do
    create table(:trading_stock_adjustments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # System no ADJ-###### (gapless TradingStockAdj)
      add :reference_no, :string, null: false
      add :adjust_date, :date, null: false
      # Book on-hand at entry, what was counted, and the signed difference
      add :system_qty, :decimal, null: false
      add :counted_qty, :decimal, null: false
      add :qty, :decimal, null: false
      add :reason, :string, null: false

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :location_id, references(:trading_locations, type: :binary_id, on_delete: :restrict),
        null: false

      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_stock_adjustments, [:company_id])
    create index(:trading_stock_adjustments, [:location_id, :good_id, :adjust_date])

    create unique_index(:trading_stock_adjustments, [:company_id, :reference_no],
             name: :trading_stock_adjustments_unique_reference_no_per_company
           )

    execute("""
    INSERT INTO gapless_doc_ids (id, doc_type, current, company_id)
    SELECT gen_random_uuid(), 'TradingStockAdj', 0, c.id
    FROM companies c
    WHERE NOT EXISTS (
      SELECT 1 FROM gapless_doc_ids g
      WHERE g.company_id = c.id AND g.doc_type = 'TradingStockAdj'
    )
    """)
  end

  def down do
    execute("DELETE FROM gapless_doc_ids WHERE doc_type = 'TradingStockAdj'")
    drop table(:trading_stock_adjustments)
  end
end
