defmodule FullCircle.EInvMetas.EInvoice do
  @derive {Jason.Encoder,
           only: [
             :rejectRequestDateTime,
             :intermediaryROB,
             :totalExcludingTax,
             :uuid,
             :totalNetAmount,
             :supplierTIN,
             :issuerTIN,
             :receiverIDType,
             :internalId,
             :status,
             :documentStatusReason,
             :longId,
             :submissionChannel,
             :buyerTIN,
             :issuerID,
             :supplierName,
             :issuerIDType,
             :totalPayableAmount,
             :dateTimeValidated,
             :typeName,
             :buyerName,
             :intermediaryTIN,
             :dateTimeReceived,
             :receiverTIN,
             :dateTimeIssued,
             :submissionUid,
             :cancelDateTime,
             :documentCurrency,
             :receiverID,
             :receiverName,
             :typeVersionName,
             :createdByUserId,
             :intermediaryName,
             :totalDiscount,
             :company_id
           ]}
  use FullCircle.Schema
  import Ecto.Changeset

  @primary_key false
  schema "e_invoices" do
    field :rejectRequestDateTime, :utc_datetime
    field :intermediaryROB, :string
    field :totalExcludingTax, :decimal
    field :uuid, :string
    field :totalNetAmount, :decimal
    field :supplierTIN, :string
    field :issuerTIN, :string
    field :receiverIDType, :string
    field :internalId, :string
    field :status, :string
    field :documentStatusReason, :string
    field :longId, :string
    field :submissionChannel, :string
    field :buyerTIN, :string
    field :issuerID, :string
    field :supplierName, :string
    field :issuerIDType, :string
    field :totalPayableAmount, :decimal
    field :dateTimeValidated, :utc_datetime
    field :typeName, :string
    field :buyerName, :string
    field :intermediaryTIN, :string
    field :dateTimeReceived, :utc_datetime
    field :receiverTIN, :string
    field :dateTimeIssued, :utc_datetime
    field :submissionUid, :string
    field :cancelDateTime, :utc_datetime
    field :documentCurrency, :string
    field :receiverID, :string
    field :receiverName, :string
    field :typeVersionName, :string
    field :createdByUserId, :string
    field :intermediaryName, :string
    field :totalDiscount, :decimal

    belongs_to(:company, FullCircle.Sys.Company, type: :binary_id)
  end

  @doc false
  def changeset(e_invoice, attrs) do
    e_invoice
    |> cast(attrs, [
      :rejectRequestDateTime,
      :intermediaryROB,
      :totalExcludingTax,
      :uuid,
      :totalNetAmount,
      :supplierTIN,
      :issuerTIN,
      :receiverIDType,
      :internalId,
      :status,
      :documentStatusReason,
      :longId,
      :submissionChannel,
      :buyerTIN,
      :issuerID,
      :supplierName,
      :issuerIDType,
      :totalPayableAmount,
      :dateTimeValidated,
      :typeName,
      :buyerName,
      :intermediaryTIN,
      :dateTimeReceived,
      :receiverTIN,
      :dateTimeIssued,
      :submissionUid,
      :cancelDateTime,
      :documentCurrency,
      :receiverID,
      :receiverName,
      :typeVersionName,
      :createdByUserId,
      :intermediaryName,
      :totalDiscount,
      :company_id
    ])
    |> validate_required([
      :company_id,
      :totalExcludingTax,
      :uuid,
      :totalNetAmount,
      :supplierTIN,
      :issuerTIN,
      :receiverIDType,
      :internalId,
      :status,
      :longId,
      :submissionChannel,
      :buyerTIN,
      :issuerID,
      :supplierName,
      :issuerIDType,
      :totalPayableAmount,
      :dateTimeValidated,
      :typeName,
      :buyerName,
      :dateTimeReceived,
      :receiverTIN,
      :dateTimeIssued,
      :submissionUid,
      :documentCurrency,
      :receiverID,
      :receiverName,
      :typeVersionName,
      :createdByUserId,
      :totalDiscount
    ])
  end
end
