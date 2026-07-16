defmodule FullCircle.Repo.Migrations.CreateTradingMasters do
  use Ecto.Migration

  def change do
    create table(:trading_locations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false
      add :address_note, :text
      add :active, :boolean, null: false, default: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :contact_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_locations, [:company_id])
    create index(:trading_locations, [:company_id, :kind])
    create index(:trading_locations, [:company_id, :active])
    create index(:trading_locations, [:contact_id])

    create table(:trading_drivers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :phone, :string
      add :active, :boolean, null: false, default: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :contact_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_drivers, [:company_id])
    create index(:trading_drivers, [:company_id, :active])
    create index(:trading_drivers, [:contact_id])

    create table(:trading_transport_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :phone, :string
      add :active, :boolean, null: false, default: true

      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :contact_id, references(:contacts, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:trading_transport_agents, [:company_id])
    create index(:trading_transport_agents, [:company_id, :active])
    create index(:trading_transport_agents, [:contact_id])
  end
end
