defmodule FullCircle.Repo.Migrations.CreateTransactionTrigger do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_closed_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        RAISE EXCEPTION 'Cannot update or delete a CLOSED transaction!'
          USING ERRCODE = 'integrity_constraint_violation';
        RETURN OLD;
      END;
      $trigger$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER delete_closed_transaction_trigger
      BEFORE DELETE ON transactions FOR EACH ROW
      WHEN (OLD.closed = true)
      EXECUTE PROCEDURE cannot_update_or_delete_closed_transaction();
    """
  end

  def down do
    execute "DROP TRIGGER delete_closed_transaction_trigger ON transactions;"
    execute "DROP FUNCTION cannot_update_or_delete_closed_transaction();"
  end
end
