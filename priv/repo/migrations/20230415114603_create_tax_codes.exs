defmodule FullCircle.Repo.Migrations.CreateTaxCodes do
  use Ecto.Migration

  def change do
    create table(:tax_codes) do
      add :code, :string, null: false
      add :tax_type, :string, null: false
      add :rate, :decimal, default: 0
      add :descriptions, :text
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :nothing), null: false

      timestamps(type: :timestamptz)
    end

    create unique_index(:tax_codes, [:company_id, :code], name: :tax_codes_unique_code_in_company)
  end
end
