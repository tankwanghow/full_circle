defmodule FullCircle.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:journals) do
      add :journal_no, :string
      add :journal_date, :date
      add :company_id, references(:companies, on_delete: :delete_all)

      timestamps(type: :timestamptz)
    end

    create unique_index(:journals, [:company_id, :journal_no])
    create index(:journals, [:company_id])
  end
end
