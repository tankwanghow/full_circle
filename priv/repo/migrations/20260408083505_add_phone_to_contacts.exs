defmodule FullCircle.Repo.Migrations.AddPhoneToContacts do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      add :phone, :string
    end
  end
end
