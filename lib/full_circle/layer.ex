defmodule FullCircle.Layer do
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.{Repo}
  alias FullCircle.Layer.{House, Flock, Movement, Harvest, HarvestDetail, HouseHarvestWage}

  def house_feed_type(month, year, com_id) do
    fd = Date.new!(String.to_integer(year), String.to_integer(month), 1)
    td = Date.end_of_month(fd)

    """
    with
    datelist as (
         select generate_series('#{fd}'::date, '#{td}', interval '1 day')::date gdate),
      mv_qty as (
          select dl.gdate as info_date, h.id as house_id, f.id as flock_id, h.house_no, f.flock_no, f.dob, h.capacity,
                 sum(m.quantity) as qty
            from datelist dl, movements m inner join houses h
              on h.id = m.house_id inner join flocks f
              on f.id = m.flock_id
           where m.company_id = '#{com_id}'
             and h.status = 'Active'
             and m.move_date <= dl.gdate
           group by dl.gdate, h.id, f.id),
      dea_qty as (
          select dl.gdate as info_date, h2.id as house_id, f2.id as flock_id, h2.house_no, f2.flock_no, f2.dob,
                 sum(hd.dea_1) + sum(hd.dea_2) as qty, h2.capacity
            from datelist dl, harvests h inner join harvest_details hd
              on hd.harvest_id = h.id inner join houses h2
              on hd.house_id = h2.id inner join flocks f2
              on hd.flock_id = f2.id
           where h2.company_id = '#{com_id}'
             and h2.status = 'Active'
             and dl.gdate >= h.har_date
           group by dl.gdate, h2.id, f2.id),
         sum_qty as (
          select m.info_date, m.house_id, m.flock_id, m.house_no, m.flock_no, m.dob, m.qty - coalesce(d.qty, 0) as qty
            from mv_qty m left outer join dea_qty d
              on d.house_id = m.house_id
             and d.flock_id = m.flock_id
             and d.info_date = m.info_date
           where m.qty - coalesce(d.qty, 0) > 0),
    house_date_feed_0 as (
            select info.info_date, house_no, (date_part('day', info.info_date::timestamp - info.dob::timestamp)/7)::integer as age, info.qty as cur_qty
              from sum_qty info),
    house_date_feed as (
            select info_date, house_no, age, cur_qty,
                   case when age >= 0 and age <=  5 and cur_qty > 0 then 'A1'
                        when age >  5 and age <= 10 and cur_qty > 0 then 'A1'
                        when age > 10 and age <= 16 and cur_qty > 0 then 'A3'
                        when age > 16 and age <= 20 and cur_qty > 0 then 'A3'
                        when age > 20 and age <= 48 and cur_qty > 0 then 'A5'
                        when age > 48 and age <= 70 and cur_qty > 0 then 'A6'
                        when age > 70 and age <= 80 and cur_qty > 0 then 'A7'
                        when age > 80 and cur_qty > 0 then 'A8'
                        else 'NO' end as feed_type
              from house_date_feed_0 where age <= 120)

      select cur.house_no as hou,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 1 and hdf.house_no = cur.house_no) as D1,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 2 and hdf.house_no = cur.house_no) as D2,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 3 and hdf.house_no = cur.house_no) as D3,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 4 and hdf.house_no = cur.house_no) as D4,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 5 and hdf.house_no = cur.house_no) as D5,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 6 and hdf.house_no = cur.house_no) as D6,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 7 and hdf.house_no = cur.house_no) as D7,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 8 and hdf.house_no = cur.house_no) as D8,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 9 and hdf.house_no = cur.house_no) as D9,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 10 and hdf.house_no = cur.house_no) as D10,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 11 and hdf.house_no = cur.house_no) as D11,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 12 and hdf.house_no = cur.house_no) as D12,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 13 and hdf.house_no = cur.house_no) as D13,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 14 and hdf.house_no = cur.house_no) as D14,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 15 and hdf.house_no = cur.house_no) as D15,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 16 and hdf.house_no = cur.house_no) as D16,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 17 and hdf.house_no = cur.house_no) as D17,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 18 and hdf.house_no = cur.house_no) as D18,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 19 and hdf.house_no = cur.house_no) as D19,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 20 and hdf.house_no = cur.house_no) as D20,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 21 and hdf.house_no = cur.house_no) as D21,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 22 and hdf.house_no = cur.house_no) as D22,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 23 and hdf.house_no = cur.house_no) as D23,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 24 and hdf.house_no = cur.house_no) as D24,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 25 and hdf.house_no = cur.house_no) as D25,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 26 and hdf.house_no = cur.house_no) as D26,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 27 and hdf.house_no = cur.house_no) as D27,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 28 and hdf.house_no = cur.house_no) as D28,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 29 and hdf.house_no = cur.house_no) as D29,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 30 and hdf.house_no = cur.house_no) as D30,
            (select hdf.feed_type from house_date_feed hdf where extract(day from hdf.info_date) = 31 and hdf.house_no = cur.house_no) as D31
      from house_date_feed cur
      group by cur.house_no
      order by 1
    """
    |> exec_query_row_col()
  end

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
        where (date_part('day', dl.gdate::timestamp - f.dob::timestamp)/7)::integer < 110
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
    |> exec_query_map()
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
    (house_info_query(dt, com_id) <> " and h.house_no = '#{h_no}'")
    |> exec_query_map()
    |> Enum.at(0)
  end

  def house_index(terms, com_id, page: page, per_page: per_page) do
    (house_info_query(Timex.today(), com_id) <>
       " order by COALESCE(WORD_SIMILARITY('#{terms}', h.house_no), 0) +" <>
       " COALESCE(WORD_SIMILARITY('#{terms}', info.flock_no), 0) +" <>
       " COALESCE(WORD_SIMILARITY('#{terms}', h.status), 0) desc, h.house_no" <>
       " limit #{per_page} offset #{(page - 1) * per_page}")
    |> exec_query_map()
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

     select h.id, h.house_no, info.flock_id, h.capacity, info.flock_no, h.filling_wages, h.feeding_wages, h.status,
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
