# Egg Stock Planned Sales Loading List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user tick a subset of planned sales rows on the egg stock day board or the weekly sales book and print just those rows as a lorry loading list.

**Architecture:** One context function (`EggStock.loading_list_groups/3`) resolves selected row ids into ordered, separator-grouped rows for either source (day board or weekly book). One print LiveView (`EggStockLive.LoadingList`) renders both, differing only in its date line. The two board surfaces in `egg_stock_live/form.ex` each grow a gutter checkbox column, a section "select all", and an action bar whose print link is built from the current selection.

**Tech Stack:** Elixir 1.19.5, Phoenix 1.8.3, Phoenix LiveView 1.1.x, Ecto, Tailwind CSS 3.4, Gettext.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-10-egg-stock-planned-sales-loading-list-design.md`.
- Commit directly on `master`. No feature branches.
- Never run bare `mix format` — it rewrites ~14 unrelated already-unformatted files. Format only the files you touched: `mix format <path> <path>`.
- All schemas use `use FullCircle.Schema` (binary_id primary keys). Row ids are UUID strings.
- All queries must be company-scoped. The egg stock board is light-mode only — `form.ex` and `print.ex` carry no `dark:` Tailwind variants, so new markup must not introduce any.
- All user-visible strings go through `gettext(...)`.
- Planned sales sections must be filtered with `EggStock.planned_sales_sections()` (which is `["planned_order", "actual_order"]`) — never hardcode only `"planned_order"`.
- Run tests with `mix test`. QueryRepo log noise during tests is harmless.

---

### Task 1: Context — `loading_list_groups/3` for the day board

Resolves selected `EggStockDayDetail` ids into ordered groups. A group's name comes from the separator row above it; groups with no selected row never get created.

**Files:**
- Modify: `lib/full_circle/egg_stock.ex` (add a new section after the `list_dow_lines/3` / `dow_totals/4` block, around line 234)
- Test: `test/full_circle/egg_stock_test.exs` (new `describe` block at the end of the file)

**Interfaces:**
- Consumes: `EggStock.planned_sales_sections/0`, `EggStock.normalize_qty_map/1`, the `EggStockDayDetail` and `EggStockDay` schemas, `FullCircle.Accounting.Contact` (all already aliased at the top of `egg_stock.ex`).
- Produces:
  - `EggStock.loading_list_groups(company_id :: binary, source, selected_ids :: [binary]) :: [group]`
  - `source :: {:day, Date.t()} | {:dow, kind :: String.t() | atom, dow :: integer}` — the `{:dow, _, _}` clause lands in Task 2.
  - `group :: %{group_name: String.t(), rows: [row]}`
  - `row :: %{id: String.t(), contact_name: String.t(), quantities: %{String.t() => integer}}`
  - Rows are ordered by board `position`. Groups are in board order. Group names may be `""` (rows appearing before any separator).

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/egg_stock_test.exs`, inside the top-level `defmodule` (the `setup` block already provides `admin`, `company`, `contact` and grades `AA` / `A` / `B`):

```elixir
  describe "loading_list_groups/3 for the day board" do
    setup %{company: company, admin: admin, contact: contact} do
      date = ~D[2026-08-10]
      {:ok, day} = EggStock.get_or_create_day(company.id, date)

      {:ok, day} =
        EggStock.save_day(
          day,
          %{
            "egg_stock_day_details" => %{
              "0" => %{
                "section" => "planned_order",
                "contact_id" => contact.id,
                "contact_name" => contact.name,
                "quantities" => %{"AA" => "10"},
                "position" => "0",
                "is_separator" => "false"
              },
              "1" => %{
                "section" => "planned_order",
                "contact_name" => "",
                "group_name" => "Lorry 2",
                "position" => "1",
                "is_separator" => "true"
              },
              "2" => %{
                "section" => "planned_order",
                "contact_name" => "Ah Seng",
                "quantities" => %{"AA" => "5", "A" => "3"},
                "position" => "2",
                "is_separator" => "false"
              },
              "3" => %{
                "section" => "planned_order",
                "contact_name" => "Kedai Muar",
                "quantities" => %{"B" => "7"},
                "position" => "3",
                "is_separator" => "false"
              },
              "4" => %{
                "section" => "planned_purchase",
                "contact_name" => "Supplier X",
                "quantities" => %{"AA" => "99"},
                "position" => "4",
                "is_separator" => "false"
              }
            }
          },
          company,
          admin
        )

      day =
        FullCircle.Repo.preload(day, [egg_stock_day_details: EggStock.__day_details_query__()],
          force: true
        )

      by_name = Map.new(day.egg_stock_day_details, &{&1.contact_name, &1})
      %{date: date, day: day, by_name: by_name}
    end

    test "groups selected rows under the separator above them", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Ah Seng"].id, by_name["Kedai Muar"].id]

      assert [%{group_name: "Lorry 2", rows: rows}] =
               EggStock.loading_list_groups(company.id, {:day, date}, ids)

      assert Enum.map(rows, & &1.contact_name) == ["Ah Seng", "Kedai Muar"]
      assert Enum.at(rows, 0).quantities == %{"AA" => 5, "A" => 3}
    end

    test "rows before any separator land in an unnamed group", %{
      company: company,
      contact: contact,
      date: date,
      by_name: by_name
    } do
      ids = [by_name[contact.name].id, by_name["Kedai Muar"].id]

      assert [
               %{group_name: "", rows: [%{contact_name: first}]},
               %{group_name: "Lorry 2", rows: [%{contact_name: "Kedai Muar"}]}
             ] = EggStock.loading_list_groups(company.id, {:day, date}, ids)

      assert first == contact.name
    end

    test "groups with no selected row are dropped", %{
      company: company,
      contact: contact,
      date: date,
      by_name: by_name
    } do
      ids = [by_name[contact.name].id]

      assert [%{group_name: "", rows: [_]}] =
               EggStock.loading_list_groups(company.id, {:day, date}, ids)
    end

    test "rows print in board position order regardless of id order", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Kedai Muar"].id, by_name["Ah Seng"].id]

      assert [%{rows: rows}] = EggStock.loading_list_groups(company.id, {:day, date}, ids)
      assert Enum.map(rows, & &1.contact_name) == ["Ah Seng", "Kedai Muar"]
    end

    test "ignores ids from the planned purchase section", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Supplier X"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:day, date}, ids)
    end

    test "ignores ids that belong to another date", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:day, ~D[2026-08-11]}, ids)
    end

    test "ignores ids that belong to another company", %{
      company: company,
      date: date,
      by_name: by_name
    } do
      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(other_company.id, {:day, date}, ids)
      assert [_] = EggStock.loading_list_groups(company.id, {:day, date}, ids)
    end

    test "returns no groups for an empty selection", %{company: company, date: date} do
      assert [] == EggStock.loading_list_groups(company.id, {:day, date}, [])
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/egg_stock_test.exs`

