# Pay Run UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Pay Run grid with a two-month rich-row view that shows status, net pay, and unprocessed salary-notes/advances per employee, includes resigned employees that had activity in the window, and navigates by month.

**Architecture:** Most of the change is in the data layer: `PayRun.pay_run_index/3` is rewritten to return a 2-month window (latest month first), enriched per employee×month with net pay and unprocessed-item aggregates, and to include resigned employees who have activity in the window. Two small pure functions (`cell_state/2`, `pay_run_totals/1`) drive cell rendering and the summary/totals. The LiveView (`index.ex`) and its row component (`index_component.ex`) are reworked to render the new layout and month navigation.

**Tech Stack:** Elixir, Phoenix LiveView, raw SQL via `FullCircle.Helpers.exec_query_map/1`, `Decimal`, `Number.Delimit`, `Timex`. Spec: [docs/superpowers/specs/2026-06-05-pay-run-ui-refresh-design.md](../specs/2026-06-05-pay-run-ui-refresh-design.md).

---

## File Structure

- **Modify** `lib/full_circle/pay_run.ex` — rewrite `pay_run_index/3` (2-month window, enriched fields, resigned-employee inclusion); change `unzip_pay_list_string/1` to emit a map; add `cell_state/2` and `pay_run_totals/1`.
- **Modify** `lib/full_circle_web/live/pay_run_live/index_component.ex` — render two rich month blocks per employee (status, net pay, unprocessed badges, actions, resigned marker), preserving the print checkbox.
- **Modify** `lib/full_circle_web/live/pay_run_live/index.ex` — month-window navigation (prev/next/current), summary band, totals row.
- **Modify (tests)** `test/full_circle/pay_run_test.exs` — context tests for the data layer and pure helpers.

**Testing posture:** The codebase has context tests but no company-scoped LiveView tests (the only LiveView test is the non-company `user_settings_live_test.exs`). Per "follow established patterns", the logic-bearing data layer (Tasks 1–2) is fully TDD'd; the UI (Tasks 3–4) is implemented to the existing component patterns and verified manually with the commands given.

---

## Task 1: Rewrite `pay_run_index/3` data layer

**Files:**
- Modify: `lib/full_circle/pay_run.ex` (`pay_run_index/3`, `unzip_pay_lists/1`, `unzip_pay_list_string/1`)
- Test: `test/full_circle/pay_run_test.exs`

- [ ] **Step 1: Add a payroll setup helper + failing tests**

Add to `test/full_circle/pay_run_test.exs` (inside the module, alongside the existing `employee_leave_summary` describe block):

