defmodule FullCircle.Repo.Migrations.CreateLogs do
  use Ecto.Migration

  def change do
    create table(:logs) do
      add :entity, :string, null: false
      add :entity_id, :integer, null: false
      add :action, :string, null: false
      add :delta, :text, null: false
      add :user_id, references(:users, on_delete: :nothing), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create index(:logs, [:user_id])
    create index(:logs, [:company_id])
  end
end
