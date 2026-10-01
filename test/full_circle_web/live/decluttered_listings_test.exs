defmodule FullCircleWeb.DeclutteredListingsTest do
  # Smoke tests for the listings moved onto ListComponents (shared top bar,
  # table frame, one line per record). Rows render real records where a
  # fixture exists, which is where template errors would surface.
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.HRFixtures
  import FullCircle.ChequeFixtures
  import FullCircle.ReceiveFundFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    company = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, company: company}
  end

  defp assert_list_page(lv) do
    assert has_element?(lv, "h1")
    refute render(lv) =~ "bg-amber-200 border-b border-t"
  end

  for path <- ~w(Journal Weighing flocks houses harvests) do
    @path path
    test "#{path} listing renders on the shared layout", %{conn: conn, company: company} do
      {:ok, lv, _} = live(conn, "/companies/#{company.id}/#{@path}")
      assert_list_page(lv)
    end
  end

  test "Advance listing shows an advance on one line", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    emp = employee_fixture(%{}, company, admin)
    funds = funds_account_fixture(company, admin)

    adv =
      advance_fixture(
        %{
          "slip_date" => Date.to_iso8601(Date.utc_today()),
          "amount" => "500",
          "employee_name" => emp.name,
          "employee_id" => emp.id,
          "funds_account_name" => funds.name,
          "funds_account_id" => funds.id,
          "note" => "advance"
        },
        company,
        admin
      )

    {:ok, lv, _} = live(conn, "/companies/#{company.id}/Advance")
    assert_list_page(lv)
    assert has_element?(lv, "#objects-#{adv.id}", emp.name)
    assert has_element?(lv, "#objects-#{adv.id} .text-right", "500.00")
  end

  test "Salary Note listing shows a note on one line", %{
    conn: conn,
    admin: admin,
    company: company
  } do
    emp = employee_fixture(%{}, company, admin)
    st = FullCircle.HR.get_salary_type_by_name("Annual Leave Taken", company, admin)

    note =
      salary_note_fixture(
        %{
          "note_date" => Date.to_iso8601(Date.utc_today()),
          "quantity" => "2",
          "unit_price" => "1",
          "employee_name" => emp.name,
          "employee_id" => emp.id,
          "salary_type_name" => st.name,
          "salary_type_id" => st.id,
          "descriptions" => "annual leave"
        },
        company,
        admin
      )

    {:ok, lv, _} = live(conn, "/companies/#{company.id}/SalaryNote")
    assert_list_page(lv)
    assert has_element?(lv, "#objects-#{note.id}", emp.name)
  end

  test "Deposit listing shows a deposit", %{conn: conn, admin: admin, company: company} do
    dep = deposit_fixture(company, admin)
    {:ok, lv, _} = live(conn, "/companies/#{company.id}/Deposit")
    assert_list_page(lv)
    assert has_element?(lv, "#objects_list", dep.deposit_no)
  end

  test "Return Cheque listing renders", %{conn: conn, company: company} do
    {:ok, lv, _} = live(conn, "/companies/#{company.id}/ReturnCheque")
    assert_list_page(lv)
  end
end
