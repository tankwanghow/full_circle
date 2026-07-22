defmodule FullCircle.Repo.Migrations.EggStockDowTemplates do
  use Ecto.Migration

  def up do
    create table(:egg_stock_dow_template_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :dow, :integer, null: false
      add :contact_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0
      add :quantities, :map, null: false, default: %{}

      timestamps(type: :timestamptz)
    end

    create index(:egg_stock_dow_template_lines, [:company_id, :kind, :dow, :position],
             name: :egg_stock_dow_lines_company_kind_dow_pos
           )

    create index(:egg_stock_dow_template_lines, [:contact_id])

    execute("""
    UPDATE egg_stock_day_details
    SET section = 'planned_order'
    WHERE section = 'actual_order'
    """)

    execute("""
    UPDATE egg_stock_day_details
    SET section = 'planned_purchase'
    WHERE section = 'actual_purchase'
    """)
  end

  def down do
    execute("""
    UPDATE egg_stock_day_details
    SET section = 'actual_order'
    WHERE section = 'planned_order'
    """)

    execute("""
    UPDATE egg_stock_day_details
    SET section = 'actual_purchase'
    WHERE section = 'planned_purchase'
    """)

    drop_if_exists index(:egg_stock_dow_template_lines, [:contact_id])

    drop_if_exists index(:egg_stock_dow_template_lines, [:company_id, :kind, :dow, :position],
                     name: :egg_stock_dow_lines_company_kind_dow_pos
                   )

    drop table(:egg_stock_dow_template_lines)
  end
end
