defmodule FullCircle.Billing.Invoice do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  alias FullCircle.Billing.DetailHelpers
  use Gettext, backend: FullCircleWeb.Gettext

  schema "invoices" do
    field :invoice_no, :string
    field :descriptions, :string
    field :due_date, :date
    field :invoice_date, :date
    field :loader_tags, :string
    field :delivery_man_tags, :string
    field :loader_wages_tags, :string
    field :delivery_wages_tags, :string
    field :e_inv_uuid, :string
    field :e_inv_internal_id, :string

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    has_many :invoice_details, FullCircle.Billing.InvoiceDetail, on_replace: :delete

    field :e_inv_long_id, :string, virtual: true
    field :contact_name, :string, virtual: true
    field :tax_id, :string, virtual: true
    field :reg_no, :string, virtual: true
    field :invoice_amount, :decimal, virtual: true, default: 0
    field :invoice_good_amount, :decimal, virtual: true, default: 0
    field :invoice_tax_amount, :decimal, virtual: true, default: 0
    field :sum_qty, :decimal, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(inv, attrs) do
    inv
    |> normal_changeset(attrs)
    |> validate_date(:invoice_date, days_before: 60)
    |> validate_date(:invoice_date, days_after: 3)
  end

  def admin_changeset(inv, attrs) do
    inv
    |> normal_changeset(attrs)
  end

  @doc false
  defp normal_changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :invoice_date,
      :due_date,
      :descriptions,
      :loader_tags,
      :delivery_man_tags,
      :loader_wages_tags,
      :delivery_wages_tags,
      :company_id,
      :contact_id,
      :contact_name,
      :invoice_no,
      :e_inv_uuid,
      :e_inv_internal_id
    ])
    |> fill_today(:invoice_date)
    |> fill_today(:due_date)
    |> validate_required([
      :invoice_date,
      :due_date,
      :company_id,
      :contact_name,
      :invoice_no
    ])
    |> cast_assoc(:invoice_details)
    |> validate_length(:descriptions, max: 230)
    |> validate_id(:contact_name, :contact_id)
    |> unique_constraint(:e_inv_uuid)
    |> unsafe_validate_unique([:invoice_no, :company_id], FullCircle.Repo,
      message: gettext("invoice no already in company")
    )
    |> compute_fields()
  end

  def compute_struct_fields(inv) do
    DetailHelpers.compute_struct_fields(
      inv, :invoice_details, :invoice_amount, :invoice_good_amount, :invoice_tax_amount
    )
  end

  def compute_fields(changeset) do
    DetailHelpers.compute_fields(
      changeset, :invoice_details, :invoice_amount, :invoice_good_amount, :invoice_tax_amount
    )
  end
end
