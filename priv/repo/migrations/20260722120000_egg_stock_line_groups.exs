defmodule FullCircle.Repo.Migrations.EggStockLineGroups do
  use Ecto.Migration

  def change do
    alter table(:egg_stock_dow_template_lines) do
      add :group_name, :string, null: false, default: ""
      add :group_position, :integer, null: false, default: 0
    end

    create index(:egg_stock_dow_template_lines, [:company_id, :kind, :dow, :group_position, :position],
             name: :egg_stock_dow_lines_group_order
           )

    alter table(:egg_stock_day_details) do
      add :group_name, :string, null: false, default: ""
      add :group_position, :integer, null: false, default: 0
    end

    create index(:egg_stock_day_details, [:egg_stock_day_id, :group_position, :section],
             name: :egg_stock_day_details_group_order
           )
  end
end
