defmodule FullCircle.Repo.Migrations.TradingLoadPurInvoice do
  use Ecto.Migration

  def change do
    alter table(:trading_trip_loads) do
      add :pur_invoice_id, references(:pur_invoices, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:trading_trip_loads, [:pur_invoice_id])
  end
end
