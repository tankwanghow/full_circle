defmodule FullCircle.BillPay.Payment do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  use Gettext, backend: FullCircleWeb.Gettext

  schema "payments" do
    field :payment_no, :string
    field :payment_date, :date
    belongs_to :contact, FullCircle.Accounting.Contact
    field :descriptions, :string
    belongs_to :funds_account, FullCircle.Accounting.Account
    field :funds_amount, :decimal, default: Decimal.new("0")
    belongs_to :company, FullCircle.Sys.Company

    has_many :payment_details, FullCircle.BillPay.PaymentDetail, on_replace: :delete

    has_many :transaction_matchers, FullCircle.Accounting.TransactionMatcher,
      where: [doc_type: "Payment"],
      on_replace: :delete,
      foreign_key: :doc_id,
      references: :id

    field :contact_name, :string, virtual: true
    field :funds_account_name, :string, virtual: true
    field :matched_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :payment_detail_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :payment_good_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :payment_tax_amount, :decimal, virtual: true, default: Decimal.new("0")

    field :payment_balance, :decimal, virtual: true, default: Decimal.new("0")

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :payment_date,
      :descriptions,
      :company_id,
      :contact_id,
      :contact_name,
      :payment_no,
      :funds_account_name,
      :funds_account_id,
      :funds_amount
    ])
    |> fill_today(:payment_date)
    |> validate_required([
      :payment_date,
      :company_id,
      :contact_name,
      :payment_no,
      :funds_account_name,
      :funds_amount
    ])
    |> validate_id(:contact_name, :contact_id)
    |> validate_length(:descriptions, max: 230)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> validate_date(:payment_date, days_before: 60)
    |> validate_date(:payment_date, days_after: 0)
    |> unsafe_validate_unique([:payment_no, :company_id], FullCircle.Repo,
      message: gettext("payment no already in company")
    )
    |> cast_assoc(:transaction_matchers)
    |> cast_assoc(:payment_details)
    |> compute_balance()
    |> validate_number(:funds_amount, greater_than: Decimal.new("0.00"))
    |> validate_number(:payment_balance, equal_to: Decimal.new("0.00"))
  end

  def compute_struct_balance(inval) do
    inval
    |> sum_struct_field_to(:payment_details, :good_amount, :payment_good_amount)
    |> sum_struct_field_to(:payment_details, :tax_amount, :payment_tax_amount)
    |> sum_struct_field_to(:payment_details, :amount, :payment_detail_amount)
    |> sum_struct_field_to(:transaction_matchers, :match_amount, :matched_amount)
  end

  def compute_balance(cs) do
    # cs =
    #   Map.replace(
    #     cs,
    #     :errors,
    #     Enum.filter(cs.errors, fn {k, _} -> k != :payment_balance end)
    #   )

    # cs = if(Enum.count(cs.errors) == 0, do: Map.replace(cs, :valid?, true), else: cs)

    cs =
      cs
      |> compute_match_transactions_amount()
      |> compute_details_amount()

    pos = fetch_field!(cs, :funds_amount) |> Decimal.to_float()

    neg =
      (fetch_field!(cs, :matched_amount) |> Decimal.to_float()) +
        (fetch_field!(cs, :payment_detail_amount) |> Decimal.to_float())

    bal = Decimal.from_float(pos - neg)

    cs
    |> cast(%{"payment_balance" => bal}, [:payment_balance])
    |> validate_number(:payment_balance, equal_to: Decimal.new("0.00"))
  end

  def compute_details_amount(changeset) do
    changeset
    |> sum_field_to(:payment_details, :good_amount, :payment_good_amount)
    |> sum_field_to(:payment_details, :tax_amount, :payment_tax_amount)
    |> sum_field_to(:payment_details, :amount, :payment_detail_amount)
  end

  def compute_match_transactions_amount(changeset) do
    changeset |> sum_field_to(:transaction_matchers, :match_amount, :matched_amount)
  end
end
