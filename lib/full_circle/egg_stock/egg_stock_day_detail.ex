defmodule FullCircle.EggStock.EggStockDayDetail do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "egg_stock_day_details" do
    field :section, :string
    field :quantities, :map, default: %{}
    field :ignore, :boolean, default: false
    field :group_name, :string, default: ""
    field :group_position, :integer, default: 0
    field :is_separator, :boolean, default: false
    field :position, :integer, default: 0
    # Persisted label; used when contact_id is nil (ad-hoc name) and as fallback
    field :contact_name, :string, default: ""
    field :_persistent_id, :integer, virtual: true

    belongs_to :egg_stock_day, FullCircle.EggStock.EggStockDay
    belongs_to :contact, FullCircle.Accounting.Contact
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
    |> update_change(:group_name, &normalize_text/1)
    |> update_change(:contact_name, &normalize_text/1)
    |> maybe_clear_contact_for_separator()
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(name), do: name |> to_string() |> String.trim()

  defp maybe_clear_contact_for_separator(cs) do
    if get_field(cs, :is_separator) do
      cs
      |> put_change(:contact_id, nil)
      |> put_change(:contact_name, "")
      |> put_change(:quantities, %{})
    else
      cs
    end
  end
end
