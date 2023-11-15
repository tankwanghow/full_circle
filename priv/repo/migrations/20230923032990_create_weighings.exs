defmodule FullCircle.Repo.Migrations.CreateWeighings do
  use Ecto.Migration

  def change do
    create table(:weighings) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :note_no, :string
      add :note_date, :date
      add :vehicle_no, :string
      add :good_name, :string
      add :note, :string
      add :gross, :integer, default: 0
      add :tare, :integer, default: 0

      timestamps(type: :timestamptz)
    end

    create unique_index(:weighings, [:company_id, :note_no],
             name: :weighings_unique_note_no_in_company
           )

    create index(:weighings, [:company_id, :note_date])
    create index(:weighings, [:company_id, :note_date, :good_name])
  end
end
