defmodule FullCircle.HR.Employee do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "employees" do
    field(:name, :string)
    field(:department, :string)
    field(:id_no, :string)
    field(:dob, :date)
    field(:gender, :string)
    field(:epf_no, :string)
    field(:socso_no, :string)
    field(:tax_no, :string)
    field(:marital_status, :string)
    field(:nationality, :string)
    field(:partner_working, :string)
    field(:children, :integer)
    field(:service_since, :date)
    field(:contract_expire_date, :date)
    field(:work_hours_per_day, :decimal, default: 7.5)
    field(:work_days_per_week, :decimal, default: 6)
    field(:work_days_per_month, :decimal, default: 26)
    field(:annual_leave, :integer, default: 8)
    field(:sick_leave, :integer, default: 14)
    field(:hospital_leave, :integer, default: 60)
    field(:maternity_leave, :integer, default: 98)
    field(:paternity_leave, :integer, default: 7)
    field(:status, :string)
    field(:note, :string)
    belongs_to(:company, FullCircle.Sys.Company)

    has_many(:employee_salary_types, FullCircle.HR.EmployeeSalaryType, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(emp, attrs) do
    emp
    |> cast(attrs, [
      :name,
      :id_no,
      :department,
      :dob,
      :gender,
      :epf_no,
      :socso_no,
      :tax_no,
      :marital_status,
      :nationality,
      :partner_working,
      :children,
      :service_since,
      :contract_expire_date,
      :status,
      :note,
      :company_id,
      :work_hours_per_day,
      :work_days_per_week,
      :work_days_per_month,
      :annual_leave,
      :sick_leave,
      :hospital_leave,
      :maternity_leave,
      :paternity_leave
    ])
    |> validate_required([
      :name,
      :id_no,
      :dob,
      :gender,
      :marital_status,
      :nationality,
      :partner_working,
      :children,
      :service_since,
      :status,
      :company_id,
      :work_hours_per_day,
      :work_days_per_week,
      :work_days_per_month,
      :annual_leave,
      :sick_leave,
      :hospital_leave,
      :maternity_leave,
      :paternity_leave
    ])
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :employees_unique_name_in_company,
      message: gettext("has already been taken")
    )
    |> validate_number(:work_hours_per_day, less_than_or_equal_to: 12)
    |> validate_number(:work_days_per_week, less_than_or_equal_to: 7)
    |> validate_number(:work_days_per_month, less_than_or_equal_to: 26)
    |> cast_assoc(:employee_salary_types)
  end
end
