defmodule FullCircle.LegacyStatutory do
  @moduledoc """
  Frozen copies of the original name-matched statutory SQL functions, kept ONLY as the
  golden-parity oracle for the new Elixir formatters. Not used by application code.
  """
  import FullCircle.Helpers, only: [exec_query_row_col: 1]

  def epf_submit_file_format_query(month, year, epf_code, com_id) do
    """
    with step_1 as (
      select epf_no, id_no as ID_NUMBER, emp.name AS NAME, '#{epf_code}' as epf_code,
             (select sum(quantity * unit_price) from salary_notes sn
               inner join salary_types st on sn.salary_type_id = st.id
               where st.type = 'Addition' and sn.company_id = '#{com_id}' and sn.pay_slip_id = ps.id) as WAGES,
             (select quantity * unit_price from salary_notes sn
               inner join salary_types st on sn.salary_type_id = st.id
               where st.name = 'EPF By Employer' and sn.company_id = '#{com_id}' and sn.pay_slip_id = ps.id) as EMPLOYER,
             (select quantity * unit_price from salary_notes sn
               inner join salary_types st on sn.salary_type_id = st.id
               where (st.name = 'EPF By Employee' or st.name = 'EPF Employee Self')
                 and sn.company_id = '#{com_id}' and sn.pay_slip_id = ps.id) as EMPLOYEE
        from pay_slips ps inner join employees emp on emp.id = ps.employee_id
       where ps.pay_month = #{month} and ps.pay_year = #{year} and ps.company_id = '#{com_id}'
       order by name)

    select epf_no, id_number, name, round(wages, 2) as wages, round(employer, 0) as employer, round(employee, 0) as employee
      from step_1 where employer > 0 or employee > 0
    """
    |> exec_query_row_col()
  end

  def socso_submit_file_format_query(month, year, socso_code, com_id) do
    """
    with step_1 as (
      select case when socso_no = '' then id_no when socso_no = '-' then id_no when socso_no is null then id_no else socso_no end as ID_NUMBER,
             emp.name AS NAME, service_since, ps.pay_month, ps.pay_year,
             COALESCE((select sum(quantity * unit_price) from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.type = 'Addition' and sn.pay_slip_id = ps.id), 0) as WAGES,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'SOCSO By Employer' and sn.pay_slip_id = ps.id), 0) as EMPLOYER,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'SOCSO By Employee' and sn.pay_slip_id = ps.id),0) as EMPLOYEE,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'SOCSO Employer Only' and sn.pay_slip_id = ps.id),0) as EMPLOYER_ONLY
        from pay_slips ps inner join employees emp on emp.id = ps.employee_id
       where ps.pay_month = #{month} and ps.pay_year = #{year} and ps.company_id = '#{com_id}'
       order by name)

    select rpad('#{socso_code}', 12, ' ') || rpad('', 20, ' ') || rpad(replace(id_number, '-', ''), 12, ' ') ||
           rpad(upper(name), 150, ' ') || trim(to_char(pay_month, '00')) || trim(to_char(pay_year, '0000')) ||
           trim(to_char((employer + employee + employer_only) * 100, '00000000000000')) ||
           rpad('', 9, ' ') as textstr
      from step_1
     where employer > 0 or employee > 0 or employer_only > 0
    """
    |> exec_query_row_col()
  end

  def eis_submit_file_format_query(month, year, eis_code, com_id) do
    """
    with step_1 as (
      select case when socso_no = '' then id_no when socso_no = '-' then id_no when socso_no is null then id_no else socso_no end as ID_NUMBER,
             emp.name AS NAME, service_since, ps.pay_month, ps.pay_year,
             COALESCE((select sum(quantity * unit_price) from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.type = 'Addition' and sn.pay_slip_id = ps.id), 0) as WAGES,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'EIS By Employer' and sn.pay_slip_id = ps.id), 0) as EMPLOYER,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'EIS By Employee' and sn.pay_slip_id = ps.id),0) as EMPLOYEE,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'EIS Employer Only' and sn.pay_slip_id = ps.id),0) as EMPLOYER_ONLY
        from pay_slips ps inner join employees emp on emp.id = ps.employee_id
       where ps.pay_month = #{month} and ps.pay_year = #{year} and ps.company_id = '#{com_id}'
       order by name)

    select rpad('#{eis_code}', 12, ' ') || rpad('', 20, ' ') || rpad(replace(id_number, '-', ''), 12, ' ') ||
           rpad(upper(name), 150, ' ') || trim(to_char(pay_month, '00')) || trim(to_char(pay_year, '0000')) ||
           trim(to_char((employer + employee + employer_only) * 100, '00000000000000')) || rpad('', 9, ' ') as textstr
      from step_1 where employer > 0 or employee > 0 or employer_only > 0
    """
    |> exec_query_row_col()
  end

  def socso_eis_submit_file_format_query(month, year, emp_code, com_id) do
    """
    with step_1 as (
      select case when socso_no = '' then id_no when socso_no = '-' then id_no when socso_no is null then id_no else socso_no end as ID_NUMBER,
             emp.name AS NAME, service_since, ps.pay_month, ps.pay_year,
             COALESCE((select sum(quantity * unit_price) from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.type = 'Addition' and sn.pay_slip_id = ps.id), 0) as WAGES,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'SOCSO By Employer' and sn.pay_slip_id = ps.id), 0) as SOCSO_EMPLOYER,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'SOCSO By Employee' and sn.pay_slip_id = ps.id),0) as SOCSO_EMPLOYEE,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'SOCSO Employer Only' and sn.pay_slip_id = ps.id),0) as SOCSO_EMPLOYER_ONLY,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'EIS By Employer' and sn.pay_slip_id = ps.id), 0) as EIS_EMPLOYER,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'EIS By Employee' and sn.pay_slip_id = ps.id),0) as EIS_EMPLOYEE,
             COALESCE((select quantity * unit_price from salary_notes sn inner join salary_types st on sn.salary_type_id = st.id
                        where st.name = 'EIS Employer Only' and sn.pay_slip_id = ps.id),0) as EIS_EMPLOYER_ONLY
        from pay_slips ps inner join employees emp on emp.id = ps.employee_id
       where ps.pay_month = #{month} and ps.pay_year = #{year} and ps.company_id = '#{com_id}'
       order by name)

    select rpad('#{emp_code}', 12, ' ') || rpad('', 20, ' ') || rpad(replace(id_number, '-', ''), 12, ' ') ||
           rpad(upper(name), 150, ' ') || trim(to_char(pay_month, '00')) || trim(to_char(pay_year, '0000')) ||
           trim(to_char(wages * 100, '00000000000000')) ||
           trim(to_char((socso_employer + socso_employer_only) * 100, '000000')) ||
           trim(to_char(socso_employee * 100, '000000')) ||
           trim(to_char((eis_employer + eis_employer_only) * 100, '000000')) ||
           trim(to_char(eis_employee * 100, '000000')) ||
           rpad('', 40, ' ')
           as textstr
      from step_1 where socso_employer > 0 or socso_employee > 0 or socso_employer_only > 0 or eis_employer > 0 or eis_employee > 0 or eis_employer_only > 0
    """
    |> exec_query_row_col()
  end
end
