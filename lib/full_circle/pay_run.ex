defmodule FullCircle.PayRun do
  import Ecto.Query, warn: false

  alias FullCircle.{Repo}
  alias FullCircle.Sys.Company
  alias FullCircle.HR.{Employee, SalaryNote, SalaryType}

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
    pay_month_year_list =
      -2..0
      |> Enum.map(fn x ->
        Timex.end_of_month(year, month)
        |> Timex.shift(months: x)
      end)
      |> Enum.map(fn x ->
        "select #{x.month} as pay_month, #{x.year} as pay_year"
      end)
      |> Enum.join(" union ")

    "select el0.employee_id as id, el0.name as employee_name,
            array_agg(coalesce(p5.slip_no, '') || '|' || coalesce(p5.id::varchar, '') || '|' ||
                      el0.pay_year::varchar || '|' || el0.pay_month::varchar order by el0.pay_year desc, el0.pay_month desc) as pay_list
       from (select e0.id as employee_id, e0.name, c1.id as company_id, l0.pay_month, l0.pay_year
               from employees as e0 inner join companies as c1 on c1.id = '#{com.id}'
                and e0.status = 'Active', (#{pay_month_year_list}) as l0) as el0
       left outer join pay_slips as p5 on p5.employee_id = el0.employee_id
        and p5.company_id = el0.company_id and p5.pay_month = el0.pay_month
        and p5.pay_year = el0.pay_year group by el0.employee_id, el0.name
      order by el0.name" |> FullCircle.HR.exec_query() |> unzip_pay_lists()
  end

  defp unzip_pay_lists(lists) do
    Enum.map(lists, fn x -> Map.merge(x, %{pay_list: unzip_pay_list(x.pay_list)}) end)
  end

  defp unzip_pay_list(list) do
    Enum.map(list, fn x -> unzip_pay_list_string(x) end)
  end

  defp unzip_pay_list_string(str) do
    [ps, ps_id, yr, mth] = str |> String.split("|")

    {if(ps == "", do: nil, else: ps), if(ps_id == "", do: nil, else: ps_id),
     String.to_integer(yr), String.to_integer(mth)}
  end
end
