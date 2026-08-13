defmodule FullCircle.Repo.Migrations.AddUpdateClosedTransactionTrigger do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_closed_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        IF (OLD.closed = true) AND EXISTS(SELECT 1 FROM companies WHERE id=OLD.company_id) THEN
          RAISE EXCEPTION 'Cannot update or delete a CLOSED transaction!'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          RETURN NEW;
        ELSE
          RETURN OLD;
        END IF;
      END;
      $trigger$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER update_closed_transaction_trigger
      BEFORE UPDATE ON transactions FOR EACH ROW
      EXECUTE PROCEDURE cannot_update_or_delete_closed_transaction();
    """
  end

  def down do
    execute "DROP TRIGGER update_closed_transaction_trigger ON transactions;"

    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_closed_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        IF (OLD.closed = true) AND EXISTS(SELECT 1 FROM companies WHERE id=OLD.company_id) THEN
          RAISE EXCEPTION 'Cannot update or delete a CLOSED transaction!'
            USING ERRCODE = 'integrity_constraint_violation';
        ELSE
          RETURN OLD;
        END IF;
      END;
      $trigger$ LANGUAGE plpgsql;
    """
  end
end
