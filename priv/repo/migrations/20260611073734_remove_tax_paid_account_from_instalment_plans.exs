defmodule FullCircle.Repo.Migrations.RemoveTaxPaidAccountFromInstalmentPlans do
  use Ecto.Migration

  def change do
    alter table(:tax_instalment_plans) do
      remove :tax_paid_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
