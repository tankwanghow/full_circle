defmodule FullCircle.HR.Advance do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext
  import FullCircle.Helpers

  schema "advances" do
    field(:slip_no, :string)
    field(:slip_date, :date)

    belongs_to(:pay_slip, FullCircle.HR.PaySlip)
    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:funds_account, FullCircle.Accounting.Account)

    field(:amount, :decimal)
    field(:note, :string)

    field(:employee_name, :string, virtual: true)
    field(:funds_account_name, :string, virtual: true)
    field(:pay_slip_no, :string, virtual: true)
    field(:delete, :boolean, virtual: true, default: false)

    timestamps(type: :utc_datetime)
  end

  def changeset_on_payslip(slip, attrs) do
    slip
    |> cast(attrs, [
      :slip_no,
      :slip_date,
      :employee_name,
      :employee_id,
      :funds_account_name,
      :funds_account_id,
      :company_id,
      :note,
      :amount,
      :pay_slip_id,
      :delete
    ])
    |> validate_required([
      :slip_no,
      :slip_date,
      :employee_name,
      :funds_account_name,
      :company_id,
      :amount
    ])
    |> validate_number(:amount, greater_than: 0)
  end

  @doc false
  def changeset(slip, attrs) do
    slip
    |> cast(attrs, [
      :slip_no,
      :slip_date,
      :employee_name,
      :employee_id,
      :funds_account_name,
      :funds_account_id,
      :company_id,
      :note,
      :amount,
      :pay_slip_id
    ])
    |> validate_required([
      :slip_no,
      :slip_date,
      :employee_name,
      :funds_account_name,
      :company_id,
      :amount
    ])
    |> fill_today(:slip_date)
    |> validate_id(:employee_name, :employee_id)
    |> validate_id(:funds_account_name, :funds_account_id)
    |> validate_date(:slip_date, days_before: 2)
    |> validate_date(:slip_date, days_after: 2)
    |> validate_number(:amount, greater_than: 0)
    |> unsafe_validate_unique([:slip_no, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:slip_no,
      name: :advances_unique_slip_no_in_company,
      message: gettext("has already been taken")
    )
  end
end
