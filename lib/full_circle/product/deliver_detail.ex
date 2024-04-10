defmodule FullCircle.Product.DeliveryDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "delivery_details" do
    field :_persistent_id, :integer
    field :descriptions, :string
    field :delivery_qty, :decimal, default: 0
    field :delivery_pack_qty, :decimal, default: 0
    field :status, :string

    belongs_to :delivery, FullCircle.Product.Delivery
    belongs_to :good, FullCircle.Product.Good
    belongs_to :package, FullCircle.Product.Packaging
    belongs_to :load_detail, FullCircle.Product.LoadDetail

    has_many :invoice_details, FullCircle.Billing.InvoiceDetail

    field :package_name, :string, virtual: true
    field :unit_multiplier, :decimal, virtual: true, default: 1
    field :good_name, :string, virtual: true
    field :unit, :string, virtual: true
    field :delete, :boolean, virtual: true, default: false
  end

  def changeset(details, attrs) do
    details
    |> cast(attrs, [
      :_persistent_id,
      :delivery_pack_qty,
      :delivery_qty,
      :descriptions,
      :unit,
      :good_name,
      :package_name,
      :good_id,
      :package_id,
      :load_detail_id,
      :unit_multiplier,
      :status,
      :delete
    ])
    |> validate_required([
      :package_name,
      :delivery_pack_qty,
      :delivery_qty,
      :good_name,
      :status
    ])
    |> validate_id(:good_name, :good_id)
    |> validate_id(:package_name, :package_id)
    |> validate_number(:delivery_qty, greater_than: 0)
    |> validate_length(:descriptions, max: 230)
    |> compute_fields()
    |> maybe_mark_for_deletion()
  end

  defp compute_fields(changeset) do
    unit_multi = fetch_field!(changeset, :unit_multiplier)
    delivery_pack_qty = fetch_field!(changeset, :delivery_pack_qty)

    delivery_qty =
      if Decimal.gt?(delivery_pack_qty, "0") and Decimal.gt?(unit_multi, "0") do
        Decimal.mult(delivery_pack_qty, unit_multi)
      else
        fetch_field!(changeset, :delivery_qty)
      end

    changeset
    |> put_change(:delivery_qty, delivery_qty)
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
