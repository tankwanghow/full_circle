defmodule FullCircle.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :title, :string, size: 120
      add :body, :text, null: false
      add :subject_type, :string
      add :subject_id, :binary_id
      add :visibility, {:array, :string}
      add :author_id, references(:users, on_delete: :nothing), null: false
      add :updated_by_id, references(:users, on_delete: :nothing), null: false
      add :lock_version, :integer, null: false, default: 0
      add :deleted_at, :utc_datetime
      add :deleted_by_id, references(:users, on_delete: :nothing)
      timestamps(type: :utc_datetime)
    end

    create constraint(:notes, :notes_subject_pair,
             check: "(subject_type IS NULL) = (subject_id IS NULL)"
           )

    # nil means public; an empty list would mean "nobody but admin and the
    # author", which is never what someone ticking no boxes intends.
    create constraint(:notes, :notes_visibility_not_empty,
             check: "visibility IS NULL OR cardinality(visibility) > 0"
           )

    create index(:notes, [:company_id, :subject_type, :subject_id])
    create index(:notes, [:company_id, :inserted_at])

    execute(
      "CREATE INDEX notes_title_trgm ON notes USING gin (title gin_trgm_ops)",
      "DROP INDEX notes_title_trgm"
    )

    execute(
      "CREATE INDEX notes_body_trgm ON notes USING gin (body gin_trgm_ops)",
      "DROP INDEX notes_body_trgm"
    )

    create table(:note_versions) do
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :title, :string, size: 120
      add :body, :text, null: false
      add :subject_type, :string
      add :subject_id, :binary_id
      add :visibility, {:array, :string}
      add :written_by_id, references(:users, on_delete: :nothing), null: false
      add :written_at, :utc_datetime, null: false
      add :edited_by_id, references(:users, on_delete: :nothing), null: false
      # usec: an edit and a delete can land inside the same second.
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:note_versions, [:note_id, :version])

    create table(:note_attachments) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :note_id, references(:notes, on_delete: :delete_all), null: false
      add :file_name, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :path, :string, null: false
      add :uploaded_by_id, references(:users, on_delete: :nothing), null: false
      add :removed_at, :utc_datetime
      add :removed_by_id, references(:users, on_delete: :nothing)
      timestamps(type: :utc_datetime)
    end

    create index(:note_attachments, [:note_id])

    create table(:record_links) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :from_type, :string, null: false
      add :from_id, :binary_id, null: false
      add :to_type, :string, null: false
      add :to_id, :binary_id, null: false
      add :created_by_id, references(:users, on_delete: :nothing), null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:record_links, [:company_id, :from_type, :from_id, :to_type, :to_id])
    create index(:record_links, [:company_id, :to_type, :to_id])

    create constraint(:record_links, :record_links_not_self,
             check: "NOT (from_type = to_type AND from_id = to_id)"
           )
  end
end
