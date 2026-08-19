defmodule FullCircle.Repo.Migrations.OrderedCompanyDeleteCleanup do
  use Ecto.Migration

  # Deleting a company cascades to its direct children in FK-creation order,
  # which matches dependency order for parent tables (children were always
  # migrated after parents), and the closed-transaction guard's escape hatch
  # (companies row already gone) admits the cascade. GRANDCHILD tables are
  # the exception: they carry no company_id, their cascade is enqueued only
  # when their parent's cascade runs — after earlier cascades (accounts,
  # goods, ...) have already queued RESTRICT checks against them. Pre-delete
  # every grandchild here; leave everything with a company_id to the cascade.
  def up do
    execute """
    CREATE OR REPLACE FUNCTION delete_non_cascadeable_records()
      RETURNS trigger AS $trigger$
      BEGIN
        -- matcher rows (RESTRICT onto transactions)
        DELETE FROM transaction_matchers tm
         USING transactions txn
         WHERE tm.transaction_id = txn.id AND txn.company_id = OLD.id;

        DELETE FROM seed_transaction_matchers tm
         USING transactions txn
         WHERE tm.transaction_id = txn.id AND txn.company_id = OLD.id;

        -- document detail rows (RESTRICT onto goods/accounts/tax_codes/packagings)
        DELETE FROM invoice_details d
         USING invoices h WHERE d.invoice_id = h.id AND h.company_id = OLD.id;

        DELETE FROM pur_invoice_details d
         USING pur_invoices h WHERE d.pur_invoice_id = h.id AND h.company_id = OLD.id;

        DELETE FROM payment_details d
         USING payments h WHERE d.payment_id = h.id AND h.company_id = OLD.id;

        DELETE FROM receipt_details d
         USING receipts h WHERE d.receipt_id = h.id AND h.company_id = OLD.id;

        DELETE FROM credit_note_details d
         USING credit_notes h WHERE d.credit_note_id = h.id AND h.company_id = OLD.id;

        DELETE FROM debit_note_details d
         USING debit_notes h WHERE d.debit_note_id = h.id AND h.company_id = OLD.id;

        -- HR junction rows (RESTRICT onto employees)
        DELETE FROM employee_salary_types est
         USING employees e WHERE est.employee_id = e.id AND e.company_id = OLD.id;

        -- trading grandchildren (RESTRICT onto employees/goods)
        DELETE FROM trading_trip_drop_employees de
         USING trading_trip_drops dr, trading_trips t
         WHERE de.trip_drop_id = dr.id AND dr.trip_id = t.id AND t.company_id = OLD.id;

        DELETE FROM trading_trip_load_employees le
         USING trading_trip_loads lo, trading_trips t
         WHERE le.trip_load_id = lo.id AND lo.trip_id = t.id AND t.company_id = OLD.id;

        DELETE FROM trading_trip_drops dr
         USING trading_trips t WHERE dr.trip_id = t.id AND t.company_id = OLD.id;

        DELETE FROM trading_trip_loads lo
         USING trading_trips t WHERE lo.trip_id = t.id AND t.company_id = OLD.id;

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
end
