defmodule FullCircle.Layer.HarvestDetail do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "harvest_details" do
    belongs_to :harvest, FullCircle.Layer.Harvest
    belongs_to :flock, FullCircle.Layer.Flock
    belongs_to :house, FullCircle.Layer.House

    field :har_1, :integer, default: 0
    field :har_2, :integer, default: 0
    field :har_3, :integer, default: 0
    field :dea_1, :integer, default: 0
    field :dea_2, :integer, default: 0

    field :flock_no, :string, virtual: true
    field :house_no, :string, virtual: true
    field(:delete, :boolean, virtual: true, default: false)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :har_1,
      :har_2,
      :har_3,
      :dea_1,
      :dea_2,
      :harvest_id,
      :flock_id,
      :house_id,
      :flock_no,
      :house_no,
      :delete
    ])
    |> validate_required([
      :har_1,
      :har_2,
      :har_3,
      :dea_1,
      :dea_2,
      :flock_no,
      :house_no
    ])
    |> validate_id(:house_no, :house_id)
    |> validate_id(:flock_no, :flock_id)
    |> validate_number(:har_1, greater_than: -1)
    |> validate_number(:har_2, greater_than: -1)
    |> validate_number(:har_3, greater_than: -1)
    |> validate_number(:dea_1, greater_than: -1)
    |> validate_number(:dea_2, greater_than: -1)
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
