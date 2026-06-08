# Fingerprint `.xls` Attendance Import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let HR upload the two fingerprint machines' monthly `.xls` files and have punches land in `time_attendences`, with a fast 3-tier employee matcher that persists matches — so the existing Punch Card → PaySlip flow takes over with no manual punch-reading.

**Architecture:** The `.xls` is converted to `.xlsx` **in the browser** (vendored SheetJS) and handed to the existing LiveView upload via a programmatic `this.upload`, so the server's `xlsx_reader` path is unchanged. Parsing/merge logic is extracted into a pure, unit-tested context module. A 3-tier matcher (exact `punch_card_id` → top-3 pg_trgm fuzzy → manual autocomplete) writes the fingerprint `punch_card_id` onto the chosen employee for future auto-matching. Import remains the existing idempotent insert.

**Tech Stack:** Elixir 1.19 / Phoenix LiveView 1.1, `xlsx_reader`, PostgreSQL `pg_trgm` (`WORD_SIMILARITY`), esbuild (vendored SheetJS ESM), Ecto.

**Spec:** `docs/superpowers/specs/2026-06-08-fingerprint-xls-import-design.md`

---

## File Structure

- **Create** `lib/full_circle/hr/finger_print_import.ex` — pure parse/merge of `Att.log report` rows into attendance attr maps (no IO, no DB). Unit-tested.
- **Create** `test/full_circle/finger_print_import_test.exs` — tests for the parse/merge module.
- **Modify** `lib/full_circle/hr.ex` — add `match_employee_candidates/4` (status-agnostic, Active-first, top-N fuzzy) and `set_employee_punch_card_id/4` (persist a match).
- **Modify** `test/full_circle/hr_test.exs` — tests for the two new HR functions.
- **Create** `assets/vendor/sheetjs/xlsx.mjs` — vendored SheetJS ESM build.
- **Modify** `assets/js/app.js` — add `Hooks.XlsToXlsxUpload` (dynamic-imports SheetJS, converts `.xls`→`.xlsx`, programmatic `this.upload`).
- **Modify** `lib/full_circle_web/live/time_attend_live/upload_punch_log.ex` — multi-file upload + all-done gate, delegate parsing to the new module, render the 3-tier matching panel, add match events.

> The existing `read_excel_files/1`, `fill_in_employee_info/3`, and `HR.insert_time_attendence_from_log/2` are reused unchanged except where noted. `HR.employees/3` (Active-only) is **not** modified — other screens depend on it.

---

## Task 1: Extract parsing into a pure, testable module

Moves the existing in-LiveView parsing (`parse_xlsx_to_attrs/1`, `filter_times_n_split_to_map/2`, `fill_flags_to_map/1`, `extract_date_range/1`) into a dedicated context module **verbatim** (no behavior change), so it can be unit-tested and reused.

**Files:**
- Create: `lib/full_circle/hr/finger_print_import.ex`
- Test: `test/full_circle/finger_print_import_test.exs`
- Modify: `lib/full_circle_web/live/time_attend_live/upload_punch_log.ex` (delegate)

- [ ] **Step 1: Write the failing test**

`test/full_circle/finger_print_import_test.exs`:

