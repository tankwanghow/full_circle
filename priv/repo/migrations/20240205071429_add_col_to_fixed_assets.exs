defmodule FullCircle.Repo.Migrations.AddColToHouse do
  use Ecto.Migration

  def change do
    alter table(:fixed_assets) do
      add :status, :string, default: "Active"
    end
  end
end
