defmodule FullCircle.Repo.Migrations.CreateEggStockTables do
  use Ecto.Migration

  def change do
    create table(:egg_grades) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :nickname, :string
      add :position, :integer, null: false, default: 0

      timestamps(type: :timestamptz)
    end

    create unique_index(:egg_grades, [:company_id, :name],
             name: :egg_grades_unique_name_in_company
           )

    create index(:egg_grades, [:company_id, :position])

    create table(:egg_stock_days) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :stock_date, :date, null: false
      add :opening_bal, :map, default: %{}
      add :closing_bal, :map, default: %{}
      add :expired, :map, default: %{}
      add :ungraded_bal, :integer, default: 0
      add :note, :text

      timestamps(type: :timestamptz)
    end

    create unique_index(:egg_stock_days, [:company_id, :stock_date],
             name: :egg_stock_days_unique_date_in_company
           )

    create table(:egg_stock_day_details) do
      add :egg_stock_day_id, references(:egg_stock_days, on_delete: :delete_all), null: false
      add :contact_id, references(:contacts, on_delete: :nilify_all)
      add :section, :string, null: false
      add :quantities, :map, default: %{}
      add :ignore, :boolean, default: false, null: false
    end

    create index(:egg_stock_day_details, [:egg_stock_day_id])
    create index(:egg_stock_day_details, [:contact_id])

    alter table(:invoices) do
      add :load_date, :date
    end

    alter table(:pur_invoices) do
      add :load_date, :date
    end
  end
end
