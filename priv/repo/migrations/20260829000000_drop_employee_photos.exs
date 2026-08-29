defmodule FullCircle.Repo.Migrations.DropEmployeePhotos do
  use Ecto.Migration

  # Face ID / Take Photo feature was removed; drop its table and the
  # fct_ query function that returns SETOF employee_photos (the function
  # depends on the table's row type, so it must go first).

  def up do
    execute("DROP FUNCTION IF EXISTS fct_employee_photos(uuid)")
    drop(table(:employee_photos))
  end

  def down do
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

    execute("""
    CREATE OR REPLACE FUNCTION fct_employee_photos(com_id uuid) RETURNS SETOF employee_photos AS $$
      SELECT t.* FROM employee_photos t WHERE t.company_id = com_id;
    $$ LANGUAGE SQL SECURITY DEFINER;
    """)
  end
end
