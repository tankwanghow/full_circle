defmodule FullCircle.Repo.Migrations.CreateHolidays do
  use Ecto.Migration

  def change do
    create table(:holidays) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :name, :string
      add :short_name, :string
      add :holidate, :date

      timestamps(type: :timestamptz)
    end

    create unique_index(:holidays, [:company_id, :holidate],
             name: :holidays_unique_holidate_in_company
           )
  end
end
