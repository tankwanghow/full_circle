defmodule FullCircle.SalaryNoteCalFunc do
  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias FullCircle.HR.{SalaryNote, SalaryType}
  alias FullCircle.Repo

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
      [5000, 999_999, 9.90, 9.90, 19.80]
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
      [5000, 999_999, 86.65, 24.75, 61.9]
    ]
  end

  defp pcb_table_normal() do
    [
      [5001.0, 20000.0, 5000.0, 0.01, -400.0, -800.0],
      [20001.0, 35000.0, 20000.0, 0.03, -250.0, -650.0],
      [35001.0, 50000.0, 35000.0, 0.06, 600.0, 600.0],
      [50001.0, 70000.0, 50000.0, 0.11, 1500.0, 1500.0],
      [70001.0, 100_000.0, 70000.0, 0.19, 3700.0, 3700.0],
      [100_001.0, 400_000.0, 100_000.0, 0.25, 9400.0, 9400.0],
      [400_001.0, 600_000.0, 400_000.0, 0.26, 84400.0, 84400.0],
      [600_001.0, 2_000_000.0, 600_000.0, 0.28, 136_400.0, 136_400.0],
      [2_000_000.01, 999_999_999.0, 2_000_000.0, 0.30, 528_400.0, 528_400.0]
    ]
  end

  @zakat_name "Employee Zakat"
  @epf_name "EPF By Employee"
  @pcb_name "Employee PCB"
  @income_cy "Employee Current Year Income"
  @epf_cy "EPF By Employee Current Year"
  @pcb_cy "PCB Current Year"
  @zkt_cy "Zakat Current Year"
  @qualify_children_deduction 2000.0
  @invidual_deduction 9000.0
  @spouse_deduction 4000.0
  @epf_or_insurance_limit 4000.0

  # Total chargeable income for a year
  def p(emp, mth, yr, cs) do
    y = y(emp, mth, yr)
    k = k(emp, mth, yr)
    y1 = y1(cs)
    k1 = k1(k, emp, cs)
    y2 = y2(y1)
    k2 = k2(k, k1, mth)
    yt = yt(cs)
    kt = kt(k, k1, k2, emp, cs)
    n = n(mth)
    d = @invidual_deduction
    s = s(emp)
    q = @qualify_children_deduction
    c = c(emp)
    y - k + (y1 - k1) + (y2 - k2) * n + (yt - kt) - (d + s + q * c)
  end

  def x(emp, mth, yr) do
    from(sn in SalaryNote,
      join: st in SalaryType,
      on: st.id == sn.salary_type_id,
      where: sn.employee_id == ^emp.id,
      # where: not is_nil(sn.pay_slip_id),
      where: fragment("extract(year from ?) = ?", sn.note_date, ^yr),
      where: fragment("extract(month from ?) < ?", sn.note_date, ^mth),
      where: st.name == ^@pcb_name or st.name == ^@pcb_cy,
      select: coalesce(sum(sn.quantity * sn.unit_price), 0)
    )
    |> Repo.one()
    |> Decimal.to_float()
  end

  def z(emp, mth, yr) do
    from(sn in SalaryNote,
      join: st in SalaryType,
      on: st.id == sn.salary_type_id,
      where: sn.employee_id == ^emp.id,
      # where: not is_nil(sn.pay_slip_id),
      where: fragment("extract(year from ?) = ?", sn.note_date, ^yr),
      where: fragment("extract(month from ?) < ?", sn.note_date, ^mth),
      where: st.name == ^@zakat_name or st.name == ^@zkt_cy,
      select: coalesce(sum(sn.quantity * sn.unit_price), 0)
    )
    |> Repo.one()
    |> Decimal.to_float()
  end

  defp mrb(p, emp) do
    [_, _, m, r, b13, b2] =
      Enum.find(pcb_table_normal(), [0.0, 0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _, _] ->
        p > u and p <= l
      end)

    b =
      cond do
        emp.marital_status == "Single" ->
          b13

        emp.marital_status == "Married" and
            (emp.partner_working == "true" or emp.partner_working == "Yes") ->
          b13

        emp.marital_status == "Married" and
            (emp.partner_working == "false" or emp.partner_working == "No") ->
          b2
      end

    [m, r, b]
  end

  # Total accumulated gross normal remuneration and gross additional
  # remuneration for the current year, paid to an employee prior to the current
  # month, including gross normal remuneration
  def y(emp, mth, yr) do
    from(sn in SalaryNote,
      join: st in SalaryType,
      on: st.id == sn.salary_type_id,
      where: sn.employee_id == ^emp.id,
      # where: not is_nil(sn.pay_slip_id),
      where: fragment("extract(year from ?) = ?", sn.note_date, ^yr),
      where: fragment("extract(month from ?) < ?", sn.note_date, ^mth),
      where: st.type == "Addition" or st.name == ^@income_cy,
      select: coalesce(sum(sn.quantity * sn.unit_price), 0)
    )
    |> Repo.one()
    |> Decimal.to_float()
  end

  # Total contribution to Employees Provident Fund or other approved scheme
  # paid in respect of Y, if any, subject to the total qualifying amount per year
  def k(emp, mth, yr) do
    k =
      from(sn in SalaryNote,
        join: st in SalaryType,
        on: st.id == sn.salary_type_id,
        where: sn.employee_id == ^emp.id,
        # where: not is_nil(sn.pay_slip_id),
        where: fragment("extract(year from ?) = ?", sn.note_date, ^yr),
        where: fragment("extract(month from ?) < ?", sn.note_date, ^mth),
        where: st.name == ^@epf_name or st.name == @epf_cy,
        select: coalesce(sum(sn.quantity * sn.unit_price), 0)
      )
      |> Repo.one()
      |> Decimal.to_float()

    if k >= @epf_or_insurance_limit, do: @epf_or_insurance_limit, else: k
  end

  # Gross normal remuneration for the current month
  defp y1(cs) do
    fetch_field!(cs, :addition_amount)
    |> Decimal.to_float()
  end

  # Contribution to Employees Provident Fund or other approved scheme paid in
  # respect of Y1, subject to the total qualifying amount per year
  defp k1(k, emp, cs) do
    if k >= @epf_or_insurance_limit do
      0.0
    else
      cur_epf = calculate_value(:epf_employee, emp, cs) |> Decimal.to_float()

      cond do
        cur_epf == 0.0 -> cur_epf
        k + cur_epf >= @epf_or_insurance_limit -> @epf_or_insurance_limit - k
        true -> cur_epf
      end
    end
  end

  # Estimated remuneration as Y1 for the subsequent months
  defp y2(y1) do
    y1
  end

  # Estimated balance of total contribution to Employees Provident Fund or other
  # approved scheme paid for the balance of qualifying months [[Total qualifying
  # amount per year – (K + K1 + Kt)] / n] or K1, whichever is lower
  defp k2(k, k1, mth) do
    t = k + k1 * n(mth)

    if k + k1 == 0 do
      0.0
    else
      if t >= @epf_or_insurance_limit do
        0.0
      else
        @epf_or_insurance_limit - t
      end
    end
  end

  # Gross additional remuneration for the current month
  defp yt(cs) do
    fetch_field!(cs, :bonus_amount) |> Decimal.to_float()
  end

  # Contribution to Employees Provident Fund or other approved scheme paid in
  # respect of Yt , subject to the total qualifying amount per year
  defp kt(k, k1, k2, emp, cs) do
    if k + k1 + k2 == 0 do
      0.0
    else
      if k + k1 + k2 >= @epf_or_insurance_limit do
        0.0
      else
        kt = calculate_value(:epf_employee, emp, cs) |> Decimal.to_float()

        cond do
          k + k1 + k2 + kt <= @epf_or_insurance_limit ->
            kt

          k + k1 + k2 + kt > @epf_or_insurance_limit ->
            @epf_or_insurance_limit - (k + k1 + k2)
        end
      end
    end
  end

  ######
  ## K + K1 + K2 + Kt not exceeding total qualifying amount per year
  ## CUME(Yt – Kt) only applies to calculation of Monthly Tax Deduction for additional remuneration
  #####

  # N Balance of month in a year
  defp n(mth) do
    12 - mth
  end

  #########################
  #   Value of D, S and C are determined as follows:
  #   (i) Category 1 = Single:
  #         Value of D = Deduction for individual, S = 0 and C = 0;
  #  (ii) Category 2 = Married and husband or wife is not working:
  #         Value of D = Deduction for individual,
  #         Value of S = Deduction for husband or wife, and
  #         Value of C = Number of qualifying children;
  # (iii) Category 3 = Married and husband or wife is working, divorced or widowed, or single with adopted child:
  #         Value of D = Deduction for individual,
  #         Value of S = 0, and
  #         Value of C = Number of qualifying children
  ########################

  # S Deduction for husband or wife
  defp s(emp) do
    cond do
      emp.marital_status == "Single" ->
        0.0

      emp.marital_status == "Married" and
          (emp.partner_working == "true" or emp.partner_working == "Yes") ->
        0.0

      emp.marital_status == "Married" and
          (emp.partner_working == "false" or emp.partner_working == "No") ->
        @spouse_deduction
    end
  end

  # C Number of qualifying children
  defp c(emp) do
    emp.children
  end

  def calculate_value(:pcb_employee, emp, cs) do
    yr = fetch_field!(cs, :pay_year)
    mth = fetch_field!(cs, :pay_month)

    p = p(emp, mth, yr, cs)
    x = x(emp, mth, yr)
    n = n(mth)
    z = z(emp, mth, yr)

    [m, r, b] = mrb(p, emp)

    pcb = ((p - m) * r + b - (z + x)) / (n + 1)

    if pcb > 0, do: Float.round(pcb, 2), else: 0
  end

  def calculate_value(:epf_employer, emp, cs) do
    income =
      (fetch_field!(cs, :addition_amount) |> Decimal.to_float()) +
        (fetch_field!(cs, :bonus_amount) |> Decimal.to_float())

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    is_malaysian =
      emp.nationality |> String.trim() |> String.downcase() |> String.starts_with?("malays")

    rate =
      cond do
        income <= 10 -> 0.0
        age >= 60 and is_malaysian -> 0.04
        income <= 5000 and is_malaysian and age < 60 -> 0.13
        income <= 5000 and not is_malaysian and age >= 60 -> 0.065
        income > 5000 and is_malaysian and age < 60 -> 0.12
        income > 5000 and not is_malaysian and age >= 60 -> 0.06
        true -> 0.0
      end

    (income * rate) |> Float.ceil() |> Decimal.from_float()
  end

  def calculate_value(:epf_employee, emp, cs) do
    income =
      (fetch_field!(cs, :addition_amount) |> Decimal.to_float()) +
        (fetch_field!(cs, :bonus_amount) |> Decimal.to_float())

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    is_malaysian =
      emp.nationality |> String.trim() |> String.downcase() |> String.starts_with?("malays")

    rate =
      cond do
        income <= 10 -> 0
        age >= 60 and is_malaysian -> 0.0
        income <= 5000 and is_malaysian and age < 60 -> 0.11
        income <= 5000 and not is_malaysian and age >= 60 -> 0.055
        income > 5000 and is_malaysian and age < 60 -> 0.11
        income > 5000 and not is_malaysian and age >= 60 -> 0.055
        true -> 0.0
      end

    (income * rate) |> Float.ceil() |> Decimal.from_float()
  end

  def calculate_value(:eis_employer, emp, cs) do
    income = fetch_field!(cs, :addition_amount) |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, empr, _, _] =
      Enum.find(eis_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age < 60, do: empr, else: 0.0) |> Decimal.from_float()
  end

  def calculate_value(:eis_employee, emp, cs) do
    income = fetch_field!(cs, :addition_amount) |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, _, empe, _] =
      Enum.find(eis_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age < 60, do: empe, else: 0.0) |> Decimal.from_float()
  end

  def calculate_value(:socso_employee, emp, cs) do
    income = fetch_field!(cs, :addition_amount) |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, _, empe, _] =
      Enum.find(socso_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age > 60, do: 0.0, else: empe) |> Decimal.from_float()
  end

  def calculate_value(:socso_employer, emp, cs) do
    income = fetch_field!(cs, :addition_amount) |> Decimal.to_float()

    age =
      Timex.end_of_month(fetch_field!(cs, :pay_year), fetch_field!(cs, :pay_month))
      |> Timex.diff(emp.dob, :years)

    [_, _, empr, _, empro] =
      Enum.find(socso_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    if(age > 60, do: empro, else: empr) |> Decimal.from_float()
  end

  def calculate_value(:socso_employer_only, _emp, cs) do
    income = fetch_field!(cs, :addition_amount) |> Decimal.to_float()

    [_, _, _, _, empro] =
      Enum.find(socso_table(), [0.0, 0.0, 0.0, 0.0, 0.0], fn [u, l, _, _, _] ->
        income > u and income <= l
      end)

    empro |> Decimal.from_float()
  end
end
