defmodule FullCircle.Repo.Migrations.AddCategoryToGoods do
  use Ecto.Migration

  def change do
    alter table(:goods) do
      add :category, :string, default: "Others"
    end
  end
end
