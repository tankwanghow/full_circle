defmodule FullCircle.Repo.Migrations.AddBillingQueryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:transactions, [:company_id, :doc_type, :doc_date], concurrently: true)

    create index(:transactions, [:doc_id],
      where: "doc_id IS NOT NULL",
      concurrently: true
    )
  end
end
