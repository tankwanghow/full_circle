defmodule FullCircleWeb.EggStockLoadingListLiveTest do
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

  defp seed_day(company, user, date) do
    {:ok, day} = EggStock.get_or_create_day(company.id, date)

    {:ok, day} =
      EggStock.save_day(
        day,
        %{
          "egg_stock_day_details" => %{
            "0" => %{
              "section" => "planned_order",
              "contact_name" => "",
              "group_name" => "Lorry 2",
              "position" => "0",
              "is_separator" => "true"
            },
            "1" => %{
              "section" => "planned_order",
              "contact_name" => "Ah Seng",
              "quantities" => %{"AA" => "5", "A" => "3"},
              "position" => "1",
              "is_separator" => "false"
            },
            "2" => %{
              "section" => "planned_order",
              "contact_name" => "Kedai Muar",
              "quantities" => %{"AA" => "2"},
              "position" => "2",
              "is_separator" => "false"
            }
          }
        },
        company,
        user
      )

    FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()],
      force: true
    )
  end

  test "day source prints selected rows with group heading and totals", %{
    conn: conn,
    company: company,
    user: user
  } do
    date = ~D[2026-08-10]
    day = seed_day(company, user, date)
    by_name = Map.new(day.egg_stock_day_details, &{&1.contact_name, &1})
    ids = Enum.map_join(["Ah Seng", "Kedai Muar"], ",", &by_name[&1].id)

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "day", date: "2026-08-10", ids: ids]}"
      )

    assert html =~ "Ah Seng"
    assert html =~ "Kedai Muar"
    assert html =~ "Lorry 2"
    assert html =~ "Loaded by"
  end

  test "day source omits rows that were not selected", %{
    conn: conn,
    company: company,
    user: user
  } do
    date = ~D[2026-08-10]
    day = seed_day(company, user, date)
    by_name = Map.new(day.egg_stock_day_details, &{&1.contact_name, &1})

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "day", date: "2026-08-10", ids: by_name["Ah Seng"].id]}"
      )

    assert html =~ "Ah Seng"
    refute html =~ "Kedai Muar"
  end

  test "dow source renders the weekday and its upcoming date", %{
    conn: conn,
    company: company,
    user: user
  } do
    {:ok, _} =
      EggStock.save_dow_lines(
        company.id,
        :sales,
        3,
        [
          %{
            "id" => "",
            "contact_name" => "Weekly Ah Seng",
            "quantities" => %{"AA" => "4"},
            "is_separator" => "false",
            "delete" => "false"
          }
        ],
        company,
        user
      )

    [line] = EggStock.list_dow_lines(company.id, :sales, 3)

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "dow", kind: "sales", dow: "3", ids: line.id]}"
      )

    assert html =~ "Weekly Ah Seng"
    assert html =~ "Wed"
  end

  test "an empty selection renders the sheet with no rows", %{conn: conn, company: company} do
    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "day", date: "2026-08-10", ids: ""]}"
      )

    assert html =~ "Planned sales"
    refute html =~ "Ah Seng"
  end
end
