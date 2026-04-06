defmodule FullCircle.Repo.Migrations.AddSettingsToCompanies do
  use Ecto.Migration

  def change do
    alter table(:companies) do
      add :settings, :map, default: %{}
    end
  end
end
