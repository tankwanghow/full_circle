defmodule FullCircle.Repo.Migrations.CreatePunchDevices do
  use Ecto.Migration

  def change do
    create table(:punch_devices) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :revoked_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :paired_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:punch_devices, [:company_id, :name])
    create unique_index(:punch_devices, [:token_hash])
    create index(:punch_devices, [:company_id])

    alter table(:time_attendences) do
      add :punch_device_id, references(:punch_devices, on_delete: :nilify_all)
      add :photo_path, :string
      add :client_id, :string
    end

    create unique_index(:time_attendences, [:punch_device_id, :client_id],
             where: "client_id IS NOT NULL"
           )
  end
end
