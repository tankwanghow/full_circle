defmodule FullCircle.Repo.Migrations.CreateGoods do
  use Ecto.Migration

  def change do
    create table(:goods) do
      add :name, :string, null: false
      add :unit, :string, null: false
      add :descriptions, :text
      add :purchase_account_id, references(:accounts, on_delete: :restrict), null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :purchase_tax_code_id, references(:tax_codes, on_delete: :restrict), null: false
      add :sales_account_id, references(:accounts, on_delete: :restrict), null: false
      add :sales_tax_code_id, references(:tax_codes, on_delete: :restrict), null: false

      timestamps(type: :timestamptz)
    end

    create unique_index(:goods, [:company_id, :name], name: :goods_unique_name_in_company)

    create index(:goods, [:purchase_account_id])
    create index(:goods, [:company_id])
    create index(:goods, [:purchase_tax_code_id])
    create index(:goods, [:sales_account_id])
    create index(:goods, [:sales_tax_code_id])

    create table(:packagings) do
      add :_persistent_id, :integer
      add :good_id, references(:goods, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :unit_multiplier, :decimal, default: 1
      add :cost_per_package, :decimal, default: 0
    end

    create unique_index(:packagings, [:good_id, :name], name: :packagings_unique_name_in_goods)
  end
end
