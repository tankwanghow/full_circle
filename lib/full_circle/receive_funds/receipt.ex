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
    field :funds_amount, :decimal, default: 0
    belongs_to :company, FullCircle.Sys.Company

    has_many :received_cheques, FullCircle.ReceiveFund.ReceivedCheque, on_replace: :delete
    has_many :receipt_details, FullCircle.ReceiveFund.ReceiptDetail, on_replace: :delete

    has_many :transaction_matchers, FullCircle.Accounting.TransactionMatcher,
      where: [doc_type: "Receipt"],
      on_replace: :delete,
      foreign_key: :doc_id,
      references: :id

    field :contact_name, :string, virtual: true
    field :funds_account_name, :string, virtual: true
    field :cheques_amount, :decimal, virtual: true, default: 0
    field :matched_amount, :decimal, virtual: true, default: 0
    field :receipt_detail_amount, :decimal, virtual: true, default: 0
    field :receipt_good_amount, :decimal, virtual: true, default: 0
    field :receipt_tax_amount, :decimal, virtual: true, default: 0

    field :receipt_balance, :decimal, virtual: true, default: Decimal.new("0.00")
    field :receipt_amount, :decimal, virtual: true, default: Decimal.new("0.00")

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
    |> fill_today(:receipt_date)
    |> validate_required([
      :receipt_date,
      :company_id,
      :contact_name,
      :receipt_no,
      :funds_amount
    ])
    |> validate_funds_account_name()
    |> validate_date(:receipt_date, before: (Timex.shift(Timex.today(), days: 1)))
    |> validate_date(:receipt_date, after: (Timex.shift(Timex.today(), days: -60)))
    |> validate_id(:contact_name, :contact_id)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> unsafe_validate_unique([:receipt_no, :company_id], FullCircle.Repo,
      message: gettext("receipt no already in company")
    )
    |> cast_assoc(:transaction_matchers)
    |> cast_assoc(:received_cheques)
    |> cast_assoc(:receipt_details)
    |> compute_balance()
    |> validate_number(:receipt_amount, greater_than: Decimal.new("0.00"))
    |> validate_number(:receipt_balance, equal_to: Decimal.new("0.00"))
  end

  defp validate_funds_account_name(changeset) do
    if fetch_field!(changeset, :funds_amount) |> Decimal.gt?(0) do
      validate_required(changeset, :funds_account_name)
    else
      changeset
    end
  end

  def compute_struct_balance(inval) do
    inval
    |> sum_struct_field_to(:receipt_details, :good_amount, :receipt_good_amount)
    |> sum_struct_field_to(:receipt_details, :tax_amount, :receipt_tax_amount)
    |> sum_struct_field_to(:receipt_details, :amount, :receipt_detail_amount)
    |> sum_struct_field_to(:transaction_matchers, :match_amount, :matched_amount)
    |> sum_struct_field_to(:received_cheques, :amount, :cheques_amount)
  end

  def compute_balance(cs) do
    cs =
      Map.replace(
        cs,
        :errors,
        Enum.filter(cs.errors, fn {k, _} -> k != :receipt_balance and k != :receipt_amount end)
      )

    cs = if(Enum.count(cs.errors) == 0, do: Map.replace(cs, :valid?, true), else: cs)

    cs =
      cs
      |> compute_cheques_amount()
      |> compute_match_transactions_amount()
      |> compute_details_amount()

    pos =
      Decimal.add(
        fetch_field!(cs, :cheques_amount),
        fetch_field!(cs, :funds_amount)
      )

    neg =
      Decimal.sub(
        fetch_field!(cs, :matched_amount),
        fetch_field!(cs, :receipt_detail_amount)
      )

    bal = Decimal.add(pos, neg)

    cs
    |> cast(%{"receipt_balance" => bal, "receipt_amount" => pos}, [
      :receipt_balance,
      :receipt_amount
    ])
    |> validate_number(:receipt_amount, greater_than: Decimal.new("0.00"))
    |> validate_number(:receipt_balance, equal_to: Decimal.new("0.00"))
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
end
