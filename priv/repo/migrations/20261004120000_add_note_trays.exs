defmodule FullCircle.Repo.Migrations.AddNoteTrays do
  use Ecto.Migration

  def change do
    # A write box's files before Save. note_id is set when Save claims the
    # tray, so a phone upload that arrives after Save can follow to the note.
    create table(:note_trays) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :note_id, references(:notes, on_delete: :delete_all)
      add :closed_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:note_trays, [:inserted_at])

    execute "ALTER TABLE note_attachments ALTER COLUMN note_id DROP NOT NULL",
            "ALTER TABLE note_attachments ALTER COLUMN note_id SET NOT NULL"

    alter table(:note_attachments) do
      add :tray_id, references(:note_trays, on_delete: :nothing)
    end

    create index(:note_attachments, [:tray_id])

    create constraint(:note_attachments, :note_xor_tray,
             check: "(note_id IS NULL) <> (tray_id IS NULL)"
           )
  end
end
