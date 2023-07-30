defmodule FullCircle.Repo.Migrations.CreateReceipts do
  use Ecto.Migration

  def change do
    create table(:receipts) do
      add :receipt_no, :string
      add :receipt_date, :date
      add :contact_id, references(:contacts, on_delete: :restrict)
      add :descriptions, :text
      add :funds_account_id, references(:accounts, on_delete: :restrict)
      add :receipt_amount, :decimal, default: 0
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:receipts, [:company_id, :receipt_no])
    create index(:receipts, [:company_id])
    create index(:receipts, [:contact_id])
    create index(:receipts, [:funds_account_id])

    create table(:received_cheques) do
      add :_persistent_id, :integer
      add :bank, :string
      add :due_date, :date
      add :city, :string
      add :state, :string
      add :cheque_no, :string
      add :amount, :decimal, default: 0
      add :receipt_id, references(:receipts, on_delete: :delete_all)
      # add :deposit_id, references(:deposits, on_delete: :nilify_all)
      # add :return_cheque_id, references(return_cheque_notes: :nilify_all)
    end

    create index(:received_cheques, [:due_date])
    create index(:received_cheques, [:receipt_id])

    create table(:receipt_transaction_matchers) do
      add :_persistent_id, :integer
      add :match_amount, :decimal, default: 0
      add :transaction_id, references(:transactions, on_delete: :restrict)
      add :receipt_id, references(:receipts, on_delete: :delete_all)
    end

    create index(:receipt_transaction_matchers, [:transaction_id])
  end
end