Expected: the eight new tests FAIL with `** (UndefinedFunctionError) function FullCircle.EggStock.loading_list_groups/3 is undefined or private`. The pre-existing tests in the file still pass.

- [ ] **Step 3: Write the implementation**

In `lib/full_circle/egg_stock.ex`, insert immediately after the `dow_totals/4` function (before `save_dow_lines/6`):

```elixir
  # --- Loading list (selected planned sales rows) ---

  @doc """
  Selected planned-sales rows for a loading list, in board order, grouped by the
  separator label above them.

  `source` is `{:day, %Date{}}` for the day board or `{:dow, kind, dow}` for the
  weekly book. Ids that do not resolve inside that scope are dropped, which is
  also the multi-tenant guard. Groups containing no selected row are omitted.
  """
  def loading_list_groups(company_id, source, selected_ids) do
    selected = MapSet.new(selected_ids, &to_string/1)

    company_id
    |> loading_list_source_rows(source)
    |> Enum.reduce({[], ""}, fn row, {groups, current} ->
      cond do
        row.is_separator ->
          {groups, row.group_name || ""}

        MapSet.member?(selected, to_string(row.id)) ->
          entry = %{
            id: to_string(row.id),
            contact_name: row.contact_name || "",
            quantities: normalize_qty_map(row.quantities)
          }

          case groups do
            [%{group_name: ^current, rows: rows} = g | rest] ->
              {[%{g | rows: rows ++ [entry]} | rest], current}

            _ ->
              {[%{group_name: current, rows: [entry]} | groups], current}
          end

        true ->
          {groups, current}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp loading_list_source_rows(company_id, {:day, date}) do
    from(d in EggStockDayDetail,
      join: day in EggStockDay,
      on: day.id == d.egg_stock_day_id,
      left_join: c in Contact,
      on: c.id == d.contact_id,
      where:
        day.company_id == ^company_id and day.stock_date == ^date and
          d.section in ^planned_sales_sections(),
      order_by: [asc: d.position, asc: d.id],
      select: d,
      select_merge: %{contact_name: fragment("coalesce(?, ?)", c.name, d.contact_name)}
    )
    |> Repo.all()
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/egg_stock_test.exs`

Expected: PASS, including the eight new tests.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/egg_stock.ex test/full_circle/egg_stock_test.exs
git add lib/full_circle/egg_stock.ex test/full_circle/egg_stock_test.exs
git commit -m "feat(egg-stock): group selected planned sales rows for a loading list"
```

---

### Task 2: Context — weekly book source clause

Adds the `{:dow, kind, dow}` clause so the weekly sales book feeds the same grouping logic, plus a public `dow_date/2` the print view needs for its date line.

**Files:**
- Modify: `lib/full_circle/egg_stock.ex` (add one `loading_list_source_rows/2` clause next to the one from Task 1; add `dow_date/2` near `list_dow_lines/3`)
- Modify: `lib/full_circle_web/live/egg_stock_live/form.ex:1300` (delegate the existing private `dow_date/2` to the context so there is one definition)
- Test: `test/full_circle/egg_stock_test.exs` (new `describe` block)

**Interfaces:**
- Consumes: `EggStock.loading_list_groups/3` and the `group` / `row` shapes from Task 1; `EggStock.list_dow_lines/3` (already exists — it orders by `position` then `id` and coalesces the linked contact name over the stored `contact_name`).
- Produces:
  - `EggStock.loading_list_groups(company_id, {:dow, kind, dow}, selected_ids)` — same return shape as Task 1. `kind` accepts `:sales`, `:purchase`, `"sales"` or `"purchase"`; `dow` is `1..7` with Monday = 1.
  - `EggStock.dow_date(date :: Date.t(), dow :: integer) :: Date.t()` — the next occurrence of `dow` on or after `date`.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/egg_stock_test.exs`:

