defmodule FullCircle.BillPay.PaymentDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "payment_details" do
    field :descriptions, :string
    field :discount, :decimal, default: 0
    field :quantity, :decimal, default: 0
    field :unit_price, :decimal, default: 0
    field :tax_rate, :decimal, default: 0
    field :package_qty, :decimal, default: 0
    field :_persistent_id, :integer

    belongs_to :payment, FullCircle.BillPay.Payment
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

  def changeset(invoice_details, attrs) do
    invoice_details
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
    |> validate_id(:good_name, :good_id)
    |> validate_id(:tax_code_name, :tax_code_id)
    |> validate_id(:package_name, :package_id)
    |> validate_id(:account_name, :account_id)
    |> validate_number(:quantity, greater_than: 0)
    |> compute_fields()
    |> maybe_mark_for_deletion()
  end

  defp compute_fields(changeset) do
    unit_multi = fetch_field!(changeset, :unit_multiplier)
    pack_qty = fetch_field!(changeset, :package_qty)
    price = fetch_field!(changeset, :unit_price)
    disc = fetch_field!(changeset, :discount)
    rate = fetch_field!(changeset, :tax_rate)

    qty =
      if Decimal.gt?(pack_qty, "0") and Decimal.gt?(unit_multi, "0") do
        Decimal.mult(pack_qty, unit_multi)
      else
        fetch_field!(changeset, :quantity)
      end

    good_amount = Decimal.mult(qty, price) |> Decimal.add(disc) |> Decimal.round(2)
    tax_amount = Decimal.mult(good_amount, rate) |> Decimal.round(2)
    amount = Decimal.add(good_amount, tax_amount)

    changeset
    |> put_change(:good_amount, good_amount)
    |> put_change(:tax_amount, tax_amount)
    |> put_change(:amount, amount)
    |> put_change(:quantity, qty)
  end

  defp maybe_mark_for_deletion(%{data: %{id: nil}} = changeset), do: changeset

  defp maybe_mark_for_deletion(changeset) do
    if get_change(changeset, :delete) do
      %{changeset | action: :delete}
    else
      changeset
    end
  end
end
