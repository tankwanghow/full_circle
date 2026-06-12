defmodule FullCircle.Repo.Migrations.AddRemedyFieldsToTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    alter table(:tax_instalment_plans) do
      add :remedy_director_count, :integer, null: false, default: 1
      add :remedy_existing_income, :decimal, null: false, default: 0
    end
  end
end