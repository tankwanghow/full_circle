defmodule FullCircle.Repo.Migrations.AddMissingFctQueryFunctions do
  use Ecto.Migration

  defp with_company_id do
    ~w(
      bank_statement_balances bank_statement_lines
      e_inv_metas e_invoices
      egg_grades egg_stock_days egg_stock_dow_template_lines
      employee_photos good_price_histories pay_preps
      statutory_calcs statutory_file_formats statutory_rate_tables
      tax_instalment_plans
      trading_locations trading_sales_positions trading_supply_positions trading_trips
    )
  end

  defp without_company_id do
    ~w(
      egg_stock_day_details seed_transaction_matchers
      trading_trip_drop_employees trading_trip_drops
      trading_trip_load_employees trading_trip_loads
    )
  end

  def up do
    Enum.each(with_company_id(), fn table ->
      execute("""
      CREATE OR REPLACE FUNCTION fct_#{table}(com_id uuid) RETURNS SETOF #{table} AS $$
        SELECT t.* FROM #{table} t WHERE t.company_id = com_id;
      $$ LANGUAGE SQL SECURITY DEFINER;
      """)
    end)

    Enum.each(without_company_id(), fn table ->
      execute("""
      CREATE OR REPLACE FUNCTION fct_#{table}(com_id uuid) RETURNS SETOF #{table} AS $$
        SELECT t.* FROM #{table} t;
      $$ LANGUAGE SQL SECURITY DEFINER;
      """)
    end)
  end

  def down do
    (with_company_id() ++ without_company_id())
    |> Enum.each(fn table ->
      execute("DROP FUNCTION IF EXISTS fct_#{table}(uuid)")
    end)
  end
end
