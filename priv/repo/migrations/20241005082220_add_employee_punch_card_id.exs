defmodule FullCircle.Repo.Migrations.AddEmployeePunchCardId do
  use Ecto.Migration

  def change do
    alter table(:employees) do
      add :punch_card_id, :string, default: nil
    end

    create unique_index(:employees, [:punch_card_id])
  end
end
