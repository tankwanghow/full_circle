defmodule FullCircle.HR.Holiday do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "holidays" do
    field(:name, :string)
    field(:holidate, :date)
    field(:short_name, :string)

    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(st, attrs) do
    st
    |> cast(attrs, [
      :name,
      :short_name,
      :holidate,
      :company_id
    ])
    |> validate_required([
      :name,
      :short_name,
      :company_id,
      :holidate
    ])
    |> unsafe_validate_unique([:name, :holidate, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :holidays_unique_name_holidate_in_company,
      message: gettext("has already been taken")
    )
  end
end
