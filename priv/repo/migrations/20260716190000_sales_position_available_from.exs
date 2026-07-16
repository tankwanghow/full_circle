defmodule FullCircle.Repo.Migrations.SalesPositionAvailableFrom do
  use Ecto.Migration

  def change do
    alter table(:trading_sales_positions) do
      remove :period, :string
      add :available_from, :date
    end

    create index(:trading_sales_positions, [:company_id, :available_from])
  end
end
