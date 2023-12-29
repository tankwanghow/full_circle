defmodule FullCircle.Repo.Migrations.CreatLoad do
  use Ecto.Migration

  def change do
    create table(:loads) do
      add :load_no, :string
      add :load_date, :date
      add :lorry, :string
      add :descriptions, :text
      add :loader_tags, :text
      add :loader_wages_tags, :text
      add :company_id, references(:companies, on_delete: :delete_all)
      add :shipper_id, references(:contacts, on_delete: :restrict)
      add :supplier_id, references(:contacts, on_delete: :restrict)

      timestamps(type: :timestamptz)
    end

    create unique_index(:loads, [:company_id, :load_no])
    create index(:loads, [:company_id])
    create index(:loads, [:company_id, :shipper_id])
    create index(:loads, [:company_id, :supplier_id])
    create index(:loads, [:company_id, :load_date])

    create table(:load_details) do
      add :_persistent_id, :integer
      add :package_id, references(:packagings, on_delete: :restrict)
      add :order_detail_id, references(:order_details, on_delete: :restrict)
      add :load_pack_qty, :decimal, default: 0
      add :load_qty, :decimal, default: 0
      add :descriptions, :string
      add :unit_price, :decimal, default: 0
      add :status, :string
      add :load_id, references(:loads, on_delete: :delete_all)
      add :good_id, references(:goods, on_delete: :restrict)
    end

    create index(:load_details, [:load_id])
    create index(:load_details, [:good_id])
    create index(:load_details, [:package_id])
    create index(:load_details, [:order_detail_id])
  end
end
