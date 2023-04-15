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
      add :company_id, references(:companies, on_delete: :delete_all)
      add :asset_ac_id, references(:accounts, on_delete: :nothing)
      add :depre_ac_id, references(:accounts, on_delete: :nothing)
      add :cume_depre_ac_id, references(:accounts, on_delete: :nothing)

      timestamps(type: :timestamptz)
    end

    create unique_index(:fixed_assets, [:company_id, :name],
             name: :fixed_assets_unique_name_in_company
           )

    create index(:fixed_assets, [:company_id])
    create index(:fixed_assets, [:asset_ac_id])

    create index(:fixed_assets, [:cume_depre_ac_id])

    create table(:fixed_assets_depreciations) do
      add :fixed_asset_id, references(:fixed_assets, on_delete: :delete_all)
      add :depre_till_date, :date
      add :cost_basis, :decimal
      add :YTD_depre, :decimal
      add :cume_depre, :decimal
      add :confirmed, :boolean

      timestamps(type: :timestamptz)
    end

    create index(:fixed_assets_depreciations, [:fixed_asset_id])

    create table(:fixed_assets_additions) do
      add :fixed_asset_id, references(:fixed_assets, on_delete: :delete_all)
      add :add_date, :date
      add :add_amount, :decimal
      add :confirmed, :boolean

      timestamps(type: :timestamptz)
    end

    create index(:fixed_assets_additions, [:fixed_asset_id])

    create table(:fixed_assets_disposals) do
      add :fixed_asset_id, references(:fixed_assets, on_delete: :delete_all)
      add :disp_date, :date
      add :disp_amount, :decimal
      add :disp_loss_gain_ac_id, references(:accounts, on_delete: :nothing)
      add :confirmed, :boolean

      timestamps(type: :timestamptz)
    end

    create index(:fixed_assets_disposals, [:fixed_asset_id])
  end
end
