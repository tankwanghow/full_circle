defmodule FullCircle.Repo.Migrations.CreateCompanies do
  use Ecto.Migration

  def change do
    create table(:companies) do
      add :name, :string, null: false
      add :address1, :string
      add :address2, :string
      add :city, :string
      add :zipcode, :string
      add :state, :string
      add :country, :string, null: false
      add :timezone, :string, null: false
      add :reg_no, :string
      add :email, :string
      add :tel, :string
      add :fax, :string
      add :descriptions, :text
      add :tax_id, :string
      add :closing_day, :integer
      add :closing_month, :integer
      add :normal_work_hours, :decimal
      timestamps(type: :timestamptz)
    end

    create index(:companies, :name)

    create table(:company_user) do
      add :role, :string, null: false
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :default_company, :boolean, default: false

      timestamps(type: :timestamptz)
    end

    create index(:company_user, :company_id)
    create index(:company_user, :user_id)

    create unique_index(:company_user, [:user_id, :company_id],
             name: :company_user_unique_company_in_user
           )
  end
end