```elixir
  describe "loading_list_groups/3 for the weekly book" do
    setup %{company: company, admin: admin, contact: contact} do
      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :sales,
          3,
          [
            %{
              "id" => "",
              "contact_id" => contact.id,
              "contact_name" => contact.name,
              "quantities" => %{"AA" => "10"},
              "is_separator" => "false",
              "delete" => "false"
            },
            %{
              "id" => "",
              "contact_name" => "",
              "group_name" => "Lorry 2",
              "is_separator" => "true",
              "delete" => "false"
            },
            %{
              "id" => "",
              "contact_name" => "Ah Seng",
              "quantities" => %{"AA" => "5", "A" => "3"},
              "is_separator" => "false",
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      {:ok, _} =
        EggStock.save_dow_lines(
          company.id,
          :purchase,
          3,
          [
            %{
              "id" => "",
              "contact_name" => "Supplier X",
              "quantities" => %{"AA" => "99"},
              "is_separator" => "false",
              "delete" => "false"
            }
          ],
          company,
          admin
        )

      sales = EggStock.list_dow_lines(company.id, :sales, 3)
      purchases = EggStock.list_dow_lines(company.id, :purchase, 3)
      by_name = Map.new(sales ++ purchases, &{&1.contact_name, &1})
      %{by_name: by_name}
    end

    test "groups selected weekly rows under their separator", %{
      company: company,
      by_name: by_name
    } do
      ids = [by_name["Ah Seng"].id]

      assert [%{group_name: "Lorry 2", rows: [row]}] =
               EggStock.loading_list_groups(company.id, {:dow, "sales", 3}, ids)

      assert row.contact_name == "Ah Seng"
      assert row.quantities == %{"AA" => 5, "A" => 3}
    end

    test "ignores ids from the purchase book", %{company: company, by_name: by_name} do
      ids = [by_name["Supplier X"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:dow, "sales", 3}, ids)
    end

    test "ignores ids from another weekday", %{company: company, by_name: by_name} do
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(company.id, {:dow, "sales", 4}, ids)
    end

    test "ignores ids from another company", %{company: company, by_name: by_name} do
      other_admin = user_fixture()
      other_company = company_fixture(other_admin, %{})
      ids = [by_name["Ah Seng"].id]

      assert [] == EggStock.loading_list_groups(other_company.id, {:dow, "sales", 3}, ids)
    end
  end

  describe "dow_date/2" do
    test "returns the same date when the weekday already matches" do
      monday = ~D[2026-08-10]
      assert Date.day_of_week(monday) == 1
      assert EggStock.dow_date(monday, 1) == monday
    end

    test "returns the next occurrence of a later weekday" do
      assert EggStock.dow_date(~D[2026-08-10], 3) == ~D[2026-08-12]
    end

    test "wraps to next week for an earlier weekday" do
      assert EggStock.dow_date(~D[2026-08-12], 1) == ~D[2026-08-17]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/egg_stock_test.exs`

Expected: the weekly-book tests fail with `FunctionClauseError` on `loading_list_source_rows/2` (no clause matches `{:dow, _, _}`); the `dow_date` tests fail with `UndefinedFunctionError`.

- [ ] **Step 3: Write the implementation**

In `lib/full_circle/egg_stock.ex`, add the second source clause directly below the `{:day, date}` clause from Task 1:

```elixir
  defp loading_list_source_rows(company_id, {:dow, kind, dow}) do
    list_dow_lines(company_id, kind, dow)
  end
```

And add `dow_date/2` immediately after `list_dow_lines/3`:

```elixir
  @doc """
  The next occurrence of weekday `dow` (Monday = 1) on or after `date`.
  """
  def dow_date(date, dow), do: Date.add(date, Integer.mod(dow - Date.day_of_week(date), 7))
```

Then in `lib/full_circle_web/live/egg_stock_live/form.ex`, replace the private definition at line 1300:

```elixir
  defp dow_date(date, dow), do: Date.add(date, Integer.mod(dow - Date.day_of_week(date), 7))
```

with a delegation to the context so there is a single definition:

```elixir
  defp dow_date(date, dow), do: EggStock.dow_date(date, dow)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/egg_stock_test.exs`

Expected: PASS, including all Task 1 tests.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/egg_stock.ex lib/full_circle_web/live/egg_stock_live/form.ex test/full_circle/egg_stock_test.exs
git add lib/full_circle/egg_stock.ex lib/full_circle_web/live/egg_stock_live/form.ex test/full_circle/egg_stock_test.exs
git commit -m "feat(egg-stock): feed the weekly sales book into the loading list grouping"
```

---

### Task 3: Print LiveView — `EggStockLive.LoadingList`

The shared print template for both sources. Renders company name, title, date line, one table with a group heading + subtotal per group, a grand total, and signature lines.

**Files:**
- Create: `lib/full_circle_web/live/egg_stock_live/loading_list.ex`
- Modify: `lib/full_circle_web/router.ex:386` (add the route next to the existing `EggStockLive.Print` route, inside the same print `live_session`)
- Test: `test/full_circle_web/live/egg_stock_loading_list_live_test.exs` (create)

**Interfaces:**
- Consumes: `EggStock.loading_list_groups/3` (Task 1, Task 2), `EggStock.dow_date/2` (Task 2), `EggStock.list_grades/1`, `EggStock.to_int/1`, `FullCircle.Sys.get_company!/1`, `FullCircleWeb.Helpers.format_date/1`.
- Produces: the route

  ```
  /companies/:company_id/EggStock/loading_list?src=day&date=YYYY-MM-DD&ids=id1,id2
  /companies/:company_id/EggStock/loading_list?src=dow&kind=sales&dow=3&ids=id1,id2
  ```

  Tasks 4 and 5 build hrefs against exactly these params.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/egg_stock_loading_list_live_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle_web/live/egg_stock_loading_list_live_test.exs`

