defmodule FullCircle.Repo.Migrations.CreateTimeAttends do
  use Ecto.Migration

  def change do
    create table(:time_attendences) do
      add :employee_id, references(:employees, on_delete: :restrict)
      add :user_id, references(:users)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :flag, :string
      add :input_medium, :string
      add :gps_long, :float
      add :gps_lat, :float
      add :punch_time, :timestamptz
      add :shift_id, :string
      add :status, :string

      timestamps(type: :timestamptz)
    end

    create index(:time_attendences, [:company_id])
    create index(:time_attendences, [:company_id, :employee_id])
    create index(:time_attendences, [:company_id, :employee_id, :flag])
    create index(:time_attendences, [:company_id, :employee_id, :punch_time])
    create index(:time_attendences, [:company_id, :employee_id, :shift_id])
  end
end
