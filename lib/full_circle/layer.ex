defmodule FullCircle.Layer do
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.{Repo}
  alias FullCircle.Layer.{House, Flock, Movement, Harvest, HarvestDetail, HouseHarvestWage}

  def harvest_wage_report(fd, td, com_id) do
    from(hhw in HouseHarvestWage,
      join: h in House,
      on: h.id == hhw.house_id,
      join: hd in HarvestDetail,
      on: hd.house_id == h.id,
      join: hv in Harvest,
      on: hv.id == hd.harvest_id,
      left_join: e in FullCircle.HR.Employee,
      on: e.id == hv.employee_id,
      where: hv.har_date >= ^fd,
      where: hv.har_date <= ^td,
      where: hd.har_1 + hd.har_2 + hd.har_3 >= hhw.ltry,
      where: hd.har_1 + hd.har_2 + hd.har_3 <= hhw.utry,
      where: hv.company_id == ^com_id,
      order_by: [e.name, hv.har_date],
      select: %{
        house_no: h.house_no,
        prod: hd.har_1 + hd.har_2 + hd.har_3,
        har_date: hv.har_date,
        employee: e.name,
        wages: hhw.wages
      }
    )
    |> Repo.all()
  end

  def harvest_report(dt, com_id) do
    "WITH
      datelist as (
        select generate_series(('#{dt}'::date-interval '7 day'), '#{dt}', interval '1 day') :: date gdate),
      hou_flo_dt_qty as (
        select dl.gdate, hou.id as house_id, hou.house_no, f.id as flock_id, f.flock_no, f.dob,
              (date_part('day', dl.gdate::timestamp - f.dob::timestamp)/7)::integer as age,
              (select sum(m.quantity) from movements m
                where m.move_date <= dl.gdate
                  and hou.id = m.house_id and f.id = m.flock_id) -
              coalesce((select sum(hd1.dea_1+hd1.dea_2)
                  from harvests hv1
                inner join harvest_details hd1 on hv1.id = hd1.harvest_id
                where hd1.house_id = hou.id
                  and hv1.har_date < dl.gdate
                  and hd1.flock_id = f.id), 0) as cur_qty
          from movements m inner join houses hou on hou.id = m.house_id
        inner join flocks f on m.flock_id = f.id, datelist dl
        where (date_part('day', dl.gdate::timestamp - f.dob::timestamp)/7)::integer < 95
          and m.company_id = '#{com_id}'
        group by dl.gdate, hou.id, f.id)

    select hq.gdate, string_agg(distinct e.name, ', ') as employee,
          hq.house_no, hq.age, hq.flock_no, hq.cur_qty,
          coalesce(sum(hd.har_1+hd.har_2+hd.har_3),0)*30 as prod, coalesce(sum(hd.dea_1+hd.dea_2),0) as dea
      from harvests h
    inner join harvest_details hd on h.id = hd.harvest_id
    inner join employees e on e.id = h.employee_id
    right outer join hou_flo_dt_qty hq on hd.house_id = hq.house_id and hd.flock_id = hq.flock_id and h.har_date = hq.gdate
    where hq.cur_qty > 0 and hq.age >= 14
      group by hq.gdate, hq.house_no, hq.flock_no, hq.age, hq.cur_qty"
    |> exec_query()
    |> format_harvest_report(dt)
  end

  defp format_harvest_report(l, dt) do
    tl =
      l
      |> Enum.filter(fn e ->
        e.gdate ==
          dt
      end)
      |> Enum.map(fn e -> Map.merge(e, %{id: e.house_no, yield_0: e.prod / e.cur_qty}) end)

    tl
    |> Enum.map(fn e ->
      Map.merge(e, %{
        yield_1: house_flock_yield(l, e.house_no, e.flock_no, dt, -1),
        yield_2: house_flock_yield(l, e.house_no, e.flock_no, dt, -2),
        yield_3: house_flock_yield(l, e.house_no, e.flock_no, dt, -3),
        yield_4: house_flock_yield(l, e.house_no, e.flock_no, dt, -4),
        yield_5: house_flock_yield(l, e.house_no, e.flock_no, dt, -5),
        yield_6: house_flock_yield(l, e.house_no, e.flock_no, dt, -6),
        yield_7: house_flock_yield(l, e.house_no, e.flock_no, dt, -7)
      })
    end)
  end

  defp house_flock_yield(l, hou, flo, dt, day) do
    dt =
      dt |> Timex.shift(days: day)

    a = l |> Enum.find(fn e -> e.house_no == hou and e.flock_no == flo and e.gdate == dt end)
    if a, do: a.prod / a.cur_qty, else: 0
  end

  def get_house_info_at(dt, h_no, com_id) do
    (house_info_query(dt, com_id) <> " and h.house_no = '#{h_no}'") |> exec_query() |> Enum.at(0)
  end

  def house_index(terms, com_id, page: page, per_page: per_page) do
    (house_info_query(Timex.today(), com_id) <>
       " order by COALESCE(WORD_SIMILARITY('#{terms}', h.house_no), 0) +" <>
       " COALESCE(WORD_SIMILARITY('#{terms}', info.flock_no), 0) desc, h.house_no" <>
       " limit #{per_page} offset #{(page - 1) * per_page}")
    |> exec_query()
  end

  defp house_info_query(dt, com_id) do
    "WITH
       mv_qty as (
         select h.id as house_id, f.id as flock_id, h.house_no, f.flock_no,
                h.capacity,
                max(m.move_date) as info_date, sum(m.quantity) as qty
           from movements m inner join houses h
             on h.id = m.house_id inner join flocks f
             on f.id = m.flock_id
          where m.company_id = '#{com_id}'
            and m.move_date <= '#{dt}'
          group by h.id, f.id),
       dea_qty as (
         select h2.id as house_id, f2.id as flock_id, h2.house_no, f2.flock_no,
                max(h.har_date) as info_date, sum(hd.dea_1) + sum(hd.dea_2) as qty,
                h2.capacity
           from harvests h inner join harvest_details hd
             on hd.harvest_id = h.id inner join houses h2
             on hd.house_id = h2.id inner join flocks f2
             on hd.flock_id = f2.id
          where h2.company_id = '#{com_id}'
            and h.har_date <= '#{dt}'
          group by h2.id, f2.id),
       sum_qty as (
         select m.house_id, m.flock_id, m.house_no, m.flock_no,
                (select max(x) from unnest(array[m.info_date, coalesce(d.info_date, m.info_date)]) as x) as info_date,
                (m.qty - coalesce(d.qty, 0)) as qty
           from mv_qty m left outer join dea_qty d
             on d.house_id = m.house_id
            and d.flock_id = m.flock_id
          where (m.qty - coalesce(d.qty, 0)) > 0
            and date_part('day', '#{dt}'::timestamp -
                          (select max(x) from unnest(array[m.info_date, coalesce(d.info_date, m.info_date)]) as x)::timestamp) < 60
         )

     select h.id, h.house_no, info.flock_id, h.capacity, info.flock_no,
            coalesce(info.qty, 0) as qty, info.info_date
       from houses h
       left join sum_qty info
         on info.house_id = h.id
      where true"
  end

  def get_flock!(id, com) do
    from(flk in Flock,
      preload: [movements: ^flock_movements()],
      where: flk.id == ^id,
      where: flk.company_id == ^com.id
    )
    |> Repo.one!()
  end

  def get_house!(id, com) do
    from(hou in House,
      preload: [:house_harvest_wages],
      where: hou.id == ^id,
      where: hou.company_id == ^com.id
    )
    |> Repo.one!()
  end

  def get_harvest!(id, com) do
    from(obj in Harvest,
      join: emp in FullCircle.HR.Employee,
      on: emp.id == obj.employee_id,
      preload: [harvest_details: ^harvest_details()],
      where: obj.company_id == ^com.id,
      where: obj.id == ^id,
      select: obj,
      select_merge: %{employee_name: emp.name}
    )
    |> Repo.one()
  end

  defp harvest_details() do
    from(hd in HarvestDetail,
      join: h in House,
      on: h.id == hd.house_id,
      join: f in Flock,
      on: f.id == hd.flock_id,
      select: hd,
      select_merge: %{house_no: h.house_no, flock_no: f.flock_no}
    )
  end

  defp flock_movements() do
    from(m in Movement,
      join: h in House,
      on: h.id == m.house_id,
      select: m,
      select_merge: %{house_no: h.house_no},
      order_by: [m.move_date, m.quantity]
    )
  end

  def get_house_by_no(no, com, _user) do
    no = no |> String.trim()

    from(hou in House,
      where: hou.company_id == ^com.id,
      where: hou.house_no == ^no,
      select: %{
        id: hou.id,
        value: hou.house_no
      },
      order_by: hou.house_no
    )
    |> Repo.one()
  end

  def get_harvest_by_no(no, com, _user) do
    no = no |> String.trim()

    from(obj in Harvest,
      where: obj.company_id == ^com.id,
      where: obj.harvest_no == ^no,
      select: %{
        id: obj.id,
        value: obj.harvest_no
      },
      order_by: obj.harvest_no
    )
    |> Repo.one()
  end

  def get_flock_by_no(no, com, _user) do
    no = no |> String.trim()

    from(obj in Flock,
      where: obj.company_id == ^com.id,
      where: obj.flock_no == ^no,
      select: %{
        id: obj.id,
        value: obj.flock_no
      },
      order_by: obj.flock_no
    )
    |> Repo.one()
  end

  def houses_no(terms, com, _user) do
    from(hou in House,
      where: hou.company_id == ^com.id,
      where: ilike(hou.house_no, ^"%#{terms}%"),
      select: %{
        id: hou.id,
        value: hou.house_no
      },
      order_by: hou.house_no
    )
    |> Repo.all()
  end
end