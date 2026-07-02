defmodule FullCircle.HR.SalaryType do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircle.Helpers

  @statutory_codes ~w(epf_employer epf_employee socso_employer socso_employee
                      socso_employer_only socso_24hour eis_employer eis_employee
                      eis_employer_only pcb_employee)

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
    |> update_change(:cal_func, fn v -> if v in ["", nil], do: nil, else: v end)
    |> validate_statutory_code()
    |> validate_cal_func()
    |> validate_ac_names()
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :salary_types_unique_name_in_company,
      message: gettext("has already been taken")
    )
  end

  defp validate_statutory_code(cs) do
    code = fetch_field!(cs, :statutory_code)
    com_id = fetch_field!(cs, :company_id)

    cond do
      is_nil(code) ->
        cs

      code in @statutory_codes ->
        cs

      not is_nil(com_id) and code in FullCircle.StatutoryConfig.calc_codes(com_id) ->
        cs

      true ->
        add_error(cs, :statutory_code, gettext("is not a valid statutory code"))
    end
  end

  # cal_func picks the statutory_calcs script (or the legacy function) that
  # computes the note amount at pay time; an unknown code would only surface
  # as a crash when running pay, so reject it here.
  defp validate_cal_func(cs) do
    func = fetch_field!(cs, :cal_func)
    com_id = fetch_field!(cs, :company_id)

    cond do
      is_nil(func) ->
        cs

      func in FullCircle.PaySlipOp.legacy_cal_funcs() ->
        cs

      not is_nil(com_id) and func in FullCircle.StatutoryConfig.calc_codes(com_id) ->
        cs

      true ->
        add_error(cs, :cal_func, gettext("is not a valid calculation function"))
    end
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
