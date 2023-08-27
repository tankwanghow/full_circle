defmodule FullCircle.Repo.Migrations.CreateUserSettings do
  use Ecto.Migration

  def change do
    create table(:user_settings) do
      add :page, :string
      add :code, :string
      add :display_name, :string
      add :type, :string
      add :values, :map
      add :value, :string
      add :company_user_id, references(:company_user, on_delete: :delete_all)
    end

    create index(:user_settings, [:page, :company_user_id])
  end
end
