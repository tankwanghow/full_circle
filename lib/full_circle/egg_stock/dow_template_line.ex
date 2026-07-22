defmodule FullCircle.EggStock.DowTemplateLine do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "egg_stock_dow_template_lines" do
    field :kind, :string
    field :dow, :integer
    field :position, :integer, default: 0
    field :quantities, :map, default: %{}
    field :delete, :boolean, virtual: true, default: false
    field :_persistent_id, :integer, virtual: true
    field :contact_name, :string, virtual: true

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    timestamps(type: :utc_datetime)
  end

  def changeset(line, attrs) do
    line
    |> cast(attrs, [
      :kind,
      :dow,
      :position,
      :quantities,
      :contact_id,
      :contact_name,
      :company_id,
      :delete,
      :_persistent_id
    ])
    |> validate_required([:kind, :dow, :company_id])
    |> validate_inclusion(:kind, ["sales", "purchase"])
    |> validate_inclusion(:dow, 1..7)
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
