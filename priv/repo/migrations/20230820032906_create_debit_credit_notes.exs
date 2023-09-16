defmodule FullCircle.Repo.Migrations.CreateDebitCreditNotes do
  use Ecto.Migration

  def change do
    create table(:credit_notes) do
      add :note_no, :string
      add :note_date, :date
      add :company_id, references(:companies, on_delete: :delete_all)
      add :contact_id, references(:contacts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:credit_notes, [:company_id, :note_no])
    create index(:credit_notes, [:company_id])
    create index(:credit_notes, [:company_id, :contact_id])
    create index(:credit_notes, [:company_id, :note_date])

    create table(:credit_note_details) do
      add :_persistent_id, :integer
      add :descriptions, :string
      add :quantity, :decimal, default: 0
      add :unit_price, :decimal, default: 0
      add :tax_rate, :decimal, default: 0
      add :credit_note_id, references(:credit_notes, on_delete: :delete_all)
      add :account_id, references(:accounts, on_delete: :restrict)
      add :tax_code_id, references(:tax_codes, on_delete: :restrict)
    end

    create index(:credit_note_details, [:credit_note_id])
    create index(:credit_note_details, [:account_id])
    create index(:credit_note_details, [:tax_code_id])

    create table(:debit_notes) do
      add :note_no, :string
      add :note_date, :date
      add :company_id, references(:companies, on_delete: :delete_all)
      add :contact_id, references(:contacts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:debit_notes, [:company_id, :note_no])
    create index(:debit_notes, [:company_id])
    create index(:debit_notes, [:company_id, :contact_id])
    create index(:debit_notes, [:company_id, :note_date])

    create table(:debit_note_details) do
      add :_persistent_id, :integer
      add :descriptions, :string
      add :quantity, :decimal, default: 0
      add :unit_price, :decimal, default: 0
      add :tax_rate, :decimal, default: 0
      add :debit_note_id, references(:debit_notes, on_delete: :delete_all)
      add :account_id, references(:accounts, on_delete: :restrict)
      add :tax_code_id, references(:tax_codes, on_delete: :restrict)
    end

    create index(:debit_note_details, [:debit_note_id])
    create index(:debit_note_details, [:account_id])
    create index(:debit_note_details, [:tax_code_id])
  end
end
