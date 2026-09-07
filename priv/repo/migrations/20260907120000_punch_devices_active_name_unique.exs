defmodule FullCircle.Repo.Migrations.PunchDevicesActiveNameUnique do
  use Ecto.Migration

  def change do
    drop unique_index(:punch_devices, [:company_id, :name])

    create unique_index(:punch_devices, [:company_id, :name],
             where: "revoked_at IS NULL",
             name: :punch_devices_company_id_name_active_index
           )
  end
end
