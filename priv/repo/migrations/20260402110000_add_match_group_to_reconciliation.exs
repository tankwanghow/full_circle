defmodule FullCircle.Repo.Migrations.AddMatchGroupToReconciliation do
  use Ecto.Migration

  def change do
    alter table(:bank_statement_lines) do
      remove :matched_transaction_id
      add :match_group_id, :binary_id
    end

    alter table(:transactions) do
      add :match_group_id, :binary_id
    end

    create index(:bank_statement_lines, [:match_group_id])
    create index(:transactions, [:match_group_id])
  end
end
