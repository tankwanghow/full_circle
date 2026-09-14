defmodule FullCircle.Repo.Migrations.CreatePunchIngestLogs do
  use Ecto.Migration

  def change do
    create table(:punch_ingest_logs) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :punch_device_id, references(:punch_devices, on_delete: :nilify_all)
      add :employee_id, references(:employees, on_delete: :nilify_all)
      add :employee_id_raw, :string
      add :time_attendence_id, references(:time_attendences, on_delete: :nilify_all)
      add :client_id, :string
      add :punched_at, :timestamptz
      add :outcome, :string, null: false
      add :reason, :string
      add :http_status, :integer, null: false
      add :photo_path, :string

      timestamps(updated_at: false)
    end

    # Newest-first listing. PostgreSQL scans a btree backwards, so a plain
    # ascending index serves `order_by: [desc: inserted_at]` without a DESC index.
    # The list query adds `desc: id` as a tiebreaker; it is not in the index
    # because inserted_at is microsecond precision, so ties are vanishingly rare
    # and only need to be *deterministic*, not index-ordered.
    create index(:punch_ingest_logs, [:company_id, :inserted_at])
    create index(:punch_ingest_logs, [:company_id, :outcome, :inserted_at])

    create constraint(:punch_ingest_logs, :punch_ingest_logs_outcome_check,
             check: "outcome IN ('accepted','replayed','duplicate','rejected')"
           )

    create constraint(:punch_ingest_logs, :punch_ingest_logs_reason_presence_check,
             check:
               "(outcome = 'rejected' AND reason IS NOT NULL) OR (outcome <> 'rejected' AND reason IS NULL)"
           )

    create constraint(:punch_ingest_logs, :punch_ingest_logs_reason_check,
             check:
               "reason IS NULL OR reason IN ('not_found','inactive','too_large','missing_photo','future','invalid','revoked')"
           )
  end
end
