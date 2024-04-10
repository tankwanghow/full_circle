defmodule FullCircle.Product.LoadDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "load_details" do
    field :_persistent_id, :integer
    field :descriptions, :string
    field :load_qty, :decimal, default: 0
    field :load_pack_qty, :decimal, default: 0
    field :status, :string

    belongs_to :load, FullCircle.Product.Load
    belongs_to :good, FullCircle.Product.Good
    belongs_to :package, FullCircle.Product.Packaging
    belongs_to :order_detail, FullCircle.Product.OrderDetail

    has_many :delivery_details, FullCircle.Product.DeliveryDetail

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
      :load_pack_qty,
      :load_qty,
      :descriptions,
      :unit,
      :good_name,
      :package_name,
      :good_id,
      :package_id,
      :order_detail_id,
      :unit_multiplier,
      :status,
      :delete
    ])
    |> validate_required([
      :package_name,
      :load_pack_qty,
      :load_qty,
      :good_name,
      :status
    ])
    |> validate_id(:good_name, :good_id)
    |> validate_id(:package_name, :package_id)
    |> validate_number(:load_qty, greater_than: 0)
    |> validate_length(:descriptions, max: 230)
    |> compute_fields()
    |> maybe_mark_for_deletion()
  end

  defp compute_fields(changeset) do
    unit_multi = fetch_field!(changeset, :unit_multiplier)
    load_pack_qty = fetch_field!(changeset, :load_pack_qty)

    load_qty =
      if Decimal.gt?(load_pack_qty, "0") and Decimal.gt?(unit_multi, "0") do
        Decimal.mult(load_pack_qty, unit_multi)
      else
        fetch_field!(changeset, :load_qty)
      end

    changeset
    |> put_change(:load_qty, load_qty)
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
