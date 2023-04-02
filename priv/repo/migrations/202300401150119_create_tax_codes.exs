defmodule FullCircle.Repo.Migrations.CreateTaxCodes do
  use Ecto.Migration

  def change do
    create table(:tax_codes) do
      add :code, :string
      add :tax_type, :string
      add :rate, :decimal
      add :descriptions, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :account_id, references(:accounts, on_delete: :nothing)

      timestamps(type: :timestamptz)
    end

    create unique_index(:tax_codes, [:company_id, :code])
  end
end
