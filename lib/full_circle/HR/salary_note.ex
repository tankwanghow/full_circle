defmodule FullCircle.HR.SalaryNote do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "salary_notes" do
    field(:note_no, :string)
    field(:note_date, :date)
    field(:quantity, :decimal, default: 1)
    field(:unit_price, :decimal, default: 0)
    field(:descriptions, :string)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:pay_slip, FullCircle.HR.PaySlip)
    belongs_to(:recurring, FullCircle.HR.Recurring)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:salary_type, FullCircle.HR.SalaryType)

    field(:employee_name, :string, virtual: true)
    field(:salary_type_name, :string, virtual: true)
    field(:salary_type_type, :string, virtual: true)
    field(:amount, :decimal, virtual: true, default: 0)
    field(:pay_slip_no, :string, virtual: true)
    field(:delete, :boolean, virtual: true, default: false)
    field(:cal_func, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  def changeset_on_payslip(sn, attrs) do
    sn
    |> cast(attrs, [
      :note_no,
      :note_date,
      :quantity,
      :unit_price,
      :employee_name,
      :employee_id,
      :pay_slip_id,
      :salary_type_id,
      :salary_type_type,
      :salary_type_name,
      :recurring_id,
      :descriptions,
      :company_id,
      :delete,
      :cal_func
    ])
    |> validate_required([
      :note_date,
      :quantity,
      :unit_price,
      :salary_type_name
    ])
    |> validate_id(:salary_type_name, :salary_type_id)
    |> validate_date(:note_date, days_before: 8)
    |> validate_date(:note_date, days_after: 14)
    |> compute_fields()
  end

  @doc false
  def changeset(recur, attrs) do
    recur
    |> cast(attrs, [
      :note_no,
      :note_date,
      :quantity,
      :unit_price,
      :employee_name,
      :employee_id,
      :pay_slip_id,
      :salary_type_id,
      :salary_type_name,
      :recurring_id,
      :descriptions,
      :company_id
    ])
    |> validate_required([
      :note_no,
      :note_date,
      :quantity,
      :unit_price,
      :employee_name,
      :salary_type_name,
      :company_id
    ])
    |> fill_today(:note_date)
    |> validate_id(:employee_name, :employee_id)
    |> validate_id(:salary_type_name, :salary_type_id)
    |> validate_date(:note_date, days_before: 8)
    |> validate_date(:note_date, days_after: 14)
    |> unsafe_validate_unique([:note_no, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:note_no,
      name: :salary_notes_unique_note_no_in_company,
      message: gettext("has already been taken")
    )
    |> compute_fields()
  end

  def compute_fields(cs) do
    amt =
      Decimal.mult(fetch_field!(cs, :quantity), fetch_field!(cs, :unit_price)) |> Decimal.round(2)

    cs = put_change(cs, :amount, amt)

    if Decimal.eq?(amt, 0) do
      add_unique_error(cs, :amount, gettext("cannot be zero"))
    else
      cs
    end
  end
end
