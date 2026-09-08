defmodule FullCircleWeb.PunchPhotoThumbnailTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.HRFixtures

  alias FullCircle.HR.TimeAttend
  alias FullCircle.Repo

  # Thumbnails are always rendered; the "Show photos" toggle adds
  # `show-punch-photos` to the list wrapper and CSS does the rest. That keeps
  # the toggle instant — Punch IO streams its rows, and a stream comprehension
  # emits nothing on re-render, so re-rendering them would need a re-query.

  setup %{conn: conn} do
    user = user_fixture()
    comp = company_fixture(user, %{})
    emp = employee_fixture(%{}, comp, user)

    ta =
      Repo.insert!(%TimeAttend{
        company_id: comp.id,
        employee_id: emp.id,
        user_id: user.id,
        punch_time: DateTime.utc_now() |> DateTime.truncate(:second),
        flag: "1_IN_1",
        status: "Draft",
        input_medium: "QRGate",
        photo_path: "#{comp.id}/punch_photos/2026/09/#{Ecto.UUID.generate()}.jpg"
      })

    # Punch Card previews a pay slip on mount, which needs the PCB salary type.
    ensure_salary_type(comp, user, "Employee PCB", "Deduction")

    %{conn: log_in_user(conn, user), comp: comp, emp: emp, ta: ta}
  end

  describe "Punch IO" do
    test "renders the thumbnail but keeps it hidden by default", %{conn: conn, comp: comp, ta: ta} do
      {:ok, lv, html} = live(conn, ~p"/companies/#{comp.id}/PunchIndex")

      assert html =~ "TimeAttend/#{ta.id}/photo"
      assert has_element?(lv, "a.punch-photo")
      refute has_element?(lv, "#punch_photos_wrapper.show-punch-photos")
    end

    test "reveals photos when the URL asks for them", %{conn: conn, comp: comp} do
      {:ok, lv, _html} =
        live(conn, ~p"/companies/#{comp.id}/PunchIndex?search[show_photos]=true")

      assert has_element?(lv, "#punch_photos_wrapper.show-punch-photos")
    end

    test "toggles live on click, without a form submit", %{conn: conn, comp: comp} do
      {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/PunchIndex")
      refute has_element?(lv, "#punch_photos_wrapper.show-punch-photos")

      lv |> element("#search_show_photos") |> render_click()
      assert has_element?(lv, "#punch_photos_wrapper.show-punch-photos")

      lv |> element("#search_show_photos") |> render_click()
      refute has_element?(lv, "#punch_photos_wrapper.show-punch-photos")
    end
  end

  describe "Punch Card" do
    test "renders the thumbnail but keeps it hidden by default", %{
      conn: conn,
      comp: comp,
      emp: emp,
      ta: ta
    } do
      {:ok, lv, html} = live(conn, punch_card_path(comp, emp, false))

      assert html =~ "TimeAttend/#{ta.id}/photo"
      assert has_element?(lv, "a.punch-photo")
      refute has_element?(lv, "#punches_list.show-punch-photos")
    end

    test "reveals photos when the URL asks for them", %{conn: conn, comp: comp, emp: emp} do
      {:ok, lv, _html} = live(conn, punch_card_path(comp, emp, true))

      assert has_element?(lv, "#punches_list.show-punch-photos")
    end

    test "toggles live on click, without a form submit", %{conn: conn, comp: comp, emp: emp} do
      {:ok, lv, _html} = live(conn, punch_card_path(comp, emp, false))
      refute has_element?(lv, "#punches_list.show-punch-photos")

      lv |> element("#search_show_photos") |> render_click()
      assert has_element?(lv, "#punches_list.show-punch-photos")

      lv |> element("#search_show_photos") |> render_click()
      refute has_element?(lv, "#punches_list.show-punch-photos")
    end
  end

  describe "the toggle fires on click, not on blur" do
    # core_components' .input declares attr :"phx-debounce" with default "blur",
    # so every input debounces unless it opts out. On this checkbox that made
    # the toggle wait for focus to leave, which is not "live".
    test "Punch IO checkbox has no phx-debounce", %{conn: conn, comp: comp} do
      {:ok, lv, _html} = live(conn, ~p"/companies/#{comp.id}/PunchIndex")

      assert has_element?(lv, "#search_show_photos")
      refute has_element?(lv, "#search_show_photos[phx-debounce]")
    end

    test "Punch Card checkbox has no phx-debounce", %{conn: conn, comp: comp, emp: emp} do
      {:ok, lv, _html} = live(conn, punch_card_path(comp, emp, false))

      assert has_element?(lv, "#search_show_photos")
      refute has_element?(lv, "#search_show_photos[phx-debounce]")
    end
  end

  describe "Punch Card form" do
    test "ticking Show photos does not remount the page", %{conn: conn, comp: comp, emp: emp} do
      # The filter form is phx-change="search", which push_navigates. Without a
      # dedicated no-op clause the toggle remounts instead of being live.
      {:ok, lv, _html} = live(conn, punch_card_path(comp, emp, false))
      today = Timex.today()

      html =
        lv
        |> element("#search-form")
        |> render_change(%{
          "_target" => ["search", "show_photos"],
          "search" => %{
            "employee_name" => emp.name,
            "month" => to_string(today.month),
            "year" => to_string(today.year),
            "show_photos" => "true"
          }
        })

      assert is_binary(html)
      assert has_element?(lv, "#search_show_photos")
    end
  end

  describe "Punch Card with no employee selected" do
    # filter_punches/4 rebuilds the search assign on its no-employee branch,
    # which is the page's default state.
    test "keeps the Show photos toggle when asked for photos", %{conn: conn, comp: comp} do
      qry = URI.encode_query(%{"search[employee_name]" => "", "search[show_photos]" => "true"})

      {:ok, _lv, html} = live(conn, "/companies/#{comp.id}/PunchCard?#{qry}")

      assert html =~ "Show photos"
    end

    test "renders with no employee and the toggle off", %{conn: conn, comp: comp} do
      {:ok, _lv, html} = live(conn, "/companies/#{comp.id}/PunchCard")

      assert html =~ "Show photos"
    end
  end

  defp punch_card_path(comp, emp, show_photos?) do
    today = Timex.today()

    qry =
      URI.encode_query(%{
        "search[employee_name]" => emp.name,
        "search[month]" => today.month,
        "search[year]" => today.year,
        "search[show_photos]" => to_string(show_photos?)
      })

    "/companies/#{comp.id}/PunchCard?#{qry}"
  end

  defp ensure_salary_type(com, user, name, type) do
    case FullCircle.HR.get_salary_type_by_name(name, com, user) do
      nil ->
        cr = FullCircle.Accounting.get_account_by_name("Salaries and Wages Payable", com, user)

        salary_type_fixture(
          %{
            name: name,
            type: type,
            db_ac_name: cr.name,
            db_ac_id: cr.id,
            cr_ac_name: cr.name,
            cr_ac_id: cr.id
          },
          com,
          user
        )

      st ->
        st
    end
  end
end
