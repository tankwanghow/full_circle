defmodule FullCircle.Accounting.Transaction do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "transactions" do
    field :doc_type, :string
    field :doc_date, :date
    field :particulars, :string
    field :contact_particulars, :string
    field :amount, :decimal, default: Decimal.new(0)
    field :doc_no, :string
    field :doc_id, :binary_id

    field :old_data, :boolean, default: false
    field :closed, :boolean, default: false
    field :reconciled, :boolean, default: false

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact
    belongs_to :account, FullCircle.Accounting.Account
    belongs_to :fixed_asset, FullCircle.Accounting.FixedAsset

    has_many :seed_transaction_matchers, FullCircle.Accounting.SeedTransactionMatcher
    has_many :receipt_transaction_matchers, FullCircle.Accounting.TransactionMatcher

    field :account_name, :string, virtual: true
    field :contact_name, :string, virtual: true
    field :delete, :boolean, virtual: true, default: false
    field :count, :decimal, virtual: true, default: Decimal.new("1")

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def seed_changeset(tran, attrs) do
    tran
    |> cast(attrs, [
      :doc_type,
      :doc_date,
      :doc_no,
      :particulars,
      :amount,
      :company_id,
      :account_id,
      :contact_id,
      :account_name,
      :contact_name
    ])
  end

  def journal_entry_changeset(tran, attrs) do
    tran
    |> cast(attrs, [
      :doc_type,
      :doc_date,
      :doc_no,
      :particulars,
      :amount,
      :company_id,
      :account_id,
      :contact_id,
      :account_name,
      :contact_name,
      :delete
    ])
    |> validate_required([
      :particulars,
      :amount,
      :account_name
    ])
    |> validate_id(:contact_name, :contact_id)
    |> validate_id(:account_name, :account_id)
    |> maybe_mark_for_deletion()
  end

  @doc false
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :doc_type,
      :doc_date,
      :doc_no,
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
      :doc_no,
      :doc_date,
      :particulars,
      :amount,
      :company_id,
      :account_id
    ])
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
