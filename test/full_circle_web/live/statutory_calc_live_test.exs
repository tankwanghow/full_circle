defmodule FullCircleWeb.StatutoryCalcLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.HRFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    FullCircle.StatutoryConfig.seed_company!(com.id)
    %{conn: log_in_user(conn, admin), admin: admin, com: com}
  end

  test "index lists seeded calcs", %{conn: conn, com: com} do
    {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/statutory_calcs")
    assert html =~ "epf_employee"
  end

  test "form saves a new version visible in index", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_calcs/new")

    assert lv
           |> form("#object-form", %{
             "calc" => %{
               "code" => "custom_calc",
               "name" => "Custom",
               "effective_from" => "2026-07-01",
               "script" => "result = 42"
             }
           })
           |> render_submit()
           |> then(fn _ ->
             {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/statutory_calcs")
             assert html =~ "custom_calc"
           end)
  end

  test "saving over an existing version asks to confirm, replace updates in place", %{
    conn: conn,
    com: com,
    admin: admin
  } do
    {:ok, _} =
      FullCircle.StatutoryConfig.save_calc(
        %{code: "fix_me", name: "Fix", effective_from: ~D[2026-06-01], script: "result = 1"},
        com,
        admin
      )

    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_calcs/new")

    html =
      lv
      |> form("#object-form", %{
        "calc" => %{
          "code" => "fix_me",
          "name" => "Fix",
          "effective_from" => "2026-06-01",
          "script" => "result = 2"
        }
      })
      |> render_submit()

    assert html =~ "already exists"
    assert html =~ "Replace this version"

    {:ok, _lv, html} =
      lv
      |> element("#replace-version")
      |> render_click()
      |> follow_redirect(conn)

    assert html =~ "Calc version replaced."

    assert %{script: "result = 2"} =
             FullCircle.StatutoryConfig.effective_calc(com.id, "fix_me", ~D[2026-06-30])

    assert [_only_one] =
             FullCircle.StatutoryConfig.list_versions(:calc, com.id)
             |> Enum.filter(&(&1.code == "fix_me"))
  end

  test "invalid script shows PayScript error", %{conn: conn, com: com} do
    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_calcs/new")

    html =
      lv
      |> form("#object-form", %{
        "calc" => %{
          "code" => "bad_calc",
          "name" => "Bad",
          "effective_from" => "2026-07-01",
          "script" => "a = wage_typo\nresult = a"
        }
      })
      |> render_submit()

    assert html =~ "unknown identifier"
  end

  test "preview event renders a value for seeded employee", %{conn: conn, com: com, admin: admin} do
    emp = employee_fixture(%{}, com, admin)
    monthly = FullCircle.HR.get_salary_type_by_name("Monthly Salary", com, admin)

    {:ok, _} =
      FullCircle.Repo.insert(%FullCircle.HR.EmployeeSalaryType{
        employee_id: emp.id,
        salary_type_id: monthly.id,
        amount: Decimal.new("3000")
      })

    {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_calcs/new?code=epf_employee")

    lv
    |> form("#object-form")
    |> render_change(%{
      "_target" => ["calc", "employee_name"],
      "calc" => %{
        "employee_name" => emp.name,
        "pay_month" => "6",
        "pay_year" => "2026"
      }
    })

    html = render_click(lv, "preview")
    assert html =~ "New:"
    assert html =~ "Current:"
  end

  test "non-admin redirected", %{conn: _conn, com: com, admin: admin} do
    clerk = user_fixture()
    {:ok, _} = FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
    conn = log_in_user(build_conn(), clerk)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/companies/#{com.id}/statutory_calcs")

    assert to =~ "/companies/#{com.id}/dashboard"
  end

  test "export endpoint returns JSON with bundle_version", %{conn: conn, com: com} do
    conn = get(conn, ~p"/companies/#{com.id}/statutory_bundle/export")
    assert conn.status == 200
    assert conn.resp_body =~ "bundle_version"
  end
end