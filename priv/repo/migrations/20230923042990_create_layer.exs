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
      add :flock_no, :string
      add :dob, :date
      add :quantity, :integer
      add :breed, :string
      add :note, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:flocks, [:company_id, :flock_no],
             name: :flocks_unique_flock_no_in_company
           )

    create table(:movements) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :flock_id, references(:flocks, on_delete: :restrict)
      add :house_id, references(:houses, on_delete: :restrict)
      add :move_date, :date
      add :quantity, :integer
      add :note, :string

      timestamps(type: :timestamptz)
    end

    create index(:movements, [:company_id, :move_date, :flock_id, :house_id])

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
      add :harvest_no, :string
      add :har_date, :date
      add :employee_id, references(:employees, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:harvests, [:company_id, :harvest_no],
             name: :harvests_unique_harvest_no_in_company
           )

    create index(:harvests, [:company_id, :har_date, :employee_id])

    create table(:harvest_details) do
      add :harvest_id, references(:harvests, on_delete: :delete_all)
      add :house_id, references(:houses, on_delete: :restrict)
      add :flock_id, references(:flocks, on_delete: :restrict)
      add :har_qty_1, :integer, default: 0
      add :har_qty_2, :integer, default: 0
      add :har_qty_3, :integer, default: 0
      add :dea_qty_1, :integer, default: 0
      add :dea_qty_2, :integer, default: 0

      timestamps(type: :timestamptz)
    end

    create index(:harvest_details, [:harvest_id, :house_id, :flock_id])
    create index(:harvest_details, [:house_id, :flock_id])
  end
end
