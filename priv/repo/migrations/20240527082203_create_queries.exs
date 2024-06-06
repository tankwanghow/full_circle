defmodule FullCircle.Repo.Migrations.CreateQueries do
  use Ecto.Migration

  defp table_names_with_company_id do
    ~w(advances employees accounts credit_notes debit_notes deposits company_user
       contacts deliveries gapless_doc_ids fixed_assets goods flocks harvests
       holidays invoices journals houses movements op_codes operations logs
       loads orders pay_slips pur_invoices receipts payments recurrings
       return_cheques time_attendences salary_types tax_codes weighings
       salary_notes transactions)
  end

  defp table_names_without_company_id do
    ~w(credit_note_details debit_note_details delivery_details employee_salary_types
       fixed_asset_depreciations fixed_asset_disposals harvest_details house_harvest_wages
       invoice_details load_details order_details packagings payment_details pur_invoice_details
       receipt_details received_cheques transaction_matchers users)
  end

  def up do
    create table(:queries) do
      add :qry_name, :string
      add :company_id, references(:companies, on_delete: :delete_all)
      add :sql_string, :text

      timestamps()
    end

    create unique_index(:queries, [:company_id, :qry_name],
             name: :queries_unique_qry_name_in_company
           )

    # execute "CREATE ROLE full_circle_query NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT LOGIN NOREPLICATION NOBYPASSRLS PASSWORD 'nyhlisted';"

    # execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO full_circle_query;"

    create_function_tables()
  end

  def down do
    drop unique_index(:queries, [:company_id, :qry_name],
           name: :queries_unique_qry_name_in_company
         )

    drop table(:queries)

    drop_function_tables()

    # execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM full_circle_query;"

    # execute "DROP ROLE full_circle_query;"
  end

  defp create_function_tables() do
    table_names_with_company_id()
    |> Enum.each(fn x ->
      execute """
      CREATE OR REPLACE FUNCTION fct_#{x}(com_id uuid) RETURNS SETOF #{x} as $$
        SELECT t.* FROM #{x} t where t.company_id = com_id;
      $$ LANGUAGE SQL SECURITY DEFINER;
      """
    end)

    table_names_without_company_id()
    |> Enum.each(fn x ->
      execute """
      CREATE OR REPLACE FUNCTION fct_#{x}(com_id uuid) RETURNS SETOF #{x} as $$
        SELECT t.* FROM #{x} t;
      $$ LANGUAGE SQL SECURITY DEFINER;
      """
    end)
  end

  defp drop_function_tables() do
    [table_names_with_company_id() | table_names_without_company_id()]
    |> List.flatten()
    |> Enum.each(fn x ->
      execute "DROP FUNCTION IF EXISTS fct_#{x};"
    end)
  end
end
