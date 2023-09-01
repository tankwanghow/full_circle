defmodule FullCircle.Repo.Migrations.CreateTransactionMatchers do
  use Ecto.Migration

  def change do
    create table(:seed_transaction_matchers) do
      add :m_doc_type, :string
      add :m_doc_id, :integer
      add :n_doc_type, :string
      add :n_doc_id, :integer
      add :match_amount, :decimal, default: 0
      add :transaction_id, references(:transactions, on_delete: :restrict)
    end

    create index(:seed_transaction_matchers, [:transaction_id])

    create table(:transaction_matchers) do
      add :_persistent_id, :integer
      add :match_amount, :decimal, default: 0
      add :transaction_id, references(:transactions, on_delete: :restrict)
      add :doc_id, :binary_id
      add :doc_type, :string
    end

    create index(:transaction_matchers, [:transaction_id])
    create index(:transaction_matchers, [:doc_id, :doc_type])
  end
end
