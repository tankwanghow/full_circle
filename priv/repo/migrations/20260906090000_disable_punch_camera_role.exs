defmodule FullCircle.Repo.Migrations.DisablePunchCameraRole do
  use Ecto.Migration

  # The web PunchCamera kiosk (and its dedicated punch_camera role) was removed.
  # Existing kiosk logins become disable until an admin reassigns them.

  def up do
    execute("UPDATE company_user SET role = 'disable' WHERE role = 'punch_camera'")
  end

  def down do
    # Cannot restore which users were punch_camera.
  end
end
