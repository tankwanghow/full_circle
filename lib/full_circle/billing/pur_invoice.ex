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
    field :tags, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :pur_invoice_details, FullCircle.Billing.PurInvoiceDetail, on_replace: :delete

    field :contact_name, :string, virtual: true
    field :pur_invoice_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_good_amount, :decimal, virtual: true, default: 0
    field :pur_invoice_tax_amount, :decimal, virtual: true, default: 0

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
      :tags,
      :company_id,
      :contact_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> fill_default_date()
    |> validate_required([
      :pur_invoice_date,
      :supplier_invoice_no,
      :due_date,
      :company_id,
      :contact_name,
      :pur_invoice_no
    ])
    |> validate_id(:contact_name, :contact_id)
    |> unsafe_validate_unique([:pur_invoice_no, :company_id], FullCircle.Repo,
      message: gettext("pur_invoice no already in company")
    )
    |> cast_assoc(:pur_invoice_details)
    |> compute_fields()
  end

  def compute_fields(changeset) do
    changeset =
      if is_nil(get_change(changeset, :pur_invoice_details)) do
        changeset
      else
        changeset
        |> sum_field_to(:pur_invoice_details, :good_amount, :pur_invoice_good_amount)
        |> sum_field_to(:pur_invoice_details, :tax_amount, :pur_invoice_tax_amount)
        |> sum_field_to(:pur_invoice_details, :amount, :pur_invoice_amount)
      end

    if Decimal.lt?(fetch_field!(changeset, :pur_invoice_amount), 0) do
      add_error(changeset, :pur_invoice_amount, gettext("must be +ve"))
    else
      changeset
    end
  end

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :pur_invoice_date)) do
      changeset
      |> force_change(:pur_invoice_date, Date.utc_today())
      |> force_change(:due_date, Date.utc_today())
    else
      changeset
    end
  end
end
