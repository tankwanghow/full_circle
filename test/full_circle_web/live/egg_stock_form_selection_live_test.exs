defmodule FullCircleWeb.EggStockFormSelectionLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.EggStock

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})

    {:ok, _} =
      EggStock.save_grades(company.id, [
        %{"name" => "AA", "nickname" => "AA", "position" => 0, "delete" => "false"},
        %{"name" => "A", "nickname" => "A", "position" => 1, "delete" => "false"}
      ])

    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp seed_today(company, user) do
    date = Date.utc_today()
    {:ok, day} = EggStock.get_or_create_day(company.id, date)

    {:ok, day} =
      EggStock.save_day(
        day,
        %{
          "egg_stock_day_details" => %{
            "0" => %{
              "section" => "planned_order",
              "contact_name" => "Ah Seng",
              "quantities" => %{"AA" => "5", "A" => "3"},
              "position" => "0",
              "is_separator" => "false"
            },
            "1" => %{
              "section" => "planned_order",
              "contact_name" => "Kedai Muar",
              "quantities" => %{"AA" => "2"},
              "position" => "1",
              "is_separator" => "false"
            },
            "2" => %{
              "section" => "planned_purchase",
              "contact_name" => "Supplier X",
              "quantities" => %{"AA" => "99"},
              "position" => "2",
              "is_separator" => "false"
            }
          }
        },
        company,
        user
      )

    day =
      FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()],
        force: true
      )

    {date, Map.new(day.egg_stock_day_details, &{&1.contact_name, &1})}
  end

  test "the action bar appears only after a row is selected", %{
    conn: conn,
    company: company,
    user: user
  } do
    {_date, by_name} = seed_today(company, user)
    {:ok, lv, html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    refute html =~ "Print selected"

    html = render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})

    assert html =~ "Print selected"
    assert html =~ "1 selected"
    assert html =~ "8 eggs"
  end

  test "toggling the same row twice clears the action bar", %{
    conn: conn,
    company: company,
    user: user
  } do
    {_date, by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})
    html = render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})

    refute html =~ "Print selected"
  end

  test "the print link carries the selected ids and the day source", %{
    conn: conn,
    company: company,
    user: user
  } do
    {date, by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    html = render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})

    assert html =~ "src=day"
    assert html =~ "date=#{Date.to_iso8601(date)}"
    assert html =~ by_name["Ah Seng"].id
  end

  test "select all takes the sales section only, not planned purchases", %{
    conn: conn,
    company: company,
    user: user
  } do
    {_date, _by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    html = render_click(lv, "toggle_all_print_rows", %{})

    assert html =~ "2 selected"
    assert html =~ "10 eggs"
  end

  test "selection clears when the date changes", %{conn: conn, company: company, user: user} do
    {_date, by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})
    html = render_click(lv, "nav_date", %{"dir" => "prev"})

    refute html =~ "Print selected"
  end

  test "selection clears when the tab changes", %{conn: conn, company: company, user: user} do
    {_date, by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})
    render_click(lv, "switch_tab", %{"tab" => "estimated"})
    html = render_click(lv, "switch_tab", %{"tab" => "now"})

    refute html =~ "Print selected"
  end

  test "selecting a row does not change the stored quantities", %{
    conn: conn,
    company: company,
    user: user
  } do
    {date, by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})

    reloaded =
      EggStock.get_day(company.id, date)
      |> FullCircle.Repo.preload([egg_stock_day_details: EggStock.__day_details_query__()],
        force: true
      )

    row = Enum.find(reloaded.egg_stock_day_details, &(&1.contact_name == "Ah Seng"))
    assert EggStock.to_int(row.quantities["AA"]) == 5
    assert EggStock.to_int(row.quantities["A"]) == 3
  end
end
