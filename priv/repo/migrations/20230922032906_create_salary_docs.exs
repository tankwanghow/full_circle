defmodule FullCircle.Repo.Migrations.CreateSalaryDoc do
  use Ecto.Migration

  def change do
    create table(:pay_slips) do
      add :slip_no, :string
      add :slip_date, :date
      add :employee_id, references(:employees, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :funds_account_id, references(:accounts, on_delete: :restrict)
      add :pay_month, :integer
      add :pay_year, :integer

      timestamps(type: :timestamptz)
    end

    create table(:recurrings) do
      add :recur_no, :string
      add :recur_date, :date
      add :employee_id, references(:employees, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :salary_type_id, references(:salary_types, on_delete: :restrict)
      add :descriptions, :text
      add :start_date, :date
      add :amount, :decimal
      add :target_amount, :decimal
      add :status, :string

      timestamps(type: :timestamptz)
    end

    create table(:advances) do
      add :slip_no, :string
      add :slip_date, :date
      add :pay_slip_id, references(:pay_slips, on_delete: :restrict)
      add :employee_id, references(:employees, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :funds_account_id, references(:accounts, on_delete: :restrict)
      add :note, :text
      add :amount, :decimal

      timestamps(type: :timestamptz)
    end

    create table(:salary_notes) do
      add :note_no, :string
      add :note_date, :date
      add :pay_slip_id, references(:pay_slips, on_delete: :restrict)
      add :recurring_id, references(:recurrings, on_delete: :restrict)
      add :employee_id, references(:employees, on_delete: :restrict)
      add :salary_type_id, references(:salary_types, on_delete: :restrict)
      add :company_id, references(:companies, on_delete: :delete_all)
      add :descriptions, :text
      add :quantity, :decimal
      add :unit_price, :decimal

      timestamps(type: :timestamptz)
    end

    create unique_index(:pay_slips, [:company_id, :slip_no],
             name: :pay_slips_unique_slip_no_in_company
           )

    create unique_index(:pay_slips, [:company_id, :employee_id, :pay_month, :pay_year],
           name: :pay_slips_unique_employee_id_pay_month_pay_year_in_company
         )

    create unique_index(:advances, [:company_id, :slip_no],
             name: :advances_unique_slip_no_in_company
           )

    create unique_index(:recurrings, [:company_id, :recur_no],
             name: :recurrings_unique_recur_no_in_company
           )

    create unique_index(:salary_notes, [:company_id, :note_no],
             name: :salary_notes_unique_note_no_in_company
           )
  end
end
