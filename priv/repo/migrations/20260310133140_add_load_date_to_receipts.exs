defmodule FullCircle.Repo.Migrations.AddLoadDateToReceipts do
  use Ecto.Migration

  def change do
    alter table(:receipts) do
      add :load_date, :date
    end
  end
end
