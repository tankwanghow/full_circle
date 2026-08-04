defmodule FullCircle.Repo.Migrations.TrimTradingLocationNames do
  use Ecto.Migration

  # Auto site names used String.slice(0, 20) without a post-trim, so some rows
  # stored trailing spaces (e.g. "Ngei Sing Farm Sdn. "). Typeahead re-resolve
  # trims the label and exact-matched, which cleared location_id on the trip form.
  def up do
    execute("""
    UPDATE trading_locations
    SET name = btrim(name)
    WHERE name IS DISTINCT FROM btrim(name)
    """)
  end

  def down do
    # irreversible data cleanup
  end
end
