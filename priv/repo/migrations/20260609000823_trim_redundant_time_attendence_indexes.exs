defmodule FullCircle.Repo.Migrations.TrimRedundantTimeAttendenceIndexes do
  use Ecto.Migration

  # time_attendences grows fast (every employee punch). Of its 5 indexes, three
  # are dead weight and only inflate storage + slow every insert:
  #
  #   * [:company_id]                          -> prefix of the composites below
  #   * [:company_id, :employee_id]            -> prefix of the composites below
  #   * [:company_id, :employee_id, :shift_id] -> shift_id is not mapped in the
  #                                               schema and unused anywhere in lib/
  #
  # Postgres serves company_id-only and (company_id, employee_id) lookups from
  # the leading columns of the remaining composite indexes, so dropping these
  # causes no read regression. We keep the two that back real queries:
  #   * [:company_id, :employee_id, :punch_time]  (last_punch_record, listings)
  #   * [:company_id, :employee_id, :flag]        (dedup on fingerprint import)
  def change do
    drop index(:time_attendences, [:company_id])
    drop index(:time_attendences, [:company_id, :employee_id])
    drop index(:time_attendences, [:company_id, :employee_id, :shift_id])
  end
end
