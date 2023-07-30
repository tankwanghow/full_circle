defmodule FullCircle.ReceiveFund.Receipt do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "receipts" do
    field :receipt_no, :string
    field :receipt_date, :date
    belongs_to :contact, FullCircle.Accounting.Contact
    field :descriptions, :string
    belongs_to :funds_account, FullCircle.Accounting.Account
    field :receipt_amount, :decimal, default: 0
    belongs_to :company, FullCircle.Sys.Company

    has_many :received_cheques, FullCircle.ReceiveFund.ReceivedCheque, on_replace: :delete
    has_many :receipt_transaction_matchers, FullCircle.ReceiveFund.ReceiptTransactionMatcher,
      on_replace: :delete

    field :contact_name, :string, virtual: true
    field :funds_account_name, :string, virtual: true
    field :receipt_good_amount, :decimal, virtual: true, default: 0
    field :receipt_tax_amount, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :receipt_date,
      :descriptions,
      :company_id,
      :contact_id,
      :contact_name,
      :receipt_no,
      :funds_account_name,
      :funds_account_id,
      :receipt_amount
    ])
    |> fill_default_date()
    |> validate_required([
      :receipt_date,
      :company_id,
      :contact_name,
      :receipt_no,
      :receipt_amount
    ])
    |> validate_id(:contact_name, :contact_id)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> unsafe_validate_unique([:receipt_no, :company_id], FullCircle.Repo,
      message: gettext("receipt no already in company"))
    |> validate_number(:receipt_amount, greater_than: 0)
    |> cast_assoc(:receipt_transaction_matchers)
    # |> compute_fields()
  end

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :receipt_date)) do
      changeset
      |> put_change(:receipt_date, Timex.today())
    else
      changeset
    end
  end
end
