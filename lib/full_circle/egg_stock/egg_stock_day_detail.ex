defmodule FullCircle.EggStock.EggStockDayDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "egg_stock_day_details" do
    field :section, :string
    field :quantities, :map, default: %{}
    field :_persistent_id, :integer, virtual: true
    field :delete, :boolean, virtual: true, default: false

    belongs_to :egg_stock_day, FullCircle.EggStock.EggStockDay
    belongs_to :contact, FullCircle.Accounting.Contact

    field :contact_name, :string, virtual: true
  end

  def changeset(detail, attrs) do
    detail
    |> cast(attrs, [:section, :quantities, :contact_id, :contact_name, :_persistent_id, :delete])
    |> validate_required([:section])
    |> validate_id(:contact_name, :contact_id)
    |> maybe_mark_for_deletion()
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
