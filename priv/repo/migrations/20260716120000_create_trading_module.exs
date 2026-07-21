defmodule FullCircle.Repo.Migrations.CreateTradingModule do
  @moduledoc """
  Grain trading module (locations, supply/sales positions, multi-good trips).

  Compacted from incremental trading migrations before first production deploy.
  """
  use Ecto.Migration

  def up do
    create_locations()
    create_supply_positions()
    create_sales_positions()
    create_trips()
    seed_gapless_doc_types()
  end

  def down do
    execute("""
    DELETE FROM gapless_doc_ids
    WHERE doc_type IN ('TradingSupply', 'TradingSales', 'TradingTrip')
    """)

    drop_if_exists table(:trading_trip_drop_employees)
    drop_if_exists table(:trading_trip_load_employees)
    drop_if_exists table(:trading_trip_drops)
    drop_if_exists table(:trading_trip_loads)
    drop_if_exists table(:trading_trips)
    drop_if_exists table(:trading_sales_positions)
    drop_if_exists table(:trading_supply_positions)
    drop_if_exists table(:trading_locations)
  end

  defp create_locations do
    create table(:trading_locations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false
      add :address_note, :text
      # Optional GPS (WGS84); maps link is derived, not stored
      add :latitude, :decimal
      add :longitude, :decimal
      add :active, :boolean, null: false, default: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :contact_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_locations, [:company_id])
    create index(:trading_locations, [:company_id, :kind])
    create index(:trading_locations, [:company_id, :active])
    create index(:trading_locations, [:contact_id])
  end

  defp create_supply_positions do
    create table(:trading_supply_positions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # System no SUP-###### (gapless TradingSupply)
      add :title, :string, null: false
      add :available_from, :date
      add :quantity, :decimal, null: false
      add :unit_price, :decimal
      # open | hold | collect | closed
      add :status, :string, null: false, default: "open"
      add :notes, :text

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :supplier_id, references(:contacts, type: :binary_id, on_delete: :restrict), null: false
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:trading_supply_positions, [:company_id])
    create index(:trading_supply_positions, [:company_id, :status])
    create index(:trading_supply_positions, [:company_id, :available_from])
    create index(:trading_supply_positions, [:supplier_id])
    create index(:trading_supply_positions, [:good_id])

    create unique_index(:trading_supply_positions, [:company_id, :title],
      name: :trading_supply_positions_unique_title_per_company
    )
  end

  defp create_sales_positions do
    create table(:trading_sales_positions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # System no SAL-###### (gapless TradingSales)
      add :title, :string, null: false
      add :available_from, :date
      add :quantity, :decimal, null: false
      add :unit_price, :decimal
      # draft | open | hold | fulfilled | cancelled
      add :status, :string, null: false, default: "draft"
      add :notes, :text
      add :fulfilled_note, :text

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :customer_id, references(:contacts, type: :binary_id, on_delete: :restrict), null: false
      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

      add :preferred_supply_id,
          references(:trading_supply_positions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_sales_positions, [:company_id])
    create index(:trading_sales_positions, [:company_id, :status])
    create index(:trading_sales_positions, [:company_id, :available_from])
    create index(:trading_sales_positions, [:customer_id])
    create index(:trading_sales_positions, [:good_id])
    create index(:trading_sales_positions, [:preferred_supply_id])

    create unique_index(:trading_sales_positions, [:company_id, :title],
      name: :trading_sales_positions_unique_title_per_company
    )
  end

  defp create_trips do
    create table(:trading_trips, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :date, :date, null: false
      add :transport_mode, :string, null: false
      # draft | planned | completed | cancelled
      add :status, :string, null: false, default: "draft"
      add :notes, :text
      # System no TRP-###### (gapless TradingTrip)
      add :reference_no, :string, null: false
      add :vehicle_number, :string

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      # Transport agents are contacts (haulage)
      add :transport_agent_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_trips, [:company_id])
    create index(:trading_trips, [:company_id, :status])
    create index(:trading_trips, [:company_id, :date])
    create index(:trading_trips, [:transport_agent_id])

    create unique_index(:trading_trips, [:company_id, :reference_no],
      name: :trading_trips_unique_reference_no_per_company
    )

    create table(:trading_trip_loads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :planned_mt, :decimal
      add :actual_mt, :decimal
      add :location_note, :string
      # FILO order on the truck (1 = first on)
      add :seq, :integer, null: false, default: 0

      add :trip_id, references(:trading_trips, type: :binary_id, on_delete: :delete_all),
        null: false

      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

      add :supply_position_id,
          references(:trading_supply_positions, type: :binary_id, on_delete: :restrict)

      add :location_id, references(:trading_locations, type: :binary_id, on_delete: :restrict),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:trading_trip_loads, [:trip_id])
    create index(:trading_trip_loads, [:trip_id, :seq])
    create index(:trading_trip_loads, [:good_id])
    create index(:trading_trip_loads, [:supply_position_id])
    create index(:trading_trip_loads, [:location_id])

    create table(:trading_trip_drops, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :planned_mt, :decimal
      add :actual_mt, :decimal
      add :location_note, :string
      add :variance_note, :string
      # Unload order (1 = first off)
      add :seq, :integer, null: false, default: 0

      add :trip_id, references(:trading_trips, type: :binary_id, on_delete: :delete_all),
        null: false

      add :good_id, references(:goods, type: :binary_id, on_delete: :restrict), null: false

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
    create index(:trading_trip_drops, [:trip_id, :seq])
    create index(:trading_trip_drops, [:good_id])
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

  defp seed_gapless_doc_types do
    for doc_type <- ~w(TradingSupply TradingSales TradingTrip) do
      execute("""
      INSERT INTO gapless_doc_ids (id, doc_type, current, company_id)
      SELECT gen_random_uuid(), '#{doc_type}', 0, c.id
      FROM companies c
      WHERE NOT EXISTS (
        SELECT 1 FROM gapless_doc_ids g
        WHERE g.company_id = c.id AND g.doc_type = '#{doc_type}'
      )
      """)
    end
  end
end
