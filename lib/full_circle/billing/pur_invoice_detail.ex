defmodule FullCircle.Billing.PurInvoiceDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircle.Billing.DetailHelpers

  schema "pur_invoice_details" do
    field :descriptions, :string
    field :discount, :decimal, default: 0
    field :quantity, :decimal, default: 0
    field :unit_price, :decimal, default: 0
    field :tax_rate, :decimal, default: 0
    field :package_qty, :decimal, default: 0
    field :_persistent_id, :integer

    belongs_to :pur_invoice, FullCircle.Billing.PurInvoice
    belongs_to :good, FullCircle.Product.Good
    belongs_to :account, FullCircle.Accounting.Account
    belongs_to :tax_code, FullCircle.Accounting.TaxCode
    belongs_to :package, FullCircle.Product.Packaging

    field :package_name, :string, virtual: true
    field :account_name, :string, virtual: true
    field :tax_code_name, :string, virtual: true
    field :unit_multiplier, :decimal, virtual: true, default: 1
    field :good_name, :string, virtual: true
    field :unit, :string, virtual: true
    field :amount, :decimal, virtual: true, default: 0
    field :tax_amount, :decimal, virtual: true, default: 0
    field :good_amount, :decimal, virtual: true, default: 0
    field :delete, :boolean, virtual: true, default: false
  end

  def changeset(pur_invoice_details, attrs) do
    pur_invoice_details
    |> cast(attrs, [
      :_persistent_id,
      :quantity,
      :unit_price,
      :discount,
      :descriptions,
      :unit,
      :account_name,
      :tax_code_name,
      :good_name,
      :package_name,
      :tax_rate,
      :account_id,
      :tax_code_id,
      :good_id,
      :package_id,
      :package_qty,
      :unit_multiplier,
      :delete
    ])
    |> validate_required([
      :quantity,
      :unit_price,
      :discount,
      :tax_rate,
      :package_name,
      :account_name,
      :tax_code_name,
      :good_name
    ])
    |> compute_detail_fields()
    |> validate_id(:good_name, :good_id)
    |> validate_id(:tax_code_name, :tax_code_id)
    |> validate_id(:package_name, :package_id)
    |> validate_id(:account_name, :account_id)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:discount, less_than_or_equal_to: 0)
    |> validate_length(:descriptions, max: 230)
    |> maybe_mark_for_deletion()
  end
end