```elixir
  alias FullCircle.{PaySlipOp, Accounting}
  import FullCircle.AccountingFixtures

  defp setup_payroll(_context) do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    employee = employee_fixture(%{}, com, admin)

    funds_ac =
      account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)

    salary_type = HR.get_salary_type_by_name("Monthly Salary", com, admin)
    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)

    salary_type_fixture(
      %{
        name: "Employee PCB",
        type: "Deduction",
        cal_func: "pcb_employee",
        db_ac_name: cr_ac.name,
        db_ac_id: cr_ac.id,
        cr_ac_name: cr_ac.name,
        cr_ac_id: cr_ac.id
      },
      com,
      admin
    )

    %{admin: admin, com: com, employee: employee, funds_ac: funds_ac, salary_type: salary_type}
  end

  # Creates an addition salary note dated `date` for `emp` and returns it.
  defp addition_note(emp, date, qty, price, %{salary_type: st} = ctx) do
    salary_note_fixture(
      %{
        "note_date" => to_string(date),
        "quantity" => to_string(qty),
        "unit_price" => to_string(price),
        "employee_name" => emp.name,
        "employee_id" => emp.id,
        "salary_type_name" => st.name,
        "salary_type_id" => st.id,
        "descriptions" => "salary"
      },
      ctx.com,
      ctx.admin
    )
  end

  # Builds a pay slip for `emp` in (mth/yr) with a single addition note of `amount`.
  defp pay_slip_with_addition(emp, mth, yr, amount, ctx) do
    date = Timex.end_of_month(yr, mth)
    sn = addition_note(emp, date, 1, amount, ctx)

    ps_attrs = %{
      "slip_date" => to_string(date),
      "pay_month" => to_string(mth),
      "pay_year" => to_string(yr),
      "employee_name" => emp.name,
      "employee_id" => emp.id,
      "funds_account_name" => ctx.funds_ac.name,
      "funds_account_id" => ctx.funds_ac.id,
      "pay_slip_amount" => to_string(amount),
      "additions" => %{
        "0" => %{
          "_id" => sn.id,
          "note_no" => sn.note_no,
          "note_date" => to_string(date),
          "quantity" => "1",
          "unit_price" => to_string(amount),
          "amount" => to_string(amount),
          "salary_type_name" => ctx.salary_type.name,
          "salary_type_id" => ctx.salary_type.id,
          "employee_id" => emp.id,
          "descriptions" => "salary"
        }
      }
    }

    {:ok, %{create_pay_slip: ps}} = PaySlipOp.create_pay_slip(ps_attrs, ctx.com, ctx.admin)
    ps
  end

  defp find_row(rows, emp), do: Enum.find(rows, fn r -> r.id == emp.id end)
  defp month_cell(row, yr, mth),
    do: Enum.find(row.pay_list, fn p -> p.year == yr and p.month == mth end)

  describe "pay_run_index" do
    setup :setup_payroll

    test "returns a 2-month window, latest month first", ctx do
      base = ~D[2026-05-15]
      rows = PayRun.pay_run_index(base.month, base.year, ctx.com)
      row = find_row(rows, ctx.employee)

      assert length(row.pay_list) == 2
      [first, second] = row.pay_list
      assert {first.year, first.month} == {2026, 5}
      assert {second.year, second.month} == {2026, 4}
    end

    test "reports net pay for a processed pay slip", ctx do
      pay_slip_with_addition(ctx.employee, 5, 2026, "3000", ctx)

      rows = PayRun.pay_run_index(5, 2026, ctx.com)
      cell = ctx.employee |> then(&find_row(rows, &1)) |> month_cell(2026, 5)

      refute is_nil(cell.slip_no)
      assert Decimal.eq?(cell.net_pay, Decimal.new("3000"))
    end

    test "reports unprocessed note and advance counts/sums for a pending employee", ctx do
      emp = employee_fixture(%{}, ctx.com, ctx.admin)
      addition_note(emp, ~D[2026-05-10], 2, 100, ctx)

      advance_fixture(
        %{
          "slip_date" => "2026-05-12",
          "amount" => "500",
          "employee_name" => emp.name,
          "employee_id" => emp.id,
          "funds_account_name" => ctx.funds_ac.name,
          "funds_account_id" => ctx.funds_ac.id,
          "note" => "advance"
        },
        ctx.com,
        ctx.admin
      )

      rows = PayRun.pay_run_index(5, 2026, ctx.com)
      cell = find_row(rows, emp) |> month_cell(2026, 5)

      assert is_nil(cell.slip_no)
      assert cell.unproc_note_count == 1
      assert Decimal.eq?(cell.unproc_note_sum, Decimal.new("200"))
      assert cell.unproc_adv_count == 1
      assert Decimal.eq?(cell.unproc_adv_sum, Decimal.new("500"))
    end

    test "includes a resigned employee that has activity in the window", ctx do
      resigned = employee_fixture(%{status: "Resigned"}, ctx.com, ctx.admin)
      addition_note(resigned, ~D[2026-05-08], 1, 250, ctx)

      rows = PayRun.pay_run_index(5, 2026, ctx.com)

      assert find_row(rows, resigned)
      assert find_row(rows, resigned).status == "Resigned"
    end

    test "excludes a resigned employee with no activity in the window", ctx do
      resigned = employee_fixture(%{status: "Resigned"}, ctx.com, ctx.admin)

      rows = PayRun.pay_run_index(5, 2026, ctx.com)

      assert is_nil(find_row(rows, resigned))
    end
  end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix test test/full_circle/pay_run_test.exs --only-failures 2>/dev/null; mix test test/full_circle/pay_run_test.exs`
