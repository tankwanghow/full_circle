defmodule FullCircle.BillPay.Payment do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

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
  def changeset(receipt, attrs) do
    receipt
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
    |> fill_default_date()
    |> validate_required([
      :payment_date,
      :company_id,
      :contact_name,
      :payment_no,
      :funds_account_name,
      :funds_amount
    ])
    |> validate_id(:contact_name, :contact_id)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> unsafe_validate_unique([:payment_no, :company_id], FullCircle.Repo,
      message: gettext("receipt no already in company")
    )
    |> cast_assoc(:transaction_matchers)
    |> cast_assoc(:payment_details)
    |> compute_balance()
  end

  def compute_struct_balance(inval) do
    inval
    |> sum_struct_field_to(:payment_details, :good_amount, :payment_good_amount)
    |> sum_struct_field_to(:payment_details, :tax_amount, :payment_tax_amount)
    |> sum_struct_field_to(:payment_details, :amount, :payment_detail_amount)
    |> sum_struct_field_to(:transaction_matchers, :match_amount, :matched_amount)
  end

  def compute_balance(changeset) do
    changeset =
      changeset
      |> compute_match_transactions_amount()
      |> compute_details_amount()

    pos = fetch_field!(changeset, :funds_amount) |> Decimal.to_float()

    neg =
      (fetch_field!(changeset, :matched_amount) |> Decimal.to_float()) +
        (fetch_field!(changeset, :payment_detail_amount) |> Decimal.to_float())

    bal = Decimal.from_float(pos - neg)

    changeset =
      changeset
      |> put_change(:payment_balance, bal)

    if !Decimal.eq?(bal, 0) and
         !Enum.any?(changeset.errors, fn x ->
           {:payment_balance, {gettext("must be ZERO"), []}} == x
         end) do
      add_error(changeset, :payment_balance, gettext("must be ZERO"))
    else
      changeset
    end
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

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :payment_date)) do
      changeset
      |> put_change(:payment_date, Timex.today())
    else
      changeset
    end
  end
end
