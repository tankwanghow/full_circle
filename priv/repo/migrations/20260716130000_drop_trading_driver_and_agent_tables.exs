defmodule FullCircle.Repo.Migrations.DropTradingDriverAndAgentTables do
  use Ecto.Migration

  def up do
    drop_if_exists table(:trading_drivers)
    drop_if_exists table(:trading_transport_agents)
  end

  def down do
    raise "irreversible: drivers are employees; transport agents are contacts"
  end
end