Expected: the new `pay_run_index` tests FAIL — `row.pay_list` entries are tuples (no `.year`/`.month`/`.net_pay` map keys), so they raise `BadMapError`/`KeyError`; resigned employees are absent.

- [ ] **Step 3: Rewrite `pay_run_index/3` and the unzip helpers**

In `lib/full_circle/pay_run.ex`, replace the existing `pay_run_index/3`, `unzip_pay_lists/1`, and `unzip_pay_list_string/1` with:

```elixir
  def pay_run_index(month, year, com) do
    months =
      [0, -1]
      |> Enum.map(fn x -> Timex.end_of_month(year, month) |> Timex.shift(months: x) end)
      |> Enum.map(fn d -> {d.year, d.month} end)

    months_sql =
      months
      |> Enum.map_join(" union all ", fn {y, m} ->
        "select #{m} as pay_month, #{y} as pay_year"
      end)

    cid = com.id

    """
    with months as (#{months_sql}),
    candidates as (
      select e.id as employee_id, e.name, e.status
        from employees e
       where e.company_id = '#{cid}'
         and (
           e.status = 'Active'
           or exists (select 1 from pay_slips p join months mm
                        on mm.pay_month = p.pay_month and mm.pay_year = p.pay_year
                       where p.employee_id = e.id and p.company_id = e.company_id)
           or exists (select 1 from salary_notes sn join months mm
                        on mm.pay_month = extract(month from sn.note_date)::int
                       and mm.pay_year = extract(year from sn.note_date)::int
                       where sn.employee_id = e.id and sn.company_id = e.company_id)
           or exists (select 1 from advances av join months mm
                        on mm.pay_month = extract(month from av.slip_date)::int
                       and mm.pay_year = extract(year from av.slip_date)::int
                       where av.employee_id = e.id and av.company_id = e.company_id)
         )
    ),
    emp_month as (
      select c.employee_id, c.name, c.status, m.pay_month, m.pay_year
        from candidates c cross join months m
    )
    select em.employee_id as id, em.name as employee_name, em.status,
           array_agg(
             coalesce(p.slip_no, '') || '|' || coalesce(p.id::varchar, '') || '|' ||
             em.pay_year::varchar || '|' || em.pay_month::varchar || '|' ||
             coalesce((
               select sum(case st.type
                            when 'Addition' then sn.quantity * sn.unit_price
                            when 'Bonus' then sn.quantity * sn.unit_price
                            when 'Deduction' then -(sn.quantity * sn.unit_price)
                            else 0 end)
                 from salary_notes sn join salary_types st on st.id = sn.salary_type_id
                where sn.pay_slip_id = p.id), 0)
             - coalesce((select sum(av.amount) from advances av where av.pay_slip_id = p.id), 0) || '|' ||
             (select count(*) from salary_notes sn
               where sn.employee_id = em.employee_id and sn.company_id = '#{cid}'
                 and sn.pay_slip_id is null
                 and extract(month from sn.note_date)::int = em.pay_month
                 and extract(year from sn.note_date)::int = em.pay_year)::varchar || '|' ||
             coalesce((select sum(sn.quantity * sn.unit_price) from salary_notes sn
               where sn.employee_id = em.employee_id and sn.company_id = '#{cid}'
                 and sn.pay_slip_id is null
                 and extract(month from sn.note_date)::int = em.pay_month
                 and extract(year from sn.note_date)::int = em.pay_year), 0)::varchar || '|' ||
             (select count(*) from advances av
               where av.employee_id = em.employee_id and av.company_id = '#{cid}'
                 and av.pay_slip_id is null
                 and extract(month from av.slip_date)::int = em.pay_month
                 and extract(year from av.slip_date)::int = em.pay_year)::varchar || '|' ||
             coalesce((select sum(av.amount) from advances av
               where av.employee_id = em.employee_id and av.company_id = '#{cid}'
                 and av.pay_slip_id is null
                 and extract(month from av.slip_date)::int = em.pay_month
                 and extract(year from av.slip_date)::int = em.pay_year), 0)::varchar
             order by em.pay_year desc, em.pay_month desc
           ) as pay_list
      from emp_month em
      left join pay_slips p
        on p.employee_id = em.employee_id and p.company_id = '#{cid}'
       and p.pay_month = em.pay_month and p.pay_year = em.pay_year
     group by em.employee_id, em.name, em.status
     order by em.name
    """
    |> Helpers.exec_query_map()
    |> unzip_pay_lists()
  end

  defp unzip_pay_lists(lists) do
    Enum.map(lists, fn x -> Map.merge(x, %{pay_list: unzip_pay_list(x.pay_list)}) end)
  end

  defp unzip_pay_list(list) do
    Enum.map(list, fn x -> unzip_pay_list_string(x) end)
  end

  defp unzip_pay_list_string(str) do
    [ps, ps_id, yr, mth, net, nc, ns, ac, as] = String.split(str, "|")

    %{
      slip_no: blank_to_nil(ps),
      slip_id: blank_to_nil(ps_id),
      year: String.to_integer(yr),
      month: String.to_integer(mth),
      net_pay: if(ps == "", do: nil, else: Decimal.new(net)),
      unproc_note_count: String.to_integer(nc),
      unproc_note_sum: Decimal.new(ns),
      unproc_adv_count: String.to_integer(ac),
      unproc_adv_sum: Decimal.new(as)
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
```

