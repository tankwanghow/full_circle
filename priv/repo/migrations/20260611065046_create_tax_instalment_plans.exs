defmodule FullCircle.Repo.Migrations.CreateTaxInstalmentPlans do
  use Ecto.Migration

  def change do
    create table(:tax_instalment_plans) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :tax_paid_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :fy_year, :integer, null: false
      add :tolerance_pct, :decimal, null: false, default: 30
      add :estimate, :decimal, null: false, default: 0
      add :estimate_month, :integer, null: false, default: 1
      add :paid_overrides, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tax_instalment_plans, [:company_id, :fy_year],
             name: :tax_instalment_plans_unique_period
           )
  end
end
