INSERT INTO public.time_attendences
  (id, employee_id, user_id, company_id, flag, input_medium, punch_time, shift_id, status, inserted_at, updated_at)
  select
    gen_random_uuid(),
    e.id,
    'ebc7770b-940f-47a1-82d5-d38ea5c80eb3',
    '66abd687-cfb8-47a7-827d-f8c39b2f8df5',
    it1.flag,
    'WebCamT',
    it1.punch_time,
    substring(it1.punch_time::varchar, 1, 10) || '-A',
    'normal', now(), now()
  from
    employees e,
    (
    select
      'IN' as flag,
      (generate_series::date || ' ' || '8:' || (random() * 30)::integer::varchar || ' +08')::timestamptz as punch_time
    from
      generate_series('2020-01-01',
      '2023-10-31',
      interval '1 day') union all
      select
      'OUT' as flag,
      (generate_series::date || ' ' || '12:' || (random() * 30)::integer::varchar || ' +08')::timestamptz as punch_time
    from
      generate_series('2020-01-01',
      '2023-10-31',
      interval '1 day') union all
      select
      'IN' as flag,
      (generate_series::date || ' ' || '13:' || (random() * 30)::integer::varchar || ' +08')::timestamptz as punch_time
    from
      generate_series('2020-01-01',
      '2023-10-31',
      interval '1 day') union all
      select
      'OUT' as flag,
      (generate_series::date || ' ' || '17:' || (random() * 30)::integer::varchar || ' +08')::timestamptz as punch_time
    from
      generate_series('2020-01-01',
      '2023-10-31',
      interval '1 day')

      ) it1
      where e.status = 'Active'


with
      d1 as (select dd::date, e.name, e.id, e.status, e.id_no from employees e,
                    generate_series('2023-10-11'::date, '2023-10-12'::date, '1 day') as dd),
      d2 as (select d1.dd, d1.name, d1.id, d1.status, d1.id_no,
                    string_agg(hl.name, ', ' order by hl.name) as holi_list,
                    string_agg(hl.short_name, ', ' order by hl.short_name) as sholi_list
               from d1 left outer join holidays hl
                 on hl.holidate = d1.dd
              group by d1.dd, d1.name, d1.id, d1.status, d1.id_no),
      p2 as (select ta.employee_id, ta.shift_id as shift, min(ta.punch_time)::date as pt, min(ta.punch_time) as punch_time,
                    array_agg(ta.punch_time::varchar || '|' || ta.id::varchar || '|' || ta.status || '|' || ta.flag order by ta.punch_time) time_list
              from time_attendences ta
             where ta.company_id = '66abd687-cfb8-47a7-827d-f8c39b2f8df5'
             group by ta.employee_id, ta.shift_id)

   select d2.id::varchar || d2.dd::varchar as idg, d2.dd, d2.name,
          d2.id as employee_id, p2.shift, p2.time_list,
          holi_list, sholi_list
     from d2 left outer join p2
       on p2.pt = d2.dd
      and d2.id = p2.employee_id
    where d2.status = 'Active' and d2.dd >= '2023-10-11' and d2.dd <= '2023-10-12' order by d2.name, d2.dd, p2.shift limit 60 offset (3 - 1) * 60



    