Keep the existing `import Ecto.Query`, `alias`, and `employee_leave_summary/3` untouched.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/pay_run_test.exs`
Expected: PASS (all `pay_run_index` tests plus the existing `employee_leave_summary` tests).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_run.ex test/full_circle/pay_run_test.exs
git commit -m "Rewrite pay_run_index: 2-month window, net pay, unprocessed items, resigned employees"
```

---

## Task 2: Add `cell_state/2` and `pay_run_totals/1` pure helpers

**Files:**
- Modify: `lib/full_circle/pay_run.ex`
- Test: `test/full_circle/pay_run_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/full_circle/pay_run_test.exs`:

```elixir
  describe "cell_state/2" do
    defp cell(attrs) do
      Map.merge(
        %{slip_no: nil, unproc_note_count: 0, unproc_adv_count: 0},
        Map.new(attrs)
      )
    end

    test "done when a slip exists" do
      assert PayRun.cell_state("Active", cell(slip_no: "PS-1")) == :done
      assert PayRun.cell_state("Resigned", cell(slip_no: "PS-1")) == :done
    end

    test "pending when active with no slip" do
      assert PayRun.cell_state("Active", cell([])) == :pending
    end

    test "pending when resigned but has unprocessed items" do
      assert PayRun.cell_state("Resigned", cell(unproc_note_count: 1)) == :pending
      assert PayRun.cell_state("Resigned", cell(unproc_adv_count: 2)) == :pending
    end

    test "na when resigned, no slip, no unprocessed items" do
      assert PayRun.cell_state("Resigned", cell([])) == :na
    end
  end

  describe "pay_run_totals/1" do
    test "aggregates done/pending counts and payroll per month" do
      objects = [
        %{
          status: "Active",
          pay_list: [
            %{year: 2026, month: 5, slip_no: "PS-1", net_pay: Decimal.new("3000"),
              unproc_note_count: 0, unproc_adv_count: 0},
            %{year: 2026, month: 4, slip_no: nil, net_pay: nil,
              unproc_note_count: 1, unproc_adv_count: 0}
          ]
        },
        %{
          status: "Active",
          pay_list: [
            %{year: 2026, month: 5, slip_no: nil, net_pay: nil,
              unproc_note_count: 0, unproc_adv_count: 0},
            %{year: 2026, month: 4, slip_no: "PS-2", net_pay: Decimal.new("2000"),
              unproc_note_count: 0, unproc_adv_count: 0}
          ]
        }
      ]

      totals = PayRun.pay_run_totals(objects)

      assert totals[{2026, 5}].done == 1
      assert totals[{2026, 5}].pending == 1
      assert Decimal.eq?(totals[{2026, 5}].payroll, Decimal.new("3000"))
      assert totals[{2026, 4}].done == 1
      assert totals[{2026, 4}].pending == 1
      assert Decimal.eq?(totals[{2026, 4}].payroll, Decimal.new("2000"))
    end
  end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix test test/full_circle/pay_run_test.exs`
