defmodule FullCircle.Repo.Migrations.DeleteMatchersOnCompanyDelete do
  use Ecto.Migration

  # transaction_matchers / seed_transaction_matchers reference transactions
  # with ON DELETE RESTRICT (a business protection), which blocks the
  # companies -> transactions cascade. Pre-delete them in the existing
  # BEFORE DELETE trigger, same as invoice_details / pur_invoice_details.
  def up do
    execute """
    CREATE OR REPLACE FUNCTION delete_non_cascadeable_records()
      RETURNS trigger AS $trigger$
      BEGIN
        DELETE FROM transaction_matchers
         USING (SELECT tm.id as tm_id FROM transactions txn INNER JOIN transaction_matchers tm
                    ON txn.id = tm.transaction_id
                WHERE txn.company_id = OLD.id) dtm
         WHERE transaction_matchers.id = dtm.tm_id;

        DELETE FROM seed_transaction_matchers
         USING (SELECT tm.id as tm_id FROM transactions txn INNER JOIN seed_transaction_matchers tm
                    ON txn.id = tm.transaction_id
                WHERE txn.company_id = OLD.id) dtm
         WHERE seed_transaction_matchers.id = dtm.tm_id;

        DELETE FROM invoice_details
         USING (SELECT invd.id as invd_id FROM invoices inv INNER JOIN invoice_details invd
                    ON inv.id = invd.invoice_id
                WHERE inv.company_id = OLD.id) dinvd
         WHERE invoice_details.id = dinvd.invd_id;

        DELETE FROM pur_invoice_details
         USING (SELECT invd.id as invd_id FROM pur_invoices inv INNER JOIN pur_invoice_details invd
                    ON inv.id = invd.pur_invoice_id
                WHERE inv.company_id = OLD.id) dinvd
         WHERE pur_invoice_details.id = dinvd.invd_id;
        RETURN OLD;
      END;
      $trigger$ LANGUAGE plpgsql;
    """
  end

  def down do
    execute """
    CREATE OR REPLACE FUNCTION delete_non_cascadeable_records()
      RETURNS trigger AS $trigger$
      BEGIN
        DELETE FROM invoice_details
         USING (SELECT invd.id as invd_id FROM invoices inv INNER JOIN invoice_details invd
                    ON inv.id = invd.invoice_id
                WHERE inv.company_id = OLD.id) dinvd
         WHERE invoice_details.id = dinvd.invd_id;

        DELETE FROM pur_invoice_details
         USING (SELECT invd.id as invd_id FROM pur_invoices inv INNER JOIN pur_invoice_details invd
                    ON inv.id = invd.pur_invoice_id
                WHERE inv.company_id = OLD.id) dinvd
         WHERE pur_invoice_details.id = dinvd.invd_id;
        RETURN OLD;
      END;
      $trigger$ LANGUAGE plpgsql;
    """
  end
end
