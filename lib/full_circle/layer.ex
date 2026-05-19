defmodule FullCircle.Layer do
  import Ecto.Query, warn: false
  import FullCircle.Helpers

  alias FullCircle.{Repo}
  alias FullCircle.Layer.{House, Flock, Movement, Harvest, HarvestDetail, HouseHarvestWage}

  def house_feed_type_query(
        month,
        year,
        com_id,
        feed_str \\ "0-5=A1, 5-10=A2, 10-16=A3, 16-20=A4, 20-48=A5, 48-70=A6, 70-80=A7, 80-200=A8",
        field \\ "feed_type"
      ) do
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
      select info.info_date, info.house_no, info.house_id, (date_part('day', info.info_date::timestamp - info.dob::timestamp)/7)::integer as age,
             info.qty as cur_qty
        from sum_qty info),
    house_date as (
      select dl.gdate as info_date, h.house_no, h.id as house_id, 0 as age, 0 as cur_qty from houses h, datelist dl
       where h.id not in (select distinct house_id from house_date_feed_0 where age <= 120)
         and h.status = 'Active'),
    house_date_feed_1 as (select * from house_date_feed_0 where age <= 120 union all select * from house_date),
    house_date_feed as (
        select info_date, hdf1.house_no, age, cur_qty,
               case #{feed_type_age(feed_str)},
               h.filling_wages, h.feeding_wages
          from house_date_feed_1 hdf1 inner join houses h on h.id = hdf1.house_id)

      select cur.house_no as hou,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 1 and hdf.house_no = cur.house_no) as D1,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 2 and hdf.house_no = cur.house_no) as D2,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 3 and hdf.house_no = cur.house_no) as D3,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 4 and hdf.house_no = cur.house_no) as D4,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 5 and hdf.house_no = cur.house_no) as D5,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 6 and hdf.house_no = cur.house_no) as D6,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 7 and hdf.house_no = cur.house_no) as D7,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 8 and hdf.house_no = cur.house_no) as D8,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 9 and hdf.house_no = cur.house_no) as D9,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 10 and hdf.house_no = cur.house_no) as D10,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 11 and hdf.house_no = cur.house_no) as D11,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 12 and hdf.house_no = cur.house_no) as D12,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 13 and hdf.house_no = cur.house_no) as D13,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 14 and hdf.house_no = cur.house_no) as D14,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 15 and hdf.house_no = cur.house_no) as D15,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 16 and hdf.house_no = cur.house_no) as D16,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 17 and hdf.house_no = cur.house_no) as D17,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 18 and hdf.house_no = cur.house_no) as D18,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 19 and hdf.house_no = cur.house_no) as D19,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 20 and hdf.house_no = cur.house_no) as D20,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 21 and hdf.house_no = cur.house_no) as D21,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 22 and hdf.house_no = cur.house_no) as D22,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 23 and hdf.house_no = cur.house_no) as D23,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 24 and hdf.house_no = cur.house_no) as D24,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 25 and hdf.house_no = cur.house_no) as D25,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 26 and hdf.house_no = cur.house_no) as D26,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 27 and hdf.house_no = cur.house_no) as D27,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 28 and hdf.house_no = cur.house_no) as D28,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 29 and hdf.house_no = cur.house_no) as D29,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 30 and hdf.house_no = cur.house_no) as D30,
            (select hdf.#{field} from house_date_feed hdf where extract(day from hdf.info_date) = 31 and hdf.house_no = cur.house_no) as D31
      from house_date_feed cur
      group by cur.house_no
      order by 1
    """
  end

  defp feed_type_age(age_feeds) do
    r =
      Regex.scan(~r/(\d|\d+)-(\d|\d+)=(\w+)/, age_feeds)
      |> Enum.map_join(" ", fn [_, l, h, f] ->
        "when age > #{l} and age <= #{h} and cur_qty > 0 then '#{f}'"
      end)

    "#{r} else '' end as feed_type"
  end

  @default_feed_good_names ~w(A1 A2 A3 A4 A5 A6 A7)

  @grade_weights_g %{
    "AA" => 72.5,
    "A" => 67.5,
    "B" => 62.5,
    "C" => 57.5,
    "D" => 52.5,
    "E" => 47.5,
    "F" => 42.5
  }

  @avg_fallback_weight_g 55.0

  def default_feed_good_names, do: @default_feed_good_names

  def feed_egg_report(fd, td, com_id, group_days \\ 1, feed_names \\ @default_feed_good_names) do
    fd = to_date(fd)
    td = to_date(td)
    group_days = max(group_days, 1)
    feed_names = normalize_feed_names(feed_names)

    feeds =
      from(w in FullCircle.WeightBridge.Weighing,
        where: w.company_id == ^com_id,
        where: w.note_date >= ^fd,
        where: w.note_date <= ^td,
        where: w.good_name in ^feed_names,
        group_by: w.note_date,
        select: %{date: w.note_date, feed_kg: sum(w.gross - w.tare)}
      )
      |> Repo.all()
      |> Map.new(fn r -> {r.date, r.feed_kg || 0} end)

    eggs =
      from(hv in Harvest,
        join: hd in HarvestDetail,
        on: hd.harvest_id == hv.id,
        where: hv.company_id == ^com_id,
        where: hv.har_date >= ^fd,
        where: hv.har_date <= ^td,
        group_by: hv.har_date,
        select: %{date: hv.har_date, trays: sum(hd.har_1 + hd.har_2 + hd.har_3)}
      )
      |> Repo.all()
      |> Map.new(fn r -> {r.date, r.trays || 0} end)

    graded_grades_by_date =
      FullCircle.EggStock.production_report(com_id, fd, td)
      |> Map.new(fn row ->
        grade_map = Map.new(row.quantities, fn {g, v} -> {g, parse_int(v)} end)
        {row.date, grade_map}
      end)

    expired_grades_by_date =
      from(d in FullCircle.EggStock.EggStockDay,
        where: d.company_id == ^com_id,
        where: d.stock_date >= ^fd and d.stock_date <= ^td,
        select: {d.stock_date, d.expired}
      )
      |> Repo.all()
      |> Map.new(fn {date, expired_map} ->
        grade_map =
          (expired_map || %{})
          |> Map.new(fn {g, v} -> {g, parse_int(v)} end)

        {date, grade_map}
      end)

    rows =
      fd
      |> bucket_starts(td, group_days)
      |> Enum.map(fn bstart ->
        bend = Date.add(bstart, group_days - 1) |> min_date(td)
        days_in_bucket = Date.diff(bend, bstart) + 1
        days = Date.range(bstart, bend)

        bucket_feed_kg =
          Enum.reduce(days, 0, fn d, acc -> acc + Map.get(feeds, d, 0) end)

        bucket_trays =
          Enum.reduce(days, 0, fn d, acc -> acc + Map.get(eggs, d, 0) end)

        graded_grades =
          Enum.reduce(days, %{}, fn d, acc ->
            sum_grade_maps(acc, Map.get(graded_grades_by_date, d, %{}))
          end)

        expired_grades =
          Enum.reduce(days, %{}, fn d, acc ->
            sum_grade_maps(acc, Map.get(expired_grades_by_date, d, %{}))
          end)

        bucket_graded_trays = sum_map_values(graded_grades)
        bucket_expired_trays = sum_map_values(expired_grades)

        eggs_count = bucket_trays * 30
        graded_eggs = bucket_graded_trays * 30
        expired_eggs = bucket_expired_trays * 30
        net_eggs = graded_eggs - expired_eggs
        net_trays = bucket_graded_trays - bucket_expired_trays

        graded_mass_kg = egg_mass_kg(graded_grades)
        expired_mass_kg = egg_mass_kg(expired_grades)
        net_mass_kg = graded_mass_kg - expired_mass_kg

        feed_tons = bucket_feed_kg / 1000
        fcr = if graded_mass_kg > 0, do: bucket_feed_kg / graded_mass_kg, else: 0
        fcr_net = if net_mass_kg > 0, do: bucket_feed_kg / net_mass_kg, else: 0
        eggs_per_ton_gross = if feed_tons > 0, do: eggs_count / feed_tons, else: 0
        eggs_per_ton_net = if feed_tons > 0, do: net_eggs / feed_tons, else: 0

        %{
          from_date: bstart,
          to_date: bend,
          days: days_in_bucket,
          feed_kg: bucket_feed_kg,
          feed_tons: feed_tons,
          trays: bucket_trays,
          eggs: eggs_count,
          graded_trays: bucket_graded_trays,
          graded_eggs: graded_eggs,
          graded_mass_kg: graded_mass_kg,
          expired_trays: bucket_expired_trays,
          expired_eggs: expired_eggs,
          expired_mass_kg: expired_mass_kg,
          net_eggs: net_eggs,
          net_trays: net_trays,
          net_mass_kg: net_mass_kg,
          fcr: fcr,
          fcr_net: fcr_net,
          eggs_per_ton_gross: eggs_per_ton_gross,
          eggs_per_ton_net: eggs_per_ton_net
        }
      end)

    total_feed_kg = Enum.reduce(rows, 0, &(&1.feed_kg + &2))
    total_trays = Enum.reduce(rows, 0, &(&1.trays + &2))
    total_graded_trays = Enum.reduce(rows, 0, &(&1.graded_trays + &2))
    total_expired_trays = Enum.reduce(rows, 0, &(&1.expired_trays + &2))
    total_days = Enum.reduce(rows, 0, &(&1.days + &2))
    total_eggs = total_trays * 30
    total_graded_eggs = total_graded_trays * 30
    total_expired_eggs = total_expired_trays * 30
    total_net_eggs = total_graded_eggs - total_expired_eggs
    total_net_trays = total_graded_trays - total_expired_trays
    total_feed_tons = total_feed_kg / 1000

    total_graded_grades =
      Enum.reduce(graded_grades_by_date, %{}, fn {_d, m}, acc -> sum_grade_maps(acc, m) end)

    total_expired_grades =
      Enum.reduce(expired_grades_by_date, %{}, fn {_d, m}, acc -> sum_grade_maps(acc, m) end)

    total_graded_mass_kg = egg_mass_kg(total_graded_grades)
    total_expired_mass_kg = egg_mass_kg(total_expired_grades)
    total_net_mass_kg = total_graded_mass_kg - total_expired_mass_kg

    total_fcr = if total_graded_mass_kg > 0, do: total_feed_kg / total_graded_mass_kg, else: 0
    total_fcr_net = if total_net_mass_kg > 0, do: total_feed_kg / total_net_mass_kg, else: 0

    total_eggs_per_ton_gross =
      if total_feed_tons > 0, do: total_eggs / total_feed_tons, else: 0

    total_eggs_per_ton_net =
      if total_feed_tons > 0, do: total_net_eggs / total_feed_tons, else: 0

    %{
      rows: rows,
      total: %{
        days: total_days,
        feed_kg: total_feed_kg,
        feed_tons: total_feed_tons,
        trays: total_trays,
        graded_mass_kg: total_graded_mass_kg,
        expired_mass_kg: total_expired_mass_kg,
        net_mass_kg: total_net_mass_kg,
        fcr: total_fcr,
        fcr_net: total_fcr_net,
        eggs_per_ton_gross: total_eggs_per_ton_gross,
        eggs_per_ton_net: total_eggs_per_ton_net,
        eggs: total_eggs,
        graded_trays: total_graded_trays,
        graded_eggs: total_graded_eggs,
        expired_trays: total_expired_trays,
        expired_eggs: total_expired_eggs,
        net_eggs: total_net_eggs,
        net_trays: total_net_trays
      }
    }
  end

  defp sum_grade_maps(a, b) do
    Map.merge(a, b, fn _k, v1, v2 -> v1 + v2 end)
  end

  defp sum_map_values(m) do
    Enum.reduce(m, 0, fn {_k, v}, acc -> acc + v end)
  end

  defp grade_weight_g(grade) do
    key = grade |> to_string() |> String.trim() |> String.upcase()
    Map.get(@grade_weights_g, key)
  end

  defp egg_mass_kg(grade_qty_map_trays) do
    {weighted_eggs, weighted_mass_g, unweighted_eggs} =
      Enum.reduce(grade_qty_map_trays, {0, 0.0, 0}, fn {grade, trays}, {we, wmg, ue} ->
        eggs = parse_int(trays) * 30

        case grade_weight_g(grade) do
          nil -> {we, wmg, ue + eggs}
          w_g -> {we + eggs, wmg + eggs * w_g, ue}
        end
      end)

    avg_weight_g =
      if weighted_eggs > 0, do: weighted_mass_g / weighted_eggs, else: @avg_fallback_weight_g

    total_mass_g = weighted_mass_g + unweighted_eggs * avg_weight_g
    total_mass_g / 1000
  end

  defp parse_int(nil), do: 0
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_float(v), do: round(v)

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  defp bucket_starts(fd, td, group_days) do
    Stream.unfold(fd, fn d ->
      if Date.compare(d, td) == :gt, do: nil, else: {d, Date.add(d, group_days)}
    end)
    |> Enum.to_list()
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)

  defp min_date(a, b), do: if(Date.compare(a, b) == :lt, do: a, else: b)

  defp normalize_feed_names(names) when is_list(names), do: names

  defp normalize_feed_names(names) when is_binary(names) do
    names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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
    sql = """
    WITH
      datelist AS (
        SELECT generate_series($2::date - interval '7 day', $2::date, interval '1 day')::date AS gdate
      ),
      hf AS MATERIALIZED (
        SELECT DISTINCT m.house_id, m.flock_id, hou.house_no, f.flock_no, f.dob
          FROM movements m
         INNER JOIN houses hou ON hou.id = m.house_id
         INNER JOIN flocks f ON f.id = m.flock_id
         WHERE m.company_id = $1
      ),
      total_dea AS MATERIALIZED (
        SELECT hd.house_id, hd.flock_id, sum(hd.dea_1 + hd.dea_2) AS total_dea
          FROM harvest_details hd
         INNER JOIN harvests h ON h.id = hd.harvest_id
         WHERE h.company_id = $1 AND h.har_date < $2::date
         GROUP BY hd.house_id, hd.flock_id
      ),
      recent_dea_by_day AS MATERIALIZED (
        SELECT hd.house_id, hd.flock_id, h.har_date, sum(hd.dea_1 + hd.dea_2) AS dea
          FROM harvest_details hd
         INNER JOIN harvests h ON h.id = hd.harvest_id
         WHERE h.company_id = $1
           AND h.har_date >= $2::date - interval '7 day'
           AND h.har_date < $2::date
         GROUP BY hd.house_id, hd.flock_id, h.har_date
      ),
      deaths_cum AS (
        SELECT hf.house_id, hf.flock_id, dl.gdate,
               coalesce(td.total_dea, 0)
                 - coalesce(sum(rd.dea) FILTER (WHERE rd.har_date >= dl.gdate AND rd.har_date < $2::date), 0) AS cum_dea
          FROM hf
          CROSS JOIN datelist dl
          LEFT JOIN total_dea td ON td.house_id = hf.house_id AND td.flock_id = hf.flock_id
          LEFT JOIN recent_dea_by_day rd ON rd.house_id = hf.house_id AND rd.flock_id = hf.flock_id
         GROUP BY hf.house_id, hf.flock_id, dl.gdate, td.total_dea
      ),
      mv_cum AS MATERIALIZED (
        SELECT m.house_id, m.flock_id, dl.gdate, sum(m.quantity) AS total_qty
          FROM movements m, datelist dl
         WHERE m.company_id = $1 AND m.move_date <= dl.gdate
         GROUP BY m.house_id, m.flock_id, dl.gdate
      ),
      today_harvest AS MATERIALIZED (
        SELECT hd.house_id, hd.flock_id, h.har_date, h.employee_id,
               sum(hd.har_1 + hd.har_2 + hd.har_3) AS har,
               sum(hd.dea_1 + hd.dea_2) AS dea
          FROM harvest_details hd
         INNER JOIN harvests h ON h.id = hd.harvest_id
         WHERE h.company_id = $1
           AND h.har_date BETWEEN $2::date - interval '7 day' AND $2::date
         GROUP BY hd.house_id, hd.flock_id, h.har_date, h.employee_id
      )
    SELECT dl.gdate, hf.house_id, hf.flock_id, hf.house_no, hf.flock_no,
           (date_part('day', dl.gdate::timestamp - hf.dob::timestamp)/7)::integer AS age,
           (mv.total_qty - COALESCE(dc.cum_dea, 0))::bigint AS cur_qty,
           (COALESCE(sum(th.har), 0) * 30)::bigint AS prod,
           COALESCE(sum(th.dea), 0)::bigint AS dea,
           string_agg(DISTINCT e.name, ', ') AS employee
      FROM hf
      CROSS JOIN datelist dl
      INNER JOIN mv_cum mv ON mv.house_id = hf.house_id AND mv.flock_id = hf.flock_id AND mv.gdate = dl.gdate
      LEFT JOIN deaths_cum dc ON dc.house_id = hf.house_id AND dc.flock_id = hf.flock_id AND dc.gdate = dl.gdate
      LEFT JOIN today_harvest th ON th.house_id = hf.house_id AND th.flock_id = hf.flock_id AND th.har_date = dl.gdate
      LEFT JOIN employees e ON e.id = th.employee_id
     WHERE (mv.total_qty - COALESCE(dc.cum_dea, 0)) > 0
       AND (date_part('day', dl.gdate::timestamp - hf.dob::timestamp)/7)::integer BETWEEN 14 AND 109
     GROUP BY dl.gdate, hf.house_id, hf.flock_id, hf.house_no, hf.flock_no, hf.dob, mv.total_qty, dc.cum_dea
    """

    exec_query_map(sql, [dump_uuid!(com_id), to_date!(dt)], FullCircle.Repo)
    |> format_harvest_report(to_date!(dt))
  end

  @valid_sort_fields ~w(house_no employee age prod dea yield_0 yield_1 yield_2 yield_3 yield_4 yield_5 yield_6 yield_7)a

  def sort_harvest_report(rows, sort_by, sort_dir) do
    {field, dir} = normalize_sort(sort_by, sort_dir)
    Enum.sort_by(rows, &Map.get(&1, field), dir)
  end

  defp normalize_sort(sort_by, sort_dir) do
    field =
      case sort_by do
        atom when is_atom(atom) -> if atom in @valid_sort_fields, do: atom, else: :house_no
        bin when is_binary(bin) ->
          try do
            atom = String.to_existing_atom(bin)
            if atom in @valid_sort_fields, do: atom, else: :house_no
          rescue
            ArgumentError -> :house_no
          end
        _ -> :house_no
      end

    dir =
      case sort_dir do
        :asc -> :asc
        :desc -> :desc
        "asc" -> :asc
        "desc" -> :desc
        _ -> :asc
      end

    {field, dir}
  end

  def harvest_detail_for(house_id, flock_id, end_date, com_id, days \\ 14) do
    end_date = to_date!(end_date)
    start_date = Date.add(end_date, -days)

    sql = """
    SELECT h.har_date, h.harvest_no, e.name AS employee,
           coalesce(sum(hd.har_1), 0)::bigint AS har_1,
           coalesce(sum(hd.har_2), 0)::bigint AS har_2,
           coalesce(sum(hd.har_3), 0)::bigint AS har_3,
           coalesce(sum(hd.dea_1), 0)::bigint AS dea_1,
           coalesce(sum(hd.dea_2), 0)::bigint AS dea_2,
           coalesce(sum(hd.har_1 + hd.har_2 + hd.har_3), 0)::bigint AS total_har,
           coalesce(sum(hd.dea_1 + hd.dea_2), 0)::bigint AS total_dea
      FROM harvests h
     INNER JOIN harvest_details hd ON hd.harvest_id = h.id
     INNER JOIN employees e ON e.id = h.employee_id
     WHERE h.company_id = $1
       AND hd.house_id = $2
       AND hd.flock_id = $3
       AND h.har_date >= $4
       AND h.har_date <= $5
     GROUP BY h.har_date, h.harvest_no, e.name
     ORDER BY h.har_date DESC, e.name
    """

    exec_query_map(
      sql,
      [
        dump_uuid!(com_id),
        dump_uuid!(house_id),
        dump_uuid!(flock_id),
        start_date,
        end_date
      ],
      FullCircle.Repo
    )
  end

  defp format_harvest_report(l, dt) do
    yields = Map.new(l, fn e -> {{e.house_no, e.flock_no, e.gdate}, e.prod / e.cur_qty} end)

    l
    |> Enum.filter(fn e -> e.gdate == dt end)
    |> Enum.map(fn e ->
      Map.merge(e, %{
        id: e.house_no,
        yield_0: e.prod / e.cur_qty,
        yield_1: shifted_yield(yields, e.house_no, e.flock_no, dt, -1),
        yield_2: shifted_yield(yields, e.house_no, e.flock_no, dt, -2),
        yield_3: shifted_yield(yields, e.house_no, e.flock_no, dt, -3),
        yield_4: shifted_yield(yields, e.house_no, e.flock_no, dt, -4),
        yield_5: shifted_yield(yields, e.house_no, e.flock_no, dt, -5),
        yield_6: shifted_yield(yields, e.house_no, e.flock_no, dt, -6),
        yield_7: shifted_yield(yields, e.house_no, e.flock_no, dt, -7)
      })
    end)
  end

  defp shifted_yield(yields, hou, flo, dt, day) do
    Map.get(yields, {hou, flo, Timex.shift(dt, days: day)}, 0)
  end

  defp to_date!(%Date{} = d), do: d
  defp to_date!(d) when is_binary(d), do: Date.from_iso8601!(d)

  defp dump_uuid!(<<_::binary-size(16)>> = bin), do: bin

  defp dump_uuid!(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, bin} -> bin
      :error -> raise ArgumentError, "invalid UUID: #{inspect(uuid)}"
    end
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
                          (select max(x) from unnest(array[m.info_date, coalesce(d.info_date, m.info_date)]) as x)::timestamp) < 75
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
