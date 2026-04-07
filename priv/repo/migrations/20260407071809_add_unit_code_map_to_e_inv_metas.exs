defmodule FullCircle.Repo.Migrations.AddUnitCodeMapToEInvMetas do
  use Ecto.Migration

  def change do
    alter table(:e_inv_metas) do
      add :unit_code_map, :map, default: %{}
    end
  end
end
