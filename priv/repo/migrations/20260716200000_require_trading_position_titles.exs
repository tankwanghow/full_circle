defmodule FullCircle.Repo.Migrations.RequireTradingPositionTitles do
  use Ecto.Migration

  def change do
    execute(
      "UPDATE trading_supply_positions SET title = 'Untitled supply' WHERE title IS NULL OR btrim(title) = ''",
      "SELECT 1"
    )

    execute(
      "UPDATE trading_sales_positions SET title = 'Untitled sales' WHERE title IS NULL OR btrim(title) = ''",
      "SELECT 1"
    )

    alter table(:trading_supply_positions) do
      modify :title, :string, null: false
    end

    alter table(:trading_sales_positions) do
      modify :title, :string, null: false
    end
  end
end
