defmodule FullCircle.Repo.Migrations.CreateBankStatementLines do
  use Ecto.Migration

  def change do
    create table(:bank_statement_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :statement_date, :date, null: false
      add :description, :string
      add :cheque_no, :string
      add :amount, :decimal, null: false
      add :reference, :text
      add :source_format, :string, null: false
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false

      add :matched_transaction_id,
          references(:transactions, type: :binary_id, on_delete: :nilify_all)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:bank_statement_lines, [:account_id, :company_id])
    create index(:bank_statement_lines, [:matched_transaction_id])
  end
end