```elixir
defmodule FullCircle.FingerPrintImportTest do
  use ExUnit.Case, async: true

  alias FullCircle.HR.FingerPrintImport

  # Minimal stand-in for the "Att.log report" sheet:
  # row 0: title, row 1: blank, row 2: date range at index 2,
  # row 3: day-number header, row 4+: pairs of [info-row, attendance-row].
  defp sample_rows do
    info = ["ID:", "", "7", "", "", "", "", "", "Name:", "", "Gurung Bir Bahadur",
            "", "", "", "", "", "", "", "Chicken Farm"]
    # 2 days of punches; day 1 has 4 punches, day 2 has 2 punches + a <10min dup to drop
    att = ["07:5512:0112:5417:01", "07:5107:5512:01"]
    [
      ["Attendance Record Report"],
      [],
      ["Att. Time", "", "2026-01-01 ~ 2026-01-02"],
      [1.0, 2.0],
      info,
      att
    ]
  end

  test "parse_file_rows/1 splits concatenated times, dedups <10min, flags IN/OUT positionally" do
    [d1, d2] =
      FingerPrintImport.parse_file_rows(sample_rows())
      |> Enum.group_by(& &1.punch_time_local |> NaiveDateTime.to_date())
      |> Enum.sort_by(fn {d, _} -> d end)
      |> Enum.map(fn {_d, list} -> list end)

    # Day 1: 4 punches -> 1_IN_1,1_OUT_1,2_IN_2,2_OUT_2
    assert Enum.map(d1, & &1.flag) == ["1_IN_1", "1_OUT_1", "2_IN_2", "2_OUT_2"]
    assert Enum.map(d1, & &1.stamp) ==
             [~T[07:55:00], ~T[12:01:00], ~T[12:54:00], ~T[17:01:00]]

    # Day 2: 07:51 then 07:55 (<10min, dropped) then 12:01 -> two punches
    assert Enum.map(d2, & &1.stamp) == [~T[07:51:00], ~T[12:01:00]]
    assert Enum.map(d2, & &1.flag) == ["1_IN_1", "1_OUT_1"]

    # punch_card_id is "Name.ID.Dept" with spaces removed
    assert hd(d1).punch_card_id == "GurungBirBahadur.7.ChickenFarm"
    assert hd(d1)[:Name] == "Gurung Bir Bahadur"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/finger_print_import_test.exs`
Expected: FAIL — `FullCircle.HR.FingerPrintImport` is undefined.

- [ ] **Step 3: Create the module (logic moved verbatim from the LiveView)**

`lib/full_circle/hr/finger_print_import.ex`:

```elixir
defmodule FullCircle.HR.FingerPrintImport do
  @moduledoc """
  Pure parsing of a fingerprint machine's "Att.log report" sheet rows into
  attendance attribute maps. No IO, no DB. The LiveView handles file reading
  (xlsx_reader) and employee/company enrichment.
  """

  @doc """
  Parse one file's sheet `rows` (list of row-lists) into a flat list of punch maps:
  `%{stamp: Time, flag: String|nil, ID:, Name:, Department:, punch_card_id:, punch_time_local:}`.
  """
  def parse_file_rows(rows) do
    date_range = Enum.at(rows, 2) |> Enum.at(2) |> extract_date_range()

    rows
    |> Enum.drop(4)
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [info, att] -> parse_employee_block(info, att, date_range)
      [_info] -> []
    end)
    |> List.flatten()
  end

  @doc """
  Extract the `2026-01-01 ~ 2026-01-31` date span from a file's row-2 cell as
  `{from_date, to_date}`.
  """
  def file_date_range(rows) do
    [from | _] = dr = Enum.at(rows, 2) |> Enum.at(2) |> extract_date_range()
    {from, List.last(dr)}
  end

  defp parse_employee_block(info, att, date_range) do
    Enum.map(att, fn cell ->
      Regex.scan(~r/\d{2}:\d{2}/, to_string(cell))
      |> List.flatten()
      |> Enum.map(fn time_str ->
        [hour, minute] = String.split(time_str, ":") |> Enum.map(&String.to_integer/1)
        Time.new!(hour, minute, 0)
      end)
    end)
    |> Enum.zip(date_range)
    |> Enum.map(fn x -> filter_times_n_split_to_map(x, info) end)
    |> List.flatten()
  end

  defp extract_date_range(date_line) do
    [start_date, end_date] =
      Regex.scan(~r/\d{4}-\d{2}-\d{2}/, to_string(date_line))
      |> List.flatten()
      |> Enum.map(&Date.from_iso8601!/1)

    Date.range(start_date, end_date) |> Enum.to_list()
  end

  defp filter_times_n_split_to_map({times, dt}, info) do
    info = Enum.reject(info, fn x -> x == "" end)

    times
    |> Enum.reduce({[], nil}, fn time, {acc, last_time} ->
      if last_time && Time.diff(time, last_time, :second) < 600 do
        {acc, last_time}
      else
        {[time | acc], time}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> fill_flags_to_map()
    |> Enum.map(fn x ->
      Map.merge(x, %{
        ID: Enum.at(info, 1),
        Name: Enum.at(info, 3),
        Department: Enum.at(info, 5),
        punch_card_id:
          "#{Enum.at(info, 3)}.#{Enum.at(info, 1)}.#{Enum.at(info, 5)}"
          |> String.replace(" ", ""),
        punch_time_local: NaiveDateTime.new!(dt, x.stamp)
      })
    end)
  end

  def fill_flags_to_map(tl) do
    Enum.map(Enum.with_index(tl, 1), fn {t, index} ->
      cond do
        index == 1 -> %{stamp: t, flag: "1_IN_1"}
        index == 2 -> %{stamp: t, flag: "1_OUT_1"}
        index == 3 -> %{stamp: t, flag: "2_IN_2"}
        index == 4 -> %{stamp: t, flag: "2_OUT_2"}
        index == 5 -> %{stamp: t, flag: "3_IN_3"}
        index == 6 -> %{stamp: t, flag: "3_OUT_3"}
        true -> %{stamp: t, flag: nil}
      end
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/finger_print_import_test.exs`
Expected: PASS.