Expected: FAIL — no route matches `/EggStock/loading_list`, raising `Phoenix.Router.NoRouteError`.

- [ ] **Step 3: Add the route**

In `lib/full_circle_web/router.ex`, directly below the existing line 386:

```elixir
      live("/EggStock/:date/print", EggStockLive.Print, :print)
```

add:

```elixir
      live("/EggStock/loading_list", EggStockLive.LoadingList, :print)
```

Both routes live in the same print `live_session`, which already supplies `current_company`, `current_user` and the `print_root` layout.

- [ ] **Step 4: Write the LiveView**

Create `lib/full_circle_web/live/egg_stock_live/loading_list.ex`:

```elixir
defmodule FullCircleWeb.EggStockLive.LoadingList do
  use FullCircleWeb, :live_view

  alias FullCircle.EggStock

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    grades = EggStock.list_grades(company.id)
    grade_names = Enum.map(grades, & &1.name)
    grade_labels = Map.new(grades, fn g -> {g.name, g.nickname || g.name} end)

    ids = params |> Map.get("ids", "") |> String.split(",", trim: true)
    {source, date_label} = parse_source(params)
    groups = EggStock.loading_list_groups(company.id, source, ids)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Loading List"),
       date_label: date_label,
       groups: groups,
       grade_names: grade_names,
       grade_labels: grade_labels,
       grand_total: total_of(groups, grade_names),
       company: FullCircle.Sys.get_company!(company.id)
     )}
  end

  defp parse_source(%{"src" => "dow", "kind" => kind, "dow" => dow_str})
       when kind in ["sales", "purchase"] do
    dow = String.to_integer(dow_str)
    date = EggStock.dow_date(Date.utc_today(), dow)
    {{:dow, kind, dow}, "#{dow_label(dow)} #{FullCircleWeb.Helpers.format_date(date)}"}
  end

  defp parse_source(%{"src" => "day", "date" => date_str}) do
    date = Date.from_iso8601!(date_str)
    {{:day, date}, FullCircleWeb.Helpers.format_date(date)}
  end

  defp dow_label(1), do: gettext("Mon")
  defp dow_label(2), do: gettext("Tue")
  defp dow_label(3), do: gettext("Wed")
  defp dow_label(4), do: gettext("Thu")
  defp dow_label(5), do: gettext("Fri")
  defp dow_label(6), do: gettext("Sat")
  defp dow_label(7), do: gettext("Sun")

  defp qty(row, grade), do: EggStock.to_int(row.quantities[grade])

  defp row_total(row, grade_names),
    do: Enum.reduce(grade_names, 0, fn g, acc -> acc + qty(row, g) end)

  defp group_subtotal(rows, grade), do: Enum.reduce(rows, 0, fn r, acc -> acc + qty(r, grade) end)

  defp group_total(rows, grade_names),
    do: Enum.reduce(rows, 0, fn r, acc -> acc + row_total(r, grade_names) end)

  defp total_of(groups, grade_names),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + group_total(g.rows, grade_names) end)

  defp grand_subtotal(groups, grade),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + group_subtotal(g.rows, grade) end)

  # Running row number across all groups, so the sheet numbers 1..n end to end.
  defp numbered(groups) do
    {numbered, _} =
      Enum.map_reduce(groups, 1, fn group, start ->
        {rows, next} =
          Enum.map_reduce(group.rows, start, fn row, n -> {Map.put(row, :no, n), n + 1} end)

        {%{group | rows: rows}, next}
      end)

    numbered
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, numbered(assigns.groups))

    ~H"""
    <div id="print-me" class="print-here">
      <style>
        .page {
          width: 210mm;
          min-height: 290mm;
          padding: 10mm;
          font-size: 12px;
          position: relative;
        }
        @media print {
          .page { padding: 5mm; margin: 0; }
        }
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid #ccc; padding: 4px 5px; text-align: center; }
        th { background: #f3f4f6; font-weight: 600; }
        .no-col { width: 26px; }
        .contact-name { text-align: left; }
        .tick-col { width: 34px; }
        .group-row td {
          text-align: left;
          background: #e5e7eb;
          font-weight: 700;
          padding: 4px 5px;
        }
        .subtotal-row td { font-weight: 700; background: #fafafa; }
        .total-row td { font-weight: 700; border-top: 2px solid #666; }
        h1 { text-align: center; font-size: 18px; font-weight: 700; margin-bottom: 2px; }
        h2 { text-align: center; font-size: 14px; font-weight: 600; color: #555; margin-bottom: 10px; }
        .company-name { text-align: center; font-size: 14px; font-weight: 600; margin-bottom: 2px; }
        .sign-row { display: flex; gap: 40px; margin-top: 30px; }
        .sign-box { flex: 1; border-top: 1px solid #666; padding-top: 4px; text-align: center; }
      </style>

      <div class="page">
        <div class="company-name">{@company.name}</div>
        <h1>{gettext("Planned sales — loading list")}</h1>
        <h2>{@date_label}</h2>

        <table>
          <thead>
            <tr>
              <th class="no-col">#</th>
              <th class="contact-name">{gettext("Contact")}</th>
              <th :for={g <- @grade_names}>{@grade_labels[g]}</th>
              <th>{gettext("Total")}</th>
              <th class="tick-col">✓</th>
            </tr>
          </thead>
          <tbody>
            <%= for group <- @groups do %>
              <tr :if={group.group_name != ""} class="group-row">
                <td colspan={length(@grade_names) + 4}>{group.group_name}</td>
              </tr>
              <tr :for={row <- group.rows}>
                <td class="no-col">{row.no}</td>
                <td class="contact-name">{row.contact_name}</td>
                <td :for={g <- @grade_names}>{qty(row, g)}</td>
                <td>{row_total(row, @grade_names)}</td>
                <td class="tick-col"></td>
              </tr>
              <tr class="subtotal-row">
                <td class="no-col"></td>
                <td class="contact-name">{gettext("Subtotal")}</td>
                <td :for={g <- @grade_names}>{group_subtotal(group.rows, g)}</td>
                <td>{group_total(group.rows, @grade_names)}</td>
                <td class="tick-col"></td>
              </tr>
            <% end %>
            <tr class="total-row">
              <td class="no-col"></td>
              <td class="contact-name">{gettext("Total")}</td>
              <td :for={g <- @grade_names}>{grand_subtotal(@groups, g)}</td>
              <td>{@grand_total}</td>
              <td class="tick-col"></td>
            </tr>
          </tbody>
        </table>

        <div class="sign-row">
          <div class="sign-box">{gettext("Loaded by")}</div>
          <div class="sign-box">{gettext("Checked by")}</div>
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/full_circle_web/live/egg_stock_loading_list_live_test.exs`

