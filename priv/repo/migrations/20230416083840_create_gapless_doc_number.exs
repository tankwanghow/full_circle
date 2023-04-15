defmodule FullCircle.Repo.Migrations.CreateGaplessDocNumber do
  use Ecto.Migration

  def change do
    create table(:gapless_doc_ids) do
      add :doc_type, :string
      add :current, :integer
      add :company_id, references(:companies, on_delete: :delete_all)
    end

    create unique_index(:gapless_doc_ids, [:company_id, :doc_type])
    create index(:gapless_doc_ids, [:doc_type])
    create index(:gapless_doc_ids, [:company_id])
  end
end
