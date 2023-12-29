defmodule FullCircle.Repo.Migrations.CreatOrder do
  use Ecto.Migration

  def change do
    create table(:orders) do
      add :order_no, :string
      add :order_date, :date
      add :etd_date, :date
      add :descriptions, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :customer_id, references(:contacts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:orders, [:company_id, :order_no])
    create index(:orders, [:company_id])
    create index(:orders, [:company_id, :customer_id])
    create index(:orders, [:company_id, :order_date])
    create index(:orders, [:company_id, :etd_date])

    create table(:order_details) do
      add :_persistent_id, :integer
      add :package_id, references(:packagings, on_delete: :restrict)
      add :order_pack_qty, :decimal, default: 0
      add :order_qty, :decimal, default: 0
      add :descriptions, :string
      add :unit_price, :decimal, default: 0
      add :status, :string
      add :order_id, references(:orders, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :restrict)
    end

    create index(:order_details, [:order_id])
    create index(:order_details, [:good_id])
    create index(:order_details, [:package_id])
  end
end
