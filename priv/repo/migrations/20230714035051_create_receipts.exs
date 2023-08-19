defmodule FullCircle.Repo.Migrations.CreateReceipts do
  use Ecto.Migration

  def change do
    create table(:receipts) do
      add :receipt_no, :string
      add :receipt_date, :date
      add :contact_id, references(:contacts, on_delete: :restrict)
      add :descriptions, :text
      add :funds_account_id, references(:accounts, on_delete: :restrict)
      add :funds_amount, :decimal, default: 0
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:receipts, [:company_id, :receipt_no])
    create index(:receipts, [:company_id])
    create index(:receipts, [:contact_id])
    create index(:receipts, [:funds_account_id])

    create table(:receipt_details) do
      add :_persistent_id, :integer
      add :package_qty, :decimal, default: 0
      add :package_id, references(:packagings, on_delete: :restrict)
      add :quantity, :decimal, default: 0
      add :unit_price, :decimal, default: 0
      add :discount, :decimal, default: 0
      add :tax_rate, :decimal, default: 0
      add :descriptions, :string
      add :receipt_id, references(:receipts, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :restrict)
      add :account_id, references(:accounts, on_delete: :restrict)
      add :tax_code_id, references(:tax_codes, on_delete: :restrict)
    end

    create index(:receipt_details, [:receipt_id])
    create index(:receipt_details, [:good_id])
    create index(:receipt_details, [:account_id])
    create index(:receipt_details, [:tax_code_id])

    create table(:received_cheques) do
      add :_persistent_id, :integer
      add :bank, :string
      add :due_date, :date
      add :city, :string
      add :state, :string
      add :cheque_no, :string
      add :amount, :decimal, default: 0
      add :receipt_id, references(:receipts, on_delete: :delete_all)
      add :deposit_date, :date
      add :deposit_account_id, references(:accounts, on_delete: :restrict)
      add :return_cheque_date, :date
      add :return_from_account_id, references(:accounts, on_delete: :restrict)
      add :return_to_account_id, references(:accounts, on_delete: :restrict)
    end

    create index(:received_cheques, [:due_date])
    create index(:received_cheques, [:receipt_id])
    create index(:received_cheques, [:deposit_date])
    create index(:received_cheques, [:deposit_account_id])
    create index(:received_cheques, [:return_cheque_date])
    create index(:received_cheques, [:return_from_account_id])
    create index(:received_cheques, [:return_to_account_id])
  end
end
