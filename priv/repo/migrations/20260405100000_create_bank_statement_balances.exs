defmodule FullCircle.Repo.Migrations.CreateBankStatementBalances do
  use Ecto.Migration

  def change do
    create table(:bank_statement_balances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :from_date, :date, null: false
      add :to_date, :date, null: false
      add :opening_balance, :decimal
      add :closing_balance, :decimal
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all), null: false
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_statement_balances, [:account_id, :company_id, :from_date, :to_date])
  end
end
