defmodule FullCircle.Repo.Migrations.CreateTimeAttends do
  use Ecto.Migration

  def change do
    create table(:time_attendences) do
      add :employee_id, references(:employees, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :flag, :string
      add :punch_time, :utc_datetime
    end
    create index(:time_attendences, [:company_id, :employee_id])
  end
end
