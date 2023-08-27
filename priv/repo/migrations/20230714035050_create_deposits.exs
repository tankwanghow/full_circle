defmodule FullCircle.Repo.Migrations.CreateDeposits do
  use Ecto.Migration

  def change do
    create table(:deposits) do
      add :deposit_no, :string
      add :deposit_date, :date
      add :company_id, references(:companies, on_delete: :delete_all)
      add :funds_from, references(:accounts, on_delete: :delete_all)
      add :funds_to, references(:accounts, on_delete: :delete_all)
      add :amount, :decimal, default: 0

      timestamps(type: :timestamptz)
    end

    create unique_index(:deposits, [:company_id, :deposit_no])
    create index(:deposits, [:company_id])
    create index(:deposits, [:company_id, :deposit_date])

    create table(:return_cheques) do
      add :return_no, :string
      add :return_date, :date
      add :company_id, references(:companies, on_delete: :delete_all)
      add :funds_from, references(:accounts, on_delete: :delete_all)
      add :funds_to, references(:accounts, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:return_cheques, [:company_id, :return_no])
    create index(:return_cheques, [:company_id, :return_date])
    create index(:return_cheques, [:company_id])
  end
end
