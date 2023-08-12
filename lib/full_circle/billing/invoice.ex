defmodule FullCircle.Billing.Invoice do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "invoices" do
    field :invoice_no, :string
    field :descriptions, :string
    field :due_date, :date
    field :invoice_date, :date
    field :tags, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :invoice_details, FullCircle.Billing.InvoiceDetail, on_replace: :delete

    field :contact_name, :string, virtual: true
    field :invoice_amount, :decimal, virtual: true, default: 0
    field :invoice_good_amount, :decimal, virtual: true, default: 0
    field :invoice_tax_amount, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :invoice_date,
      :due_date,
      :descriptions,
      :tags,
      :company_id,
      :contact_id,
      :contact_name,
      :invoice_no
    ])
    |> fill_default_date()
    |> validate_required([
      :invoice_date,
      :due_date,
      :company_id,
      :contact_name,
      :invoice_no
    ])
    |> validate_id(:contact_name, :contact_id)
    |> unsafe_validate_unique([:invoice_no, :company_id], FullCircle.Repo,
      message: gettext("invoice no already in company")
    )
    |> cast_assoc(:invoice_details)
    |> compute_fields()
  end

  def compute_fields(changeset) do
    changeset =
      changeset
      |> sum_field_to(:invoice_details, :good_amount, :invoice_good_amount)
      |> sum_field_to(:invoice_details, :tax_amount, :invoice_tax_amount)
      |> sum_field_to(:invoice_details, :amount, :invoice_amount)

    if Decimal.lt?(fetch_field!(changeset, :invoice_amount), 0) do
      add_error(changeset, :invoice_amount, gettext("must be +ve"))
    else
      changeset
    end
  end

  defp fill_default_date(changeset) do
    if is_nil(fetch_field!(changeset, :invoice_date)) do
      changeset
      |> force_change(:invoice_date, Date.utc_today())
      |> force_change(:due_date, Date.utc_today())
    else
      changeset
    end
  end
end
