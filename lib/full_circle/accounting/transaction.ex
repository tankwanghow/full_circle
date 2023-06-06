defmodule FullCircle.Accounting.Transaction do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "transactions" do
    field :doc_type, :string
    field :doc_id, :binary_id
    field :doc_date, :date
    field :particulars, :string
    field :contact_particulars, :string
    field :amount, :decimal
    field :doc_no, :string

    field :old_data, :boolean, default: false
    field :closed, :boolean, default: false
    field :reconciled, :boolean, default: false

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact
    belongs_to :account, FullCircle.Accounting.Account
    belongs_to :fixed_asset, FullCircle.Accounting.FixedAsset

    field :account_name, :string, virtual: true
    field :contact_name, :string, virtual: true

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :doc_type,
      :doc_id,
      :doc_date,
      :particulars,
      :contact_particulars,
      :amount,
      :old_data,
      :closed,
      :reconciled,
      :company_id,
      :account_id,
      :contact_id
    ])
    |> validate_required([
      :doc_type,
      :doc_id,
      :doc_date,
      :particulars,
      :amount,
      :company_id,
      :account_id
    ])
  end
end
