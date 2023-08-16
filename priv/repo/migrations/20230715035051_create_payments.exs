defmodule FullCircle.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments) do
      add :payment_no, :string
      add :payment_date, :date
      add :contact_id, references(:contacts, on_delete: :restrict)
      add :descriptions, :text
      add :funds_account_id, references(:accounts, on_delete: :restrict)
      add :funds_amount, :decimal, default: 0
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:payments, [:company_id, :payment_no])
    create index(:payments, [:company_id])
    create index(:payments, [:contact_id])
    create index(:payments, [:funds_account_id])

    create table(:payment_details) do
      add :_persistent_id, :integer
      add :package_qty, :decimal, default: 0
      add :package_id, references(:packagings, on_delete: :restrict)
      add :quantity, :decimal, default: 0
      add :unit_price, :decimal, default: 0
      add :discount, :decimal, default: 0
      add :tax_rate, :decimal, default: 0
      add :descriptions, :string
      add :payment_id, references(:payments, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :restrict)
      add :account_id, references(:accounts, on_delete: :restrict)
      add :tax_code_id, references(:tax_codes, on_delete: :restrict)
    end

    create index(:payment_details, [:payment_id])
    create index(:payment_details, [:good_id])
    create index(:payment_details, [:account_id])
    create index(:payment_details, [:tax_code_id])
  end
end
