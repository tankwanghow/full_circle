defmodule FullCircleWeb.CsvControllerStatutoryTest do
  use FullCircleWeb.ConnCase

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.HRFixtures

  alias FullCircle.{Accounting, HR, PaySlipOp, StatutoryConfig}

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    StatutoryConfig.seed_company!(com.id)

    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)
    funds_ac = account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)
    monthly = HR.get_salary_type_by_name("Monthly Salary", com, admin)

    socso_er =
      salary_type_fixture(
        %{
          name: "SOCSO By Employer",
          type: "Deduction",
          statutory_code: "socso_employer",
          db_ac_name: cr_ac.name,
          db_ac_id: cr_ac.id,
          cr_ac_name: cr_ac.name,
          cr_ac_id: cr_ac.id
        },
        com,
        admin
      )

    socso_ee =
      salary_type_fixture(
        %{
          name: "SOCSO By Employee",
          type: "Deduction",
          statutory_code: "socso_employee",
          db_ac_name: cr_ac.name,
          db_ac_id: cr_ac.id,
          cr_ac_name: cr_ac.name,
          cr_ac_id: cr_ac.id
        },
        com,
        admin
      )

    emp =
      employee_fixture(
        %{name: "Amy", epf_no: "E1", socso_no: "S1", tax_no: "55491986090", id_no: "890703085395"},
        com,
        admin
      )

    date = Timex.end_of_month(2026, 6)

    note = fn st, amt ->
      salary_note_fixture(
        %{
          "note_date" => to_string(date),
          "quantity" => "1",
          "unit_price" => amt,
          "employee_name" => emp.name,
          "employee_id" => emp.id,
          "salary_type_name" => st.name,
          "salary_type_id" => st.id,
          "descriptions" => st.name
        },
        com,
        admin
      )
    end

    notes = [
      {"Monthly Salary", "3000", note.(monthly, "3000")},
      {"SOCSO By Employer", "51.65", note.(socso_er, "51.65")},
      {"SOCSO By Employee", "14.75", note.(socso_ee, "14.75")}
    ]

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

    {:ok, _} =
      PaySlipOp.create_pay_slip(
        %{
          "slip_date" => to_string(date),
          "pay_month" => "6",
          "pay_year" => "2026",
          "employee_name" => emp.name,
          "employee_id" => emp.id,
          "funds_account_name" => funds_ac.name,
          "funds_account_id" => funds_ac.id,
          "pay_slip_amount" => "0",
          "additions" => additions,
          "deductions" => deductions
        },
        com,
        admin
      )

    {:ok, render} = StatutoryConfig.render_file(com.id, "socso_txt", 6, 2026, "SOCSOCODE")

    %{
      conn: log_in_user(conn, admin),
      com: com,
      expected_text: elem(render, 1)
    }
  end

  test "SOCSO download body matches render_file output", %{conn: conn, com: com, expected_text: text} do
    conn =
      get(
        conn,
        ~p"/companies/#{com.id}/csv?report=epfsocsoeis&rep=SOCSO&month=6&year=2026&code=SOCSOCODE"
      )

    assert response(conn, 200) == text
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "content-disposition") == [
             ~s|attachment; filename="socso_txt_6_2026.txt"|
           ]
  end

  test "Contributions download returns per-employee category CSV", %{conn: conn, com: com} do
    conn =
      get(
        conn,
        ~p"/companies/#{com.id}/csv?report=epfsocsoeis&rep=Contributions&month=6&year=2026&code="
      )

    body = response(conn, 200)
    assert body =~ "Amy"
    assert body =~ "socso_employee"
  end
end