- [ ] **Step 5: Delegate from the LiveView (remove the moved private functions)**

In `lib/full_circle_web/live/time_attend_live/upload_punch_log.ex`:

1. Add near the top, after `alias FullCircle.HR`:

```elixir
  alias FullCircle.HR.FingerPrintImport
```

2. Delete the now-moved functions from the LiveView: `parse_xlsx_to_attrs/1`, `extract_date_range/1`, `filter_times_n_split_to_map/2`, and `fill_flags_to_map/1`.

3. Replace the two call sites that used `parse_xlsx_to_attrs(...)` (in `handle_event("refresh", ...)` and `handle_progress/3`) with `FingerPrintImport.parse_file_rows(...)`. For the single-file call sites this is a drop-in (`parse_xlsx_to_attrs(raw)` → `FingerPrintImport.parse_file_rows(raw)`). Task 5 changes these to the multi-file form.

- [ ] **Step 6: Verify compile + existing path still parses**

Run: `mix compile --warnings-as-errors && mix test test/full_circle/finger_print_import_test.exs`
Expected: compiles clean; test passes.

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle/hr/finger_print_import.ex test/full_circle/finger_print_import_test.exs lib/full_circle_web/live/time_attend_live/upload_punch_log.ex
git commit -m "refactor: extract fingerprint Att.log parsing into testable HR.FingerPrintImport"
```

---

## Task 2: Multi-file parse + date-range guard

Add `parse_files_rows/1`: parse each file's rows and **concatenate** (no overlap → no per-employee merge), but reject mixing different months.

**Files:**
- Modify: `lib/full_circle/hr/finger_print_import.ex`
- Test: `test/full_circle/finger_print_import_test.exs`

- [ ] **Step 1: Write the failing tests** (append to the existing test module)

```elixir
  defp file_rows(name_id_dept, day_cells, range) do
    [name, id, dept] = name_id_dept
    info = ["ID:", "", id, "", "", "", "", "", "Name:", "", name,
            "", "", "", "", "", "", "", dept]
    [
      ["Attendance Record Report"],
      [],
      ["Att. Time", "", range],
      Enum.map(1..length(day_cells), &(&1 / 1)),
      info,
      day_cells
    ]
  end

  test "parse_files_rows/1 concatenates punches from both machine files" do
    f1 = file_rows(["Gurung Bir Bahadur", "7", "Chicken Farm"],
                   ["07:5512:01"], "2026-01-01 ~ 2026-01-01")
    f2 = file_rows(["Linda Santika", "4", "Office"],
                   ["08:0017:00"], "2026-01-01 ~ 2026-01-01")

    {:ok, attrs} = FingerPrintImport.parse_files_rows([f1, f2])

    cards = attrs |> Enum.map(& &1.punch_card_id) |> Enum.uniq() |> Enum.sort()
    assert cards == ["GurungBirBahadur.7.ChickenFarm", "LindaSantika.4.Office"]
  end

  test "parse_files_rows/1 rejects files covering different months" do
    f1 = file_rows(["A", "1", "X"], ["07:5512:01"], "2026-01-01 ~ 2026-01-31")
    f2 = file_rows(["B", "2", "Y"], ["07:5512:01"], "2026-02-01 ~ 2026-02-28")

    assert {:error, {:date_range_mismatch, ranges}} =
             FingerPrintImport.parse_files_rows([f1, f2])

    assert {~D[2026-01-01], ~D[2026-01-31]} in ranges
    assert {~D[2026-02-01], ~D[2026-02-28]} in ranges
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/finger_print_import_test.exs`
Expected: FAIL — `parse_files_rows/1` undefined.

- [ ] **Step 3: Implement `parse_files_rows/1`**

Add to `lib/full_circle/hr/finger_print_import.ex`:

```elixir
  @doc """
  Parse multiple files' rows. Returns `{:ok, attrs}` (concatenated punch maps) when
  every file covers the same date range, or `{:error, {:date_range_mismatch, ranges}}`.
  """
  def parse_files_rows(files) when is_list(files) do
    ranges = files |> Enum.map(&file_date_range/1) |> Enum.uniq()

    case ranges do
      [_single] -> {:ok, Enum.flat_map(files, &parse_file_rows/1)}
      many -> {:error, {:date_range_mismatch, many}}
    end
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/finger_print_import_test.exs`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/hr/finger_print_import.ex test/full_circle/finger_print_import_test.exs
git commit -m "feat: parse_files_rows/1 unions both machine files with same-month guard"
```

