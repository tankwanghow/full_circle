defmodule FullCircle.PayRun do
  import Ecto.Query, warn: false

  alias FullCircle.{Repo, Helpers}
  alias FullCircle.Sys.Company
  alias FullCircle.HR.{Employee, SalaryNote, SalaryType}

  @doc """
  Classifies a month cell for an employee: :done (slip exists),
  :pending (active or has unprocessed items, no slip), or :na
  (resigned with no slip and nothing pending).
  """
  def cell_state(status, pay) do
    cond do
      not is_nil(pay.slip_no) -> :done
      status == "Active" or pay.unproc_note_count > 0 or pay.unproc_adv_count > 0 -> :pending
      true -> :na
    end
  end

  @doc """
  Per-month summary across all rows: `%{{year, month} => %{done, pending, payroll}}`.
  `payroll` sums net pay over done cells; `pending` counts cells in :pending state.
  """
  def pay_run_totals(objects) do
    objects
    |> Enum.flat_map(fn o -> Enum.map(o.pay_list, fn p -> {o.status, p} end) end)
    |> Enum.group_by(fn {_status, p} -> {p.year, p.month} end)
    |> Map.new(fn {ym, pairs} ->
      states = Enum.map(pairs, fn {status, p} -> {cell_state(status, p), p} end)
      done = Enum.count(states, fn {s, _} -> s == :done end)
      pending = Enum.count(states, fn {s, _} -> s == :pending end)

      payroll =
        states
        |> Enum.filter(fn {s, _} -> s == :done end)
        |> Enum.reduce(Decimal.new(0), fn {_s, p}, acc -> Decimal.add(acc, p.net_pay) end)

      {ym, %{done: done, pending: pending, payroll: payroll}}
    end)
  end

  def employee_leave_summary(emp_id, year, com) do
    from(sn in SalaryNote,
      join: comp in Company,
      on: comp.id == sn.company_id,
      on: comp.id == ^com.id,
      join: st in SalaryType,
      on: sn.salary_type_id == st.id,
      join: emp in Employee,
      on: emp.id == ^emp_id,
      on: emp.id == sn.employee_id,
      where: fragment("extract(year from ?) = ?", sn.note_date, ^year),
      where: st.type == "LeaveTaken",
      select: %{
        name: st.name,
        amount: sum(sn.quantity * sn.unit_price)
      },
      group_by: st.id
    )
    |> Repo.all()
  end

  def pay_run_index(month, year, com) do
    months =
      [-1, 0, 1]
      |> Enum.map(fn x -> Timex.end_of_month(year, month) |> Timex.shift(months: x) end)
      |> Enum.map(fn d -> {d.year, d.month} end)

    months_sql =
      months
      |> Enum.map_join(" union all ", fn {y, m} ->
        "select #{m} as pay_month, #{y} as pay_year"
      end)

    cid = com.id

    """
    with months as (#{months_sql}),
    candidates as (
      select e.id as employee_id, e.name, e.status
        from employees e
       where e.company_id = '#{cid}'
         and (
           e.status = 'Active'
           or exists (select 1 from pay_slips p join months mm
                        on mm.pay_month = p.pay_month and mm.pay_year = p.pay_year
                       where p.employee_id = e.id and p.company_id = e.company_id)
           or exists (select 1 from salary_notes sn join months mm
                        on mm.pay_month = extract(month from sn.note_date)::int
                       and mm.pay_year = extract(year from sn.note_date)::int
                       where sn.employee_id = e.id and sn.company_id = e.company_id)
           or exists (select 1 from advances av join months mm
                        on mm.pay_month = extract(month from av.slip_date)::int
                       and mm.pay_year = extract(year from av.slip_date)::int
                       where av.employee_id = e.id and av.company_id = e.company_id)
         )
    ),
    emp_month as (
      select c.employee_id, c.name, c.status, m.pay_month, m.pay_year
        from candidates c cross join months m
    ),
    -- Pre-aggregate once per source instead of per-cell correlated subqueries
    -- (the original ran 6 seq scans of salary_notes/advances for every cell).
    unproc_notes as (
      select sn.employee_id,
             extract(year from sn.note_date)::int as yr,
             extract(month from sn.note_date)::int as mth,
             count(*) as cnt,
             sum(sn.quantity * sn.unit_price) as amt
        from salary_notes sn
       where sn.company_id = '#{cid}' and sn.pay_slip_id is null
       group by 1, 2, 3
    ),
    unproc_advs as (
      select av.employee_id,
             extract(year from av.slip_date)::int as yr,
             extract(month from av.slip_date)::int as mth,
             count(*) as cnt,
             sum(av.amount) as amt
        from advances av
       where av.company_id = '#{cid}' and av.pay_slip_id is null
       group by 1, 2, 3
    ),
    slip_notes as (
      select sn.pay_slip_id,
             sum(case st.type
                   when 'Addition' then sn.quantity * sn.unit_price
                   when 'Bonus' then sn.quantity * sn.unit_price
                   when 'Deduction' then -(sn.quantity * sn.unit_price)
                   else 0 end) as amt
        from salary_notes sn join salary_types st on st.id = sn.salary_type_id
       where sn.company_id = '#{cid}' and sn.pay_slip_id is not null
       group by sn.pay_slip_id
    ),
    slip_advs as (
      select av.pay_slip_id, sum(av.amount) as amt
        from advances av
       where av.company_id = '#{cid}' and av.pay_slip_id is not null
       group by av.pay_slip_id
    )
    select em.employee_id as id, em.name as employee_name, em.status,
           array_agg(
             coalesce(p.slip_no, '') || '|' || coalesce(p.id::varchar, '') || '|' ||
             em.pay_year::varchar || '|' || em.pay_month::varchar || '|' ||
             (coalesce(sln.amt, 0) - coalesce(sla.amt, 0)) || '|' ||
             coalesce(un.cnt, 0)::varchar || '|' ||
             coalesce(un.amt, 0)::varchar || '|' ||
             coalesce(ua.cnt, 0)::varchar || '|' ||
             coalesce(ua.amt, 0)::varchar
             order by em.pay_year asc, em.pay_month asc
           ) as pay_list
      from emp_month em
      left join pay_slips p
        on p.employee_id = em.employee_id and p.company_id = '#{cid}'
       and p.pay_month = em.pay_month and p.pay_year = em.pay_year
      left join slip_notes sln on sln.pay_slip_id = p.id
      left join slip_advs sla on sla.pay_slip_id = p.id
      left join unproc_notes un
        on un.employee_id = em.employee_id and un.yr = em.pay_year and un.mth = em.pay_month
      left join unproc_advs ua
        on ua.employee_id = em.employee_id and ua.yr = em.pay_year and ua.mth = em.pay_month
     group by em.employee_id, em.name, em.status
     order by em.name
    """
    |> Helpers.exec_query_map()
    |> unzip_pay_lists()
  end

  defp unzip_pay_lists(lists) do
    Enum.map(lists, fn x -> Map.merge(x, %{pay_list: unzip_pay_list(x.pay_list)}) end)
  end

  defp unzip_pay_list(list) do
    Enum.map(list, fn x -> unzip_pay_list_string(x) end)
  end

  defp unzip_pay_list_string(str) do
    [ps, ps_id, yr, mth, net, nc, ns, ac, as] = String.split(str, "|")

    %{
      slip_no: blank_to_nil(ps),
      slip_id: blank_to_nil(ps_id),
      year: String.to_integer(yr),
      month: String.to_integer(mth),
      net_pay: if(ps == "", do: nil, else: Decimal.new(net)),
      unproc_note_count: String.to_integer(nc),
      unproc_note_sum: Decimal.new(ns),
      unproc_adv_count: String.to_integer(ac),
      unproc_adv_sum: Decimal.new(as)
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