Expected: FAIL — `PayRun.cell_state/2` and `PayRun.pay_run_totals/1` are undefined.

- [ ] **Step 3: Implement the helpers**

Add to `lib/full_circle/pay_run.ex` (public functions, above `employee_leave_summary/3`):

```elixir
  @doc """
  Classifies a month cell for an employee: :done (slip exists),
  :pending (active or has unprocessed items, no slip), or :na
  (resigned with no slip and nothing pending).
  """
  def cell_state(status, pay) do
    cond do
      not is_nil(pay.slip_no) -> :done
      status == "Active" or pay.unproc_note_count > 0 or pay.unproc_adv_count > 0 -> :pending
      true -> :na
    end
  end

  @doc """
  Per-month summary across all rows: `%{{year, month} => %{done, pending, payroll}}`.
  `payroll` sums net pay over done cells; `pending` counts cells in :pending state.
  """
  def pay_run_totals(objects) do
    objects
    |> Enum.flat_map(fn o -> Enum.map(o.pay_list, fn p -> {o.status, p} end) end)
    |> Enum.group_by(fn {_status, p} -> {p.year, p.month} end)
    |> Map.new(fn {ym, pairs} ->
      states = Enum.map(pairs, fn {status, p} -> {cell_state(status, p), p} end)
      done = Enum.count(states, fn {s, _} -> s == :done end)
      pending = Enum.count(states, fn {s, _} -> s == :pending end)

      payroll =
        states
        |> Enum.filter(fn {s, _} -> s == :done end)
        |> Enum.reduce(Decimal.new(0), fn {_s, p}, acc -> Decimal.add(acc, p.net_pay) end)

      {ym, %{done: done, pending: pending, payroll: payroll}}
    end)
  end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/pay_run_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_run.ex test/full_circle/pay_run_test.exs
git commit -m "Add PayRun.cell_state/2 and pay_run_totals/1 helpers"
```

---

## Task 3: Render rich two-month rows in `index_component.ex`

**Files:**
- Modify: `lib/full_circle_web/live/pay_run_live/index_component.ex`

- [ ] **Step 1: Replace the component with the rich-row renderer**

Replace the entire contents of `lib/full_circle_web/live/pay_run_live/index_component.ex` with:

