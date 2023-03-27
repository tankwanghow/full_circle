defmodule FullCircle.Repo.Migrations.CreateLogs do
  use Ecto.Migration

  def change do
    create table(:logs) do
      add :entity, :string
      add :entity_id, :integer
      add :action, :string
      add :delta, :text
      add :user_id, references(:users, on_delete: :nothing)
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(updated_at: false)
    end

    create index(:logs, [:user_id])
    create index(:logs, [:company_id])
  end
end
