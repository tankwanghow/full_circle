defmodule FullCircle.Repo.Migrations.CreatePurInvoices do
  use Ecto.Migration

  def change do
    create table(:pur_invoices) do
      add :pur_invoice_no, :string
      add :supplier_invoice_no, :string
      add :pur_invoice_date, :date
      add :due_date, :date
      add :descriptions, :text
      add :tags, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :contact_id, references(:contacts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:pur_invoices, [:company_id, :pur_invoice_no])
    create index(:pur_invoices, [:company_id])
    create index(:pur_invoices, [:company_id, :contact_id])
    create index(:pur_invoices, [:company_id, :pur_invoice_date])
    create index(:pur_invoices, [:company_id, :due_date])
    create index(:pur_invoices, [:company_id, :supplier_invoice_no])


    create table(:pur_invoice_details) do
      add :_persistent_id, :integer
      add :package_qty, :decimal, default: 0
      add :package_id, references(:packagings, on_delete: :restrict)
      add :quantity, :decimal, default: 0
      add :unit_price, :decimal, default: 0
      add :discount, :decimal, default: 0
      add :tax_rate, :decimal, default: 0
      add :descriptions, :string
      add :pur_invoice_id, references(:pur_invoices, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :restrict)
      add :account_id, references(:accounts, on_delete: :restrict)
      add :tax_code_id, references(:tax_codes, on_delete: :restrict)
    end

    create index(:pur_invoice_details, [:pur_invoice_id])
    create index(:pur_invoice_details, [:good_id])
    create index(:pur_invoice_details, [:account_id])
    create index(:pur_invoice_details, [:tax_code_id])
  end
end