```elixir
defmodule FullCircleWeb.PayRunLive.IndexComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.PayRun

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  defp card_url(yr, mth, name, com) do
    qry = %{
      "search[employee_name]" => name,
      "search[month]" => mth,
      "search[year]" => yr
    }

    "/companies/#{com.id}/PunchCard?#{URI.encode_query(qry)}"
  end

  defp new_payslip_url(id, yr, mth, com) do
    qry = %{"emp_id" => id, "month" => mth, "year" => yr}
    "/companies/#{com.id}/PaySlip/new?#{URI.encode_query(qry)}"
  end

  defp money(nil), do: ""
  defp money(d), do: Number.Delimit.number_to_delimited(d)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={"#{@ex_class} flex bg-gray-200 hover:bg-gray-300 text-center"}>
      <div class="w-[16%] border border-gray-300 py-1">
        <.link
          class="hover:font-bold"
          navigate={~p"/companies/#{@company.id}/employees/#{@obj.id}/edit"}
        >
          {@obj.employee_name}
        </.link>
        <div :if={@obj.status == "Resigned"} class="text-xs text-rose-600">
          {gettext("Resigned")}
        </div>
      </div>

      <.month_block :for={pay <- @obj.pay_list} pay={pay} obj={@obj} company={@company} />
    </div>
    """
  end

  defp month_block(assigns) do
    assigns = assign(assigns, :state, PayRun.cell_state(assigns.obj.status, assigns.pay))

    ~H"""
    <div class="w-[42%] border border-gray-300 flex items-center px-1 py-1 gap-1 text-sm">
      <%= case @state do %>
        <% :done -> %>
          <span class="w-[16%] text-green-700 font-semibold">● {gettext("Done")}</span>
          <span class="w-[26%] text-right font-mono">{money(@pay.net_pay)}</span>
          <span class="w-[28%]"></span>
          <span class="w-[6%]">
            <input
              id={"checkbox_#{@pay.slip_id}"}
              name={"checkbox[#{@pay.slip_id}]"}
              type="checkbox"
              class="rounded border-green-600 checked:bg-green-600"
              phx-click="check_click"
              phx-value-object-id={@pay.slip_id}
            />
          </span>
          <.link
            navigate={"/companies/#{@company.id}/PaySlip/#{@pay.slip_id}/view"}
            class="w-[16%] text-green-700 hover:font-bold"
          >
            {@pay.slip_no}
          </.link>
          <.link
            navigate={card_url(@pay.year, @pay.month, @obj.employee_name, @company)}
            class="w-[8%] text-orange-600 hover:font-bold"
          >
            {gettext("Card")}
          </.link>
        <% :pending -> %>
          <span class="w-[16%] text-amber-600 font-semibold">○ {gettext("Pend")}</span>
          <span class="w-[26%]"></span>
          <span class="w-[34%] flex gap-1 justify-center flex-wrap">
            <span
              :if={@pay.unproc_note_count > 0}
              class="bg-amber-200 rounded px-1"
              title={gettext("Unprocessed salary notes")}
            >
              ✎ {@pay.unproc_note_count}/{money(@pay.unproc_note_sum)}
            </span>
            <span
              :if={@pay.unproc_adv_count > 0}
              class="bg-blue-200 rounded px-1"
              title={gettext("Unprocessed advances")}
            >
              $ {@pay.unproc_adv_count}/{money(@pay.unproc_adv_sum)}
            </span>
          </span>
          <.link
            navigate={new_payslip_url(@obj.id, @pay.year, @pay.month, @company)}
            class="w-[16%] text-blue-600 hover:font-bold"
          >
            {gettext("New Pay")}
          </.link>
          <.link
            navigate={card_url(@pay.year, @pay.month, @obj.employee_name, @company)}
            class="w-[8%] text-orange-600 hover:font-bold"
          >
            {gettext("Card")}
          </.link>
        <% :na -> %>
          <span class="w-full text-gray-400 italic">— {gettext("Resigned")}</span>
      <% end %>
    </div>
    """
  end
end
```

- [ ] **Step 2: Compile and check for warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly (no undefined-function or unused-variable warnings).

- [ ] **Step 3: Commit**

```bash
git add lib/full_circle_web/live/pay_run_live/index_component.ex
git commit -m "Render rich two-month Pay Run rows with status, net pay, unprocessed badges"
```

---

## Task 4: Month navigation, summary band, and totals row in `index.ex`

**Files:**
- Modify: `lib/full_circle_web/live/pay_run_live/index.ex`

- [ ] **Step 1: Replace `index.ex` with the windowed view**

Replace the entire contents of `lib/full_circle_web/live/pay_run_live/index.ex` with:

