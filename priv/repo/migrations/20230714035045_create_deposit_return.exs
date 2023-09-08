defmodule FullCircle.Repo.Migrations.CreateDepositReturn do
  use Ecto.Migration

  def change do
    create table(:deposits) do
      add :deposit_no, :string
      add :deposit_date, :date
      add :funds_amount, :decimal, default: 0
      add :funds_from_id, references(:accounts, on_delete: :restrict)
      add :bank_id, references(:accounts, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :nilify_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:deposits, [:company_id, :deposit_no])
    create index(:deposits, [:company_id])
    create index(:deposits, [:company_id, :funds_from_id])
    create index(:deposits, [:company_id, :bank_id])
    create index(:deposits, [:company_id, :deposit_date])

    create table(:return_cheques) do
      add :return_cheque_no, :string
      add :return_date, :date
      add :return_reason, :string
      add :company_id, references(:companies, on_delete: :nilify_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:return_cheques, [:company_id, :return_cheque_no])
    create index(:return_cheques, [:company_id])
    create index(:return_cheques, [:company_id, :return_date])

  end
end
