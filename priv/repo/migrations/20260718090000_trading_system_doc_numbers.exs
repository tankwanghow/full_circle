defmodule FullCircle.Repo.Migrations.TradingSystemDocNumbers do
  use Ecto.Migration

  @doc """
  Gapless system numbers for trading supply / sales / trips (SUP / SAL / TRP).
  Seeds counters for existing companies, renumbers existing rows, unique per company.
  """
  def up do
    seed_gapless("TradingSupply")
    seed_gapless("TradingSales")
    seed_gapless("TradingTrip")

    # Assign sequential system numbers to existing rows (trading not production yet)
    execute("""
    WITH ranked AS (
      SELECT id, company_id,
             ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY inserted_at, id) AS rn
      FROM trading_supply_positions
    )
    UPDATE trading_supply_positions t
    SET title = 'SUP-' || LPAD(ranked.rn::text, 6, '0')
    FROM ranked
    WHERE t.id = ranked.id
    """)

    execute("""
    WITH ranked AS (
      SELECT id, company_id,
             ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY inserted_at, id) AS rn
      FROM trading_sales_positions
    )
    UPDATE trading_sales_positions t
    SET title = 'SAL-' || LPAD(ranked.rn::text, 6, '0')
    FROM ranked
    WHERE t.id = ranked.id
    """)

    execute("""
    WITH ranked AS (
      SELECT id, company_id,
             ROW_NUMBER() OVER (PARTITION BY company_id ORDER BY inserted_at, id) AS rn
      FROM trading_trips
    )
    UPDATE trading_trips t
    SET reference_no = 'TRP-' || LPAD(ranked.rn::text, 6, '0')
    FROM ranked
    WHERE t.id = ranked.id
    """)

    execute("""
    UPDATE gapless_doc_ids g
    SET current = COALESCE((
      SELECT COUNT(*) FROM trading_supply_positions s WHERE s.company_id = g.company_id
    ), 0)
    WHERE g.doc_type = 'TradingSupply'
    """)

    execute("""
    UPDATE gapless_doc_ids g
    SET current = COALESCE((
      SELECT COUNT(*) FROM trading_sales_positions s WHERE s.company_id = g.company_id
    ), 0)
    WHERE g.doc_type = 'TradingSales'
    """)

    execute("""
    UPDATE gapless_doc_ids g
    SET current = COALESCE((
      SELECT COUNT(*) FROM trading_trips t WHERE t.company_id = g.company_id
    ), 0)
    WHERE g.doc_type = 'TradingTrip'
    """)

    create unique_index(:trading_supply_positions, [:company_id, :title],
      name: :trading_supply_positions_unique_title_per_company
    )

    create unique_index(:trading_sales_positions, [:company_id, :title],
      name: :trading_sales_positions_unique_title_per_company
    )

    create unique_index(:trading_trips, [:company_id, :reference_no],
      name: :trading_trips_unique_reference_no_per_company
    )
  end

  def down do
    drop_if_exists index(:trading_trips, [:company_id, :reference_no],
      name: :trading_trips_unique_reference_no_per_company
    )

    drop_if_exists index(:trading_sales_positions, [:company_id, :title],
      name: :trading_sales_positions_unique_title_per_company
    )

    drop_if_exists index(:trading_supply_positions, [:company_id, :title],
      name: :trading_supply_positions_unique_title_per_company
    )

    execute("""
    DELETE FROM gapless_doc_ids
    WHERE doc_type IN ('TradingSupply', 'TradingSales', 'TradingTrip')
    """)
  end

  defp seed_gapless(doc_type) do
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
