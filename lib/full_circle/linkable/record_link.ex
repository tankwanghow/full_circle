defmodule FullCircle.Linkable.RecordLink do
  @moduledoc """
  A link between two records, stored once and queried from either side.
  The ids carry no foreign keys; `FullCircle.Linkable` validates both ends.
  """
  use FullCircle.Schema
  import Ecto.Changeset

  schema "record_links" do
    field :from_type, :string
    field :from_id, :binary_id
    field :to_type, :string
    field :to_id, :binary_id

    belongs_to :company, FullCircle.Sys.Company
    belongs_to :created_by, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields ~w(company_id from_type from_id to_type to_id created_by_id)a

  def changeset(link, attrs) do
    link
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:to_id,
      name: :record_links_company_id_from_type_from_id_to_type_to_id_index,
      message: "already linked"
    )
    |> check_constraint(:to_id, name: :record_links_not_self, message: "cannot link to itself")
  end
end
