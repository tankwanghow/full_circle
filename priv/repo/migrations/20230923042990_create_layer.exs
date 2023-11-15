defmodule FullCircle.Repo.Migrations.CreateLayer do
  use Ecto.Migration

  def change do
    create table(:houses) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :house_no, :string
      add :capacity, :integer

      timestamps(type: :timestamptz)
    end

    create unique_index(:houses, [:company_id, :house_no],
             name: :houses_unique_house_no_in_company
           )

    create table(:flocks) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :contact_id, references(:contacts, on_delete: :restrict)
      add :flock_code, :string
      add :dob, :date
      add :quantity, :integer
      add :breed, :string
      add :note, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:flocks, [:company_id, :flock_code],
             name: :flocks_unique_flock_code_in_company
           )

    create table(:op_codes) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :name, :string
      add :wages, :decimal
      add :note, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:op_codes, [:company_id, :name], name: :op_codes_unique_name_in_company)

    create table(:operations) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :house_id, references(:houses, on_delete: :restrict)
      add :flock_id, references(:flocks, on_delete: :restrict)
      add :op_date, :date
      add :op_code_id, references(:op_codes, on_delete: :restrict)
      add :employee_id, references(:employees, on_delete: :restrict)
      add :quantity, :integer
      add :note, :string

      timestamps(type: :timestamptz)
    end

    create index(:operations, [
             :company_id,
             :house_id,
             :flock_id,
             :op_date,
             :op_code_id,
             :employee_id
           ])

    create index(:operations, [:company_id, :house_id, :flock_id, :op_date, :op_code_id])

    create table(:harvests) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :house_id, references(:houses, on_delete: :restrict)
      add :flock_id, references(:flocks, on_delete: :restrict)
      add :har_date, :date
      add :employee_id, references(:employees, on_delete: :restrict)
      add :har_qty_1, :integer
      add :har_qty_2, :integer
      add :har_qty_3, :integer
      add :dea_qty_1, :integer
      add :dea_qty_2, :integer

      timestamps(type: :timestamptz)
    end

    create index(:harvests, [:company_id, :har_date, :house_id, :flock_id, :employee_id])
    create index(:harvests, [:company_id, :har_date, :house_id, :flock_id])
  end
end