---

## Task 3: HR matching functions (fuzzy candidates + persist match)

**Files:**
- Modify: `lib/full_circle/hr.ex`
- Test: `test/full_circle/hr_test.exs`

- [ ] **Step 1: Write the failing tests** (add a new `describe` block in `test/full_circle/hr_test.exs`)

```elixir
  describe "fingerprint employee matching" do
    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      %{admin: admin, com: com}
    end

    test "match_employee_candidates/4 ranks by name similarity, Active first, max 3",
         %{admin: admin, com: com} do
      employee_fixture(%{name: "Gurung Bir Bahadur", status: "Active"}, com, admin)
      employee_fixture(%{name: "Gurung Bijay", status: "Active"}, com, admin)
      employee_fixture(%{name: "Gurung Bahadur Old", status: "Resigned"}, com, admin)
      employee_fixture(%{name: "Totally Unrelated", status: "Active"}, com, admin)

      names =
        HR.match_employee_candidates("Gurung Bir Bahadur", com, admin, 3)
        |> Enum.map(& &1.name)

      assert length(names) <= 3
      assert hd(names) == "Gurung Bir Bahadur"
      # the closest Active match leads; the unrelated name is not the top suggestion
      refute hd(names) == "Totally Unrelated"
    end

    test "match_employee_candidates/4 includes resigned employees", %{admin: admin, com: com} do
      employee_fixture(%{name: "Zzz Resigned Person", status: "Resigned"}, com, admin)

      names =
        HR.match_employee_candidates("Zzz Resigned Person", com, admin, 3)
        |> Enum.map(& &1.name)

      assert "Zzz Resigned Person" in names
    end

    test "set_employee_punch_card_id/4 persists and is then exact-matchable",
         %{admin: admin, com: com} do
      emp = employee_fixture(%{name: "Mansur"}, com, admin)

      {:ok, updated} =
        HR.set_employee_punch_card_id(emp.id, "Mansur.6.Office", com, admin)

      assert updated.punch_card_id == "Mansur.6.Office"

      found = HR.get_employees_by_punch_card_ids(["Mansur.6.Office"], com, admin)
      assert Enum.map(found, & &1.id) == [emp.id]
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/hr_test.exs --only-failures 2>/dev/null; mix test test/full_circle/hr_test.exs`
Expected: FAIL — `match_employee_candidates/4` and `set_employee_punch_card_id/4` undefined.

- [ ] **Step 3: Implement the two functions**

Add to `lib/full_circle/hr.ex` (near `get_employees_by_punch_card_ids/3`, ~line 1091). Note `similarity_order/2` is already imported via `import FullCircle.Helpers` in this module:

