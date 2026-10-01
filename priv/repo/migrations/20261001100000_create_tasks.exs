defmodule FullCircle.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      # The first cycle's own id; every cycle of a repeating task shares it.
      add :series_id, :binary_id, null: false
      add :title, :string, size: 120, null: false
      add :descriptions, :text
      add :due_date, :date
      add :recur_unit, :string
      add :recur_every, :integer
      add :reminder_before_days, :integer
      add :documents_needed, :text
      add :assignee_id, references(:users, on_delete: :nilify_all)
      add :visibility, {:array, :string}
      add :status, :string, null: false, default: "open"
      add :closed_at, :utc_datetime
      add :closed_by_id, references(:users, on_delete: :nothing)
      add :creator_id, references(:users, on_delete: :nothing), null: false
      add :lock_version, :integer, null: false, default: 0
      add :deleted_at, :utc_datetime
      add :deleted_by_id, references(:users, on_delete: :nothing)
      timestamps(type: :utc_datetime)
    end

    create constraint(:tasks, :tasks_recurrence,
             check:
               "(recur_unit IS NULL) = (recur_every IS NULL) AND " <>
                 "(recur_unit IS NULL OR (recur_every >= 1 AND due_date IS NOT NULL))"
           )

    create constraint(:tasks, :tasks_status,
             check:
               "status IN ('open', 'done', 'skipped') AND (status = 'open') = (closed_at IS NULL)"
           )

    create constraint(:tasks, :tasks_visibility_not_empty,
             check: "visibility IS NULL OR cardinality(visibility) > 0"
           )

    create index(:tasks, [:company_id, :status, :due_date])
    create index(:tasks, [:company_id, :assignee_id, :status])
    create index(:tasks, [:company_id, :series_id])

    execute(
      "CREATE INDEX tasks_title_trgm ON tasks USING gin (title gin_trgm_ops)",
      "DROP INDEX tasks_title_trgm"
    )
  end
end
