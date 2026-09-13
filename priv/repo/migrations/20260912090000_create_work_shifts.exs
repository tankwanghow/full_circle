defmodule FullCircle.Repo.Migrations.CreateWorkShifts do
  use Ecto.Migration

  def up do
    create table(:work_shifts) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :start_time, :time, null: false
      add :normal_hour, :decimal, null: false
      add :max_hour, :decimal, null: false
      add :is_default, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:work_shifts, [:company_id, :name])
    # At most one default per company; the fallback path runs on every punch,
    # so it must not depend on a name someone can rename.
    create unique_index(:work_shifts, [:company_id],
             where: "is_default",
             name: :work_shifts_one_default_per_company
           )

    create table(:employee_work_shifts) do
      add :employee_id, references(:employees, on_delete: :delete_all), null: false
      add :work_shift_id, references(:work_shifts, on_delete: :delete_all), null: false
      add :effective_from, :date, null: false
      add :effective_to, :date

      timestamps()
    end

    create index(:employee_work_shifts, [:employee_id, :effective_from])

    # Seed one General per existing company. 08:00 / 9 / 12 gives a nominal
    # 08:00-17:00 and a derived cutover of 02:00, which sits inside the empty
    # 22:00-07:00 band so grouping matches today exactly.
    execute("""
    insert into work_shifts (id, company_id, name, start_time, normal_hour, max_hour,
                             is_default, inserted_at, updated_at)
    select gen_random_uuid(), c.id, 'General', time '08:00', 9, 12, true, now(), now()
      from companies c
    """)
  end

  def down do
    drop table(:employee_work_shifts)
    drop table(:work_shifts)
  end
end
