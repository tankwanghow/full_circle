defmodule FullCircle.Repo.Migrations.CreateStatutoryConfig do
  use Ecto.Migration

  def change do
    create table(:statutory_rate_tables) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :effective_from, :date, null: false
      add :columns, {:array, :string}, null: false
      add :rows, :jsonb, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:statutory_rate_tables, [:company_id, :code, :effective_from],
             name: :statutory_rate_tables_unique_code_effective
           )

    create table(:statutory_calcs) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :effective_from, :date, null: false
      add :script, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:statutory_calcs, [:company_id, :code, :effective_from],
             name: :statutory_calcs_unique_code_effective
           )

    create table(:statutory_file_formats) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :effective_from, :date, null: false
      add :renderer, :string, null: false, default: "text"
      add :spec, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:statutory_file_formats, [:company_id, :code, :effective_from],
             name: :statutory_file_formats_unique_code_effective
           )
  end
end