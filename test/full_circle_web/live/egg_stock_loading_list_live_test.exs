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
            },
            # legacy planned-sales section name, still read via planned_sales_sections()
            "3" => %{
              "section" => "actual_order",
              "contact_name" => "Legacy Ah Meng",
              "quantities" => %{"AA" => "7"},
              "position" => "0",
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

  # pins the plural planned_sales_sections() in the day query (egg_stock.ex)
  test "day source includes rows in the legacy actual_order section", %{
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
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "day", date: "2026-08-10", ids: by_name["Legacy Ah Meng"].id]}"
      )

    assert html =~ "Legacy Ah Meng"
  end

  # Each separator is one lorry load, so it needs its own subtotal even when the
  # label was left blank. A lone group would only repeat the grand total.
  test "each blank separator prints its own subtotal, and a lone group prints none", %{
    conn: conn,
    company: company,
    user: user
  } do
    date = ~D[2026-08-13]
    {:ok, day} = EggStock.get_or_create_day(company.id, date)

    row = fn pos, name ->
      %{
        "section" => "planned_order",
        "contact_name" => name,
        "quantities" => %{"AA" => "4"},
        "position" => to_string(pos),
        "is_separator" => "false"
      }
    end

    sep = fn pos ->
      %{
        "section" => "planned_order",
        "contact_name" => "",
        "group_name" => "",
        "position" => to_string(pos),
        "is_separator" => "true"
      }
    end

    {:ok, day} =
      EggStock.save_day(
        day,
        %{
          "egg_stock_day_details" => %{
            "0" => row.(0, "Lorry A Cust"),
            "1" => sep.(1),
            "2" => row.(2, "Lorry B Cust"),
            "3" => sep.(3),
            "4" => row.(4, "Lorry C Cust")
          }
        },
        company,
        user
      )

    by_name =
      FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()],
        force: true
      ).egg_stock_day_details
      |> Enum.reject(& &1.is_separator)
      |> Map.new(&{&1.contact_name, &1})

    sheet = fn names ->
      ids = Enum.map_join(names, ",", &by_name[&1].id)

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "day", date: Date.to_iso8601(date), ids: ids]}"
        )

      html
    end

    three = sheet.(["Lorry A Cust", "Lorry B Cust", "Lorry C Cust"])
    assert subtotal_rows(three) == 3
    assert three =~ "Subtotal"

    assert subtotal_rows(sheet.(["Lorry B Cust"])) == 0
  end

  # Matches the rendered attribute, not the `.subtotal-row` rule in the <style> block.
  defp subtotal_rows(html),
    do: html |> String.split(~s(class="subtotal-row")) |> length() |> Kernel.-(1)

  defp seed_dow(company, user, kind, dow, name) do
    {:ok, _} =
      EggStock.save_dow_lines(
        company.id,
        kind,
        dow,
        [
          %{
            "id" => "",
            "contact_name" => name,
            "quantities" => %{"AA" => "4"},
            "is_separator" => "false",
            "delete" => "false"
          }
        ],
        company,
        user
      )

    [line] = EggStock.list_dow_lines(company.id, kind, dow)
    line
  end

  test "dow source with no date param falls back to the upcoming occurrence", %{
    conn: conn,
    company: company,
    user: user
  } do
    line = seed_dow(company, user, :sales, 3, "Weekly Ah Seng")
    upcoming = EggStock.dow_date(Date.utc_today(), 3)

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "dow", kind: "sales", dow: "3", ids: line.id]}"
      )

    assert html =~ "Weekly Ah Seng"
    assert html =~ "Wed"
    assert html =~ FullCircleWeb.Helpers.format_date(upcoming)
  end

  # The DOW buttons on the weekly book are anchored on the board date, which can
  # be in the past. The sheet must print the date the user saw on the button.
  test "dow source prints the board-anchored date from the date param", %{
    conn: conn,
    company: company,
    user: user
  } do
    line = seed_dow(company, user, :sales, 3, "Weekly Ah Seng")

    upcoming = EggStock.dow_date(Date.utc_today(), 3)
    board_date = Date.add(upcoming, -7)

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "dow", kind: "sales", dow: "3", date: Date.to_iso8601(board_date), ids: line.id]}"
      )

    assert html =~ "Wed"
    assert html =~ FullCircleWeb.Helpers.format_date(board_date)
    refute html =~ FullCircleWeb.Helpers.format_date(upcoming)
  end

  test "the weekly purchase book prints under the purchases title", %{
    conn: conn,
    company: company,
    user: user
  } do
    line = seed_dow(company, user, :purchase, 3, "Weekly Supplier")

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "dow", kind: "purchase", dow: "3", ids: line.id]}"
      )

    assert html =~ "Weekly Supplier"
    assert html =~ "Planned purchases"
    refute html =~ "Planned sales"
  end

  test "the weekly sales book prints under the sales title", %{
    conn: conn,
    company: company,
    user: user
  } do
    line = seed_dow(company, user, :sales, 3, "Weekly Ah Seng")

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "dow", kind: "sales", dow: "3", ids: line.id]}"
      )

    assert html =~ "Planned sales"
    refute html =~ "Planned purchases"
  end

  test "an empty selection renders the sheet with no rows", %{
    conn: conn,
    company: company,
    user: user
  } do
    date = ~D[2026-08-10]
    day = seed_day(company, user, date)
    names = Enum.map(day.egg_stock_day_details, & &1.contact_name)

    # Both rows are on the day board, so their absence below is the empty
    # selection filtering them out, not an empty database.
    assert "Ah Seng" in names
    assert "Kedai Muar" in names

    {:ok, _lv, html} =
      live(
        conn,
        ~p"/companies/#{company.id}/EggStock/loading_list?#{[src: "day", date: "2026-08-10", ids: ""]}"
      )

    assert html =~ "Planned sales"
    refute html =~ "Ah Seng"
    refute html =~ "Kedai Muar"
  end
end
