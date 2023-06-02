defmodule FullCircle.Repo.Migrations.CreateTransactionTrigger do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_closed_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        RAISE EXCEPTION integrity_constraint_violation
          USING MESSAGE = 'Cannot update or delete a CLOSED transaction!';
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

    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_fixed_asset_associated_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        RAISE EXCEPTION integrity_constraint_violation
          USING MESSAGE = 'Cannot delete or update a fixed asset associated transaction!';
        RETURN OLD;
      END;
      $trigger$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER delete_fa_assoc_transaction_trigger
      BEFORE DELETE ON transactions FOR EACH ROW
      WHEN (OLD.fixed_asset_id IS NOT NULL)
      EXECUTE PROCEDURE cannot_update_or_delete_fixed_asset_associated_transaction();
    """
  end

  def down do
    execute "DROP TRIGGER delete_closed_transaction_trigger ON transactions;"
    execute "DROP FUNCTION cannot_update_or_delete_closed_transaction();"
    execute "DROP TRIGGER delete_fa_assoc_transaction_trigger ON transactions;"
    execute "DROP FUNCTION cannot_update_or_delete_fixed_asset_associated_transaction();"
  end
end
