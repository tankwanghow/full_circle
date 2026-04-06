defmodule FullCircle.Repo.Migrations.ChangeBankStatementLineDescriptionToText do
  use Ecto.Migration

  def change do
    alter table(:bank_statement_lines) do
      modify :description, :text, from: :string
    end
  end
end
