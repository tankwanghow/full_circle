defmodule FullCircle.Repo.Migrations.EggStockAdhocContactNames do
  use Ecto.Migration

  def change do
    alter table(:egg_stock_day_details) do
      add :contact_name, :string, null: false, default: ""
    end

    alter table(:egg_stock_dow_template_lines) do
      add :contact_name, :string, null: false, default: ""
    end
  end
end
