defmodule FullCircle.Repo.Migrations.CreateTugas do
  use Ecto.Migration

  def up do
    create table(:duties) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :descriptions, :text
      add :due_date, :date

      add :status, :string, null: false, default: "active"

      # Every duty belongs to a series, recurring or not. A one-off duty is a
      # series of one, so close/spawn and end_series need no special case.
      add :series_id, :binary_id, null: false
      add :series_ended_at, :utc_datetime

      add :recur_unit, :string
      add :recur_every, :integer

      timestamps()
    end

    create index(:duties, [:company_id, :status, :due_date])
    create index(:duties, [:company_id, :series_id])

    # The whole point of a series: at most one cycle is open at a time, so
    # completing cycle N is what brings cycle N+1 into existence. Enforced in
    # the database because spawn-next runs inside a transaction that a
    # concurrent close could otherwise interleave with.
    create unique_index(:duties, [:series_id],
             where: "status = 'active'",
             name: :duties_one_live_cycle_per_series
           )

    create constraint(:duties, :duties_status_check,
             check: "status in ('active', 'done', 'skipped')"
           )

    create constraint(:duties, :duties_recur_unit_check,
             check: "recur_unit is null or recur_unit in ('day', 'week', 'month', 'year')"
           )

    # recur_every is meaningless without a unit and mandatory with one.
    create constraint(:duties, :duties_recur_every_check,
             check:
               "(recur_unit is null and recur_every is null) or (recur_unit is not null and recur_every >= 1)"
           )

    create table(:duty_events) do
      add :duty_id, references(:duties, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :note, :text

      timestamps()
    end

    create index(:duty_events, [:duty_id, :inserted_at])
    create index(:duty_events, [:company_id, :inserted_at])

    create constraint(:duty_events, :duty_events_action_check,
             check: "action in ('progress', 'done', 'skip', 'linked', 'unlinked', 'end_series')"
           )

    create table(:duty_event_documents) do
      add :duty_event_id, references(:duty_events, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :file_name, :string, null: false
      # Sniffed from the bytes on the server, never taken from the client.
      add :content_type, :string, null: false
      add :file_size, :integer, null: false
      # Relative to :uploads_dir, so the row survives a move of the volume.
      add :path, :string, null: false

      timestamps()
    end

    create index(:duty_event_documents, [:duty_event_id])

    create table(:duty_documents) do
      add :duty_id, references(:duties, on_delete: :delete_all), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      # Deliberately no FK: doc_type names the table, and the set of linkable
      # document types is a whitelist in code, not a column per type.
      add :doc_type, :string, null: false
      add :doc_id, :binary_id, null: false
      add :doc_no, :string

      timestamps()
    end

    create unique_index(:duty_documents, [:duty_id, :doc_type, :doc_id])
    create index(:duty_documents, [:company_id, :doc_type, :doc_id])
  end

  def down do
    drop table(:duty_documents)
    drop table(:duty_event_documents)
    drop table(:duty_events)
    drop table(:duties)
  end
end
