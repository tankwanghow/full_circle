defmodule FullCircleWeb.HolidayLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.HRFixtures

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    holiday = holiday_fixture(%{name: "TESTHOLIDAY", short_name: "TH"}, comp, user)
    %{conn: log_in_user(conn, user), user: user, comp: comp, holiday: holiday}
  end

  describe "data value" do
    setup %{conn: conn, comp: comp, holiday: holiday} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays/#{holiday.id}/edit")
      %{conn: conn, lv: lv, html: html, obj: holiday}
    end

    test_input_value("holiday", "input", :text, "name")
    test_input_value("holiday", "input", :text, "short_name")
  end

  describe "data validation" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "name can't be blank", %{lv: lv} do
      html =
        lv
        |> element("#holiday-form")
        |> render_change(%{holiday: %{name: ""}})

      text = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()
      assert text =~ "can't be blank"
    end

    test "short_name can't be blank", %{lv: lv} do
      html =
        lv
        |> element("#holiday-form")
        |> render_change(%{holiday: %{short_name: ""}})

      text = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s|p.text-rose-600|) |> LazyHTML.text()
      assert text =~ "can't be blank"
    end
  end

  describe "Edit" do
    setup %{conn: conn, comp: comp, holiday: holiday} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays/#{holiday.id}/edit")
      %{conn: conn, lv: lv, html: html, comp: comp, holiday: holiday}
    end

    test "save valid holiday", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#holiday-form",
          holiday: valid_holiday_attributes(%{name: "NewYear", holidate: "2099-01-01"})
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "NewYear"
      assert html =~ "Holiday updated successfully"
    end

    test "save invalid holiday", %{lv: lv} do
      html =
        lv
        |> form("#holiday-form", holiday: %{name: ""})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "Edit Holiday"
    end

    test "form layout", %{html: html} do
      assert html =~ "Edit Holiday"
      assert html =~ "Holiday Name\n</label>"
      assert html =~ "Short Name\n</label>"
      assert html =~ "Holiday Date\n</label>"
    end
  end

  describe "New" do
    setup %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays/new")
      %{conn: conn, lv: lv, html: html}
    end

    test "save valid holiday", %{conn: conn, lv: lv} do
      {:ok, _, html} =
        lv
        |> form("#holiday-form",
          holiday: valid_holiday_attributes(%{name: "NewYear", holidate: "2099-01-01"})
        )
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "NewYear"
      assert html =~ "Holiday created successfully"
    end

    test "save invalid holiday", %{lv: lv} do
      html =
        lv
        |> form("#holiday-form", holiday: %{name: ""})
        |> render_submit()

      assert html =~ "Failed"
      assert html =~ "New Holiday"
    end

    test "form layout", %{html: html} do
      assert html =~ "New Holiday"
      assert html =~ "Holiday Name\n</label>"
      assert html =~ "Short Name\n</label>"
      assert html =~ "Holiday Date\n</label>"
    end
  end

  describe "Index" do
    test "layout", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays")
      assert html =~ "Holiday Listing"

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s|form input[name="search[terms]"]|)
             |> LazyHTML.to_tree() != []

      assert html =~ "Holiday Information"
    end

    test "holiday list", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays")
      text = LazyHTML.from_fragment(html) |> LazyHTML.query(~s|div#objects_list|) |> LazyHTML.text()
      assert text =~ "TESTHOLIDAY"
    end

    test "add new holiday", %{conn: conn, comp: comp} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/holidays")

      assert LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s|a#new_holiday|)
             |> LazyHTML.to_tree() != []

      {:ok, _lv, html} = lv |> element("#new_holiday") |> render_click() |> follow_redirect(conn)
      assert html =~ "New Holiday"
    end
  end
end
