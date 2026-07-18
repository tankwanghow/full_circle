defmodule FullCircle.Repo.Migrations.AddVehicleNumberToTradingTrips do
  use Ecto.Migration

  def change do
    alter table(:trading_trips) do
      add :vehicle_number, :string
    end
  end
end
