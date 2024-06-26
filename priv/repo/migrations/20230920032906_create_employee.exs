defmodule FullCircle.Repo.Migrations.CreateEmployees do
  use Ecto.Migration

  def change do
    create table(:salary_types) do
      add :name, :string
      add :type, :string
      add :cal_func, :string
      add :db_ac_id, references(:accounts, on_delete: :restrict)
      add :cr_ac_id, references(:accounts, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:salary_types, [:company_id, :name],
             name: :salary_types_unique_name_in_company
           )

    create table(:employees) do
      add :name, :string
      add :id_no, :string
      add :dob, :date
      add :gender, :string
      add :epf_no, :string
      add :socso_no, :string
      add :tax_no, :string
      add :marital_status, :string
      add :nationality, :string
      add :partner_working, :string
      add :children, :integer
      add :service_since, :date
      add :contract_expire_date, :date
      add :status, :string
      add :note, :text
      add :work_hours_per_day, :decimal, default: 7.5
      add :work_days_per_week, :decimal, default: 6
      add :work_days_per_month, :decimal, default: 26
      add :annual_leave, :integer, default: 8
      add :sick_leave, :integer, default: 14
      add :hospital_leave, :integer, default: 60
      add :maternity_leave, :integer, default: 98
      add :paternity_leave, :integer, default: 7
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:employees, [:company_id, :name], name: :employees_unique_name_in_company)
    create index(:employees, [:company_id])
    create index(:employees, [:company_id, :id_no])

    create table(:employee_salary_types) do
      add :_persistent_id, :integer
      add :salary_type_id, references(:salary_types, on_delete: :restrict)
      add :employee_id, references(:employees, on_delete: :restrict)
      add :amount, :decimal
    end

    create unique_index(:employee_salary_types, [:employee_id, :salary_type_id],
             name: :employee_salary_types_unique_name_in_employee
           )
  end
end