Expected: PASS, 4 tests.

- [ ] **Step 6: Format and commit**

```bash
mix format lib/full_circle_web/live/egg_stock_live/loading_list.ex lib/full_circle_web/router.ex test/full_circle_web/live/egg_stock_loading_list_live_test.exs
git add lib/full_circle_web/live/egg_stock_live/loading_list.ex lib/full_circle_web/router.ex test/full_circle_web/live/egg_stock_loading_list_live_test.exs
git commit -m "feat(egg-stock): add the loading list print view"
```

---

### Task 4: Stock tab — row selection and print action bar

Adds the gutter checkbox, the section "select all", and the action bar to the Planned Sales section of the `Stock` tab.

**Files:**
- Modify: `lib/full_circle_web/live/egg_stock_live/form.ex`
  - `mount/3` around line 24 — seed the selection assigns
  - `handle_event("switch_tab", ...)` line 452, `handle_event("nav_date", ...)` line 470, `handle_event("goto_date", ...)` line 482 — clear the selection
  - `planned_section/1` line 1863 — pass selection through and render the header row + action bar
  - `detail_lines/1` line 2139 — render the gutter checkbox
  - new `handle_event` clauses
- Test: `test/full_circle_web/live/egg_stock_form_selection_live_test.exs` (create)

**Interfaces:**
- Consumes: the route params from Task 3 (`src=day`, `date`, `ids`).
- Produces (used again by Task 5):
  - assign `:sel_sales_ids` — a `MapSet` of `EggStockDayDetail` id strings
  - events `"toggle_print_row"` (`%{"id" => id}`) and `"toggle_all_print_rows"` (no params)
  - `clear_print_selection(socket)` — resets both `:sel_sales_ids` and `:sel_dow_ids` to `MapSet.new()`
  - function component `print_action_bar/1` with attrs `count`, `total`, `href`

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/egg_stock_form_selection_live_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle_web/live/egg_stock_form_selection_live_test.exs`

Expected: FAIL — the first test errors because no `handle_event` clause matches `"toggle_print_row"`.

- [ ] **Step 3: Seed and clear the selection assigns**

In `lib/full_circle_web/live/egg_stock_live/form.ex`, in `mount/3` add both assigns to the existing pipeline next to `assign(active_tab: "now")` around line 24:

```elixir
     |> assign(sel_sales_ids: MapSet.new(), sel_dow_ids: MapSet.new())
```

Add the shared helper near the other private helpers (next to `flush_autosave/1` at line 1008):

```elixir
  defp clear_print_selection(socket),
    do: assign(socket, sel_sales_ids: MapSet.new(), sel_dow_ids: MapSet.new())
```

Then pipe it in wherever the surface changes:

- `handle_event("switch_tab", ...)` — after `socket = flush_autosave(socket)` on line 453, add `socket = clear_print_selection(socket)`.
- `handle_event("nav_date", ...)` — after `socket = flush_autosave(socket)` on line 471, add `socket = clear_print_selection(socket)`.
- `handle_event("goto_date", ...)` — after `socket = flush_autosave(socket)` on line 486, add `socket = clear_print_selection(socket)`.

(`goto_weekly` already routes through `goto_date` or `switch_tab`-equivalent code; `select_dow` is covered in Task 5.)

- [ ] **Step 4: Add the toggle events**

Add these clauses next to the other `handle_event/3` functions in `form.ex`:

```elixir
  def handle_event("toggle_print_row", %{"id" => id}, socket) do
    {:noreply, assign(socket, sel_sales_ids: toggle_id(socket.assigns.sel_sales_ids, id))}
  end

  def handle_event("toggle_all_print_rows", _params, socket) do
    all = MapSet.new(selectable_sales_ids(socket.assigns.day))

    selected =
      if MapSet.size(all) > 0 and MapSet.subset?(all, socket.assigns.sel_sales_ids),
        do: MapSet.new(),
        else: all

    {:noreply, assign(socket, sel_sales_ids: selected)}
  end

  def handle_event("clear_print_rows", _params, socket) do
    {:noreply, assign(socket, sel_sales_ids: MapSet.new())}
  end

  defp toggle_id(set, id) do
    id = to_string(id)
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  # Only saved, non-separator planned sales rows can be selected.
  defp selectable_sales_ids(day) do
    (day.egg_stock_day_details || [])
    |> Enum.filter(fn d ->
      d.section in EggStock.planned_sales_sections() and !d.is_separator and
        d.id not in [nil, ""]
    end)
    |> Enum.map(&to_string(&1.id))
  end

  defp all_sales_selected?(day, selected) do
    ids = selectable_sales_ids(day)
    ids != [] and MapSet.subset?(MapSet.new(ids), selected)
  end

  defp selected_rows_total(rows, grades, selected) do
    rows
    |> Enum.filter(&MapSet.member?(selected, to_string(&1.id || "")))
    |> Enum.reduce(0, fn row, acc ->
      acc + Enum.reduce(grades, 0, fn g, a -> a + to_int((row.quantities || %{})[g]) end)
    end)
  end

  defp loading_list_href(company_id, params, selected) do
    query = params ++ [ids: selected |> MapSet.to_list() |> Enum.join(",")]
    ~p"/companies/#{company_id}/EggStock/loading_list?#{query}"
  end
