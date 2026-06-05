defmodule FullCircle.StatutoryTest do
  use FullCircle.DataCase

  alias FullCircle.{HR, PaySlipOp, Accounting}
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.HRFixtures

  # Builds: company, a "Salaries and Wages" account, a Monthly Salary type,
  # and the statutory salary types with BOTH legacy name AND statutory_code set.
  def setup_statutory(_ctx) do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

    funds_ac =
      account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)

    monthly = HR.get_salary_type_by_name("Monthly Salary", com, admin)

    pcb =
      salary_type_fixture(
        %{
          name: "Employee PCB",
          type: "Deduction",
          cal_func: "pcb_employee",
          statutory_code: "pcb_employee",
          db_ac_name: cr_ac.name,
          db_ac_id: cr_ac.id,
          cr_ac_name: cr_ac.name,
          cr_ac_id: cr_ac.id
        },
        com,
        admin
      )

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

    %{
      admin: admin,
      com: com,
      funds_ac: funds_ac,
      monthly: monthly,
      st: %{
        "Employee PCB" => pcb,
        "EPF By Employer" => stat.("EPF By Employer", "epf_employer"),
        "EPF By Employee" => stat.("EPF By Employee", "epf_employee"),
        "SOCSO By Employer" => stat.("SOCSO By Employer", "socso_employer"),
        "SOCSO By Employee" => stat.("SOCSO By Employee", "socso_employee"),
        "EIS By Employer" => stat.("EIS By Employer", "eis_employer"),
        "EIS By Employee" => stat.("EIS By Employee", "eis_employee")
      }
    }
  end

  # Create a pay slip in (mth/yr) for `emp` with given line amounts:
  # %{"Monthly Salary" => "3000", "EPF By Employer" => "390", ...}
  # Salary notes are created first (unprocessed), then linked into the slip — matching the
  # real flow where create_pay_slip links existing notes via their `_id`.
  def slip(emp, mth, yr, lines, ctx) do
    date = Timex.end_of_month(yr, mth)

    salary_type = fn "Monthly Salary" -> ctx.monthly
                     n -> ctx.st[n] end

    # create each note first, returns {name, amt, sn}
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

    {:ok, %{create_pay_slip: ps}} = PaySlipOp.create_pay_slip(attrs, ctx.com, ctx.admin)
    ps
  end

  describe "statutory_contributions/3" do
    setup :setup_statutory

    test "sums wages and each statutory category per employee", ctx do
      emp =
        employee_fixture(
          %{epf_no: "E123", socso_no: "S123", tax_no: "55491986090", id_no: "890703085395"},
          ctx.com,
          ctx.admin
        )

      slip(emp, 5, 2026, %{
        "Monthly Salary" => "3000",
        "EPF By Employer" => "390",
        "EPF By Employee" => "330",
        "SOCSO By Employer" => "51.65",
        "SOCSO By Employee" => "14.75"
      }, ctx)

      rows = HR.statutory_contributions(5, 2026, ctx.com.id)
      row = Enum.find(rows, &(&1.name == emp.name))

      assert Decimal.eq?(row.wages, Decimal.new("3000"))
      assert Decimal.eq?(row.epf_employer, Decimal.new("390"))
      assert Decimal.eq?(row.epf_employee, Decimal.new("330"))
      assert Decimal.eq?(row.socso_employer, Decimal.new("51.65"))
      assert Decimal.eq?(row.socso_employee, Decimal.new("14.75"))
      assert Decimal.eq?(row.eis_employer, Decimal.new("0"))
      assert row.tax_no == "55491986090"
      assert row.id_no == "890703085395"
    end
  end

  alias FullCircle.HR.Statutory.{EpfFormat, SocsoFormat, EisFormat, SocsoEisFormat}

  # Normalize cells to strings so Decimal vs string differences don't mask real diffs.
  defp norm({col, rows}), do: {col, Enum.map(rows, fn r -> Enum.map(r, &to_string/1) end)}

  describe "formatter parity with legacy SQL" do
    setup :setup_statutory

    setup ctx do
      e1 =
        employee_fixture(
          %{name: "Bbb", epf_no: "E1", socso_no: "S1", tax_no: "111", id_no: "900101015555"},
          ctx.com,
          ctx.admin
        )

      e2 =
        employee_fixture(
          %{name: "Aaa", epf_no: "E2", socso_no: "", tax_no: "222", id_no: "910202025555"},
          ctx.com,
          ctx.admin
        )

      slip(e1, 5, 2026, %{
        "Monthly Salary" => "3000",
        "EPF By Employer" => "390",
        "EPF By Employee" => "330",
        "SOCSO By Employer" => "51.65",
        "SOCSO By Employee" => "14.75",
        "EIS By Employer" => "5.90",
        "EIS By Employee" => "5.90"
      }, ctx)

      slip(e2, 5, 2026, %{
        "Monthly Salary" => "2000",
        "EPF By Employer" => "260",
        "EPF By Employee" => "220",
        "SOCSO By Employer" => "34.45",
        "SOCSO By Employee" => "9.85",
        "EIS By Employer" => "3.90",
        "EIS By Employee" => "3.90"
      }, ctx)

      Map.put(ctx, :contribs, HR.statutory_contributions(5, 2026, ctx.com.id))
    end

    test "EPF matches legacy", ctx do
      assert norm(EpfFormat.rows(ctx.contribs, "EPFCODE")) ==
               norm(FullCircle.LegacyStatutory.epf_submit_file_format_query(5, 2026, "EPFCODE", ctx.com.id))
    end

    test "SOCSO matches legacy", ctx do
      assert norm(SocsoFormat.rows(ctx.contribs, "SOCSOCODE")) ==
               norm(FullCircle.LegacyStatutory.socso_submit_file_format_query(5, 2026, "SOCSOCODE", ctx.com.id))
    end

    test "EIS matches legacy", ctx do
      assert norm(EisFormat.rows(ctx.contribs, "EISCODE")) ==
               norm(FullCircle.LegacyStatutory.eis_submit_file_format_query(5, 2026, "EISCODE", ctx.com.id))
    end

    test "SOCSO+EIS matches legacy", ctx do
      assert norm(SocsoEisFormat.rows(ctx.contribs, "EMPCODE")) ==
               norm(FullCircle.LegacyStatutory.socso_eis_submit_file_format_query(5, 2026, "EMPCODE", ctx.com.id))
    end
  end

  alias FullCircle.HR.Statutory

  describe "Statutory dispatcher" do
    setup :setup_statutory

    test "report->setting-key mapping" do
      assert Statutory.code_key("EPF") == "epf_code"
      assert Statutory.code_key("SOCSO") == "socso_code"
      assert Statutory.code_key("EIS") == "eis_code"
      assert Statutory.code_key("SOCSO+EIS") == "socso_code"
      assert Statutory.code_key("PCB") == "pcb_code"
    end

    test "rows/5 returns {col, rows} for EPF", ctx do
      e1 =
        employee_fixture(
          %{name: "Aaa", epf_no: "E1", tax_no: "1", id_no: "900101015555"},
          ctx.com,
          ctx.admin
        )

      slip(e1, 5, 2026, %{"Monthly Salary" => "3000", "EPF By Employee" => "330"}, ctx)
      {col, rows} = Statutory.rows("EPF", 5, 2026, "EPFCODE", ctx.com.id)
      assert col == ["epf_no", "id_number", "name", "wages", "employer", "employee"]
      assert length(rows) == 1
    end
  end

  alias FullCircle.HR.Statutory.PcbFormat

  describe "PcbFormat (CP39 / e-Data PCB)" do
    setup :setup_statutory

    test "produces a spec-correct header and detail lines", ctx do
      e1 =
        employee_fixture(
          %{name: "Nasrul Bin Nayan", tax_no: "55491986090", id_no: "890703085395"},
          ctx.com,
          ctx.admin
        )

      e2 =
        employee_fixture(
          %{name: "Tan Su Yen", tax_no: "50358107000", id_no: "001206080961"},
          ctx.com,
          ctx.admin
        )

      # employee with zero PCB must be excluded
      e3 =
        employee_fixture(
          %{name: "Zero Pcb", tax_no: "999", id_no: "000101010000"},
          ctx.com,
          ctx.admin
        )

      slip(e1, 5, 2026, %{"Monthly Salary" => "5000", "Employee PCB" => "79.20"}, ctx)
      slip(e2, 5, 2026, %{"Monthly Salary" => "8000", "Employee PCB" => "318.90"}, ctx)
      slip(e3, 5, 2026, %{"Monthly Salary" => "1000"}, ctx)

      contribs = HR.statutory_contributions(5, 2026, ctx.com.id)
      text = PcbFormat.text(contribs, "0093787203", 5, 2026)
      lines = String.split(text, "\r\n", trim: true)

      # CRLF used, no other line endings
      assert text =~ "\r\n"
      refute String.contains?(String.replace(text, "\r\n", ""), "\n")

      [header | details] = lines
      assert String.length(header) == 57
      # H + tin(10) + tin(10) + year(4) + month(2) is fully deterministic:
      assert String.starts_with?(header, "H00937872030093787203202605")
      assert String.slice(header, 1, 10) == "0093787203"
      assert String.slice(header, 11, 10) == "0093787203"
      assert String.slice(header, 21, 4) == "2026"
      assert String.slice(header, 25, 2) == "05"
      assert String.slice(header, 27, 10) == "0000039810"
      assert String.slice(header, 37, 5) == "00002"
      assert String.slice(header, 42, 10) == "0000000000"
      assert String.slice(header, 52, 5) == "00000"

      assert length(details) == 2
      d = Enum.find(details, &String.contains?(&1, "Nasrul"))
      assert String.length(d) == 136
      assert String.starts_with?(d, "D55491986090")
      assert String.slice(d, 12, 60) == String.pad_trailing("Nasrul Bin Nayan", 60)
      assert String.slice(d, 72, 12) == String.pad_trailing("", 12)
      assert String.slice(d, 84, 12) == "890703085395"
      assert String.slice(d, 96, 12) == String.pad_trailing("", 12)
      assert String.slice(d, 108, 2) == "MY"
      assert String.slice(d, 110, 8) == "00007920"
      assert String.slice(d, 118, 8) == "00000000"
      assert String.slice(d, 126, 10) == String.pad_trailing("", 10)
    end
  end
end
