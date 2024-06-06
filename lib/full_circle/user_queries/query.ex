defmodule FullCircle.UserQueries.Query do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "queries" do
    field :qry_name, :string
    field :sql_string, :string

    belongs_to(:company, FullCircle.Sys.Company)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(query, attrs) do
    query
    |> cast(attrs, [:qry_name, :sql_string, :company_id])
    |> validate_required([:qry_name, :sql_string, :company_id])
    |> unsafe_validate_unique([:qry_name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:qry_name,
      name: :goods_unique_qry_name_in_company,
      message: gettext("has already been taken")
    )
  end
end
