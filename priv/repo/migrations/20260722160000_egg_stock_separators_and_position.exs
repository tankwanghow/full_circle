defmodule FullCircle.Repo.Migrations.EggStockSeparatorsAndPosition do
  use Ecto.Migration

  def change do
    alter table(:egg_stock_dow_template_lines) do
      add :is_separator, :boolean, null: false, default: false
    end

    alter table(:egg_stock_day_details) do
      add :is_separator, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0
    end

    create index(:egg_stock_day_details, [:egg_stock_day_id, :section, :position],
             name: :egg_stock_day_details_section_position
           )
  end
end
