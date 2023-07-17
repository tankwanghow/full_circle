defmodule FullCircle.Repo.Migrations.CreateIndexed do
  use Ecto.Migration

  def change do
    create index(:transactions, [:doc_type, :doc_no])
    create index(:transactions, [:company_id])
    create index(:transactions, [:contact_id])
    create index(:transactions, [:account_id])
    create index(:transactions, [:fixed_asset_id])
    create index(:contacts, [:name])
    create index(:accounts, [:name])
    create index(:goods, [:name])
    create index(:fixed_assets, [:name])
  end
end
