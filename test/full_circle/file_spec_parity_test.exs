defmodule FullCircle.FileSpecParityTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, FileSpec, HR, StatutoryConfig}
  alias FullCircle.HR.Statutory

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.HRFixtures

  @month 6
  @year 2026
  @line_ending "\r\n"

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    StatutoryConfig.seed_company!(com.id)

    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

    funds_ac =
      account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)

    monthly = HR.get_salary_type_by_name("Monthly Salary", com, admin)

    stat = fn name, code ->
      salary_type_fixture(
        %{
          name: name,
          type: "Deduction",
          statutory_code: code,
          db_ac_name: cr_ac.name,
          db_ac_id: cr_ac.id,
          cr_ac_name: cr_ac.name,
          cr_ac_id: cr_ac.id
        },
        com,
        admin
      )
    end

    ctx = %{
      admin: admin,
      com: com,
      funds_ac: funds_ac,
      monthly: monthly,
      st: %{
        "Employee PCB" => stat.("Employee PCB", "pcb_employee"),
        "EPF By Employer" => stat.("EPF By Employer", "epf_employer"),
        "EPF By Employee" => stat.("EPF By Employee", "epf_employee"),
        "SOCSO By Employer" => stat.("SOCSO By Employer", "socso_employer"),
        "SOCSO By Employee" => stat.("SOCSO By Employee", "socso_employee"),
        "EIS By Employer" => stat.("EIS By Employer", "eis_employer"),
        "EIS By Employee" => stat.("EIS By Employee", "eis_employee")
      }
    }

    e1 =
      employee_fixture(
        %{
          name: "charlie lower",
          epf_no: "E1",
          socso_no: "S1",
          tax_no: "55491986090",
          id_no: "890703-085395"
        },
        com,
        admin
      )

    e2 =
      employee_fixture(
        %{
          name: "Alice Upper",
          epf_no: "E2",
          socso_no: "",
          tax_no: "50358107000",
          id_no: "910202025555"
        },
        com,
        admin
      )

    e3 =
      employee_fixture(
        %{name: "Zero Socso", epf_no: "E3", socso_no: "S3", tax_no: "999", id_no: "000101010000"},
        com,
        admin
      )

    slip = fn emp, lines ->
      slip_fixture(emp, @month, @year, lines, ctx)
    end

    slip.(e1, %{
      "Monthly Salary" => "3000",
      "EPF By Employer" => "390",
      "EPF By Employee" => "330",
      "SOCSO By Employer" => "51.65",
      "SOCSO By Employee" => "14.75",
      "EIS By Employer" => "5.90",
      "EIS By Employee" => "5.90",
      "Employee PCB" => "79.20"
    })

    slip.(e2, %{
      "Monthly Salary" => "2000",
      "EPF By Employer" => "260",
      "EPF By Employee" => "220",
      "SOCSO By Employer" => "34.45",
      "SOCSO By Employee" => "9.85",
      "EIS By Employer" => "3.90",
      "EIS By Employee" => "3.90",
      "Employee PCB" => "318.90"
    })

    slip.(e3, %{
      "Monthly Salary" => "1000",
      "EPF By Employer" => "130",
      "EPF By Employee" => "110"
    })

    %{com: com, ctx: ctx}
  end

  defp slip_fixture(emp, mth, yr, lines, ctx) do
    date = Timex.end_of_month(yr, mth)

    salary_type = fn
      "Monthly Salary" -> ctx.monthly
      n -> ctx.st[n]
    end

    notes =
      lines
      |> Enum.map(fn {n, amt} ->
        st = salary_type.(n)

        sn =
          salary_note_fixture(
            %{
              "note_date" => to_string(date),
              "quantity" => "1",
              "unit_price" => amt,
              "employee_name" => emp.name,
              "employee_id" => emp.id,
              "salary_type_name" => st.name,
              "salary_type_id" => st.id,
              "descriptions" => n
            },
            ctx.com,
            ctx.admin
          )

        {n, amt, sn}
      end)

    line_attrs = fn list ->
      list
      |> Enum.with_index()
      |> Map.new(fn {{n, amt, sn}, i} ->
        {"#{i}",
         %{
           "_id" => sn.id,
           "note_no" => sn.note_no,
           "note_date" => to_string(date),
           "quantity" => "1",
           "unit_price" => amt,
           "amount" => amt,
           "salary_type_name" => n,
           "salary_type_id" => sn.salary_type_id,
           "employee_id" => emp.id,
           "descriptions" => n
         }}
      end)
    end

    additions = notes |> Enum.filter(fn {n, _, _} -> n == "Monthly Salary" end) |> line_attrs.()
    deductions = notes |> Enum.reject(fn {n, _, _} -> n == "Monthly Salary" end) |> line_attrs.()

    attrs = %{
      "slip_date" => to_string(date),
      "pay_month" => to_string(mth),
      "pay_year" => to_string(yr),
      "employee_name" => emp.name,
      "employee_id" => emp.id,
      "funds_account_name" => ctx.funds_ac.name,
      "funds_account_id" => ctx.funds_ac.id,
      "pay_slip_amount" => "0",
      "additions" => additions,
      "deductions" => deductions
    }

    {:ok, %{create_pay_slip: _ps}} =
      FullCircle.PaySlipOp.create_pay_slip(attrs, ctx.com, ctx.admin)
  end

  defp effective_spec(com_id, code) do
    date = Timex.end_of_month(@year, @month)
    %{spec: spec} = StatutoryConfig.effective_file_format(com_id, code, date)
    spec
  end

  defp header_ctx(code) do
    %{
      "employer_code" => code,
      "company_name" => "Test Co",
      "pay_month" => @month,
      "pay_year" => @year
    }
  end

  defp render_file_spec(com_id, code, employer_code) do
    rows = HR.statutory_contributions(@month, @year, com_id)
    spec = effective_spec(com_id, code)

    {:ok, text} = FileSpec.render(spec, rows, header_ctx(employer_code))
    String.split(text, @line_ending, trim: true)
  end

  defp legacy_text_lines(report, employer_code, com_id) do
    {_col, rows} = Statutory.rows(report, @month, @year, employer_code, com_id)

    Enum.map(rows, fn
      [line] -> line
      cells -> Enum.map(cells, &legacy_cell/1) |> Enum.join(",")
    end)
  end

  defp legacy_cell(%Decimal{} = d), do: Decimal.to_string(d)
  defp legacy_cell(v), do: to_string(v)

  for {report, code, employer_code} <- [
        {"SOCSO", "socso_txt", "SOCSOCODE"},
        {"EIS", "eis_txt", "EISCODE"},
        {"EPF", "epf_form_a", "EPFCODE"},
        {"SOCSO+EIS", "socso_eis_txt", "EMPCODE"}
      ] do
    test "#{report} (#{code}) matches legacy formatter line-for-line", %{com: com} do
      legacy = legacy_text_lines(unquote(report), unquote(employer_code), com.id)
      rendered = render_file_spec(com.id, unquote(code), unquote(employer_code))
      assert rendered == legacy
    end
  end

  test "PCB (pcb_cp39) matches legacy formatter byte-for-byte", %{com: com} do
    employer_code = "0093787203"
    legacy = Statutory.pcb_text(@month, @year, employer_code, com.id)
    rendered_lines = render_file_spec(com.id, "pcb_cp39", employer_code)
    rendered = Enum.join(rendered_lines, @line_ending) <> @line_ending
    assert rendered == legacy
  end
end
