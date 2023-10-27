defmodule FullCircle.PaySlipOp do
  import Ecto.Query, warn: false
  import Ecto.Changeset
  import FullCircle.Helpers
  import FullCircle.Authorization
  alias FullCircle.Sys.Log
  alias Ecto.Multi

  alias FullCircle.HR.{
    Employee,
    SalaryType,
    Advance,
    PaySlip,
    SalaryNote,
    Recurring
  }

  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.Accounting
  alias FullCircle.Sys.Company
  alias FullCircle.{Repo, Sys, StdInterface, HR}

  defp eis_table() do
    [
      [0, 30, 0.05, 0.05, 0.10],
      [30, 50, 0.10, 0.10, 0.20],
      [50, 70, 0.15, 0.15, 0.30],
      [70, 100, 0.20, 0.20, 0.40],
      [100, 140, 0.25, 0.25, 0.50],
      [140, 200, 0.35, 0.35, 0.70],
      [200, 300, 0.50, 0.50, 1.00],
      [300, 400, 0.70, 0.70, 1.40],
      [400, 500, 0.90, 0.90, 1.80],
      [500, 600, 1.10, 1.10, 2.20],
      [600, 700, 1.30, 1.30, 2.60],
      [700, 800, 1.50, 1.50, 3.00],
      [800, 900, 1.70, 1.70, 3.40],
      [900, 1000, 1.90, 1.90, 3.80],
      [1000, 1100, 2.10, 2.10, 4.20],
      [1100, 1200, 2.30, 2.30, 4.60],
      [1200, 1300, 2.50, 2.50, 5.00],
      [1300, 1400, 2.70, 2.70, 5.40],
      [1400, 1500, 2.90, 2.90, 5.80],
      [1500, 1600, 3.10, 3.10, 6.20],
      [1600, 1700, 3.30, 3.30, 6.60],
      [1700, 1800, 3.50, 3.50, 7.00],
      [1800, 1900, 3.70, 3.70, 7.40],
      [1900, 2000, 3.90, 3.90, 7.80],
      [2000, 2100, 4.10, 4.10, 8.20],
      [2100, 2200, 4.30, 4.30, 8.60],
      [2200, 2300, 4.50, 4.50, 9.00],
      [2300, 2400, 4.70, 4.70, 9.40],
      [2400, 2500, 4.90, 4.90, 9.80],
      [2500, 2600, 5.10, 5.10, 10.20],
      [2600, 2700, 5.30, 5.30, 10.60],
      [2700, 2800, 5.50, 5.50, 11.00],
      [2800, 2900, 5.70, 5.70, 11.40],
      [2900, 3000, 5.90, 5.90, 11.80],
      [3000, 3100, 6.10, 6.10, 12.20],
      [3100, 3200, 6.30, 6.30, 12.60],
      [3200, 3300, 6.50, 6.50, 13.00],
      [3300, 3400, 6.70, 6.70, 13.40],
      [3400, 3500, 6.90, 6.90, 13.80],
      [3500, 3600, 7.10, 7.10, 14.20],
      [3600, 3700, 7.30, 7.30, 14.60],
      [3700, 3800, 7.50, 7.50, 15.00],
      [3800, 3900, 7.70, 7.70, 15.40],
      [3900, 4000, 7.90, 7.90, 15.80],
      [4000, 4100, 8.10, 8.10, 16.20],
      [4100, 4200, 8.30, 8.30, 16.60],
      [4200, 4300, 8.50, 8.50, 17.00],
      [4300, 4400, 8.70, 8.70, 17.40],
      [4400, 4500, 8.90, 8.90, 17.80],
      [4500, 4600, 9.10, 9.10, 18.20],
      [4600, 4700, 9.30, 9.30, 18.60],
      [4700, 4800, 9.50, 9.50, 19.00],
      [4800, 4900, 9.70, 9.70, 19.40],
      [4900, 5000, 9.90, 9.90, 19.80],
      [5000, 99999, 9.90, 9.90, 19.80]
    ]
  end

  defp socso_table() do
    [
      [1, 30, 0.4, 0.1, 0.3],
      [30, 50, 0.7, 0.2, 0.5],
      [50, 70, 1.1, 0.3, 0.8],
      [70, 100, 1.5, 0.4, 1.1],
      [100, 140, 2.1, 0.6, 1.5],
      [140, 200, 2.95, 0.85, 2.1],
      [200, 300, 4.35, 1.25, 3.1],
      [300, 400, 6.15, 1.75, 4.4],
      [400, 500, 7.85, 2.25, 5.6],
      [500, 600, 9.65, 2.75, 6.9],
      [600, 700, 11.35, 3.25, 8.1],
      [700, 800, 13.15, 3.75, 9.4],
      [800, 900, 14.85, 4.25, 10.6],
      [900, 1000, 16.65, 4.75, 11.9],
      [1000, 1100, 18.35, 5.25, 13.1],
      [1100, 1200, 20.15, 5.75, 14.4],
      [1200, 1300, 21.85, 6.25, 15.6],
      [1300, 1400, 23.65, 6.75, 16.9],
      [1400, 1500, 25.35, 7.25, 18.1],
      [1500, 1600, 27.15, 7.75, 19.4],
      [1600, 1700, 28.85, 8.25, 20.6],
      [1700, 1800, 30.65, 8.75, 21.9],
      [1800, 1900, 32.35, 9.25, 23.1],
      [1900, 2000, 34.15, 9.75, 24.4],
      [2000, 2100, 35.85, 10.25, 25.6],
      [2100, 2200, 37.65, 10.75, 26.9],
      [2200, 2300, 39.35, 11.25, 28.1],
      [2300, 2400, 41.15, 11.75, 29.4],
      [2400, 2500, 42.85, 12.25, 30.6],
      [2500, 2600, 44.65, 12.75, 31.9],
      [2600, 2700, 46.35, 13.25, 33.1],
      [2700, 2800, 48.15, 13.75, 34.4],
      [2800, 2900, 49.85, 14.25, 35.6],
      [2900, 3000, 51.65, 14.75, 36.9],
      [3000, 3100, 53.35, 15.25, 38.1],
      [3100, 3200, 55.15, 15.75, 39.4],
      [3200, 3300, 56.85, 16.25, 40.6],
      [3300, 3400, 58.65, 16.75, 41.9],
      [3400, 3500, 60.35, 17.25, 43.1],
      [3500, 3600, 62.15, 17.75, 44.4],
      [3600, 3700, 63.85, 18.25, 45.6],
      [3700, 3800, 65.65, 18.75, 46.9],
      [3800, 3900, 67.35, 19.25, 48.1],
      [3900, 4000, 69.15, 19.75, 49.4],
      [4000, 4100, 70.85, 20.25, 50.6],
      [4100, 4200, 72.65, 20.75, 51.9],
      [4200, 4300, 74.35, 21.25, 53.1],
      [4300, 4400, 76.15, 21.75, 54.4],
      [4400, 4500, 77.85, 22.25, 55.6],
      [4500, 4600, 79.65, 22.75, 56.9],
      [4600, 4700, 81.35, 23.25, 58.1],
      [4700, 4800, 83.15, 23.75, 59.4],
      [4800, 4900, 84.85, 24.25, 60.6],
      [4900, 5000, 86.65, 24.75, 61.9],
      [5000, 99999, 86.65, 24.75, 61.9]
    ]
  end

  def calculate_pay(cs, emp) do
    sns =
      (fetch_field!(cs, :additions) ++
         fetch_field!(cs, :deductions) ++ fetch_field!(cs, :contributions))
      |> Enum.map(fn x ->
        if !is_nil(x.cal_func) do
          val =
            calculate_value(
              x.cal_func |> String.to_atom(),
              emp,
              fetch_field!(cs, :addition_amount),
              cs
            )

          SalaryNote.changeset_on_payslip(x, %{
            unit_price: val,
            quantity: 1,
            amount: val
          })
        else
          SalaryNote.changeset_on_payslip(x, %{})
        end
      end)

    add = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Addition" end)
    ded = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Deduction" end)
    con = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "Contribution" end)
    lea = sns |> Enum.filter(fn x -> fetch_field!(x, :salary_type_type) == "LeaveTaken" end)

    cs
    |> put_change(:additions, add)
    |> put_change(:deductions, ded)
    |> put_change(:contributions, con)
    |> put_change(:leaves, lea)
    |> PaySlip.compute_fields()
  end

  defp calculate_value(:epf_employee, emp, income, cs) do
    income = income |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    rate =
      cond do
        income <= 10 -> 0
        age >= 60 -> 0.04
        income <= 5000 and age < 60 -> 0.11
        income <= 5000 and age >= 60 -> 0.055
        income > 5000 and age < 60 -> 0.11
        income > 5000 and age >= 60 -> 0.055
      end

    (income * rate) |> Float.ceil() |> Decimal.from_float()
  end

  defp calculate_value(:epf_employer, emp, income, cs) do
    income = income |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    rate =
      cond do
        income <= 10 -> 0.0
        age >= 60 -> 0.04
        income <= 5000 and age < 60 -> 0.13
        income <= 5000 and age >= 60 -> 0.065
        income > 5000 and age < 60 -> 0.12
        income > 5000 and age >= 60 -> 0.06
      end

    (income * rate) |> Float.ceil() |> Decimal.from_float()
  end

  defp calculate_value(:eis_employer, emp, income, cs) do
    income = income |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, empr, _, _] =
      Enum.find(eis_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age < 60, do: empr, else: 0.0) |> Decimal.from_float()
  end

  defp calculate_value(:eis_employee, emp, income, cs) do
    income = income |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, _, empe, _] =
      Enum.find(eis_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age < 60, do: empe, else: 0.0) |> Decimal.from_float()
  end

  defp calculate_value(:socso_employee, emp, income, cs) do
    income = income |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, _, empe, _] =
      Enum.find(socso_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age > 60, do: 0.0, else: empe) |> Decimal.from_float()
  end

  defp calculate_value(:socso_employer, emp, income, cs) do
    income = income |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, empr, _, empro] =
      Enum.find(socso_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age > 60, do: empro, else: empr) |> Decimal.from_float()
  end

  defp calculate_value(:socso_employer_only, _emp, income, _cs) do
    income = income |> Decimal.to_float()

    [_, _, _, _, empro] =
      Enum.find(socso_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    empro |> Decimal.from_float()
  end

  defp calculate_value(:pcb_employee, emp, income, cs) do
    10
  end

  defp generate_pay_slip_children(emp, mth, yr, com) do
    sns = get_uncount_salary_notes(emp.id, com)
    adv = get_uncount_advances(emp.id, com)
    rec = get_uncount_recurrings(emp.id, mth, yr, com)

    sts =
      HR.get_employee_salary_types(emp.id)
      |> Enum.reject(fn x -> x.type == "Addition" end)
      |> Enum.reject(fn x ->
        Enum.any?(sns, fn y -> y.salary_type_id == x.id end)
      end)

    sns =
      sns ++
        rec ++
        Enum.map(sts, fn t ->
          %{
            _id: nil,
            note_no: "...new...",
            note_date: Timex.end_of_month(yr, mth),
            unit_price: t.amount,
            quantity: 1,
            amount: 0,
            salary_type_id: t.id,
            salary_type_name: t.name,
            salary_type_type: t.type,
            cal_func: t.cal_func,
            company_id: com.id,
            employee_id: emp.id,
            delete: false,
            recurring_id: nil
          }
        end)

    add = sns |> Enum.filter(fn x -> x.salary_type_type == "Addition" end)
    ded = sns |> Enum.filter(fn x -> x.salary_type_type == "Deduction" end)
    con = sns |> Enum.filter(fn x -> x.salary_type_type == "Contribution" end)
    lea = sns |> Enum.filter(fn x -> x.salary_type_type == "LeaveTaken" end)

    {add, ded, con, lea, adv}
  end

  def generate_new_changeset_for(emp, mth, yr, com) do
    {add, ded, con, lea, adv} = generate_pay_slip_children(emp, mth, yr, com)

    StdInterface.changeset(
      PaySlip,
      %PaySlip{},
      %{
        employee_id: emp.id,
        slip_no: "...new...",
        employee_name: emp.name,
        slip_date: Timex.today(),
        pay_year: yr,
        pay_month: mth,
        additions: add,
        deductions: ded,
        contributions: con,
        advances: adv
      },
      com
    )
  end

  def get_uncount_recurrings(emp_id, mth, yr, comp) do
    edate = Timex.end_of_month(yr, mth)

    from(rcr in Recurring,
      join: com in Company,
      on: rcr.start_date <= ^edate,
      on: com.id == rcr.company_id,
      on: com.id == ^comp.id,
      join: emp in Employee,
      on: emp.id == rcr.employee_id,
      on: emp.id == ^emp_id,
      join: st in SalaryType,
      on: st.id == rcr.salary_type_id,
      left_join: sn in SalaryNote,
      on: sn.recurring_id == rcr.id,
      where: rcr.status == "Active",
      select: %{
        _id: nil,
        note_no: "...new...",
        note_date: fragment("?::date", ^edate),
        unit_price: rcr.amount,
        quantity: 1.0,
        amount: rcr.amount,
        sum_sn_amount: sum(coalesce(sn.quantity, 0) * coalesce(sn.unit_price, 0)),
        descriptions: fragment("'Recurrnig Deduct' || ' ' || ?", rcr.recur_no),
        salary_type_id: rcr.salary_type_id,
        salary_type_name: st.name,
        salary_type_type: st.type,
        cal_func: st.cal_func,
        company_id: com.id,
        employee_id: emp.id,
        delete: false,
        target_amount: rcr.target_amount,
        recurring_id: rcr.id
      },
      group_by: [rcr.id, st.id, com.id, emp.id],
      having: rcr.target_amount > sum(coalesce(sn.quantity, 0) * coalesce(sn.unit_price, 0))
    )
    |> Repo.all()
    |> Enum.map(fn x ->
      cond do
        x.target_amount |> Decimal.compare(x.sum_sn_amount) == :eq ->
          nil

        x.target_amount |> Decimal.sub(x.sum_sn_amount) |> Decimal.compare(x.amount) == :gt ->
          Map.merge(x, %{unit_price: x.amount, quantity: x.quantity, amount: x.amount})

        x.target_amount |> Decimal.sub(x.sum_sn_amount) |> Decimal.compare(x.amount) == :lt ->
          amt = x.target_amount |> Decimal.sub(x.sum_sn_amount)
          Map.merge(x, %{unit_price: amt, quantity: x.quantity, amount: amt})
      end
    end)
    |> Enum.map(fn x ->
      Map.reject(x, fn {k, _} -> k == :target_amount or k == :sum_sn_amount end)
    end)
  end

  def get_uncount_advances(emp_id, comp) do
    from(adv in subquery(advance_query()),
      where: is_nil(adv.pay_slip_id),
      where: adv.company_id == ^comp.id,
      where: adv.employee_id == ^emp_id,
      select: %{
        slip_no: adv.slip_no,
        slip_date: adv.slip_date,
        note: adv.note,
        amount: adv.amount,
        _id: adv.id,
        company_id: adv.company_id,
        employee_id: adv.employee_id,
        funds_account_id: adv.funds_account_id,
        pay_slip_id: nil,
        delete: false
      }
    )
    |> Repo.all()
  end

  defp advance_query() do
    from(adv in Advance,
      join: com in Company,
      on: com.id == adv.company_id,
      join: emp in Employee,
      on: emp.id == adv.employee_id,
      select: adv,
      select_merge: %{_id: adv.id}
    )
  end

  defp salary_note_query() do
    from(note in SalaryNote,
      join: com in Company,
      on: com.id == note.company_id,
      join: emp in Employee,
      on: emp.id == note.employee_id,
      join: st in SalaryType,
      on: st.id == note.salary_type_id,
      select: note,
      select_merge: %{
        _id: note.id,
        salary_type_id: st.id,
        salary_type_name: st.name,
        salary_type_type: st.type,
        cal_func: st.cal_func,
        amount: fragment("round(? * ?, 2)", note.quantity, note.unit_price),
        employee_id: emp.id,
        company_id: com.id,
        delete: false
      }
    )
  end

  def get_uncount_salary_notes(emp_id, comp) do
    from(note in subquery(salary_note_query()),
      where: is_nil(note.pay_slip_id),
      where: note.employee_id == ^emp_id,
      where: note.company_id == ^comp.id,
      select: %{
        _id: note.id,
        note_no: note.note_no,
        note_date: note.note_date,
        salary_type_id: note.salary_type_id,
        salary_type_name: note.salary_type_name,
        salary_type_type: note.salary_type_type,
        quantity: note.quantity,
        unit_price: note.unit_price,
        amount: fragment("round(? * ?, 2)", note.quantity, note.unit_price),
        cal_func: note.cal_func,
        employee_id: note.employee_id,
        company_id: note.company_id,
        pay_slip_id: nil,
        delete: false
      }
    )
    |> Repo.all()
  end

  defp pay_slip_notes(type) do
    from(note in subquery(salary_note_query()),
      where: note.salary_type_type == ^type
    )
  end

  def get_recal_pay_slip(id, com) do
    ps = get_pay_slip!(id, com)

    {add, ded, con, lea, adv} =
      generate_pay_slip_children(%{id: ps.employee_id}, ps.pay_month, ps.pay_year, com)

    add =
      Enum.reject(add, fn a ->
        !is_nil(Enum.find_index(ps.additions, fn n -> a.salary_type_id == n.salary_type_id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    ded =
      Enum.reject(ded, fn a ->
        !is_nil(Enum.find_index(ps.deductions, fn n -> a.salary_type_id == n.salary_type_id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    con =
      Enum.reject(con, fn a ->
        !is_nil(
          Enum.find_index(ps.contributions, fn n -> a.salary_type_id == n.salary_type_id end)
        )
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)


      lea =
        Enum.reject(lea, fn a ->
          !is_nil(
            Enum.find_index(ps.leaves, fn n -> a.salary_type_id == n.salary_type_id end)
          )
        end)
        |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: SalaryNote}) end)

    adv =
      Enum.reject(adv, fn a ->
        !is_nil(Enum.find_index(ps.advances, fn n -> a._id == n.id end))
      end)
      |> Enum.map(fn x -> Map.merge(x, %{id: x._id, __struct__: Advance}) end)

    ps_add = ps.additions ++ add
    ps_ded = ps.deductions ++ ded
    ps_con = ps.contributions ++ con
    ps_lea = ps.leaves ++ lea
    ps_adv = ps.advances ++ adv

    Map.merge(ps, %{
      additions: ps_add,
      deductions: ps_ded,
      contributions: ps_con,
      leaves: ps_lea,
      advances: ps_adv
    })
  end

  def get_pay_slip!(id, com) do
    from(ps in PaySlip,
      join: emp in Employee,
      on: emp.id == ps.employee_id,
      join: ac in Account,
      on: ac.id == ps.funds_account_id,
      preload: [additions: ^pay_slip_notes("Addition")],
      preload: [deductions: ^pay_slip_notes("Deduction")],
      preload: [contributions: ^pay_slip_notes("Contribution")],
      preload: [leaves: ^pay_slip_notes("LeaveTaken")],
      preload: [advances: ^advance_query()],
      where: ps.company_id == ^com.id,
      where: ps.id == ^id,
      select: ps,
      select_merge: %{
        employee_name: emp.name,
        funds_account_name: ac.name
      }
    )
    |> Repo.one!()
  end

  def get_pay_slip_by_period(emp, mth, yr, com) do
    from(ps in PaySlip,
      join: e in Employee,
      on: ps.employee_id == e.id,
      join: c in Company,
      on: c.id == ps.company_id,
      on: c.id == ^com.id,
      on: e.id == ^emp.id,
      where: ps.pay_month == ^mth,
      where: ps.pay_year == ^yr
    )
    |> Repo.one()
  end

  def create_pay_slip(attrs, com, user) do
    case can?(user, :create_pay_slip, com) do
      true ->
        Multi.new()
        |> create_pay_slip_multi(prepare_pay_slip(attrs), attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def update_pay_slip(%PaySlip{} = ps, attrs, com, user) do
    case can?(user, :update_pay_slip, com) do
      true ->
        Multi.new()
        |> update_pay_slip_multi(ps, prepare_pay_slip(attrs), attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  defp prepare_pay_slip(attrs) do
    add =
      (attrs["additions"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}add", v} end)

    ded =
      (attrs["deductions"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}ded", v} end)

    adv = (attrs["advances"] || %{}) |> Map.to_list() |> Enum.map(fn {k, v} -> {"#{k}adv", v} end)

    pay_amount = attrs["pay_slip_amount"]

    con =
      (attrs["contributions"] || %{})
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {"#{k}con", v} end)

      lea =
        (attrs["leaves"] || %{})
        |> Map.to_list()
        |> Enum.map(fn {k, v} -> {"#{k}lea", v} end)

    pay =
      attrs
      |> Map.reject(fn {k, _v} -> k == "additions" end)
      |> Map.reject(fn {k, _v} -> k == "deductions" end)
      |> Map.reject(fn {k, _v} -> k == "advances" end)
      |> Map.reject(fn {k, _v} -> k == "contributions" end)
      |> Map.reject(fn {k, _v} -> k == "leaves" end)

    {add ++ ded ++ con ++ lea, adv, pay, pay_amount}
  end

  defp update_pay_slip_multi(multi, ps, {sns, adv, pay, pay_amount}, attrs, com, user) do
    name = :update_pay_slip

    multi
    |> Multi.update(name, StdInterface.changeset(PaySlip, ps, pay, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "PaySlip",
        where: txn.doc_no == ^ps.slip_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(name, attrs, com, user)
    |> process_notes(sns, name, com, user)
    |> process_advances(adv, name, com, user)
    |> create_pay_slip_transactions(name, pay_amount, com, user)
  end

  defp create_pay_slip_multi(multi, {sns, adv, pay, pay_amount}, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc_ps_#{gen_temp_id()}")
    name = :create_pay_slip

    multi
    |> get_gapless_doc_id(gapless_name, "PaySlip", "PS", com)
    |> Multi.insert(name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(PaySlip, %PaySlip{}, Map.merge(pay, %{"slip_no" => doc}), com)
    end)
    |> process_notes(sns, name, com, user)
    |> process_advances(adv, name, com, user)
    |> Multi.insert("#{name}_log", fn %{^name => entity} ->
      Sys.log_changeset(
        name,
        entity,
        Map.merge(attrs, %{"slip_no" => entity.slip_no}),
        com,
        user
      )
    end)
    |> create_pay_slip_transactions(name, pay_amount, com, user)
  end

  defp process_notes(multi, notes, name, com, user) do
    existing_notes = Enum.filter(notes, fn {_, a} -> a["_id"] != "" end)
    new_notes = Enum.filter(notes, fn {_, a} -> a["_id"] == "" end)

    process_existing_notes(multi, existing_notes, name, com, user)
    |> process_new_notes(new_notes, name, com, user)
  end

  defp process_new_notes(multi, notes, name, com, user) do
    Multi.merge(
      multi,
      fn %{^name => ps} ->
        Enum.reduce(notes, Multi.new(), fn {_, note}, reduce_multi ->
          HR.create_salary_note_multi(
            reduce_multi,
            note |> Map.merge(%{"pay_slip_id" => ps.id, "pay_slip_no" => ps.slip_no}),
            com,
            user,
            :changeset_on_payslip,
            "pay_slip_create_salary_note_#{gen_temp_id()}" |> String.to_atom()
          )
        end)
      end
    )
  end

  defp process_existing_notes(multi, notes, name, com, user) do
    Multi.merge(
      multi,
      fn %{^name => ps} ->
        Enum.reduce(notes, Multi.new(), fn {_, note}, reduce_multi ->
          HR.update_salary_note_multi(
            reduce_multi,
            HR.get_salary_note!(note["_id"], com, user),
            note |> Map.merge(%{"pay_slip_id" => ps.id, "pay_slip_no" => ps.slip_no}),
            com,
            user,
            :changeset_on_payslip,
            "pay_slip_update_salary_note_#{gen_temp_id()}" |> String.to_atom()
          )
        end)
      end
    )
  end

  # defp process_existing_notes(multi, notes, name, com, user) do
  #   notes_ids = Enum.map(notes, fn {_, a} -> a["_id"] end)

  #   multi
  #   |> Multi.update_all(
  #     :pay_slip_update_salary_notes,
  #     fn %{^name => slip} ->
  #       from(a in SalaryNote, where: a.id in ^notes_ids, update: [set: [pay_slip_id: ^slip.id]])
  #     end,
  #     []
  #   )
  #   |> Multi.insert_all(:insert_updated_salary_note_log, Log, fn %{
  #                                                                  ^name => slip
  #                                                                } ->
  #     notes
  #     |> Enum.map(fn {_, a} ->
  #       sn = HR.get_salary_note!(a["_id"], com, user)

  #       a =
  #         Map.merge(a, %{
  #           "employee_name" => sn.employee_name,
  #           "salary_type_name" => sn.salary_type_name,
  #           "pay_slip_no" => slip.slip_no
  #         })

  #       Sys.log_attrs(
  #         :pay_slip_update_salary_note,
  #         sn,
  #         a,
  #         com,
  #         user
  #       )
  #       |> Map.merge(%{inserted_at: Timex.now() |> DateTime.truncate(:second)})
  #     end)
  #   end)
  # end

  defp process_advances(multi, advs_attrs, name, com, user) do
    adv_ids = Enum.map(advs_attrs, fn {_, a} -> a["_id"] end)

    multi
    |> Multi.update_all(
      :update_all_advance,
      fn %{^name => slip} ->
        from(a in Advance, where: a.id in ^adv_ids, update: [set: [pay_slip_id: ^slip.id]])
      end,
      []
    )
    |> Multi.insert_all(:insert_updated_advance_log, Log, fn %{^name => slip} ->
      advs_attrs
      |> Enum.map(fn {_, a} ->
        adv = HR.get_advance!(a["_id"], com, user)

        a =
          Map.merge(a, %{
            "employee_name" => adv.employee_name,
            "funds_account_name" => adv.funds_account_name,
            "pay_slip_no" => slip.slip_no
          })

        Sys.log_attrs(
          :pay_slip_update_advance,
          adv,
          a,
          com,
          user
        )
        |> Map.merge(%{inserted_at: Timex.now() |> DateTime.truncate(:second)})
      end)
    end)
  end

  defp create_pay_slip_transactions(multi, name, pay_slip_amount, com, user) do
    sal_paya_id = Accounting.get_account_by_name("Salaries and Wages Payable", com, user).id

    multi
    |> Multi.insert_all(
      "create_db_transactions" |> String.to_atom(),
      Transaction,
      fn %{^name => slp} ->
        [
          %{
            doc_type: "PaySlip",
            doc_no: slp.slip_no,
            doc_id: slp.id,
            doc_date: slp.slip_date,
            account_id: sal_paya_id,
            company_id: com.id,
            amount: Decimal.new(pay_slip_amount),
            particulars: "Salary #{slp.pay_month}/#{slp.pay_year} to #{slp.employee_name}",
            inserted_at: Timex.now() |> DateTime.truncate(:second)
          },
          %{
            doc_type: "PaySlip",
            doc_no: slp.slip_no,
            doc_id: slp.id,
            doc_date: slp.slip_date,
            account_id: slp.funds_account_id,
            company_id: com.id,
            amount: Decimal.negate(pay_slip_amount),
            particulars: "Salary #{slp.pay_month}/#{slp.pay_year} to #{slp.employee_name}",
            inserted_at: Timex.now() |> DateTime.truncate(:second)
          }
        ]
      end
    )
  end
end
