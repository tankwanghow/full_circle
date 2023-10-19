defmodule FullCircle.Sys.Company do
  use FullCircle.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias FullCircle.Repo
  import FullCircleWeb.Gettext

  schema "companies" do
    field :address1, :string
    field :address2, :string
    field :city, :string
    field :country, :string
    field :name, :string
    field :state, :string
    field :zipcode, :string
    field :timezone, :string
    field :reg_no, :string
    field :email, :string
    field :tel, :string
    field :fax, :string
    field :descriptions, :string
    field :tax_id, :string
    field :closing_month, :integer
    field :closing_day, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(company, attrs, user) do
    company
    |> cast(attrs, [
      :name,
      :address1,
      :address2,
      :city,
      :zipcode,
      :state,
      :country,
      :closing_month,
      :closing_day,
      :timezone,
      :reg_no,
      :email,
      :tel,
      :fax,
      :descriptions,
      :tax_id
    ])
    |> validate_required([
      :name,
      :country,
      :timezone,
      :closing_day,
      :closing_month
    ])
    |> validate_number(:closing_day,
      greater_than: 0,
      less_than: 32,
      message: gettext("must between 1 to 31")
    )
    |> validate_inclusion(:country, FullCircle.Sys.countries(), message: gettext("not in list"))
    |> validate_inclusion(:timezone, Tzdata.zone_list(), message: gettext("not in list"))
    |> validate_unique_by_user(:name, user)
  end

  def validate_unique_by_user(changeset, field, user) do
    {_, name} = fetch_field(changeset, field)
    {_, id} = fetch_field(changeset, :id)

    if Repo.exists?(company_name_by_user_query(name || "", id, user)) do
      add_error(changeset, field, gettext("has already been taken"))
    else
      changeset
    end
  end

  defp company_name_by_user_query(name, company_id, user) when is_nil(company_id) do
    from f in FullCircle.Sys.Company,
      join: fu in FullCircle.Sys.CompanyUser,
      on: f.id == fu.company_id,
      where: fu.user_id == ^user.id and f.name == ^name,
      select: f
  end

  defp company_name_by_user_query(name, company_id, user) do
    from f in FullCircle.Sys.Company,
      join: fu in FullCircle.Sys.CompanyUser,
      on: f.id == fu.company_id,
      where: fu.user_id == ^user.id and f.name == ^name and f.id != ^company_id,
      select: f
  end
end
