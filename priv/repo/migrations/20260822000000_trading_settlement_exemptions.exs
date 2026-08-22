defmodule FullCircle.Repo.Migrations.TradingSettlementExemptions do
  use Ecto.Migration

  # Admin-only settlement waivers, per line per stream (nil exempt_at = not exempt).
  # A drop carries two billable streams (customer invoice + transport bill),
  # so it gets two exemption sets; a load has one (supplier bill).
  def change do
    alter table(:trading_trip_drops) do
      add :invoice_exempt_at, :utc_datetime
      add :invoice_exempt_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :invoice_exempt_reason, :string

      add :transport_exempt_at, :utc_datetime
      add :transport_exempt_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :transport_exempt_reason, :string
    end

    alter table(:trading_trip_loads) do
      add :pur_invoice_exempt_at, :utc_datetime

      add :pur_invoice_exempt_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :pur_invoice_exempt_reason, :string
    end
  end
end
