defmodule FullCircle.Repo.Migrations.CreateEmployeePhotos do
  use Ecto.Migration

  def change do
    create table(:employee_photos) do
      add :employee_id, references(:employees, on_delete: :delete_all)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :flag, :string
      add :photo_type, :string
      add :photo_data, :bytea
      add :photo_descriptor, {:array, :float}

      timestamps(type: :timestamptz, updated_at: false)
    end

    create index(:employee_photos, [:company_id, :employee_id])
    create index(:employee_photos, :flag)
  end
end