```elixir
defmodule FullCircleWeb.PayRunLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.PayRun
  alias FullCircleWeb.PayRunLive.IndexComponent

  @selected_max 15

  @impl true
  def mount(_session_params \\ %{}, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Pay Run"))
     |> assign(objects: [])}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id, "value" => "on"}, socket) do
    socket =
      socket
      |> assign(selected: [id | socket.assigns.selected])
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("check_click", %{"object-id" => id}, socket) do
    socket =
      socket
      |> assign(selected: Enum.reject(socket.assigns.selected, fn sid -> sid == id end))
      |> FullCircleWeb.Helpers.can_print?(:selected, @selected_max)

    {:noreply, socket |> assign(ids: Enum.join(socket.assigns.selected, ","))}
  end

  @impl true
  def handle_event("prev", _, socket), do: {:noreply, shift_to(socket, -1)}

  @impl true
  def handle_event("next", _, socket), do: {:noreply, shift_to(socket, 1)}

  @impl true
  def handle_event("current", _, socket) do
    d = Timex.today() |> Timex.shift(months: -1)
    {:noreply, navigate_to(socket, d.month, d.year)}
  end

  defp shift_to(socket, months) do
    d =
      Timex.end_of_month(socket.assigns.search.year, socket.assigns.search.month)
      |> Timex.shift(months: months)

    navigate_to(socket, d.month, d.year)
  end

  defp navigate_to(socket, month, year) do
    qry = %{"search[month]" => month, "search[year]" => year}
    push_navigate(socket, to: "/companies/#{socket.assigns.current_company.id}/PayRun?#{URI.encode_query(qry)}")
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]
    d = Timex.today() |> Timex.shift(months: -1)

    month = String.to_integer(params["month"] || "#{d.month}")
    year = String.to_integer(params["year"] || "#{d.year}")

    objects = PayRun.pay_run_index(month, year, socket.assigns.current_company)

    {:noreply,
     socket
     |> assign(search: %{month: month, year: year})
     |> assign(objects: objects)
     |> assign(totals: PayRun.pay_run_totals(objects))
     |> assign(months: window_months(month, year))
     |> assign(selected: [])
     |> assign(ids: "")
     |> assign(can_print: false)}
  end

  # [latest, previous] — matches pay_run_index ordering (latest month first/leftmost).
  defp window_months(month, year) do
    [0, -1]
    |> Enum.map(fn x -> Timex.end_of_month(year, month) |> Timex.shift(months: x) end)
    |> Enum.map(fn d -> {d.year, d.month} end)
  end

  defp month_label({yr, mth}), do: "#{Timex.month_shortname(mth)} #{yr}"

  defp fmt(d), do: Number.Delimit.number_to_delimited(d)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-9/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <div class="flex justify-center items-center gap-2 mb-2">
        <.button phx-click="prev" class="h-9">◀</.button>
        <div class="font-semibold text-lg w-48 text-center">
          {month_label(Enum.at(@months, 0))} – {month_label(Enum.at(@months, 1))}
        </div>
        <.button phx-click="next" class="h-9">▶</.button>
        <.button phx-click="current" class="h-9 gray">{gettext("Current")}</.button>

        <.link
          :if={@can_print}
          navigate={~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=false&ids=#{@ids}"}
          target="_blank"
          class="blue button"
        >
          {gettext("Print")}{"(#{Enum.count(@selected)})"}
        </.link>
        <.link
          :if={@can_print}
          navigate={~p"/companies/#{@current_company.id}/PaySlip/print_multi?pre_print=true&ids=#{@ids}"}
          target="_blank"
          class="blue button"
        >
          {gettext("Pre Print")}{"(#{Enum.count(@selected)})"}
        </.link>
      </div>

      <div :if={Enum.count(@objects) > 0} class="mb-2">
        <%= for ym <- @months do %>
          <div class="text-center text-sm bg-amber-100 border border-amber-300">
            <span class="font-bold">{month_label(ym)}</span>
            · {gettext("Done")} {@totals[ym].done}
            · {gettext("Pending")} {@totals[ym].pending}
            · {gettext("Payroll")} {fmt(@totals[ym].payroll)}
          </div>
        <% end %>
      </div>

      <div :if={Enum.count(@objects) > 0} class="flex bg-amber-200 text-center font-bold">
        <div class="w-[16%] border border-rose-400">{gettext("Name")}</div>
        <div :for={ym <- @months} class="w-[42%] border border-rose-400">{month_label(ym)}</div>
      </div>

      <div
        :if={Enum.count(@objects) == 0}
        class="bg-amber-200 text-3xl p-4 rounded text-center font-bold"
      >
        {gettext("No Data")}.....
      </div>

      <div id="objects_list" class="mb-2">
        <.live_component
          :for={obj <- @objects}
          module={IndexComponent}
          id={obj.id}
          obj={obj}
          company={@current_company}
          ex_class=""
        />
      </div>

      <div :if={Enum.count(@objects) > 0} class="flex bg-amber-200 text-center font-bold">
        <div class="w-[16%] border border-rose-400">{gettext("Total")}</div>
        <div :for={ym <- @months} class="w-[42%] border border-rose-400">{fmt(@totals[ym].payroll)}</div>
      </div>
    </div>
    """
  end
end
```

