defmodule FullCircle.Repo.Migrations.CreatePayPreps do
  use Ecto.Migration

  def change do
    create table(:pay_preps) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :employee_id, references(:employees, type: :binary_id, on_delete: :delete_all), null: false
      add :funds_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :verified_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :pay_month, :integer, null: false
      add :pay_year, :integer, null: false
      add :verified, :boolean, null: false, default: false
      add :verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pay_preps, [:company_id, :employee_id, :pay_month, :pay_year],
             name: :pay_preps_unique_period
           )
  end
end
