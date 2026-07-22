defmodule FullCircle.EggStock.EggStockDayDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "egg_stock_day_details" do
    field :section, :string
    field :quantities, :map, default: %{}
    field :ignore, :boolean, default: false
    field :group_name, :string, default: ""
    field :group_position, :integer, default: 0
    field :is_separator, :boolean, default: false
    field :position, :integer, default: 0
    field :_persistent_id, :integer, virtual: true

    belongs_to :egg_stock_day, FullCircle.EggStock.EggStockDay
    belongs_to :contact, FullCircle.Accounting.Contact

    field :contact_name, :string, virtual: true
  end

  def changeset(detail, attrs) do
    detail
    |> cast(attrs, [
      :section,
      :quantities,
      :contact_id,
      :contact_name,
      :_persistent_id,
      :ignore,
      :group_name,
      :group_position,
      :is_separator,
      :position
    ])
    |> validate_required([:section])
    |> update_change(:group_name, &normalize_group_name/1)
    |> maybe_clear_contact_for_separator()
    |> maybe_validate_contact()
  end

  defp normalize_group_name(nil), do: ""
  defp normalize_group_name(name), do: name |> to_string() |> String.trim()

  defp maybe_clear_contact_for_separator(cs) do
    if get_field(cs, :is_separator) do
      cs
      |> put_change(:contact_id, nil)
      |> put_change(:quantities, %{})
    else
      cs
    end
  end

  defp maybe_validate_contact(cs) do
    if get_field(cs, :is_separator) do
      cs
    else
      validate_id(cs, :contact_name, :contact_id)
    end
  end
end
