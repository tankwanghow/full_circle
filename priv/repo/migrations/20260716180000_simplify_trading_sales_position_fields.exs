defmodule FullCircle.Repo.Migrations.SimplifyTradingSalesPositionFields do
  use Ecto.Migration

  def change do
    drop_if_exists index(:trading_sales_positions, [:parent_id])

    alter table(:trading_sales_positions) do
      remove :reference_no, :string
      remove :parent_id, references(:trading_sales_positions, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
