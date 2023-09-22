defmodule FullCircle.HR.Employee do
  use FullCircle.Schema
  import Ecto.Changeset
  import FullCircleWeb.Gettext

  schema "employees" do
    field(:name, :string)
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
      :company_id
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
      :company_id
    ])
    |> unsafe_validate_unique([:name, :company_id], FullCircle.Repo,
      message: gettext("has already been taken")
    )
    |> unique_constraint(:name,
      name: :employees_unique_name_in_company,
      message: gettext("has already been taken")
    )
    |> cast_assoc(:employee_salary_types)
  end
end