```

- [ ] **Step 5: Add the shared action bar component**

Add next to the other function components in `form.ex` (e.g. after `planned_section/1`):

```elixir
  attr :count, :integer, required: true
  attr :total, :integer, required: true
  attr :href, :string, required: true
  attr :clear_event, :string, required: true

  defp print_action_bar(assigns) do
    ~H"""
    <div
      :if={@count > 0}
      class="mt-2 flex items-center gap-3 rounded border border-blue-400 bg-white px-3 py-1.5 text-sm"
    >
      <span class="font-semibold text-blue-700">{@count} {gettext("selected")}</span>
      <span class="text-gray-600">{@total} {gettext("eggs")}</span>
      <span class="flex-1"></span>
      <a
        href={@href}
        target="_blank"
        class="flex items-center gap-1 text-blue-600 hover:text-blue-800"
      >
        <.icon name="hero-printer" class="h-4 w-4" /> {gettext("Print selected")}
      </a>
      <button
        type="button"
        phx-click={@clear_event}
        class="text-gray-500 hover:text-gray-700"
      >
        {gettext("Clear")}
      </button>
    </div>
    """
  end
```

- [ ] **Step 6: Render the checkbox column in `detail_lines/1`**

In `detail_lines/1` (line 2139), add two attrs at the top of the component so the section can pass selection state down. The planned purchase section will pass `selectable: false`.

Replace the `w-12` gutter markup in the **contact line** branch (lines 2236–2258) with:

```elixir
            <div :if={@editable} class="flex items-center w-[68px] shrink-0">
              <input
                :if={@selectable}
                type="checkbox"
                class="mr-1 h-4 w-4 accent-blue-600 disabled:opacity-40"
                disabled={dtl[:id].value in [nil, ""]}
                title={
                  if dtl[:id].value in [nil, ""],
                    do: gettext("Save first before selecting this row")
                }
                checked={MapSet.member?(@selected, to_string(dtl[:id].value || ""))}
                phx-click="toggle_print_row"
                phx-value-id={dtl[:id].value}
              />
              <span :if={!@selectable} class="mr-1 w-4 shrink-0"></span>
              <button
                type="button"
                phx-click="move_detail"
                phx-value-index={dtl.index}
                phx-value-dir="up"
                class="text-gray-400 hover:text-gray-700"
                title={gettext("Move up")}
              >
                <.icon name="hero-chevron-up" class="h-3 w-3" />
              </button>
              <button
                type="button"
                phx-click="move_detail"
                phx-value-index={dtl.index}
                phx-value-dir="down"
                class="text-gray-400 hover:text-gray-700"
                title={gettext("Move down")}
              >
                <.icon name="hero-chevron-down" class="h-3 w-3" />
              </button>
            </div>
            <div :if={!@editable} class="w-[68px] shrink-0"></div>
```

The checkbox deliberately has **no `name` attribute** — this row sits inside the `phx-change="validate"` form, and a named input would land in the submitted params and reach the changeset.

In the **separator** branch (lines 2181–2203), widen the two gutters from `w-12` to `w-[68px]` and add a `<span class="mr-1 w-4 shrink-0"></span>` spacer before the up-arrow button so separators line up with contact rows. Separators get no checkbox.

- [ ] **Step 7: Wire the section header, checkbox column and action bar in `planned_section/1`**

Add `selectable`, `selected`, `all_selected`, `selected_total` and `print_href` attrs to `planned_section/1` (line 1863):

```elixir
  attr :selectable, :boolean, required: true
  attr :selected, :any, required: true
  attr :all_selected, :boolean, required: true
  attr :selected_total, :integer, required: true
  attr :print_href, :string, required: true
```

(plus the attrs the component already receives). Inside it, add the column header row above `<.detail_lines .../>`:

```elixir
      <div :if={@selectable} class="flex gap-1 items-center mb-1 text-xs text-gray-600">
        <div class="w-[68px] shrink-0 flex items-center gap-1">
          <input
            type="checkbox"
            class="h-4 w-4 accent-blue-600"
            checked={@all_selected}
            phx-click="toggle_all_print_rows"
          />
          <span>{gettext("all")}</span>
        </div>
      </div>
```

Pass the new attrs down to `detail_lines/1`, and render the bar after `<.section_totals ... />`:

```elixir
      <.print_action_bar
        :if={@selectable}
        count={MapSet.size(@selected)}
        total={@selected_total}
        href={@print_href}
        clear_event="clear_print_rows"
      />
