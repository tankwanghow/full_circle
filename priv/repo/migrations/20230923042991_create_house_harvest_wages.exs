defmodule FullCircle.Repo.Migrations.CreateHouseHarvestWages do
  use Ecto.Migration

  def change do
    create table(:house_harvest_wages) do
      add :house_id, references(:houses, on_delete: :restrict)
      add :wages, :decimal
      add :utry, :integer
      add :ltry, :integer

      timestamps(type: :timestamptz)
    end

    create unique_index(:house_harvest_wages, [:house_id, :ltry])
    create unique_index(:house_harvest_wages, [:house_id, :utry])
  end
end
