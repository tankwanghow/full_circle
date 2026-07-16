defmodule FullCircle.Repo.Migrations.CreateTradingTrips do
  use Ecto.Migration

  def change do
    create table(:trading_trips, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date, null: false
      add :transport_mode, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :notes, :text
      add :reference_no, :string

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

      # Transport agents are contacts (haulage companies)
      add :transport_agent_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_trips, [:company_id])
    create index(:trading_trips, [:company_id, :status])
    create index(:trading_trips, [:company_id, :date])
    create index(:trading_trips, [:good_id])
    create index(:trading_trips, [:transport_agent_id])

    create table(:trading_trip_loads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :planned_mt, :decimal
      add :actual_mt, :decimal
      add :location_note, :string

      add :trip_id, references(:trading_trips, type: :binary_id, on_delete: :delete_all),
        null: false

      add :supply_position_id,
          references(:trading_supply_positions, type: :binary_id, on_delete: :restrict)

      add :location_id, references(:trading_locations, type: :binary_id, on_delete: :restrict),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:trading_trip_loads, [:trip_id])
    create index(:trading_trip_loads, [:supply_position_id])
    create index(:trading_trip_loads, [:location_id])

    create table(:trading_trip_drops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :planned_mt, :decimal
      add :actual_mt, :decimal
      add :location_note, :string
      add :variance_note, :string

      add :trip_id, references(:trading_trips, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sales_position_id,
          references(:trading_sales_positions, type: :binary_id, on_delete: :restrict)

      add :supply_position_id,
          references(:trading_supply_positions, type: :binary_id, on_delete: :restrict)

      add :location_id, references(:trading_locations, type: :binary_id, on_delete: :restrict),
        null: false

      add :invoice_id, references(:invoices, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_trip_drops, [:trip_id])
    create index(:trading_trip_drops, [:sales_position_id])
    create index(:trading_trip_drops, [:supply_position_id])
    create index(:trading_trip_drops, [:location_id])
    create index(:trading_trip_drops, [:invoice_id])

    create table(:trading_trip_load_employees, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trip_load_id, references(:trading_trip_loads, type: :binary_id, on_delete: :delete_all),
        null: false

      add :employee_id, references(:employees, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:trading_trip_load_employees, [:trip_load_id, :employee_id])
    create index(:trading_trip_load_employees, [:employee_id])

    create table(:trading_trip_drop_employees, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :trip_drop_id, references(:trading_trip_drops, type: :binary_id, on_delete: :delete_all),
        null: false

      add :employee_id, references(:employees, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:trading_trip_drop_employees, [:trip_drop_id, :employee_id])
    create index(:trading_trip_drop_employees, [:employee_id])
  end
end
