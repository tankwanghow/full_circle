defmodule FullCircle.Repo.Migrations.CreatDelivery do
  use Ecto.Migration

  def change do
    create table(:deliveries) do
      add :delivery_no, :string
      add :delivery_date, :date
      add :lorry, :string
      add :descriptions, :text
      add :delivery_man_tags, :text
      add :delivery_wages_tags, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :shipper_id, references(:contacts, on_delete: :restrict)
      add :customer_id, references(:contacts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:deliveries, [:company_id, :delivery_no])
    create index(:deliveries, [:company_id])
    create index(:deliveries, [:company_id, :shipper_id])
    create index(:deliveries, [:company_id, :customer_id])
    create index(:deliveries, [:company_id, :delivery_date])

    create table(:delivery_details) do
      add :_persistent_id, :integer
      add :package_id, references(:packagings, on_delete: :restrict)
      add :load_detail_id, references(:load_details, on_delete: :restrict)
      add :delivery_pack_qty, :decimal, default: 0
      add :delivery_qty, :decimal, default: 0
      add :descriptions, :string
      add :unit_price, :decimal, default: 0
      add :status, :string
      add :delivery_id, references(:deliveries, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :restrict)
    end

    create index(:delivery_details, [:delivery_id])
    create index(:delivery_details, [:good_id])
    create index(:delivery_details, [:package_id])
    create index(:delivery_details, [:load_detail_id])

    alter table(:invoice_details) do
      add :delivery_detail_id, references(:delivery_details, on_delete: :restrict)
    end

    create index(:invoice_details, [:delivery_detail_id])
  end
end
