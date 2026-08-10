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
    # pin the href itself: the bare id also renders in a hidden input on every render
    assert html =~ "ids=#{by_name["Ah Seng"].id}"
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

  # The selection checkbox sits inside the phx-change="validate" form. A `name`
  # attribute would put it in the submitted params and reach the changeset.
  test "the selection checkbox carries no name attribute", %{
    conn: conn,
    company: company,
    user: user
  } do
    {_date, _by_name} = seed_today(company, user)
    {:ok, _lv, html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    boxes =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s{input[type=checkbox][phx-click=toggle_print_row]})

    # guards against a vacuous pass if the markup ever stops rendering checkboxes;
    # 2 == the planned sales rows only, the planned purchase row gets no checkbox
    assert Enum.count(boxes) == 2

    # LazyHTML.attribute/2 omits elements lacking the attribute, so [] proves none carry it
    assert LazyHTML.attribute(boxes, "name") == []
  end

  test "a real form change with a row selected does not corrupt stored quantities", %{
    conn: conn,
    company: company,
    user: user
  } do
    {date, by_name} = seed_today(company, user)
    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")

    render_click(lv, "toggle_print_row", %{"id" => by_name["Ah Seng"].id})

    # serializes the real rendered form — the path a named checkbox would leak through
    lv |> form("#day-form") |> render_change()

    # switch_tab flushes the pending autosave, writing the serialized params to the DB
    render_click(lv, "switch_tab", %{"tab" => "estimated"})

    reloaded =
      EggStock.get_day(company.id, date)
      |> FullCircle.Repo.preload([egg_stock_day_details: EggStock.__day_details_query__()],
        force: true
      )

    row = Enum.find(reloaded.egg_stock_day_details, &(&1.contact_name == "Ah Seng"))
    assert EggStock.to_int(row.quantities["AA"]) == 5
    assert EggStock.to_int(row.quantities["A"]) == 3
  end

  # --- Weekly Sales tab selection ---

  defp seed_weekly(company, user, dow) do
    {:ok, _} =
      EggStock.save_dow_lines(
        company.id,
        :sales,
        dow,
        [
          %{
            "id" => "",
            "contact_name" => "Weekly Ah Seng",
            "quantities" => %{"AA" => "4", "A" => "1"},
            "is_separator" => "false",
            "delete" => "false"
          },
          %{
            "id" => "",
            "contact_name" => "Weekly Kedai",
            "quantities" => %{"AA" => "2"},
            "is_separator" => "false",
            "delete" => "false"
          }
        ],
        company,
        user
      )

    Map.new(EggStock.list_dow_lines(company.id, :sales, dow), &{&1.contact_name, &1})
  end

  # Any weekday other than today, so the book is not read-only.
  defp other_dow, do: rem(Date.day_of_week(Date.utc_today()), 7) + 1

  test "the weekly action bar appears after selecting a row", %{
    conn: conn,
    company: company,
    user: user
  } do
    dow = other_dow()
    by_name = seed_weekly(company, user, dow)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")
    render_click(lv, "switch_tab", %{"tab" => "weekly_sales"})
    render_click(lv, "select_dow", %{"dow" => to_string(dow)})

    html = render_click(lv, "toggle_dow_print_row", %{"id" => by_name["Weekly Ah Seng"].id})

    assert html =~ "Print selected"
    assert html =~ "1 selected"
    assert html =~ "5 eggs"
    assert html =~ "src=dow"
    assert html =~ "kind=sales"
  end

  test "the weekly selection clears when the weekday changes", %{
    conn: conn,
    company: company,
    user: user
  } do
    dow = other_dow()
    by_name = seed_weekly(company, user, dow)
    next_dow = rem(dow, 7) + 1

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")
    render_click(lv, "switch_tab", %{"tab" => "weekly_sales"})
    render_click(lv, "select_dow", %{"dow" => to_string(dow)})
    render_click(lv, "toggle_dow_print_row", %{"id" => by_name["Weekly Ah Seng"].id})

    html = render_click(lv, "select_dow", %{"dow" => to_string(next_dow)})

    refute html =~ "Print selected"
  end

  test "weekly select all takes every saved row on that weekday", %{
    conn: conn,
    company: company,
    user: user
  } do
    dow = other_dow()
    seed_weekly(company, user, dow)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")
    render_click(lv, "switch_tab", %{"tab" => "weekly_sales"})
    render_click(lv, "select_dow", %{"dow" => to_string(dow)})

    html = render_click(lv, "toggle_all_dow_print_rows", %{})

    assert html =~ "2 selected"
    assert html =~ "7 eggs"
  end

  # The selection checkbox sits inside the phx-change="validate_dow" form. A `name`
  # attribute would put it in the submitted params and reach the changeset.
  test "the weekly selection checkbox carries no name attribute", %{
    conn: conn,
    company: company,
    user: user
  } do
    dow = other_dow()
    seed_weekly(company, user, dow)

    {:ok, lv, _html} = live(conn, ~p"/companies/#{company.id}/egg_stock")
    render_click(lv, "switch_tab", %{"tab" => "weekly_sales"})
    html = render_click(lv, "select_dow", %{"dow" => to_string(dow)})

    boxes =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s{input[type=checkbox][phx-click=toggle_dow_print_row]})

    # anti-vacuity guard: 2 seeded rows means 2 checkboxes must be present
    assert Enum.count(boxes) == 2

    # LazyHTML.attribute/2 omits elements lacking the attribute, so [] proves none carry it
    assert LazyHTML.attribute(boxes, "name") == []
  end
end
