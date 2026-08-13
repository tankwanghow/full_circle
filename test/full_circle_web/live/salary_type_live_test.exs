defmodule FullCircleWeb.SalaryTypeLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.HR

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    FullCircle.StatutoryConfig.seed_company!(com.id)
    %{conn: log_in_user(conn, admin), admin: admin, com: com}
  end

  defp edit_form(conn, com, admin, name) do
    st = HR.get_salary_type_by_name(name, com, admin)
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/salary_types/#{st.id}/edit")
    {st, lv, html}
  end

  defp type_select(lv), do: lv |> element("#object-form select[name='salary_type[type]']")

  describe "type select on default salary types" do
    test "wage defaults can flip between Addition and FixedWages", %{
      conn: conn,
      com: com,
      admin: admin
    } do
      {_st, lv, _html} = edit_form(conn, com, admin, "Monthly Salary")

      html = type_select(lv) |> render()

      refute html =~ "disabled"
      assert html =~ ~s(value="Addition")
      assert html =~ ~s(value="FixedWages")
      refute html =~ ~s(value="Deduction")
    end

    test "non-wage defaults stay locked", %{conn: conn, com: com, admin: admin} do
      {_st, lv, _html} = edit_form(conn, com, admin, "Annual Leave Taken")

      assert type_select(lv) |> render() =~ "disabled"
    end

    test "re-typing Monthly Salary to FixedWages saves", %{conn: conn, com: com, admin: admin} do
      {st, lv, _html} = edit_form(conn, com, admin, "Monthly Salary")

      lv
      |> form("#object-form", salary_type: %{type: "FixedWages"})
      |> render_submit()

      assert HR.get_salary_type!(st.id, com, admin).type == "FixedWages"
    end
  end

  describe "statutory code options" do
    test "imported calc codes are selectable", %{conn: conn, com: com, admin: admin} do
      # seed_company! imports the template, which ships hrd_corp
      assert "hrd_corp" in FullCircle.StatutoryConfig.calc_codes(com.id)

      {_st, lv, _html} = edit_form(conn, com, admin, "Monthly Salary")

      html =
        lv
        |> element("#object-form select[name='salary_type[statutory_code]']")
        |> render()

      assert html =~ ~s(value="hrd_corp")
    end
  end
end
