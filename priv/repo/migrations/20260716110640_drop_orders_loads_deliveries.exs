defmodule FullCircle.Repo.Migrations.DropOrdersLoadsDeliveries do
  use Ecto.Migration

  def up do
    # Query helper functions from create_queries migration depend on these tables
    execute("DROP FUNCTION IF EXISTS fct_delivery_details(uuid)")
    execute("DROP FUNCTION IF EXISTS fct_deliveries(uuid)")
    execute("DROP FUNCTION IF EXISTS fct_load_details(uuid)")
    execute("DROP FUNCTION IF EXISTS fct_loads(uuid)")
    execute("DROP FUNCTION IF EXISTS fct_order_details(uuid)")
    execute("DROP FUNCTION IF EXISTS fct_orders(uuid)")

    # invoice_details.delivery_detail_id was added in create_deliveries migration
    execute("""
    ALTER TABLE invoice_details
    DROP COLUMN IF EXISTS delivery_detail_id
    """)

    drop_if_exists table(:delivery_details)
    drop_if_exists table(:deliveries)
    drop_if_exists table(:load_details)
    drop_if_exists table(:loads)
    drop_if_exists table(:order_details)
    drop_if_exists table(:orders)

    execute("""
    DELETE FROM gapless_doc_ids
    WHERE doc_type IN ('Order', 'Load', 'Delivery')
    """)
  end

  def down do
    raise "irreversible: Order/Load/Delivery tables were removed as unused"
  end
end
