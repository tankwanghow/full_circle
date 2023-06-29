defmodule FullCircle.Repo.Migrations.CreateFixedAssets do
  use Ecto.Migration

  def change do
    create table(:fixed_assets) do
      add :name, :string
      add :descriptions, :text
      add :depre_start_date, :date
      add :pur_date, :date
      add :pur_price, :decimal
      add :residual_value, :decimal
      add :depre_method, :string
      add :depre_rate, :decimal
      add :depre_interval, :string
      add :company_id, references(:companies, on_delete: :delete_all)
      add :asset_ac_id, references(:accounts, on_delete: :restrict)
      add :depre_ac_id, references(:accounts, on_delete: :restrict)
      add :disp_fund_ac_id, references(:accounts, on_delete: :restrict)
      add :cume_depre_ac_id, references(:accounts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:fixed_assets, [:company_id, :name],
             name: :fixed_assets_unique_name_in_company
           )

    create index(:fixed_assets, [:company_id])
    create index(:fixed_assets, [:asset_ac_id])
  end
end
