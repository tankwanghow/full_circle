defmodule FullCircle.HRFixtures do
  def unique_holiday_name, do: "holiday#{System.unique_integer()}"
  def unique_employee_name, do: "employee#{System.unique_integer()}"
  def unique_salary_type_name, do: "saltype#{System.unique_integer()}"

  def valid_holiday_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_holiday_name(),
      short_name: "H#{System.unique_integer([:positive])}",
      holidate: Date.utc_today()
    })
  end

  def holiday_fixture(attrs, company, user) do
    attrs = attrs |> valid_holiday_attributes()

    {:ok, holiday} =
      FullCircle.StdInterface.create(
        FullCircle.HR.Holiday,
        "holiday",
        attrs,
        company,
        user
      )

    holiday
  end

  def valid_employee_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_employee_name(),
      id_no: "#{System.unique_integer([:positive])}",
      dob: ~D[1990-01-15],
      gender: "Male",
      marital_status: "Single",
      nationality: "Malaysian",
      partner_working: "No",
      children: 0,
      service_since: ~D[2020-01-01],
      status: "Active",
      work_hours_per_day: 7.5,
      work_days_per_week: 6,
      work_days_per_month: 26,
      annual_leave: 8,
      sick_leave: 14,
      hospital_leave: 60,
      maternity_leave: 98,
      paternity_leave: 7
    })
  end

  def employee_fixture(attrs \\ %{}, company, user) do
    attrs = attrs |> valid_employee_attributes()

    {:ok, employee} =
      FullCircle.StdInterface.create(
        FullCircle.HR.Employee,
        "employee",
        attrs,
        company,
        user
      )

    employee
  end

  def valid_salary_type_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_salary_type_name(),
      type: "Addition"
    })
  end

  def salary_type_fixture(attrs \\ %{}, company, user) do
    attrs = attrs |> valid_salary_type_attributes()

    {:ok, salary_type} =
      FullCircle.StdInterface.create(
        FullCircle.HR.SalaryType,
        "salary_type",
        attrs,
        company,
        user
      )

    salary_type
  end

  def salary_note_fixture(attrs, company, user) do
    {:ok, salary_note} = FullCircle.HR.create_salary_note(attrs, company, user)
    salary_note
  end

  def advance_fixture(attrs, company, user) do
    {:ok, advance} = FullCircle.HR.create_advance(attrs, company, user)
    advance
  end
end
