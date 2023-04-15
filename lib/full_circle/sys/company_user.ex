defmodule FullCircle.Sys.CompanyUser do
  use Ecto.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "company_user" do
    field :role, :string
    field :default_company, :boolean, default: false
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :user, FullCircle.UserAccounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company_user, attrs) do
    company_user
    |> cast(attrs, [:role, :default_company, :company_id, :user_id])
    |> unique_constraint(:email,
      name: :company_user_unique_user_in_company,
      message: gettext("already in company")
    )
    |> validate_required([:role, :company_id, :user_id])
    |> validate_inclusion(:role, FullCircle.Authorization.roles(), message: gettext("not in list"))
  end
end
