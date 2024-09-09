defmodule FullCircle.Repo.Migrations.AddColToFixedAssets do
  use Ecto.Migration

  def change do
    alter table(:fixed_assets) do
      add :status, :string, default: "Active"
    end
  end
end
