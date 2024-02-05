defmodule FullCircle.Layer.House do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "houses" do
    field :house_no, :string
    field :capacity, :integer
    field :status, :string, default: "Active"
    field :filling_wages, :decimal, default: 0
    field :feeding_wages, :decimal, default: 0

    belongs_to :company, FullCircle.Sys.Company
    has_many(:movements, FullCircle.Layer.Movement, on_delete: :delete_all)
    has_many(:house_harvest_wages, FullCircle.Layer.HouseHarvestWage, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :house_no,
      :capacity,
      :status,
      :filling_wages,
      :feeding_wages,
      :company_id

    ])
    |> validate_required([
      :house_no,
      :capacity,
      :status,
      :filling_wages,
      :feeding_wages,
    ])
    |> to_upcase(:house_no)
    |> validate_number(:capacity, greater_than: 0)
    |> unsafe_validate_unique([:house_no, :company_id], FullCircle.Repo,
      message: gettext("already in company")
    )
    |> cast_assoc(:house_harvest_wages)
  end
end
