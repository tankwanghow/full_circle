defmodule FullCircle.Repo.Migrations.TradingDropTransportPurInvoice do
  use Ecto.Migration

  def change do
    alter table(:trading_trip_drops) do
      add :transport_pur_invoice_id,
          references(:pur_invoices, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:trading_trip_drops, [:transport_pur_invoice_id])
  end
end
