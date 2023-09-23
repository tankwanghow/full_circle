defmodule FullCircle.HR.PaySlip do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "pay_slips" do
    field(:slip_no, :string)
    field(:slip_date, :date)
    field(:pay_month, :integer)
    field(:pay_year, :integer)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:funds_account, FullCircle.Accounting.Account)

    has_many(:salary_notes, FullCircle.HR.SalaryNote, on_delete: :delete_all)

    field(:employee_name, :string, virtual: true)
    field(:funds_account_name, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(slip, attrs) do
    slip
    |> cast(attrs, [
      :slip_no,
      :slip_date,
      :pay_month,
      :pay_year,
      :employee_name,
      :employee_id,
      :funds_account_name,
      :funds_account_id,
      :company_id
    ])
    |> validate_required([
      :slip_no,
      :slip_date,
      :pay_month,
      :pay_year,
      :employee_name,
      :funds_account_name,
      :company_id
    ])
    |> validate_id(:employee_name, :employee_id)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> validate_date(:slip_date, days_before: 5)
    |> validate_date(:slip_date, days_after: 5)
    |> validate_pay_month_year()
    |> unsafe_validate_unique([:slip_no, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:slip_no,
      name: :pay_slips_unique_slip_no_in_company,
      message: gettext("has already been taken")
    )
    |> cast_assoc(:salary_notes)
  end

  defp validate_pay_month_year(cs) do
    slip_date = fetch_field!(cs, :slip_date)

    if !is_nil(slip_date) do
      mth = fetch_field!(cs, :pay_month) || Timex.today().year
      yr = fetch_field!(cs, :pay_year) || Timex.today().month
      day = Timex.days_in_month(yr, mth)

      if abs(Timex.diff(Date.new!(yr, mth, day), slip_date, :days)) > 31 do
        cs
        |> add_unique_error(:pay_month, gettext("invalid"))
        |> add_unique_error(:pay_year, gettext("invalid"))
      else
        cs
      end
    else
      cs
    end
  end
end
