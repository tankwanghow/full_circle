defmodule FullCircle.Repo.Migrations.CreateSeedTransactionMatchers do
  use Ecto.Migration

  def change do
    create table(:seed_transaction_matchers) do
      add :m_doc_type, :string
      add :m_doc_id, :integer
      add :n_doc_type, :string
      add :n_doc_id, :integer
      add :amount, :decimal, default: 0
      add :transaction_id, references(:transactions, on_delete: :restrict)
    end

    create index(:seed_transaction_matchers, [:transaction_id])
  end
end