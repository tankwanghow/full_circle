defmodule FullCircle.Layer.Flock do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircleWeb.Gettext

  schema "flocks" do
    belongs_to :company, FullCircle.Sys.Company
    field :flock_no, :string
    field :dob, :date
    field :quantity, :integer
    field :breed, :string
    field :note, :string

    has_many(:movements, FullCircle.Layer.Movement, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :flock_no,
      :dob,
      :quantity,
      :breed,
      :note,
      :company_id
    ])
    |> validate_required([
      :flock_no,
      :dob,
      :quantity,
      :breed
    ])
    |> to_upcase(:flock_no)
    |> validate_number(:quantity, greater_than: 0)
    |> unsafe_validate_unique([:flock_no, :company_id], FullCircle.Repo,
      message: gettext("already in company")
    )
    |> cast_assoc(:movements)
  end
end
