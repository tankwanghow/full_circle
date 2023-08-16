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
    field :funds_amount, :decimal, default: Decimal.new("0")
    belongs_to :company, FullCircle.Sys.Company

    has_many :received_cheques, FullCircle.ReceiveFund.ReceivedCheque, on_replace: :delete
    has_many :receipt_details, FullCircle.ReceiveFund.ReceiptDetail, on_replace: :delete

    has_many :transaction_matchers, FullCircle.Accounting.TransactionMatcher,
      where: [entity: "receipts"],
      on_replace: :delete,
      foreign_key: :entity_id,
      references: :id

    field :contact_name, :string, virtual: true
    field :funds_account_name, :string, virtual: true
    field :cheques_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :matched_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :receipt_detail_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :receipt_good_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :receipt_tax_amount, :decimal, virtual: true, default: Decimal.new("0")

    field :receipt_balance, :decimal, virtual: true, default: Decimal.new("0")

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
      :funds_amount
    ])
    |> fill_default_date()
    |> validate_required([
      :receipt_date,
      :company_id,
      :contact_name,
      :receipt_no,
      :funds_amount
    ])
    |> validate_id(:contact_name, :contact_id)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> unsafe_validate_unique([:receipt_no, :company_id], FullCircle.Repo,
      message: gettext("receipt no already in company")
    )
    |> cast_assoc(:transaction_matchers)
    |> cast_assoc(:received_cheques)
    |> cast_assoc(:receipt_details)
    |> compute_balance()
  end

  def compute_struct_balance(inval) do
    inval
    |> sum_struct_field_to(:receipt_details, :good_amount, :receipt_good_amount)
    |> sum_struct_field_to(:receipt_details, :tax_amount, :receipt_tax_amount)
    |> sum_struct_field_to(:receipt_details, :amount, :receipt_detail_amount)
    |> sum_struct_field_to(:transaction_matchers, :match_amount, :matched_amount)
    |> sum_struct_field_to(:received_cheques, :amount, :cheques_amount)
  end

  def compute_balance(changeset) do
    changeset =
      changeset
      |> compute_cheques_amount()
      |> compute_match_transactions_amount()
      |> compute_details_amount()

    pos =
      (fetch_field!(changeset, :cheques_amount) |> Decimal.to_float()) +
        (fetch_field!(changeset, :funds_amount) |> Decimal.to_float())

    neg =
      (fetch_field!(changeset, :matched_amount) |> Decimal.to_float()) -
        (fetch_field!(changeset, :receipt_detail_amount) |> Decimal.to_float())

    bal = Decimal.from_float(pos + neg)

    changeset =
      changeset
      |> force_change(:receipt_balance, bal)

    if !Decimal.eq?(bal, 0) do
      add_error(changeset, :receipt_balance, gettext("must be ZERO"))
    else
      changeset
    end
  end

  def compute_details_amount(changeset) do
    changeset
    |> sum_field_to(:receipt_details, :good_amount, :receipt_good_amount)
    |> sum_field_to(:receipt_details, :tax_amount, :receipt_tax_amount)
    |> sum_field_to(:receipt_details, :amount, :receipt_detail_amount)
  end

  def compute_match_transactions_amount(changeset) do
    changeset |> sum_field_to(:transaction_matchers, :match_amount, :matched_amount)
  end

  def compute_cheques_amount(changeset) do
    changeset |> sum_field_to(:received_cheques, :amount, :cheques_amount)
  end

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :receipt_date)) do
      changeset
      |> force_change(:receipt_date, Timex.today())
    else
      changeset
    end
  end
end
