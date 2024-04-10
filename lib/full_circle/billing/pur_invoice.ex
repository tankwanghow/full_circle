defmodule FullCircle.Billing.PurInvoice do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "pur_invoices" do
    field :pur_invoice_no, :string
    field :supplier_invoice_no, :string
    field :descriptions, :string
    field :due_date, :date
    field :pur_invoice_date, :date
    field :loader_tags, :string
    field :delivery_man_tags, :string
    field :loader_wages_tags, :string
    field :delivery_wages_tags, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :pur_invoice_details, FullCircle.Billing.PurInvoiceDetail, on_replace: :delete

    has_many :transaction_matchers, FullCircle.Accounting.TransactionMatcher,
      where: [entity: "PurInvoice"],
      on_replace: :delete,
      foreign_key: :doc_id,
      references: :id

    field :contact_name, :string, virtual: true
    field :pur_invoice_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_good_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_tax_amount, :decimal, virtual: true, default: 0
    field :matched_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :sum_qty, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pur_invoice, attrs) do
    pur_invoice
    |> cast(attrs, [
      :pur_invoice_date,
      :supplier_invoice_no,
      :due_date,
      :descriptions,
      :loader_tags,
      :delivery_man_tags,
      :loader_wages_tags,
      :delivery_wages_tags,
      :company_id,
      :contact_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> fill_today(:pur_invoice_date)
    |> fill_today(:due_date)
    |> validate_required([
      :pur_invoice_date,
      :supplier_invoice_no,
      :due_date,
      :company_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> validate_date(:pur_invoice_date, days_before: 60)
    |> validate_date(:pur_invoice_date, days_after: 0)
    |> validate_id(:contact_name, :contact_id)
    |> validate_length(:descriptions, max: 230)
    |> unsafe_validate_unique([:pur_invoice_no, :company_id], FullCircle.Repo,
      message: gettext("pur_invoice no already in company")
    )
    |> cast_assoc(:pur_invoice_details)
    |> cast_assoc(:transaction_matchers)
    |> compute_fields()
  end

  def compute_fields(changeset) do
    changeset =
      changeset
      |> sum_field_to(:pur_invoice_details, :good_amount, :pur_invoice_good_amount)
      |> sum_field_to(:pur_invoice_details, :tax_amount, :pur_invoice_tax_amount)
      |> sum_field_to(:pur_invoice_details, :amount, :pur_invoice_amount)
      |> sum_field_to(:pur_invoice_details, :quantity, :sum_qty)

    cond do
      Decimal.to_float(fetch_field!(changeset, :pur_invoice_amount)) <= 0.0 ->
        add_unique_error(changeset, :pur_invoice_amount, gettext("must be > 0"))

      Decimal.eq?(fetch_field!(changeset, :sum_qty), 0) ->
        add_unique_error(changeset, :pur_invoice_amount, gettext("need detail"))

      true ->
        changeset
    end
  end

  def compute_match_transactions_amount(changeset) do
    changeset |> sum_field_to(:transaction_matchers, :match_amount, :matched_amount)
  end
end
