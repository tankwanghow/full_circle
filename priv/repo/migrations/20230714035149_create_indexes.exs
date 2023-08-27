defmodule FullCircle.Repo.Migrations.CreateIndexed do
  use Ecto.Migration

  def change do
    create index(:transactions, [:doc_type, :doc_no, :company_id])
    create index(:transactions, [:company_id])
    create index(:transactions, [:contact_id, :company_id])
    create index(:transactions, [:account_id, :company_id])
    create index(:transactions, [:fixed_asset_id, :company_id])
    create index(:transactions, [:doc_date, :company_id])
    create index(:contacts, [:name, :company_id])
    create index(:accounts, [:name, :company_id])
    create index(:goods, [:name, :company_id])
    create index(:fixed_assets, [:name, :company_id])
    create index(:tax_codes, [:code, :company_id])
  end
end
