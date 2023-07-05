defmodule FullCircle.Repo.Migrations.CreateTriggersWhenDeleteCompany do
  use Ecto.Migration

  def up do
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

    execute """
    CREATE TRIGGER delete_company_trigger
      BEFORE DELETE ON companies FOR EACH ROW
      EXECUTE PROCEDURE delete_non_cascadeable_records();
    """
  end

  def down do
    execute "DROP TRIGGER delete_company_trigger ON companies;"
    execute "DROP FUNCTION delete_non_cascadeable_records();"
  end
end
