defmodule FullCircle.Repo.Migrations.AddEInvoiceFeature do
  use Ecto.Migration

  def change do
    create table(:e_invoices, primary_key: false) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :rejectRequestDateTime, :utc_datetime
      add :intermediaryROB, :string
      add :totalExcludingTax, :decimal
      add :uuid, :string, primary_key: true
      add :totalNetAmount, :decimal
      add :supplierTIN, :string
      add :issuerTIN, :string
      add :receiverIDType, :string
      add :internalId, :string
      add :status, :string
      add :documentStatusReason, :string
      add :longId, :string
      add :submissionChannel, :string
      add :buyerTIN, :string
      add :issuerID, :string
      add :supplierName, :string
      add :issuerIDType, :string
      add :totalPayableAmount, :decimal
      add :dateTimeValidated, :utc_datetime
      add :typeName, :string
      add :buyerName, :string
      add :intermediaryTIN, :string
      add :dateTimeReceived, :utc_datetime
      add :receiverTIN, :string
      add :dateTimeIssued, :utc_datetime
      add :submissionUid, :string
      add :cancelDateTime, :utc_datetime
      add :documentCurrency, :string
      add :receiverID, :string
      add :receiverName, :string
      add :typeVersionName, :string
      add :createdByUserId, :string
      add :intermediaryName, :string
      add :totalDiscount, :decimal
    end

    create index(:e_invoices, [:company_id, :uuid])
    create index(:e_invoices, [:company_id, :internalId])
    create index(:e_invoices, [:company_id, :dateTimeReceived])
  end
end
