defmodule FullCircle.Repo.Migrations.CreateAccountsAndContacts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :name, :string
      add :company_id, references(:companies, on_delete: :delete_all)
      add :account_type, :string
      add :descriptions, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:accounts, [:company_id, :name])

    create table(:contacts) do
      add :name, :string
      add :company_id, references(:companies, on_delete: :delete_all)
      add :address1, :string
      add :address2, :string
      add :city, :string
      add :zipcode, :string
      add :state, :string
      add :country, :string
      add :reg_no, :string
      add :email, :string
      add :contact_info, :text
      add :descriptions, :text

      timestamps(type: :timestamptz)
    end

    create unique_index(:contacts, [:company_id, :name])
  end
end
