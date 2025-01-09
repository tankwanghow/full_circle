defmodule FullCircle.Repo.Migrations.AddEInvoiceFeature do
  use Ecto.Migration

  def change do
    create table(:e_inv_metas) do
      add :e_inv_apibaseurl, :text
      add :e_inv_idsrvbaseurl, :text
      add :e_inv_clientid, :string
      add :e_inv_clientsecret1, :string
      add :e_inv_clientsecret2, :string
      add :e_inv_clientsecretexpiration, :date
      add :company_id, references(:companies, on_delete: :delete_all)
      add :token, :text
      add :login_url, :text
      add :search_url, :text
      add :get_doc_url, :text
      add :get_doc_details_url, :text
      timestamps(type: :timestamptz)
    end

    alter table(:companies) do
      add :sst_id, :string
      add :gst_id, :string
      add :tou_id, :string
      add :misc_code, :string
    end

    alter table(:contacts) do
      add :sst_id, :string
      add :gst_id, :string
      add :tou_id, :string
      add :misc_code, :string
    end

    alter table(:invoices) do
      add :e_inv_uuid, :string
      add :e_inv_long_id, :string
      add :e_inv_info, :text
      add :e_inv_internal_id, :string
    end

    alter table(:pur_invoices) do
      add :e_inv_uuid, :string
      add :e_inv_long_id, :string
      add :e_inv_info, :text
    end

    rename table(:pur_invoices), :supplier_invoice_no, to: :e_inv_internal_id

    alter table(:payments) do
      add :e_inv_uuid, :string
      add :e_inv_long_id, :string
      add :e_inv_info, :text
      add :e_inv_internal_id, :string
    end

    alter table(:receipts) do
      add :e_inv_uuid, :string
      add :e_inv_long_id, :string
      add :e_inv_info, :text
      add :e_inv_internal_id, :string
    end

    alter table(:credit_notes) do
      add :e_inv_uuid, :string
      add :e_inv_long_id, :string
      add :e_inv_info, :text
      add :e_inv_internal_id, :string
    end

    alter table(:debit_notes) do
      add :e_inv_uuid, :string
      add :e_inv_long_id, :string
      add :e_inv_info, :text
      add :e_inv_internal_id, :string
    end

    create unique_index(:invoices, [:e_inv_uuid])
    create unique_index(:pur_invoices, [:e_inv_uuid])
    create unique_index(:debit_notes, [:e_inv_uuid])
    create unique_index(:credit_notes, [:e_inv_uuid])
    create unique_index(:payments, [:e_inv_uuid])
    create unique_index(:receipts, [:e_inv_uuid])
  end
end
