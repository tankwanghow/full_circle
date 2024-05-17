defmodule FullCircle.Repo.Migrations.AddTypeToContact do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      add :category, :string, default: "Others"
    end
  end
end
