defmodule FullCircle.Repo.Migrations.AddPriorYearEstimateToTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    alter table(:tax_instalment_plans) do
      add :prior_year_estimate, :decimal, default: 0, null: false
    end
  end
end
