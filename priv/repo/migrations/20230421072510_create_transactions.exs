defmodule FullCircle.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :doc_type, :string
      add :doc_id, :integer
      add :doc_date, :date
      add :particulars, :string
      add :contact_particulars, :string
      add :amount, :decimal
      add :doc_no, :string

      add :reconciled, :boolean, default: false
      add :closed, :boolean, default: false
      add :old_data, :boolean, default: false

      add :account_id, references(:accounts, on_delete: :restrict)
      add :contact_id, references(:contacts, on_delete: :restrict)
      add :fixed_asset_id, references(:fixed_assets, on_delete: :nilify_all)
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(updated_at: false, type: :timestamptz)
    end
  end
end
