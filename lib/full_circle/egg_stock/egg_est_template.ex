defmodule FullCircle.EggStock.EggEstTemplate do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "egg_est_templates" do
    field :type, :string
    field :day_of_week, :integer
    field :quantities, :map, default: %{}
    field :lookback_weeks, :integer, default: 4
    field :delete, :boolean, virtual: true, default: false

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :contact, FullCircle.Accounting.Contact

    field :contact_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :type,
      :day_of_week,
      :quantities,
      :lookback_weeks,
      :contact_id,
      :contact_name,
      :company_id,
      :delete
    ])
    |> validate_required([:type, :day_of_week, :company_id])
    |> validate_inclusion(:type, ["sales", "purchase"])
    |> validate_inclusion(:day_of_week, 1..7)
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
