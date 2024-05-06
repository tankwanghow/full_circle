defmodule FullCircle.HR do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization
  alias Ecto.Multi

  alias FullCircle.HR.{
    Employee,
    SalaryType,
    EmployeeSalaryType,
    Advance,
    PaySlip,
    SalaryNote,
    Recurring,
    TimeAttend
  }

  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.Accounting
  alias FullCircle.Sys.Company
  alias FullCircle.{Repo, Sys, StdInterface}

  def salary_type_types() do
    ["Addition", "Deduction", "Contribution", "Bonus", "Recording", "LeaveTaken"]
  end

  def default_salary_types(company_id) do
    [
      %{
        name: "Monthly Salary",
        type: "Addition",
        company_id: company_id,
        db_ac_name: "Salaries and Wages",
        cr_ac_name: "Salaries and Wages Payable"
      },
      %{
        name: "Daily Salary",
        type: "Addition",
        company_id: company_id,
        db_ac_name: "Salaries and Wages",
        cr_ac_name: "Salaries and Wages Payable"
      },
      %{
        name: "Hourly Salary",
        type: "Addition",
        company_id: company_id,
        db_ac_name: "Salaries and Wages",
        cr_ac_name: "Salaries and Wages Payable"
      },
      %{
        name: "Overtime Salary",
        type: "Addition",
        company_id: company_id,
        db_ac_name: "Salaries and Wages",
        cr_ac_name: "Salaries and Wages Payable"
      },
      %{
        name: "Sunday Salary",
        type: "Addition",
        company_id: company_id,
        db_ac_name: "Salaries and Wages",
        cr_ac_name: "Salaries and Wages Payable"
      },
      %{
        name: "Holiday Salary",
        type: "Addition",
        company_id: company_id,
        db_ac_name: "Salaries and Wages",
        cr_ac_name: "Salaries and Wages Payable"
      },
      %{
        name: "Annual Leave Taken",
        type: "LeaveTaken",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "Sick Leave Taken",
        type: "LeaveTaken",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "Hospitalize Leave Taken",
        type: "LeaveTaken",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "Maternity Leave Taken",
        type: "LeaveTaken",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "Employee Current Year Income",
        type: "Recording",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "EPF By Employee Current Year",
        type: "Recording",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "PCB Current Year",
        type: "Recording",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      },
      %{
        name: "Zakat Current Year",
        type: "Recording",
        company_id: company_id,
        db_ac_name: "",
        cr_ac_name: ""
      }
    ]
  end

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

  def is_default_salary_type?(st) do
    Enum.any?(FullCircle.HR.default_salary_types(st.company_id), fn a -> a.name == st.name end)
  end

  def timeattend_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(timeattend_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order(
              [:employee_name, :shift_id, :flag, :input_medium],
              terms
            ),
          order_by: [inv.punch_time]
      else
        qry
      end

    qry =
      if date_from != "" do
        date_from = "#{date_from} 00:00:00"

        from inv in qry,
          where: inv.punch_time >= ^date_from,
          order_by: [inv.punch_time]
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_time_attendence!(id, company, user) do
    from(ta in timeattend_raw_query(company, user),
      where: ta.id == ^id
    )
    |> Repo.one!()
    |> FullCircle.HR.TimeAttend.set_punch_time_local(company)
  end

  defp timeattend_raw_query(company, _user) do
    from(ta in TimeAttend,
      join: emp in Employee,
      on: emp.id == ta.employee_id,
      join: user in FullCircle.UserAccounts.User,
      on: user.id == ta.user_id,
      where: ta.company_id == ^company.id,
      select: ta,
      select_merge: %{employee_name: emp.name, email: user.email}
    )
  end

  def create_time_attendence_by_punch(attrs, com, user) do
    case can?(user, :create_time_attendence, com) do
      true ->
        Repo.insert(TimeAttend.changeset(%TimeAttend{}, attrs))

      false ->
        :not_authorise
    end
  end

  def create_time_attendence_by_entry(attrs, com, user) do
    case can?(user, :create_time_attendence, com) do
      true ->
        Repo.insert(TimeAttend.data_entry_changeset(%TimeAttend{}, attrs))

      false ->
        :not_authorise
    end
  end

  def update_time_attendence(ta, attrs, com, user) do
    case can?(user, :update_time_attendence, com) do
      true ->
        Repo.update(TimeAttend.data_entry_changeset(ta, attrs))

      false ->
        :not_authorise
    end
  end

  def delete_time_attendence(ta, com, user) do
    case can?(user, :delete_time_attendence, com) do
      true ->
        Repo.delete(ta)

      false ->
        :not_authorise
    end
  end

  def get_recurring!(id, company, user) do
    from(note in recurring_query(company, user),
      where: note.id == ^id
    )
    |> Repo.one!()
  end

  def recurring_query(company, user) do
    from(note in Recurring,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == note.company_id,
      join: emp in Employee,
      on: emp.id == note.employee_id,
      join: st in SalaryType,
      on: st.id == note.salary_type_id,
      select: note,
      select_merge: %{
        employee_name: emp.name,
        salary_type_name: st.name
      }
    )
  end

  def get_print_employees!(ids, company, user) do
    Repo.all(
      from emp in Employee,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == emp.company_id,
        where: emp.id in ^ids,
        select: emp
    )
  end

  def get_print_advances!(ids, company, user) do
    Repo.all(
      from rec in Advance,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        where: rec.id in ^ids,
        preload: [:employee, :funds_account],
        select: rec
    )
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("advances", x.id, x.company_id)})
    end)
  end

  def get_print_salary_notes!(ids, company, user) do
    Repo.all(
      from rec in SalaryNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        where: rec.id in ^ids,
        preload: [:employee, :salary_type],
        select: rec
    )
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("salary_notes", x.id, x.company_id)})
    end)
  end

  def get_salary_note!(id, com, user) do
    from(note in salary_note_query(com, user),
      where: note.id == ^id
    )
    |> Repo.one!()
  end

  def get_salary_notes(emp_id, month, year, com, user) do
    edate = Timex.end_of_month(year, month)
    sdate = Timex.beginning_of_month(year, month)

    from(note in salary_note_query(com, user),
      where: note.employee_id == ^emp_id,
      where: note.note_date >= ^sdate,
      where: note.note_date <= ^edate,
      order_by: note.note_date
    )
    |> Repo.all()
  end

  def get_advances(emp_id, month, year, com, user) do
    edate = Timex.end_of_month(year, month)
    sdate = Timex.beginning_of_month(year, month)

    from(adv in advance_query(com, user),
      where: adv.employee_id == ^emp_id,
      where: adv.slip_date >= ^sdate,
      where: adv.slip_date <= ^edate,
      order_by: adv.slip_date
    )
    |> Repo.all()
  end

  def get_employee_salary_type(emp_id, type_id) do
    if emp_id == "" or type_id == "" or is_nil(emp_id) or is_nil(type_id) do
      nil
    else
      from(et in EmployeeSalaryType,
        where: et.employee_id == ^emp_id,
        where: et.salary_type_id == ^type_id
      )
      |> Repo.one()
    end
  end

  def get_employee_salary_types(emp_id \\ "") do
    if emp_id == "" do
      nil
    else
      from(et in EmployeeSalaryType,
        join: st in SalaryType,
        on: st.id == et.salary_type_id,
        where: et.employee_id == ^emp_id,
        select: %{
          id: st.id,
          name: st.name,
          cal_func: st.cal_func,
          type: st.type,
          amount: et.amount
        }
      )
      |> Repo.all()
    end
  end

  def salary_note_query(company, user) do
    from(note in SalaryNote,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == note.company_id,
      join: emp in Employee,
      on: emp.id == note.employee_id,
      join: st in SalaryType,
      on: st.id == note.salary_type_id,
      left_join: pay in PaySlip,
      on: pay.id == note.pay_slip_id,
      select: note,
      select_merge: %{
        employee_name: emp.name,
        salary_type_name: st.name,
        salary_type_type: st.type,
        pay_slip_no: pay.slip_no,
        pay_slip_date: pay.slip_date
      }
    )
  end

  def salary_note_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(salary_note_raw_query(com, user)),
        order_by: [desc: inv.note_date]
      )

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order(
              [:note_no, :employee_name, :salary_type_name, :particulars],
              terms
            ),
          order_by: [desc: inv.note_no]
      else
        from inv in subquery(qry),
          order_by: [desc: inv.note_no]
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.note_date >= ^date_from
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_salary_note_by_id_index_component_field!(id, com, user) do
    from(i in subquery(salary_note_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp salary_note_raw_query(company, _user) do
    a =
      from(txn in Transaction,
        join: com in Company,
        on: com.id == txn.company_id and txn.doc_type == "SalaryNote",
        on: com.id == ^company.id,
        left_join: note in SalaryNote,
        on: txn.doc_no == note.note_no,
        left_join: emp in Employee,
        on: emp.id == note.employee_id,
        left_join: st in SalaryType,
        on: st.id == note.salary_type_id,
        left_join: ps in FullCircle.HR.PaySlip,
        on: ps.id == note.pay_slip_id,
        where: txn.amount > 0,
        select: %{
          id: coalesce(note.id, txn.id),
          note_no: txn.doc_no,
          employee_name: emp.name,
          salary_type_name: st.name,
          particulars: coalesce(note.descriptions, txn.particulars),
          pay_slip_no: ps.slip_no,
          note_date: txn.doc_date,
          updated_at: txn.inserted_at,
          company_id: com.id,
          amount: txn.amount,
          checked: false,
          old_data: txn.old_data
        }
      )

    b =
      from(sn in SalaryNote,
        join: com in Company,
        on: com.id == ^company.id,
        on: com.id == sn.company_id,
        join: emp in Employee,
        on: emp.id == sn.employee_id,
        join: st in SalaryType,
        on: st.id == sn.salary_type_id,
        on: is_nil(st.db_ac_id),
        on: is_nil(st.cr_ac_id),
        left_join: ps in FullCircle.HR.PaySlip,
        on: ps.id == sn.pay_slip_id,
        select: %{
          id: sn.id,
          note_no: sn.note_no,
          employee_name: emp.name,
          salary_type_name: st.name,
          particulars: sn.descriptions,
          pay_slip_no: ps.slip_no,
          note_date: sn.note_date,
          updated_at: sn.inserted_at,
          company_id: com.id,
          amount: sn.quantity * sn.unit_price,
          checked: false,
          old_data: false
        }
      )

    union_all(a, ^b)
  end

  def create_salary_note(attrs, com, user) do
    case can?(user, :create_salary_note, com) do
      true ->
        Multi.new()
        |> create_salary_note_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_salary_note_multi(multi, attrs, com, user, changeset_func \\ :changeset, name \\ nil) do
    gapless_name =
      String.to_atom(
        if(
          name,
          do: "update_gapless_doc_#{name}_#{gen_temp_id()}",
          else: "update_gapless_doc_#{gen_temp_id()}"
        )
      )

    name = name || :create_salary_note

    multi
    |> get_gapless_doc_id(gapless_name, "SalaryNote", "SN", com)
    |> Multi.insert(name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(
        SalaryNote,
        %SalaryNote{},
        Map.merge(attrs, %{"note_no" => doc}),
        com,
        changeset_func
      )
    end)
    |> Multi.insert("#{name}_log", fn %{^name => entity} ->
      Sys.log_changeset(name, entity, Map.merge(attrs, %{"note_no" => entity.note_no}), com, user)
    end)
    |> create_salary_note_transactions(name, com, user)
  end

  def create_salary_note_multi_with_note_no(
        multi,
        attrs,
        note_no,
        com,
        user,
        changeset_func \\ :changeset,
        name \\ nil
      ) do
    name = name || :create_salary_note

    multi
    |> Multi.insert(
      name,
      StdInterface.changeset(
        SalaryNote,
        %SalaryNote{},
        Map.merge(attrs, %{"note_no" => note_no}),
        com,
        changeset_func
      )
    )
    |> Multi.insert("#{name}_log", fn %{^name => entity} ->
      Sys.log_changeset(name, entity, Map.merge(attrs, %{"note_no" => entity.note_no}), com, user)
    end)
    |> create_salary_note_transactions(name, com, user)
  end

  def create_salary_note_transactions(multi, name, com, _user) do
    multi
    |> Multi.insert_all("#{name}_create_transactions", Transaction, fn %{^name => note} ->
      if Decimal.eq?(note.amount, Decimal.new(0)) do
        []
      else
        note = note |> FullCircle.Repo.preload([:salary_type, :employee])

        [
          if !is_nil(note.salary_type.cr_ac_id) do
            %{
              doc_type: "SalaryNote",
              doc_no: note.note_no,
              doc_id: note.id,
              doc_date: note.note_date,
              account_id: note.salary_type.cr_ac_id,
              company_id: com.id,
              amount: Decimal.negate(note.amount),
              particulars: "#{note.salary_type.name}, #{note.employee.name}",
              inserted_at: Timex.now() |> DateTime.truncate(:second)
            }
          end,
          if !is_nil(note.salary_type.db_ac_id) do
            %{
              doc_type: "SalaryNote",
              doc_no: note.note_no,
              doc_id: note.id,
              doc_date: note.note_date,
              account_id: note.salary_type.db_ac_id,
              company_id: com.id,
              amount: note.amount,
              particulars: "#{note.salary_type.name}, #{note.employee.name}",
              inserted_at: Timex.now() |> DateTime.truncate(:second)
            }
          end
        ]
      end
      |> Enum.reject(fn x -> is_nil(x) end)
    end)
  end

  def update_salary_note(%SalaryNote{} = salary_note, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "note_no")

    case can?(user, :update_salary_note, com) do
      true ->
        Multi.new()
        |> update_salary_note_multi(salary_note, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_salary_note_multi(
        multi,
        salary_note,
        attrs,
        com,
        user,
        changeset_func \\ :changeset,
        name \\ nil
      ) do
    name = name || :update_salary_note

    multi
    |> Multi.update(
      name,
      StdInterface.changeset(SalaryNote, salary_note, attrs, com, changeset_func)
    )
    |> Multi.delete_all(
      String.to_atom("#{name}_delete_transactions"),
      from(txn in Transaction,
        where: txn.doc_type == "SalaryNote",
        where: txn.doc_no == ^salary_note.note_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(name, attrs, com, user)
    |> create_salary_note_transactions(name, com, user)
  end

  def delete_salary_note(%SalaryNote{} = salary_note, com, user) do
    case can?(user, :delete_salary_note, com) do
      true ->
        Multi.new()
        |> delete_salary_note_multi(salary_note, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def delete_salary_note_multi(multi, salary_note, com, user) do
    salary_note_name = :delete_salary_note

    multi
    |> Multi.delete(salary_note_name, StdInterface.changeset(SalaryNote, salary_note, %{}, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "SalaryNote",
        where: txn.doc_no == ^salary_note.note_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(salary_note_name, %{"deleted_id_is" => salary_note.id}, com, user)
  end

  def get_advance!(id, com, user) do
    from(adv in advance_query(com, user),
      where: adv.id == ^id
    )
    |> Repo.one!()
  end

  def get_advance_by_no!(no, com, user) do
    from(adv in advance_query(com, user),
      where: adv.slip_no == ^no
    )
    |> Repo.one!()
  end

  def advance_query(company, user) do
    from(adv in Advance,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == adv.company_id,
      join: emp in Employee,
      on: emp.id == adv.employee_id,
      join: ac in Account,
      on: ac.id == adv.funds_account_id,
      left_join: pay in PaySlip,
      on: pay.id == adv.pay_slip_id,
      select: %Advance{
        id: adv.id,
        slip_no: adv.slip_no,
        slip_date: adv.slip_date,
        amount: adv.amount,
        note: adv.note,
        employee_name: emp.name,
        funds_account_name: ac.name,
        pay_slip_no: pay.slip_no,
        pay_slip_id: pay.id,
        company_id: com.id,
        employee_id: emp.id,
        funds_account_id: adv.funds_account_id
      }
    )
  end

  def advance_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(advance_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by:
            ^similarity_order(
              [:slip_no, :employee_name, :funds_account_name, :particulars],
              terms
            ),
          order_by: [desc: inv.slip_no]
      else
        from inv in subquery(qry),
          order_by: [desc: inv.slip_no]
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.slip_date >= ^date_from, order_by: inv.slip_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_advance_by_id_index_component_field!(id, com, user) do
    from(i in subquery(advance_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp advance_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "Advance",
      left_join: adv in Advance,
      on: txn.doc_no == adv.slip_no,
      left_join: emp in Employee,
      on: emp.id == adv.employee_id,
      left_join: funds in Account,
      on: funds.id == adv.funds_account_id,
      order_by: [desc: txn.doc_date],
      where: txn.amount > 0,
      select: %{
        id: coalesce(adv.id, txn.id),
        slip_no: txn.doc_no,
        employee_name: emp.name,
        funds_account_name: funds.name,
        particulars: coalesce(adv.note, txn.particulars),
        slip_date: txn.doc_date,
        updated_at: txn.inserted_at,
        company_id: com.id,
        amount: txn.amount,
        checked: false,
        old_data: txn.old_data
      }
  end

  def create_advance(attrs, com, user) do
    case can?(user, :create_advance, com) do
      true ->
        Multi.new()
        |> create_advance_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_advance_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    name = :create_advance

    multi
    |> get_gapless_doc_id(gapless_name, "Advance", "ADV", com)
    |> Multi.insert(name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(Advance, %Advance{}, Map.merge(attrs, %{"slip_no" => doc}), com)
    end)
    |> Multi.insert("#{name}_log", fn %{^name => entity} ->
      Sys.log_changeset(name, entity, Map.merge(attrs, %{"slip_no" => entity.slip_no}), com, user)
    end)
    |> create_advance_transactions(name, com, user)
  end

  defp create_advance_transactions(multi, name, com, user) do
    paya_id = Accounting.get_account_by_name("Salaries and Wages Payable", com, user).id

    multi
    |> Multi.insert_all("create_transactions", Transaction, fn %{^name => adv} ->
      [
        %{
          doc_type: "Advance",
          doc_no: adv.slip_no,
          doc_id: adv.id,
          doc_date: adv.slip_date,
          account_id: paya_id,
          company_id: com.id,
          amount: adv.amount,
          particulars: "From #{adv.funds_account_name} to #{adv.employee_name}",
          inserted_at: Timex.now() |> DateTime.truncate(:second)
        },
        %{
          doc_type: "Advance",
          doc_no: adv.slip_no,
          doc_id: adv.id,
          doc_date: adv.slip_date,
          account_id: adv.funds_account_id,
          company_id: com.id,
          amount: Decimal.negate(adv.amount),
          particulars: "From #{adv.funds_account_name} to #{adv.employee_name}",
          inserted_at: Timex.now() |> DateTime.truncate(:second)
        }
      ]
    end)
  end

  def update_advance(%Advance{} = advance, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "slip_no")

    case can?(user, :update_advance, com) do
      true ->
        Multi.new()
        |> update_advance_multi(advance, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_advance_multi(multi, advance, attrs, com, user) do
    advance_name = :update_advance

    multi
    |> Multi.update(advance_name, StdInterface.changeset(Advance, advance, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "Advance",
        where: txn.doc_no == ^advance.slip_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(advance_name, attrs, com, user)
    |> create_advance_transactions(advance_name, com, user)
  end

  def get_salary_type!(id, com_id) do
    from(st in SalaryType,
      left_join: dbac in Account,
      on: dbac.id == st.db_ac_id,
      left_join: crac in Account,
      on: crac.id == st.cr_ac_id,
      where: st.company_id == ^com_id,
      where: st.id == ^id,
      select: st,
      select_merge: %{db_ac_name: dbac.name, cr_ac_name: crac.name}
    )
    |> Repo.one!()
  end

  def get_salary_type!(id, com, user) do
    from(st in salary_type_query(com, user),
      where: st.id == ^id
    )
    |> Repo.one!()
  end

  def get_salary_type_by_name(name, company, user) do
    name = name |> String.trim()

    from(st in salary_type_query(company, user),
      where: st.name == ^name
    )
    |> Repo.one()
  end

  def salary_types(terms, company, user) do
    from(st in SalaryType,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == st.company_id,
      where: ilike(st.name, ^"%#{terms}%"),
      select: %{id: st.id, value: st.name},
      order_by: st.name
    )
    |> Repo.all()
  end

  def salary_type_query(company, user) do
    from(st in SalaryType,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == st.company_id,
      left_join: dbac in Account,
      on: dbac.id == st.db_ac_id,
      left_join: crac in Account,
      on: crac.id == st.cr_ac_id,
      select: st,
      select_merge: %{db_ac_name: dbac.name, cr_ac_name: crac.name}
    )
  end

  defp employee_salary_types() do
    from(est in EmployeeSalaryType,
      join: st in SalaryType,
      on: st.id == est.salary_type_id,
      select: est,
      select_merge: %{salary_type_name: st.name}
    )
  end

  def get_employee_by_name(name, company, user) do
    name = name |> String.trim()

    from(emp in employee_query(company, user),
      where: emp.name == ^name
    )
    |> Repo.one()
  end

  def get_employee!(id, company, user) do
    from(emp in Employee,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == emp.company_id,
      preload: [employee_salary_types: ^employee_salary_types()],
      where: emp.id == ^id
    )
    |> Repo.one!()
  end

  def employees(terms, company, user) do
    from(emp in Employee,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == emp.company_id,
      where: ilike(emp.name, ^"%#{terms}%"),
      where: emp.status == "Active",
      select: %{id: emp.id, value: emp.name},
      order_by: emp.name
    )
    |> Repo.all()
  end

  def get_employee_by_id_index_component_field!(id, com, user) do
    from(i in subquery(employee_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  def employee_query(company, user) do
    from(emp in Employee,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == emp.company_id,
      select: emp
    )
  end

  def employee_checked_query(company, user) do
    from(emp in Employee,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == emp.company_id,
      select: emp,
      select_merge: %{checked: false},
      order_by: [emp.status, emp.name]
    )
  end

  defp punch_query_by_company_id(sdate, edate, com_id) do
    "select d2.id::varchar || d2.dd::varchar as idg, d2.dd, d2.name, d2.work_hours_per_day,
            d2.work_days_per_week, d2.work_days_per_month, d2.id as employee_id,
            p2.shift, p2.time_list, holi_list, sholi_list
       from (select d1.dd, d1.name, d1.id, d1.status, d1.id_no, d1.work_hours_per_day,
                    d1.work_days_per_week, d1.work_days_per_month,
                    string_agg(hl.name, ', ' order by hl.name) as holi_list,
                    string_agg(hl.short_name, ', ' order by hl.short_name) as sholi_list
               from (select dd::date, e.name, e.id, e.status, e.id_no, e.work_hours_per_day,
                            e.work_days_per_week, e.work_days_per_month
                            from employees e,
                            generate_series('#{sdate}'::date, '#{edate}'::date, '1 day') as dd
                      where e.status = 'Active' and e.company_id = '#{com_id}') d1 left outer join holidays hl
                         on hl.holidate = d1.dd and hl.company_id = '#{com_id}'
                      group by d1.dd, d1.name, d1.id, d1.status, d1.id_no,
                               d1.work_hours_per_day, d1.work_days_per_week,
                               d1.work_days_per_month) d2 left outer join
              (select ta.employee_id, ta.shift_id as shift, min(ta.punch_time)::date as pt, min(ta.punch_time) as punch_time,
                      array_agg(ta.punch_time::varchar || '|' || ta.id::varchar || '|' || ta.status || '|' || ta.flag order by ta.punch_time) time_list
                 from time_attendences ta inner join companies c on c.id = ta.company_id
                where ta.company_id = '#{com_id}'
                  and ta.punch_time::date >= '#{sdate}'
                  and ta.punch_time::date <= '#{edate}'
                group by ta.employee_id, ta.shift_id) p2
         on p2.pt = d2.dd
        and d2.id = p2.employee_id
      where true"
  end

  def punch_by_date(emp_id, pdate, com_id) do
    (punch_query_by_company_id(pdate, pdate, com_id) <>
       " and d2.id = '#{emp_id}'" <>
       " order by d2.dd, p2.shift")
    |> exec_query_map()
    |> unzip_all_time_list()
    |> Enum.at(0)
  end

  def punch_card_query(month, year, emp_id, com_id) do
    edate = Timex.end_of_month(year, month)
    sdate = Timex.beginning_of_month(year, month)

    (punch_query_by_company_id(sdate, edate, com_id) <>
       " and d2.id = '#{emp_id}'" <>
       " order by d2.dd, p2.shift")
    |> exec_query_map()
    |> unzip_all_time_list()
  end

  def punch_query_by_id(empid, dd, com_id) do
    dd = Timex.to_date(dd)

    (punch_query_by_company_id(dd, dd, com_id) <>
       " and d2.id::varchar || d2.dd::varchar = '#{empid}#{dd}'")
    |> exec_query_map()
    |> unzip_all_time_list()
    |> Enum.at(0)
  end

  def punch_query(sdate, edate, terms, com_id,
        page: page,
        per_page: per_page
      ) do
    (punch_query_by_company_id(sdate, edate, com_id) <>
       if(terms != "",
         do: " and (d2.name ilike '%#{terms}%' or d2.id_no ilike '%#{terms}%')",
         else: ""
       ) <>
       " order by d2.name, d2.dd, p2.shift" <>
       " limit #{per_page} offset (#{page} - 1) * #{per_page} ")
    |> exec_query_map()
    |> unzip_all_time_list()
  end

  def last_shift(number, com_id) do
    from(ta in TimeAttend,
      join: com in FullCircle.Sys.Company,
      on: ta.company_id == com.id,
      where: com.id == ^com_id,
      limit: ^number,
      distinct: [desc: ta.shift_id],
      order_by: [desc: ta.shift_id],
      select: %{shift: ta.shift_id}
    )
    |> Repo.all()
  end

  defp count_hours_work(tl) when is_nil(tl) do
    0
  end

  defp count_hours_work(tl) do
    tl
    |> Enum.chunk_every(2)
    |> Enum.map(fn t ->
      try do
        [[ti, _, _, "IN"], [to, _, _, "OUT"]] = t
        Timex.diff(to, ti, :minute) / 60
      rescue
        MatchError ->
          0

        e ->
          reraise e, __STACKTRACE__
      end
    end)
  end

  defp unzip_all_time_list(ps) when is_nil(ps) do
    nil
  end

  defp unzip_all_time_list(ps) do
    ps
    |> Enum.map(fn t ->
      ut = Map.get(t, :time_list) |> unzip_time_list()
      # change key to id
      idg = Map.get(t, :idg)
      nwh = Decimal.to_float(Map.get(t, :work_hours_per_day) || Decimal.new("0.00001"))
      wh = Enum.sum(count_hours_work(ut))

      nh =
        cond do
          wh >= nwh -> nwh
          true -> wh
        end

      ot =
        cond do
          wh > nwh -> wh - nwh
          true -> 0
        end

      Map.merge(t, %{time_list: ut, wh: wh, nh: nh, ot: ot, id: idg, work_hours_per_day: nwh})
    end)
  end

  defp unzip_time_list(tl) do
    if is_nil(tl) do
      []
    else
      tl
      |> Enum.map(fn x -> String.split(x, "|") end)
      |> Enum.map(fn [t, i, s, f] -> [Timex.parse!(t, "{RFC3339}"), i, s, f] end)
    end
  end
end
