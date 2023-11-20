defmodule FullCircle.Layer.Movement do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers

  schema "movements" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :flock, FullCircle.Layer.Flock
    belongs_to :house, FullCircle.Layer.House

    field :move_date, :date, default: Timex.today
    field :quantity, :integer, default: 0
    field :note, :string

    field :flock_no, :string, virtual: true
    field :house_no, :string, virtual: true
    field :house_info, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :flock_id,
      :house_id,
      :house_no,
      :move_date,
      :quantity,
      :note,
      :company_id,
      :house_info
    ])
    |> validate_required([
      :house_no,
      :quantity,
      :move_date
    ])
    |> validate_id(:house_no, :house_id)
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
