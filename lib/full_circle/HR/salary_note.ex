defmodule FullCircle.HR.SalaryNote do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext
  import FullCircle.Helpers
  # import Ecto.Query, warn: false

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
    field(:pay_slip_date, :date, virtual: true)
    field(:delete, :boolean, virtual: true, default: false)
    field(:cal_func, :string, virtual: true)
    field(:_id, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  def changeset_on_payslip(sn, attrs) do
    sn
    |> cast(attrs, [
      :_id,
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
      :cal_func,
      :delete
    ])
    |> validate_required([
      :note_date,
      :quantity,
      :unit_price,
      :salary_type_name
    ])
    |> compute_fields()
  end

  @doc false
  def changeset(sn, attrs) do
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
    |> validate_has_pay_slip_no_cannot_change_after_days(7)
    |> validate_id(:employee_name, :employee_id)
    |> validate_id(:salary_type_name, :salary_type_id)
    |> validate_date_by_type()
    |> validate_number(:unit_price, greater_than_or_equal_to: 0)
    |> validate_number(:quantity, greater_than: 0)
    |> unsafe_validate_unique([:note_no, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:note_no,
      name: :salary_notes_unique_note_no_in_company,
      message: gettext("has already been taken")
    )
    |> compute_fields()
  end

  defp validate_date_by_type(cs) do
    stid = fetch_field!(cs, :salary_type_id)
    com_id = fetch_field!(cs, :company_id)
    salary_type = if(stid, do: FullCircle.HR.get_salary_type!(stid, com_id), else: nil)

    if salary_type do
      if salary_type.type != "Recording" and salary_type.type != "LeaveTaken" do
        cs
        |> validate_date(:note_date, days_before: 31)
        |> validate_date(:note_date, days_after: 14)
      else
        cs
      end
    else
      cs
    end
  end

  defp validate_has_pay_slip_no_cannot_change_after_days(cs, days) do
    psid = fetch_field!(cs, :pay_slip_id)
    com_id = fetch_field!(cs, :company_id)

    if !is_nil(psid) do
      ps = FullCircle.PaySlipOp.get_pay_slip!(psid, %{id: com_id})

      if Timex.diff(Timex.today(), ps.slip_date, :days) <= days do
        cs
      else
        add_unique_error(
          cs,
          :note_date,
          "update period over. #{days} days"
        )
      end
    else
      cs
    end
  end

  def compute_fields(cs) do
    amt =
      Decimal.mult(fetch_field!(cs, :quantity), fetch_field!(cs, :unit_price)) |> Decimal.round(2)

    put_change(cs, :amount, amt)
  end
end
