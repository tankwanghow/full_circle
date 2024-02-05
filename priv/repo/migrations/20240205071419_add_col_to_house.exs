defmodule FullCircle.Repo.Migrations.AddColToHouse do
  use Ecto.Migration

  def change do
    alter table(:houses) do
      add :status, :string, default: "Active"
      add :feeding_wages, :decimal, default: 0
      add :filling_wages, :decimal, default: 0
    end
  end
end
