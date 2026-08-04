defmodule FullCircle.Repo.Migrations.CreateGoodPriceHistories do
  use Ecto.Migration

  def change do
    create table(:good_price_histories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :good_id, references(:goods, type: :binary_id, on_delete: :delete_all), null: false

      # "sale" | "purchase"
      add :side, :string, null: false
      add :doc_date, :date, null: false
      add :unit_price, :decimal, null: false
      add :quantity, :decimal, null: false, default: 0
      add :discount, :decimal, null: false, default: 0
      # Snapshot of unit/name at source (helps when goods are renamed later)
      add :unit, :string
      add :good_name, :string
      # "invoice" | "cash_sale" | "pur_invoice"
      add :source, :string, null: false
      # Rails (or other) source identifiers for audit / re-import
      add :source_doc_id, :bigint
      add :source_line_id, :bigint

      timestamps(type: :timestamptz)
    end

    create index(:good_price_histories, [:company_id, :good_id, :side, :doc_date],
      name: :good_price_histories_lookup
    )

    create index(:good_price_histories, [:company_id, :doc_date],
      name: :good_price_histories_company_date
    )

    create unique_index(
      :good_price_histories,
      [:company_id, :source, :source_line_id],
      name: :good_price_histories_source_line_unique,
      where: "source_line_id IS NOT NULL"
    )
  end
end
