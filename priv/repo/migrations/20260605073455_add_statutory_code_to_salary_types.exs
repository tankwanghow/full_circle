defmodule FullCircle.Repo.Migrations.AddStatutoryCodeToSalaryTypes do
  use Ecto.Migration

  @map %{
    "epf by employer" => "epf_employer",
    "epf by employee" => "epf_employee",
    "epf employee self" => "epf_employee",
    "socso by employer" => "socso_employer",
    "socso by employee" => "socso_employee",
    "socso employer only" => "socso_employer_only",
    "eis by employer" => "eis_employer",
    "eis by employee" => "eis_employee",
    "eis employer only" => "eis_employer_only",
    "employee pcb" => "pcb_employee"
  }

  def up do
    alter table(:salary_types) do
      add :statutory_code, :string
    end

    flush()

    for {name, code} <- @map do
      execute("""
      update salary_types set statutory_code = '#{code}'
       where lower(name) = '#{name}'
      """)
    end
  end

  def down do
    alter table(:salary_types) do
      remove :statutory_code
    end
  end
end
