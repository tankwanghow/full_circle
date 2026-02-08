defmodule FullCircle.Billing.PurInvoice do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  alias FullCircle.Billing.DetailHelpers
  use Gettext, backend: FullCircleWeb.Gettext

  schema "pur_invoices" do
    field :pur_invoice_no, :string
    field :e_inv_internal_id, :string
    field :descriptions, :string
    field :due_date, :date
    field :pur_invoice_date, :date
    field :loader_tags, :string
    field :delivery_man_tags, :string
    field :loader_wages_tags, :string
    field :delivery_wages_tags, :string
    field :e_inv_uuid, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :pur_invoice_details, FullCircle.Billing.PurInvoiceDetail, on_replace: :delete

    has_many :transaction_matchers, FullCircle.Accounting.TransactionMatcher,
      where: [entity: "PurInvoice"],
      on_replace: :delete,
      foreign_key: :doc_id,
      references: :id

    field :e_inv_long_id, :string, virtual: true
    field :contact_name, :string, virtual: true
    field :tax_id, :string, virtual: true
    field :reg_no, :string, virtual: true
    field :pur_invoice_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_good_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_tax_amount, :decimal, virtual: true, default: 0
    field :matched_amount, :decimal, virtual: true, default: Decimal.new("0")
    field :sum_qty, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(pinv, attrs) do
    pinv
    |> normal_changeset(attrs)
    |> validate_date(:pur_invoice_date, days_before: 100)
    |> validate_date(:pur_invoice_date, days_after: 0)
  end

  def admin_changeset(pinv, attrs) do
    pinv
    |> normal_changeset(attrs)
  end

  @doc false
  defp normal_changeset(pur_invoice, attrs) do
    pur_invoice
    |> cast(attrs, [
      :pur_invoice_date,
      :e_inv_internal_id,
      :due_date,
      :descriptions,
      :loader_tags,
      :delivery_man_tags,
      :loader_wages_tags,
      :delivery_wages_tags,
      :company_id,
      :contact_id,
      :contact_name,
      :pur_invoice_no,
      :e_inv_uuid
    ])
    |> fill_today(:pur_invoice_date)
    |> fill_today(:due_date)
    |> validate_required([
      :pur_invoice_date,
      :e_inv_internal_id,
      :due_date,
      :company_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> cast_assoc(:pur_invoice_details)
    |> validate_id(:contact_name, :contact_id)
    |> validate_length(:descriptions, max: 230)
    |> unique_constraint(:e_inv_uuid)
    |> unsafe_validate_unique([:pur_invoice_no, :company_id], FullCircle.Repo,
      message: gettext("pur_invoice no already in company")
    )
    |> compute_fields()
  end

  def compute_struct_fields(pinv) do
    DetailHelpers.compute_struct_fields(
      pinv, :pur_invoice_details, :pur_invoice_amount, :pur_invoice_good_amount, :pur_invoice_tax_amount
    )
  end

  def compute_fields(changeset) do
    DetailHelpers.compute_fields(
      changeset, :pur_invoice_details, :pur_invoice_amount, :pur_invoice_good_amount, :pur_invoice_tax_amount
    )
  end
end
