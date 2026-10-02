defmodule FullCircle.Repo.Migrations.AddReplyToToNotes do
  use Ecto.Migration

  def up do
    alter table(:notes) do
      add :reply_to_id, references(:notes, on_delete: :nilify_all)
    end

    create index(:notes, [:company_id, :reply_to_id])
    flush()
    {:ok, _} = FullCircle.Notes.ReplyBackfill.run(repo())
  end

  def down do
    drop index(:notes, [:company_id, :reply_to_id])

    alter table(:notes) do
      remove :reply_to_id
    end
  end
end
