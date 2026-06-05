defmodule FullCircle.HR.SalaryType do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircle.Helpers

  @statutory_codes ~w(epf_employer epf_employee socso_employer socso_employee
                      socso_employer_only eis_employer eis_employee eis_employer_only
                      pcb_employee)

  def statutory_codes, do: @statutory_codes

  schema "salary_types" do
    field(:name, :string)
    field(:type, :string)
    field(:cal_func, :string)
    field(:statutory_code, :string)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:db_ac, FullCircle.Accounting.Account)
    belongs_to(:cr_ac, FullCircle.Accounting.Account)

    field(:db_ac_name, :string, virtual: true)
    field(:cr_ac_name, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(st, attrs) do
    st
    |> cast(attrs, [
      :name,
      :type,
      :cal_func,
      :statutory_code,
      :company_id,
      :db_ac_name,
      :cr_ac_name,
      :db_ac_id,
      :cr_ac_id
    ])
    |> validate_required([
      :name,
      :type,
      :company_id
    ])
    |> update_change(:statutory_code, fn v -> if v in ["", nil], do: nil, else: v end)
    |> validate_inclusion(:statutory_code, @statutory_codes,
      message: gettext("is not a valid statutory code")
    )
    |> validate_ac_names()
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :salary_types_unique_name_in_company,
      message: gettext("has already been taken")
    )
  end

  defp validate_ac_names(cs) do
    if fetch_field!(cs, :type) != "Recording" and fetch_field!(cs, :type) != "LeaveTaken" do
      cs
      |> validate_required([
        :db_ac_name,
        :cr_ac_name
      ])
      |> validate_id(:db_ac_name, :db_ac_id)
      |> validate_id(:cr_ac_name, :cr_ac_id)
    else
      cs
    end
  end
end
