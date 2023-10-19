defmodule FullCircle.PaySlip do
  import Ecto.Query, warn: false

  alias FullCircle.HR
  alias FullCircle.HR.{SalaryNote}

  def generate_new_changeset_for(emp_id, mth, yr, com, user) do
    sns = HR.get_salary_notes(emp_id, mth, yr, com, user)

    sts =
      HR.get_employee_salary_types(emp_id)
      |> Enum.reject(fn x -> Enum.any?(sns, fn y -> y.salary_type_id == x.id end) end)

    sns ++
      Enum.map(sts, fn t ->
        %SalaryNote{
          pay_slip_no: nil,
          note_no: "...new...",
          note_date: Timex.end_of_month(yr, mth),
          unit_price: t.amount,
          salary_type_id: t.id,
          salary_type_name: t.name,
          company_id: com.id
        }
      end)
  end
end
