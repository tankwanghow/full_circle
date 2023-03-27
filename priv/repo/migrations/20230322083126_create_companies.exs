defmodule FullCircle.Repo.Migrations.CreateCompanies do
  use Ecto.Migration

  def change do
    create table(:companies) do
      add :name, :string
      add :address1, :string
      add :address2, :string
      add :city, :string
      add :zipcode, :string
      add :state, :string
      add :country, :string
      add :timezone, :string
      add :reg_no, :string
      add :email, :string
      add :tel, :string
      add :fax, :string
      add :descriptions, :text
      add :tax_id, :string
      add :closing_day, :integer
      add :closing_month, :integer
      timestamps(type: :timestamptz)
    end

    create index(:companies, :name)

    create table(:company_user) do
      add :role, :string
      add :company_id, references(:companies, on_delete: :delete_all)
      add :user_id, references(:users, on_delete: :delete_all)
      add :default_company, :boolean, default: false

      timestamps(type: :timestamptz)
    end

    create index(:company_user, :company_id)
    create index(:company_user, :user_id)

    create unique_index(:company_user, [:user_id, :company_id],
             name: :company_user_user_id_company_id_index
           )
  end
end
