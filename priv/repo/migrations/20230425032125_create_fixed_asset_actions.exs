defmodule FullCircle.Repo.Migrations.CreateFixedAssetActions do
  use Ecto.Migration

  def change do
    create table(:fixed_asset_depreciations) do
      add :fixed_asset_id, references(:fixed_assets, on_delete: :delete_all)
      add :depre_date, :date
      add :cost_basis, :decimal
      add :amount, :decimal
      add :is_seed, :boolean, default: false
      add :doc_no, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:fixed_asset_depreciations, [:fixed_asset_id, :doc_no])
    create index(:fixed_asset_depreciations, [:fixed_asset_id])

    create table(:fixed_asset_disposals) do
      add :fixed_asset_id, references(:fixed_assets, on_delete: :delete_all)
      add :disp_date, :date
      add :amount, :decimal
      add :is_seed, :boolean, default: false
      add :doc_no, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:fixed_asset_disposals, [:fixed_asset_id, :doc_no])
    create index(:fixed_asset_disposals, [:fixed_asset_id])
  end
end