```

At the two call sites (lines 1780 and 1794):

- Planned Purchases → `selectable={false}`, `selected={MapSet.new()}`, `all_selected={false}`, `selected_total={0}`, `print_href={""}`.
- Planned Sales →

```elixir
              selectable={true}
              selected={@sel_sales_ids}
              all_selected={all_sales_selected?(@day, @sel_sales_ids)}
              selected_total={
                selected_rows_total(@day.egg_stock_day_details || [], @grades, @sel_sales_ids)
              }
              print_href={
                loading_list_href(
                  @current_company.id,
                  [src: "day", date: Date.to_iso8601(@date)],
                  @sel_sales_ids
                )
              }
```

The read-only (`@editable == false`) branch of the Stock tab at line ~1700 keeps `selectable={false}` — past days are printed with the existing day report.

- [ ] **Step 8: Run the test to verify it passes**

Run: `mix test test/full_circle_web/live/egg_stock_form_selection_live_test.exs`

Expected: PASS, 7 tests.

- [ ] **Step 9: Run the full suite**

Run: `mix test`

Expected: PASS. The suite was green at 1105 tests as of 2026-08-08; the new tests add to that count.

- [ ] **Step 10: Format and commit**

```bash
mix format lib/full_circle_web/live/egg_stock_live/form.ex test/full_circle_web/live/egg_stock_form_selection_live_test.exs
git add lib/full_circle_web/live/egg_stock_live/form.ex test/full_circle_web/live/egg_stock_form_selection_live_test.exs
git commit -m "feat(egg-stock): select planned sales rows on the day board and print them"
```

---

### Task 5: Weekly sales tab — row selection and print action bar

Same treatment on the `Weekly Sales` book. Rows come from `@dow_params` (plain maps, not a changeset), so the id lives at `line["id"]`.

**Files:**
- Modify: `lib/full_circle_web/live/egg_stock_live/form.ex`
  - `weekly_tab/1` line 1453 — gutter checkbox, header "all", action bar
  - `handle_event("select_dow", ...)` line 535 — clear the selection
  - new `handle_event` clauses
- Test: `test/full_circle_web/live/egg_stock_form_selection_live_test.exs` (extend)

**Interfaces:**
- Consumes: `:sel_dow_ids`, `clear_print_selection/1`, `toggle_id/2`, `print_action_bar/1`, `loading_list_href/3` (all from Task 4); `EggStock.list_dow_lines/3`.
- Produces: events `"toggle_dow_print_row"` (`%{"id" => id}`), `"toggle_all_dow_print_rows"`, `"clear_dow_print_rows"`.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle_web/live/egg_stock_form_selection_live_test.exs`, inside the same `defmodule`:

```elixir
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle_web/live/egg_stock_form_selection_live_test.exs`

Expected: the three new weekly tests FAIL — no `handle_event` clause matches `"toggle_dow_print_row"`. The seven Task 4 tests still pass.

- [ ] **Step 3: Add the weekly toggle events**

Add next to the Task 4 event clauses in `form.ex`:

```elixir
  def handle_event("toggle_dow_print_row", %{"id" => id}, socket) do
    {:noreply, assign(socket, sel_dow_ids: toggle_id(socket.assigns.sel_dow_ids, id))}
  end

  def handle_event("toggle_all_dow_print_rows", _params, socket) do
    all = MapSet.new(selectable_dow_ids(socket.assigns.dow_params))

    selected =
      if MapSet.size(all) > 0 and MapSet.subset?(all, socket.assigns.sel_dow_ids),
        do: MapSet.new(),
        else: all

    {:noreply, assign(socket, sel_dow_ids: selected)}
  end

  def handle_event("clear_dow_print_rows", _params, socket) do
    {:noreply, assign(socket, sel_dow_ids: MapSet.new())}
  end

  # Only saved, non-separator, non-deleted weekly rows can be selected.
  defp selectable_dow_ids(dow_params) do
    (dow_params || [])
    |> Enum.filter(fn line ->
      line["delete"] != "true" and line["is_separator"] not in [true, "true"] and
        line["id"] not in [nil, ""]
    end)
    |> Enum.map(&to_string(&1["id"]))
  end

  defp all_dow_selected?(dow_params, selected) do
    ids = selectable_dow_ids(dow_params)
    ids != [] and MapSet.subset?(MapSet.new(ids), selected)
  end

  defp selected_dow_total(dow_params, grades, selected) do
    (dow_params || [])
    |> Enum.filter(&MapSet.member?(selected, to_string(&1["id"] || "")))
    |> Enum.reduce(0, fn line, acc ->
      acc + Enum.reduce(grades, 0, fn g, a -> a + to_int((line["quantities"] || %{})[g]) end)
    end)
  end
```

In `handle_event("select_dow", ...)` at line 535, add `socket = clear_print_selection(socket)` before the existing body so switching weekday drops the selection.

- [ ] **Step 4: Render the weekly checkbox column and action bar**

In `weekly_tab/1`, widen the header gutter (line 1492) and add the "all" checkbox:

```elixir
            <div class="w-[68px] shrink-0 flex items-center gap-1">
              <input
                type="checkbox"
                class="h-4 w-4 accent-blue-600"
                checked={all_dow_selected?(@dow_params, @sel_dow_ids)}
                phx-click="toggle_all_dow_print_rows"
              />
              <span class="text-xs">{gettext("all")}</span>
            </div>
```

In the contact-row branch (line 1577), replace the `w-12` gutter opening with:

