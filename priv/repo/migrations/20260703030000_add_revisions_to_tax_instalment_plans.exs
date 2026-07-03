defmodule FullCircle.Repo.Migrations.AddRevisionsToTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    alter table(:tax_instalment_plans) do
      add :revisions, :map, default: %{}, null: false
    end
  end
end
