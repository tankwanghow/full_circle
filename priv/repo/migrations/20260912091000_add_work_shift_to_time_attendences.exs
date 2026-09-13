defmodule FullCircle.Repo.Migrations.AddWorkShiftToTimeAttendences do
  use Ecto.Migration

  def up do
    alter table(:time_attendences) do
      add :work_shift_id, references(:work_shifts, on_delete: :nilify_all)
      add :work_shift_date, :date
      add :punch_kind, :string

      # Dead since 2023: a :string column never mapped in the schema, whose
      # index was already dropped in 20260609000823 as "unused anywhere in lib/".
      remove :shift_id
    end

    create index(:time_attendences, [:company_id, :employee_id, :work_shift_id, :work_shift_date],
             name: :time_attendences_instance_index
           )

    # Every existing punch belongs to its company's General shift.
    execute("""
    update time_attendences ta
       set work_shift_id = ws.id,
           work_shift_date = (ta.punch_time at time zone c.timezone)::date
      from companies c
      join work_shifts ws on ws.company_id = c.id and ws.is_default
     where ta.company_id = c.id
    """)

    # Derive punch_kind and the display flag from position within the instance.
    execute("""
    with numbered as (
      select id,
             row_number() over (partition by employee_id, work_shift_id, work_shift_date
                                order by punch_time) rn
        from time_attendences
       where work_shift_id is not null
    )
    update time_attendences ta
       set punch_kind = case when mod(n.rn, 2) = 1 then 'IN' else 'OUT' end,
           flag = ((n.rn + 1) / 2)::text
                  || '_' || (case when mod(n.rn, 2) = 1 then 'IN' else 'OUT' end)
                  || '_' || ((n.rn + 1) / 2)::text
      from numbered n
     where ta.id = n.id
    """)

    # CUTOVER GATE. The backfill above writes the punch's local *date* as the
    # anchor. That is only correct where the punch's local *time* is at or after
    # its shift's cutover; a punch before the cutover belongs to the previous
    # day's instance, which is exactly the regrouping this migration claims does
    # not happen. So test the punch against the cutover, not against the
    # expression it was just assigned from - comparing work_shift_date with
    # (punch_time at time zone tz)::date is a tautology that passes on any data.
    #
    # cutover = (start_time + (24 + max_hour)/2) mod 24, the same arithmetic as
    # WorkShift.cutover_time/1. For the seeded General (08:00 / 12) that is
    # 02:00, and there are zero punches between 22:00 and 06:59 in 23,902 rows.
    execute("""
    do $$
    declare bad integer;
    begin
      select count(*) into bad
        from time_attendences ta
        join companies c on c.id = ta.company_id
        join work_shifts ws on ws.id = ta.work_shift_id
       where (ta.punch_time at time zone c.timezone)::time
             < ((ws.start_time + make_interval(mins => ((24 + ws.max_hour) * 30)::int))::time);

      if bad > 0 then
        raise exception
          'work shift backfill regroups % punches across a cutover - backfill is not behaviour preserving', bad;
      end if;
    end $$;
    """)
  end

  def down do
    drop index(:time_attendences, [], name: :time_attendences_instance_index)

    alter table(:time_attendences) do
      remove :work_shift_id
      remove :work_shift_date
      remove :punch_kind
      add :shift_id, :string
    end
  end
end
