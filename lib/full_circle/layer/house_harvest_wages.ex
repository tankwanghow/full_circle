defmodule FullCircle.Layer.HouseHarvestWage do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "house_harvest_wages" do
    field :wages, :decimal

    field :ltry, :integer
    field :utry, :integer

    belongs_to :house, FullCircle.Layer.House

    field(:delete, :boolean, virtual: true, default: false)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :house_id,
      :utry,
      :wages,
      :ltry,
      :delete
    ])
    |> validate_required([
      :utry,
      :wages,
      :ltry
    ])
    |> validate_number(:utry, greater_than: 0)
    |> validate_number(:ltry, greater_than: 0)
    |> validate_number(:wages, greater_than: 0)
    |> unsafe_validate_unique([:house_id, :ltry], FullCircle.Repo,
      message: gettext("already in company")
    )
    |> unsafe_validate_unique([:house_id, :utry], FullCircle.Repo,
      message: gettext("already in company")
    )
    |> unique_constraint(:utry,
      name: :house_harvest_wages_house_id_utry_index,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:ltry,
      name: :house_harvest_wages_house_id_ltry_index,
      message: gettext("has already been taken")
    )
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