```elixir
              <div class="flex items-center w-[68px] shrink-0">
                <input
                  type="checkbox"
                  class="mr-1 h-4 w-4 accent-blue-600 disabled:opacity-40"
                  disabled={line["id"] in [nil, ""]}
                  title={
                    if line["id"] in [nil, ""],
                      do: gettext("Save first before selecting this row")
                  }
                  checked={MapSet.member?(@sel_dow_ids, to_string(line["id"] || ""))}
                  phx-click="toggle_dow_print_row"
                  phx-value-id={line["id"]}
                />
```

keeping the two existing move buttons that follow. As on the Stock tab, the checkbox has **no `name` attribute** — this row is inside the `phx-change="validate_dow"` form.

Widen the separator branch gutter (line 1526) and the totals-row gutter (line 1637) from `w-12` to `w-[68px]`, adding a `<span class="mr-1 w-4 shrink-0"></span>` spacer in the separator branch so columns line up.

After `</.form>` (line 1657), add:

```elixir
        <.print_action_bar
          count={MapSet.size(@sel_dow_ids)}
          total={selected_dow_total(@dow_params, @grades, @sel_dow_ids)}
          href={
            loading_list_href(
              @current_company.id,
              [src: "dow", kind: if(@kind == "sales", do: "sales", else: "purchase"), dow: @dow],
              @sel_dow_ids
            )
          }
          clear_event="clear_dow_print_rows"
        />
```

The bar sits outside the `:if={!@readonly}` block, so today's read-only book can still be selected and printed — read-only applies to editing, not printing. For the same reason the checkbox is not gated on `@readonly`.

`weekly_tab/1` is shared by the Weekly Sales and Weekly Purchases tabs; leaving the selection available on both is the smaller change and stays honest to the shared component, but the purchase book's link resolves through `{:dow, "purchase", dow}`, which `loading_list_groups/3` scopes correctly.

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/full_circle_web/live/egg_stock_form_selection_live_test.exs`

Expected: PASS, 10 tests.

- [ ] **Step 6: Run the full suite**

Run: `mix test`

Expected: PASS.

- [ ] **Step 7: Format and commit**

```bash
mix format lib/full_circle_web/live/egg_stock_live/form.ex test/full_circle_web/live/egg_stock_form_selection_live_test.exs
git add lib/full_circle_web/live/egg_stock_live/form.ex test/full_circle_web/live/egg_stock_form_selection_live_test.exs
git commit -m "feat(egg-stock): select weekly sales book rows and print them"
```

---

### Task 6: Update the egg stock skill

`.claude/skills/egg-stock-day-board.md` documents the board's UI conventions and key files. Both drift once this ships.

**Files:**
- Modify: `.claude/skills/egg-stock-day-board.md`

**Interfaces:**
- Consumes: everything shipped in Tasks 1–5.
- Produces: nothing consumed by code.

- [ ] **Step 1: Add a loading list section**

Insert after the "UI conventions (form)" section:

```markdown
## Loading list (selected planned sales rows)

Tick planned sales rows on the Stock tab or the Weekly Sales book and print just
those rows as a lorry loading list.

- `EggStock.loading_list_groups(company_id, source, selected_ids)` —
  `source` is `{:day, %Date{}}` or `{:dow, kind, dow}`. Returns
  `[%{group_name: String.t(), rows: [%{id, contact_name, quantities}]}]`, ordered
  by board `position`, grouped by the separator label above each run of rows.
  Groups with no selected row are dropped. Ids that fall outside the scope are
  dropped — that is also the multi-tenant guard.
- Print view: `EggStockLive.LoadingList` at
  `/EggStock/loading_list?src=day&date=…&ids=…` or
  `?src=dow&kind=sales&dow=…&ids=…`.
- Selection lives in the `:sel_sales_ids` / `:sel_dow_ids` socket assigns as
  `MapSet`s of **row ids** — never list index, which shifts on move/delete.
  Cleared on date, weekday and tab change.

### Gotcha: the selection checkbox must not have a `name`

Both boards are inside a `phx-change` form. A named checkbox would be submitted
with the rest of the row and reach the changeset. Drive it from the server only:
`phx-click`, `phx-value-id`, and `checked={MapSet.member?(...)}`.

Rows with no id yet (freshly added, and the in-memory orphan rows from
`ensure_planned_lines_for_actuals/3`) render a disabled checkbox.
```

Also update the "Key files" block to add `loading_list.ex`:

```
lib/full_circle_web/live/egg_stock_live/{form,print,loading_list,production_report}.ex
```

And append a new entry to the existing numbered "Gotchas" list (which currently ends at 6):

```markdown
7. **Selection checkboxes need no `name`** — see the loading list section above.
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/egg-stock-day-board.md
git commit -m "docs(egg-stock): document the planned sales loading list"
```

---

## Verification

After Task 6, confirm the whole feature end to end:

- [ ] `mix test` passes.
- [ ] `mix phx.server`, open `/companies/<id>/egg_stock`. Tick two planned sales rows — the action bar shows the count and egg total. `Print selected` opens a new tab with only those rows, under their separator heading, with subtotals and a grand total.
- [ ] Ticking a planned sales row does not clear or alter any quantity input on the board (the `name`-less checkbox check).
- [ ] The planned purchases section has no checkboxes.
- [ ] Navigate to the previous day — the action bar disappears.
- [ ] Switch to `Weekly Sales`, pick a weekday other than today, tick a row, print. The sheet's date line shows the weekday plus its upcoming date.
