defmodule FullCircle.Repo.Migrations.AddReportSnapshotToBankStatementBalances do
  use Ecto.Migration

  def change do
    alter table(:bank_statement_balances) do
      add :report_snapshot, :map
      add :finalized_at, :utc_datetime
    end
  end
end
