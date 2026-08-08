defmodule FullCircle.Repo.Migrations.AddLockVersionToCoEditedRecords do
  use Ecto.Migration

  # Document headers and master data that two users can have open in a form at
  # the same time. `Ecto.Changeset.optimistic_lock/2` uses this column so the
  # second save is refused instead of silently overwriting the first.
  #
  # NOT NULL with a constant default is a catalog-only change on PostgreSQL 11+,
  # so this does not rewrite the tables. lock_timeout keeps the brief
  # ACCESS EXCLUSIVE lock from queueing behind a long-running transaction (and
  # everything else behind it) if this is ever run against a live database.
  @tables [
    :invoices,
    :pur_invoices,
    :receipts,
    :payments,
    :credit_notes,
    :debit_notes,
    :deposits,
    :return_cheques,
    :journals,
    :contacts,
    :goods
  ]

  def up do
    execute("SET lock_timeout = '5s'")

    for table <- @tables do
      alter table(table) do
        add(:lock_version, :integer, default: 0, null: false)
      end
    end
  end

  def down do
    execute("SET lock_timeout = '5s'")

    for table <- @tables do
      alter table(table) do
        remove(:lock_version)
      end
    end
  end
end
