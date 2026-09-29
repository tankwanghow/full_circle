defmodule FullCircle.Repo.Migrations.DropTugas do
  use Ecto.Migration

  # The backend-only Tugas tables were never used by any UI and hold no data
  # worth keeping; Notes & Tasks replace them (spec 2026-09-29).
  def up do
    drop_if_exists table(:duty_event_documents)
    drop_if_exists table(:duty_documents)
    drop_if_exists table(:duty_events)
    drop_if_exists table(:duties)
  end

  def down do
    raise Ecto.MigrationError, message: "irreversible: Tugas tables were dropped"
  end
end