```elixir
  @doc """
  Up to `limit` employees ranked by name similarity to `name`, across ALL statuses
  (Active ranked first). Used by the fingerprint import matcher so resigned employees
  with real punches can still be matched.
  """
  def match_employee_candidates(name, company, user, limit \\ 3) do
    from(e in subquery(employee_query(company, user)),
      order_by: [asc: fragment("CASE WHEN ? = 'Active' THEN 0 ELSE 1 END", e.status)],
      order_by: ^similarity_order([:name], name),
      limit: ^limit,
      select: %{id: e.id, name: e.name, status: e.status, punch_card_id: e.punch_card_id}
    )
    |> Repo.all()
  end

  @doc """
  Persist a fingerprint `punch_card_id` onto an employee so future imports auto-match
  it at the exact tier. Returns `{:ok, employee}`.
  """
  def set_employee_punch_card_id(employee_id, punch_card_id, company, user) do
    emp = get_employee!(employee_id, company, user)

    StdInterface.update(
      Employee,
      "employee",
      emp,
      %{"punch_card_id" => punch_card_id},
      company,
      user
    )
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/hr_test.exs`
Expected: PASS.

> If `match_employee_candidates` ordering is flaky for ties, it is acceptable — the test only asserts the top suggestion and a `<= 3` count, not full ordering.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/hr.ex test/full_circle/hr_test.exs
git commit -m "feat: HR fingerprint matcher — fuzzy candidates (Active-first) + persist punch_card_id"
```

---

## Task 4: Vendor SheetJS + browser conversion hook

No unit test (browser/JS); verified by running the app in Task 6.

**Files:**
- Create: `assets/vendor/sheetjs/xlsx.mjs`
- Modify: `assets/js/app.js`

- [ ] **Step 1: Vendor the SheetJS ESM build**

```bash
mkdir -p assets/vendor/sheetjs
curl -L -o assets/vendor/sheetjs/xlsx.mjs https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.mjs
head -c 200 assets/vendor/sheetjs/xlsx.mjs   # sanity: should show the SheetJS banner comment
```

Expected: file is several hundred KB and starts with the SheetJS license banner. (If the network blocks the CDN, fetch `xlsx.mjs` from the `xlsx` npm tarball `package/dist/xlsx.mjs` and place it at the same path.)

- [ ] **Step 2: Add the conversion hook in `assets/js/app.js`**

Add to the `Hooks` object (before `let liveSocket = new LiveSocket(...)`):

```javascript
// Converts machine .xls (and passes through .xlsx) to .xlsx in-browser, then
// hands the result to the LiveView uploader. Keeps the server on xlsx_reader.
// SheetJS is dynamically imported so it only loads on the import page.
Hooks.XlsToXlsxUpload = {
  mounted() {
    this.el.addEventListener("change", async (e) => {
      const files = Array.from(e.target.files || [])
      if (files.length === 0) return
      const XLSX = await import("../vendor/sheetjs/xlsx.mjs")
      const converted = []
      for (const f of files) {
        const buf = await f.arrayBuffer()
        const wb = XLSX.read(buf, { type: "array" })
        const out = XLSX.write(wb, { bookType: "xlsx", type: "array" })
        const base = f.name.replace(/\.(xls|xlsx)$/i, "")
        converted.push(new File([out], `${base}.xlsx`,
          { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }))
      }
      this.upload("xlsx_file", converted)
      e.target.value = "" // allow re-selecting the same file
    })
  }
}
```

- [ ] **Step 3: Build assets to confirm SheetJS bundles**

Run: `mix assets.build`
Expected: builds without error; a SheetJS chunk appears under `priv/static/assets/chunks/`.

- [ ] **Step 4: Commit**

```bash
git add assets/vendor/sheetjs/xlsx.mjs assets/js/app.js
git commit -m "feat: vendor SheetJS + XlsToXlsxUpload hook for in-browser .xls conversion"
```

---

## Task 5: Wire the LiveView — multi-file upload + matching panel

Rework `upload_punch_log.ex` to: accept multiple files, gate on all-done, parse via `FingerPrintImport.parse_files_rows/1`, filter zero-punch people, and render the 3-tier matcher with `confirm_match` / `manual_match` events. Verified by running (Task 6).

**Files:**
- Modify: `lib/full_circle_web/live/time_attend_live/upload_punch_log.ex`

- [ ] **Step 1: Upload config — allow multiple files**

In `mount/3`, change the `allow_upload` to:

```elixir
      |> allow_upload(:xlsx_file,
        accept: ~w(.xlsx),
        max_entries: 4,
        max_file_size: 12_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
```

- [ ] **Step 2: All-done gate + multi-file parse in `handle_progress/3`**

Replace the body of `handle_progress(:xlsx_file, entry, socket)` with:

```elixir
  def handle_progress(:xlsx_file, _entry, socket) do
    {_done, still_uploading} = uploaded_entries(socket, :xlsx_file)

    if still_uploading == [] do
      raw_files =
        consume_uploaded_entries(socket, :xlsx_file, fn %{path: path}, _entry ->
          {:ok, read_excel_files(path)}
        end)

      case FullCircle.HR.FingerPrintImport.parse_files_rows(raw_files) do
        {:ok, []} ->
          {:noreply, socket |> put_flash(:error, gettext("No punches found in the file(s)."))}

        {:ok, raw_attendances} ->
          {:noreply, build_attendances_assigns(socket, raw_files, raw_attendances)}

        {:error, {:date_range_mismatch, _ranges}} ->
          {:noreply,
           socket
           |> put_flash(:error,
             gettext("Uploaded files cover different months. Upload one month's machines together."))}
      end
    else
      {:noreply, socket}
    end
  end
```

> `read_excel_files/1` stays as-is (reads the `"Att.log report"` sheet from a single converted `.xlsx`). It now returns one file's rows; `parse_files_rows/1` receives the list of all files' rows.

- [ ] **Step 3: Add the assigns builder + match helpers**

Add these private functions to the module. `fill_in_employee_info/3` is reused unchanged; we then attach top-3 fuzzy candidates for unmatched people and drop zero-punch people:

```elixir
  defp build_attendances_assigns(socket, raw_files, raw_attendances) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    attendances = fill_in_employee_info(raw_attendances, com, user)

    people = build_people(attendances, com, user)
    todate = attendances |> Enum.max_by(& &1.punch_time_local) |> Map.get(:punch_time_local)
    fromdate = attendances |> Enum.min_by(& &1.punch_time_local) |> Map.get(:punch_time_local)

    socket
    |> assign(
      raw_attendances: raw_files,
      attendances: attendances,
      people: people,
      total_attendence_entries: Enum.count(attendances),
      total_employees: Enum.count(people),
      from_date: Timex.to_date(fromdate),
      to_date: Timex.to_date(todate),
      imported: false
    )
  end

  # One row per distinct fingerprint person that has >= 1 punch.
  defp build_people(attendances, com, user) do
    attendances
    |> Enum.group_by(& &1.punch_card_id)
    |> Enum.map(fn {card_id, list} ->
      first = hd(list)
      matched? = first.employee_id != "!! Not Found !!"

      %{
        punch_card_id: card_id,
        finger_name: first[:Name],
        punch_count: Enum.count(list),
        employee_id: if(matched?, do: first.employee_id, else: nil),
        employee_name: if(matched?, do: first.employee_name, else: nil),
        candidates:
          if(matched?, do: [], else: HR.match_employee_candidates(first[:Name], com, user, 3))
      }
    end)
    |> Enum.sort_by(& &1.finger_name)
  end
```

- [ ] **Step 4: Match events (confirm a suggestion / manual pick) + refresh re-resolves**

Add handlers. Both persist `punch_card_id`, then re-resolve people so the row turns green:

```elixir
  @impl true
  def handle_event("confirm_match", %{"card-id" => card_id, "emp-id" => emp_id}, socket) do
    {:noreply, do_match(socket, card_id, emp_id)}
  end

  @impl true
  def handle_event("manual_match", %{"card_id" => card_id, "employee_id" => emp_id}, socket)
      when emp_id != "" do
    {:noreply, do_match(socket, card_id, emp_id)}
  end

  def handle_event("manual_match", _params, socket), do: {:noreply, socket}

  defp do_match(socket, card_id, emp_id) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    case HR.set_employee_punch_card_id(emp_id, card_id, com, user) do
      {:ok, _emp} ->
        attendances = fill_in_employee_info(socket.assigns.attendances, com, user)

        socket
        |> assign(
          attendances: attendances,
          people: build_people(attendances, com, user)
        )

      _ ->
        socket |> put_flash(:error, gettext("Could not match employee."))
    end
  end
```

Update the existing `handle_event("refresh", ...)` to rebuild from `raw_attendances` through the new path:

```elixir
  @impl true
  def handle_event("refresh", _params, socket) do
    case FullCircle.HR.FingerPrintImport.parse_files_rows(socket.assigns.raw_attendances) do
      {:ok, raw_attendances} ->
        {:noreply, build_attendances_assigns(socket, socket.assigns.raw_attendances, raw_attendances)}

      _ ->
        {:noreply, socket}
    end
  end
```

Update `handle_event("import", ...)` to skip unmatched (unchanged logic, now reads `attendances`):

```elixir
  @impl true
  def handle_event("import", _params, socket) do
    insert_time_attendence_from_logs(
      socket.assigns.attendances,
      socket.assigns.current_company,
      socket.assigns.current_user
    )

    {:noreply, socket |> assign(imported: true)}
  end
```

- [ ] **Step 5: Replace the file input + employee grid in `render/1`**

Replace the `<.live_file_input ...>` with a plain hooked input so the JS converts before upload:

```heex
        <input
          type="file"
          id="xls-picker"
          name="xls-picker"
          accept=".xls,.xlsx"
          multiple
          phx-hook="XlsToXlsxUpload"
          phx-update="ignore"
        />
```

Replace the employees grid block (the `@employees`/`copyAndOpen`/`PreviewAttendenceLive` section) with a matcher panel driven by `@people`:

```heex
    <div class="w-10/12 mx-auto p-4 mb-1 border rounded-lg border-green-500 bg-green-200">
      <div class="my-2 text-center mx-auto font-bold text-2xl">
        <.link phx-click="refresh" class="button blue">{gettext("Refresh")}</.link>
      </div>

      <%= for person <- @people do %>
        <div class={"m-1 p-2 border rounded flex flex-wrap items-center gap-2 " <>
              if(person.employee_id, do: "bg-green-100 border-green-500",
                 else: "bg-rose-100 border-rose-400")}>
          <div class="w-[28%] font-bold">
            {person.finger_name}
            <span class="font-normal text-sm">({person.punch_count} {gettext("punches")})</span>
          </div>

          <%= if person.employee_id do %>
            <div class="text-green-800">✓ {person.employee_name}</div>
          <% else %>
            <div class="flex flex-wrap items-center gap-1">
              <%= for cand <- person.candidates do %>
                <button
                  type="button"
                  phx-click="confirm_match"
                  phx-value-card-id={person.punch_card_id}
                  phx-value-emp-id={cand.id}
                  class="button orange"
                >
                  {cand.name}
                  <span :if={cand.status != "Active"} class="text-xs">({cand.status})</span>
                </button>
              <% end %>

              <form phx-change="manual_match" class="inline">
                <input type="hidden" name="card_id" value={person.punch_card_id} />
                <select name="employee_id" class="border rounded p-1">
                  <option value="">{gettext("— pick manually —")}</option>
                  <%= for e <- @all_employees do %>
                    <option value={e.id}>{e.name}</option>
                  <% end %>
                </select>
              </form>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
```

- [ ] **Step 6: Provide `@all_employees` for the manual dropdown**

In `mount/3`, add to the initial `assign(...)`: `people: [], all_employees: []`. Then load the list once in `build_attendances_assigns/3` (status-agnostic — includes resigned):

In `build_attendances_assigns/3`, add to the `assign(...)`:

```elixir
      all_employees:
        FullCircle.HR.match_employee_candidates("", com, user, 10_000)
```

> `match_employee_candidates("", …, 10_000)` returns all employees (Active first) as `%{id, name, status, punch_card_id}` maps — reused as the manual picker source so resigned employees are selectable. With an empty term `similarity_order` contributes nothing, leaving the Active-first order.

- [ ] **Step 7: Remove dead assigns/helpers**

Delete the old `employees:` assign and any now-unused references (`@employees`, the `error_to_string` entries stay; `PreviewAttendenceLive.Component` usage is removed from render). Keep `read_excel_files/1`, `fill_in_employee_info/3`, `insert_time_attendence_from_logs/3`.

- [ ] **Step 8: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean. Fix any unused-variable/assign warnings the edits introduced.

- [ ] **Step 9: Commit**

```bash
git add lib/full_circle_web/live/time_attend_live/upload_punch_log.ex
git commit -m "feat: multi-file fingerprint import with 3-tier employee matching panel"
```

---

## Task 6: End-to-end verification against the dev DB

The dev DB already holds the **correct** PaySlips/salary notes for these employees/periods — the oracle.

- [ ] **Step 1: Capture a known-good baseline**

Pick the `JAN 2026` period. In the dev DB, note the days-worked / salary-note quantities the correct PaySlips imply for ~4 employees: at least two from the base machine (e.g. *Chaudhary Ramesh Kumar*, *Gurung Bir Bahadur*), one from the `a` machine, and (if present) one resigned employee. Record expected days-worked from `Att. Stat.`'s "Att. Days (Nor./Real)" as a cross-check.

- [ ] **Step 2: Run the app and import**

```bash
mix phx.server
```

Navigate to `/companies/<id>/import_attend`. Select **both** `docs/JAN 2026.xls` and `docs/JAN 2026a.xls` at once. Confirm:
- the files upload (browser converted `.xls`→`.xlsx`; no server error),
- the summary shows both machines' totals and the Jan date range,
- the matcher lists people; already-mapped ones are green; unmapped ones show up to 3 fuzzy suggestions + a manual dropdown that includes resigned employees,
- zero-punch people do **not** appear.

- [ ] **Step 3: Match + import**

Confirm/assign any unmatched people (verify a confirm flips the row green and that the same person is auto-green on a second `Refresh`). Click **Import**.

- [ ] **Step 4: Verify punches + days-worked**

```bash
# count imported finger_log punches for Jan 2026
```
Using the SQL/eval console, confirm `time_attendences` gained `finger_log` rows across `2026-01-01..2026-01-31`. Then open the **Punch Card** for each baseline employee for Jan 2026 and confirm computed **days-worked** matches the baseline from Step 1 (and the machine's `Att. Stat.` real-days).

- [ ] **Step 5: Idempotency**

Re-import the same two files. Confirm `time_attendences` row counts for Jan 2026 are **unchanged** (the ±5-min/same-flag guard held).

- [ ] **Step 6: Record results**

Note any employee whose computed days-worked diverged from the oracle and investigate (usually a matching or a missing-punch-day issue, not a parse bug). If all match, the feature is verified.

---

## Self-Review notes

- **Spec coverage:** multi-file (T2,T5) · in-browser `.xls`→`.xlsx`, no server dep (T4) · union of two disjoint machines (T2) · exact/top-3-fuzzy/manual matcher persisted to `punch_card_id` (T3,T5) · resigned included + Active-first + zero-punch filtered (T3,T5 `build_people`) · idempotent insert reused (T5,T6) · verification vs dev DB (T6). No schema/route/migration changes — matches "import-only" scope.
- **Type consistency:** `parse_file_rows/1`, `parse_files_rows/1`, `file_date_range/1`, `match_employee_candidates/4` (returns `%{id,name,status,punch_card_id}`), `set_employee_punch_card_id/4` (returns `{:ok, emp}`), `build_people/3` (uses `:employee_id`/`:candidates`/`:punch_card_id`) are used consistently across tasks.
- **Reused unchanged:** `read_excel_files/1`, `fill_in_employee_info/3`, `HR.insert_time_attendence_from_log/2`, `HR.get_employees_by_punch_card_ids/3`, `similarity_order/2`.
```
