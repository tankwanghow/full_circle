defmodule FullCircle.Product.OrderDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "order_details" do
    field :_persistent_id, :integer
    field :descriptions, :string
    field :order_qty, :decimal, default: 0
    field :order_pack_qty, :decimal, default: 0
    field :unit_price, :decimal, default: 0
    field :status, :string

    belongs_to :order, FullCircle.Product.Order
    belongs_to :good, FullCircle.Product.Good
    belongs_to :package, FullCircle.Product.Packaging

    has_many :load_details, FullCircle.Product.LoadDetail

    field :package_name, :string, virtual: true
    field :unit_multiplier, :decimal, virtual: true, default: 1
    field :good_name, :string, virtual: true
    field :unit, :string, virtual: true
    field :delete, :boolean, virtual: true, default: false
    field :delivered_qty, :decimal, virtual: true
  end

  def changeset(invoice_details, attrs) do
    invoice_details
    |> cast(attrs, [
      :_persistent_id,
      :order_pack_qty,
      :order_qty,
      :descriptions,
      :unit_price,
      :unit,
      :good_name,
      :package_name,
      :good_id,
      :package_id,
      :unit_multiplier,
      :status,
      :delete
    ])
    |> validate_required([
      :package_name,
      :order_pack_qty,
      :order_qty,
      :good_name,
      :status
    ])
    |> validate_id(:good_name, :good_id)
    |> validate_id(:package_name, :package_id)
    |> validate_number(:order_qty, greater_than: 0)
    |> compute_fields()
    |> maybe_mark_for_deletion()
  end

  defp compute_fields(changeset) do
    unit_multi = fetch_field!(changeset, :unit_multiplier)
    order_pack_qty = fetch_field!(changeset, :order_pack_qty)

    order_qty =
      if Decimal.gt?(order_pack_qty, "0") and Decimal.gt?(unit_multi, "0") do
        Decimal.mult(order_pack_qty, unit_multi)
      else
        fetch_field!(changeset, :order_qty)
      end

    changeset
    |> put_change(:order_qty, order_qty)
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