Note: `mount/3` keeps the original signature; the `\\ %{}` default is removed if it causes an "unused default" warning — if `mix compile` warns, change the head back to `def mount(_params, _session, socket) do`.

- [ ] **Step 2: Compile and check for warnings**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly. If a warning appears on `mount/3`'s default arg, replace the head with `def mount(_params, _session, socket) do`.

- [ ] **Step 3: Run the full payroll context suite (no regressions)**

Run: `mix test test/full_circle/pay_run_test.exs test/full_circle/pay_slip_op_test.exs`
Expected: PASS.

- [ ] **Step 4: Manual verification in the running app**

Run: `iex -S mix phx.server`, then in a browser open `…/companies/<id>/PayRun` and confirm:
- The header shows two months, **latest leftmost**, with `◀ / ▶ / Current` navigation that changes the window and updates the URL `search[month]`/`search[year]`.
- The summary band shows Done / Pending / Payroll per month; the bottom totals row matches.
- A **Done** cell shows net pay, a slip link, the print checkbox, and Card; ticking checkboxes (up to 15) reveals Print / Pre-Print.
- A **Pending** cell shows New Pay + Card, plus amber Notes and blue Adv badges when unprocessed items exist.
- An employee who **resigned** in a window month still appears; their no-activity month shows the muted "— Resigned" marker (no New Pay link).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/pay_run_live/index.ex
git commit -m "Add Pay Run month-window nav, summary band, and totals row"
```

---

## Self-Review Notes

- **Spec coverage:** two-month window + latest-leftmost (Task 1 SQL ordering, Task 4 `window_months`); net pay (Task 1); unprocessed note/advance counts+sums (Task 1); resigned-employee inclusion + `status` (Task 1); summary band + totals (Task 2 + Task 4); per-cell Done/Pending/Resigned rendering (Task 3); month navigation (Task 4); preserved print checkbox (Task 3 + Task 4). No-punch warning is correctly **out of scope**.
- **Net pay definition** matches `PaySlip.compute_fields/1`: additions + bonuses − deductions − advances; contributions and leaves excluded (the SQL `case` only sums Addition/Bonus/Deduction and subtracts advances).
- **Type consistency:** `pay_list` entries are maps with keys `:slip_no, :slip_id, :year, :month, :net_pay, :unproc_note_count, :unproc_note_sum, :unproc_adv_count, :unproc_adv_sum`; `cell_state/2` and `pay_run_totals/1` and both UI files use exactly these keys plus the row's `:id, :employee_name, :status`.
```
