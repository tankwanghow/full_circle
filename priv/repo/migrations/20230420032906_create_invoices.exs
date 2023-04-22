defmodule FullCircle.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  def change do
    create table(:invoices) do
      add :invoice_no, :string
      add :invoice_date, :date
      add :due_date, :date
      add :descriptions, :text
      add :tags, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :contact_id, references(:contacts, on_delete: :nothing)

      timestamps(type: :timestamptz)
    end

    create unique_index(:invoices, [:company_id, :invoice_no])
    create index(:invoices, [:company_id])
    create index(:invoices, [:contact_id])

    create table(:invoice_details) do
      add :package_qty, :decimal, default: 0
      add :package_id, references(:packagings, on_delete: :nothing)
      add :quantity, :decimal, default: 0
      add :unit_price, :decimal, default: 0
      add :discount, :decimal, default: 0
      add :tax_rate, :decimal, default: 0
      add :descriptions, :string
      add :invoice_id, references(:invoices, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :nothing)
      add :account_id, references(:accounts, on_delete: :nothing)
      add :tax_code_id, references(:tax_codes, on_delete: :nothing)
    end

    create index(:invoice_details, [:invoice_id])
    create index(:invoice_details, [:good_id])
    create index(:invoice_details, [:account_id])
    create index(:invoice_details, [:tax_code_id])
  end
end
