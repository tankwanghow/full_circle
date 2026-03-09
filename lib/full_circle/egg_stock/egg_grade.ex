defmodule FullCircle.EggStock.EggGrade do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "egg_grades" do
    field :name, :string
    field :nickname, :string
    field :position, :integer, default: 0
    field :delete, :boolean, virtual: true, default: false

    belongs_to :company, FullCircle.Sys.Company

    timestamps(type: :utc_datetime)
  end

  def changeset(grade, attrs) do
    grade
    |> cast(attrs, [:name, :nickname, :position, :company_id, :delete])
    |> validate_required([:name, :position, :company_id])
    |> unique_constraint(:name,
      name: :egg_grades_unique_name_in_company,
      message: "already exists"
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
