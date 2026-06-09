# Cash Forecast & Free Cash Flow Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a rolling 13-week cash forecast report that overlays known dated commitments on a historical run-rate baseline, computes weekly free cash above a forward-outflow buffer, and recommends a fixed-deposit tenure ladder.

**Architecture:** A new `FullCircle.Reporting.CashForecast` module holds a **pure core** (`build_forecast/3`, `fd_ladder/1`) that does all arithmetic on plain data, plus **thin query functions** that fetch raw inputs (opening balance, dated cash events, baseline averages) from the DB. A LiveView (`FullCircleWeb.ReportLive.CashForecast`) renders the form, weekly table, ladder box, CSS-bar visualization, and a print view. All reads use `FullCircle.QueryRepo`.

**Tech Stack:** Elixir/Phoenix 1.8, Phoenix LiveView 1.1, Ecto, PostgreSQL (raw SQL for the matcher-based outstanding-balance CTE), Tailwind.

**Spec:** `docs/superpowers/specs/2026-06-09-cash-forecast-free-cash-flow-design.md`

---

## File Structure

- Create: `lib/full_circle/reporting/cash_forecast.ex` — module with pure core + query functions
- Modify: `lib/full_circle/reporting.ex` — add thin delegate `cash_forecast/2` (optional convenience)
- Create: `lib/full_circle_web/live/report_live/cash_forecast.ex` — LiveView form + results
- Create: `lib/full_circle_web/live/report_live/cash_forecast_print.ex` — print view
- Modify: `lib/full_circle_web/router.ex` — add report + print routes
- Test: `test/full_circle/reporting/cash_forecast_test.exs` — pure-core + query tests
- Test: `test/full_circle_web/live/cash_forecast_live_test.exs` — LiveView smoke test

### Data shapes (used across tasks)

A **dated event** (input to the pure core) is a map:
```elixir
%{date: ~D[2026-06-15], in: Decimal.t(), out: Decimal.t(), kind: :known | :posted}
```
`in`/`out` are non-negative Decimals (one is usually zero).

A **week row** (output) is a map:
```elixir
%{
  n: 1, week_start: ~D[...], week_end: ~D[...],
  opening: Decimal, known_in: Decimal, baseline_in: Decimal,
  known_out: Decimal, baseline_out: Decimal,
  total_in: Decimal, total_out: Decimal,
  closing: Decimal, buffer: Decimal, free_cash: Decimal
}
```

The **forecast result**:
```elixir
%{
  start_date: Date, weeks_count: 13, buffer_weeks: 2,
  opening: Decimal, baseline_in: Decimal, baseline_out: Decimal,
  weeks: [week_row, ...],
  ladder: %{lockable_1mo, lockable_2mo, lockable_3mo,
            place_1mo, place_2mo, place_3mo, on_call}  # all Decimal
}
```

---

## Task 1: Pure core — week bucketing & roll-forward

**Files:**
- Create: `lib/full_circle/reporting/cash_forecast.ex`
- Test: `test/full_circle/reporting/cash_forecast_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.Reporting.CashForecastTest do
  use ExUnit.Case, async: true
  alias FullCircle.Reporting.CashForecast

  defp d(n), do: Decimal.new("#{n}")

  describe "build_forecast/3 roll-forward" do
    test "buckets events into weeks and rolls balance forward" do
      start = ~D[2026-06-08]  # a Monday

      events = [
        %{date: ~D[2026-06-10], in: d(1000), out: d(0), kind: :known},   # week 1
        %{date: ~D[2026-06-12], in: d(0), out: d(400), kind: :known},    # week 1
        %{date: ~D[2026-06-16], in: d(0), out: d(700), kind: :known}     # week 2
      ]

      res =
        CashForecast.build_forecast(
          %{opening: d(5000), baseline_in: d(0), baseline_out: d(0), events: events},
          start,
          weeks_count: 13, buffer_weeks: 2
        )

      [w1, w2 | _] = res.weeks
      assert w1.opening == d(5000)
      assert w1.known_in == d(1000)
      assert w1.known_out == d(400)
      assert w1.closing == d(5600)            # 5000 + 1000 - 400
      assert w2.opening == d(5600)
      assert w2.known_out == d(700)
      assert w2.closing == d(4900)            # 5600 - 700
      assert length(res.weeks) == 13
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs:8 -v`
Expected: FAIL — `CashForecast.build_forecast/3` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/full_circle/reporting/cash_forecast.ex`:

```elixir
defmodule FullCircle.Reporting.CashForecast do
  @moduledoc """
  Rolling weekly cash forecast and fixed-deposit tenure ladder.
  Pure core (`build_forecast/3`, `fd_ladder/1`) plus DB query helpers.
  """

  alias FullCircle.{QueryRepo, Accounting}
  alias FullCircle.Accounting.{Account, Transaction}
  import Ecto.Query, warn: false
  import FullCircle.Helpers, only: [exec_query_map: 3, dump_uuid!: 1]

  @zero Decimal.new(0)

  @doc """
  Build the forecast from already-fetched raw inputs.

  `raw` is `%{opening, baseline_in, baseline_out, events}` where events is a list
  of `%{date, in, out, kind}`. Returns the forecast result map (see plan header).
  """
  def build_forecast(raw, start_date, opts) do
    weeks_count = Keyword.fetch!(opts, :weeks_count)
    buffer_weeks = Keyword.fetch!(opts, :buffer_weeks)

    bounds = week_bounds(start_date, weeks_count)
    known = bucket_events(raw.events, bounds)

    weeks =
      bounds
      |> Enum.with_index(1)
      |> roll_forward(known, raw.opening, raw.baseline_in, raw.baseline_out)
      |> apply_buffer(buffer_weeks)

    %{
      start_date: start_date,
      weeks_count: weeks_count,
      buffer_weeks: buffer_weeks,
      opening: raw.opening,
      baseline_in: raw.baseline_in,
      baseline_out: raw.baseline_out,
      weeks: weeks,
      ladder: fd_ladder(weeks)
    }
  end

  # List of {week_start, week_end} for n consecutive 7-day windows.
  defp week_bounds(start_date, n) do
    for i <- 0..(n - 1) do
      ws = Date.add(start_date, i * 7)
      {ws, Date.add(ws, 6)}
    end
  end

  # Returns %{week_index => %{in: Decimal, out: Decimal}} for events inside the horizon.
  # Events before start_date land in week 1; events after the horizon are dropped.
  defp bucket_events(events, bounds) do
    {first_start, _} = hd(bounds)
    {_, last_end} = List.last(bounds)

    Enum.reduce(events, %{}, fn ev, acc ->
      cond do
        Date.compare(ev.date, last_end) == :gt ->
          acc

        true ->
          idx = week_index_for(ev.date, first_start, length(bounds))
          cur = Map.get(acc, idx, %{in: @zero, out: @zero})
          Map.put(acc, idx, %{in: Decimal.add(cur.in, ev.in), out: Decimal.add(cur.out, ev.out)})
      end
    end)
  end

  defp week_index_for(date, first_start, n) do
    days = Date.diff(date, first_start)
    cond do
      days < 0 -> 1
      true -> min(div(days, 7) + 1, n)
    end
  end

  defp roll_forward(indexed_bounds, known, opening, baseline_in, baseline_out) do
    {rows, _} =
      Enum.map_reduce(indexed_bounds, opening, fn {{ws, we}, idx}, open ->
        k = Map.get(known, idx, %{in: @zero, out: @zero})
        total_in = Decimal.add(k.in, baseline_in)
        total_out = Decimal.add(k.out, baseline_out)
        closing = open |> Decimal.add(total_in) |> Decimal.sub(total_out)

        row = %{
          n: idx, week_start: ws, week_end: we,
          opening: open, known_in: k.in, baseline_in: baseline_in,
          known_out: k.out, baseline_out: baseline_out,
          total_in: total_in, total_out: total_out,
          closing: closing, buffer: @zero, free_cash: @zero
        }

        {row, closing}
      end)

    rows
  end

  # buffer[w] = sum of total_out over weeks w+1 .. w+buffer_weeks
  # free_cash[w] = max(0, closing - buffer)
  defp apply_buffer(rows, buffer_weeks) do
    outs = Enum.map(rows, & &1.total_out)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      buffer =
        outs
        |> Enum.slice((i + 1)..(i + buffer_weeks))
        |> Enum.reduce(@zero, &Decimal.add(&2, &1))

      free = Decimal.sub(row.closing, buffer)
      free = if Decimal.compare(free, @zero) == :lt, do: @zero, else: free
      %{row | buffer: buffer, free_cash: free}
    end)
  end

  # Placeholder so the module compiles; real impl in Task 2.
  def fd_ladder(_weeks), do: %{}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs:8 -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/cash_forecast.ex test/full_circle/reporting/cash_forecast_test.exs
git commit -m "feat: cash forecast pure core (week roll-forward + buffer)"
```

---

## Task 2: Pure core — FD tenure ladder

**Files:**
- Modify: `lib/full_circle/reporting/cash_forecast.ex` (replace `fd_ladder/1` placeholder)
- Test: `test/full_circle/reporting/cash_forecast_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "fd_ladder/1" do
    test "rolling minimums and non-negative tenure increments" do
      # free_cash by week 1..13
      frees = [55, 60, 58, 70, 72, 80, 65, 90, 100, 100, 110, 120, 130]
      weeks = for {f, i} <- Enum.with_index(frees, 1), do: %{n: i, free_cash: d(f)}

      ladder = FullCircle.Reporting.CashForecast.fd_ladder(weeks)

      assert ladder.lockable_1mo == d(55)   # min weeks 1-4
      assert ladder.lockable_2mo == d(55)   # min weeks 1-8
      assert ladder.lockable_3mo == d(55)   # min weeks 1-13
      assert ladder.place_3mo == d(55)
      assert ladder.place_2mo == d(0)       # lockable_2mo - lockable_3mo
      assert ladder.place_1mo == d(0)       # lockable_1mo - lockable_2mo
    end

    test "decreasing free cash gives a real ladder" do
      frees = [100, 100, 100, 100, 80, 80, 80, 80, 60, 60, 60, 60, 60]
      weeks = for {f, i} <- Enum.with_index(frees, 1), do: %{n: i, free_cash: d(f)}

      ladder = FullCircle.Reporting.CashForecast.fd_ladder(weeks)

      assert ladder.lockable_1mo == d(100)  # min 1-4
      assert ladder.lockable_2mo == d(80)   # min 1-8
      assert ladder.lockable_3mo == d(60)   # min 1-13
      assert ladder.place_3mo == d(60)
      assert ladder.place_2mo == d(20)      # 80 - 60
      assert ladder.place_1mo == d(20)      # 100 - 80
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: FAIL — ladder map empty, assertions fail.

- [ ] **Step 3: Write implementation** (replace the placeholder `fd_ladder/1`)

```elixir
  @doc """
  Sustainable lock-up amount per tenure = rolling minimum of free cash:
  ~1mo = min(weeks 1-4), ~2mo = min(weeks 1-8), ~3mo = min(weeks 1-13).
  Placement increments are non-negative differences (longest tenure first).
  """
  def fd_ladder(weeks) do
    frees = weeks |> Enum.sort_by(& &1.n) |> Enum.map(& &1.free_cash)

    l1 = min_slice(frees, 4)
    l2 = min_slice(frees, 8)
    l3 = min_slice(frees, 13)

    %{
      lockable_1mo: l1,
      lockable_2mo: l2,
      lockable_3mo: l3,
      place_3mo: l3,
      place_2mo: nonneg(Decimal.sub(l2, l3)),
      place_1mo: nonneg(Decimal.sub(l1, l2)),
      on_call: @zero
    }
  end

  defp min_slice([], _n), do: @zero
  defp min_slice(list, n) do
    list
    |> Enum.take(n)
    |> Enum.reduce(nil, fn x, acc ->
      cond do
        is_nil(acc) -> x
        Decimal.compare(x, acc) == :lt -> x
        true -> acc
      end
    end) || @zero
  end

  defp nonneg(dec) do
    if Decimal.compare(dec, @zero) == :lt, do: @zero, else: dec
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: PASS (all pure-core tests).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/cash_forecast.ex test/full_circle/reporting/cash_forecast_test.exs
git commit -m "feat: cash forecast FD tenure ladder"
```

---

## Task 3: Query — liquid accounts & opening balance

**Files:**
- Modify: `lib/full_circle/reporting/cash_forecast.ex`
- Test: `test/full_circle/reporting/cash_forecast_test.exs`

Liquid = account_type in `["Cash or Equivalent", "Bank"]`. Opening balance = Σ
`transactions.amount` for those accounts with `doc_date < start_date`. Tests
insert `Transaction` rows directly (transactions are a plain table).

- [ ] **Step 1: Write the failing test** (add a new `describe` block; needs DB)

```elixir
defmodule FullCircle.Reporting.CashForecastDBTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures

  alias FullCircle.Reporting.CashForecast
  alias FullCircle.Accounting.Transaction
  alias FullCircle.Repo

  defp d(n), do: Decimal.new("#{n}")

  defp txn!(com, account_id, date, amount, attrs \\ %{}) do
    %Transaction{}
    |> Transaction.changeset(
      Map.merge(
        %{
          doc_type: "Journal", doc_no: "J#{System.unique_integer([:positive])}",
          doc_date: date, particulars: "t", amount: amount,
          company_id: com.id, account_id: account_id
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    # company_fixture seeds a default chart of accounts incl. Cash/Bank types.
    bank =
      Repo.one!(
        from a in FullCircle.Accounting.Account,
          where: a.company_id == ^com.id and a.account_type == "Bank",
          limit: 1
      )

    %{admin: admin, com: com, bank: bank}
  end

  describe "opening_liquid_balance/3" do
    test "sums liquid txns strictly before start_date", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-01], d(1000))
      txn!(com, bank.id, ~D[2026-06-07], d(-300))
      txn!(com, bank.id, ~D[2026-06-08], d(999))  # on start date -> excluded from opening

      ids = CashForecast.liquid_account_ids(com, :all)
      assert bank.id in ids

      bal = CashForecast.opening_liquid_balance(ids, ~D[2026-06-08], com)
      assert bal == d(700)
    end
  end
end
```

> Note: confirm `company_fixture/2` seeds default accounts with a "Bank" type. If
> it does not, create one with `account_fixture(%{account_type: "Bank", name: ...}, com, admin)`
> and use its id. Adjust the setup accordingly before running.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: FAIL — `liquid_account_ids/2` undefined.

- [ ] **Step 3: Write implementation**

```elixir
  @liquid_types ["Cash or Equivalent", "Bank"]

  def liquid_account_types, do: @liquid_types

  @doc "Account ids of liquid type for the company. `:all` or a list of ids to restrict."
  def liquid_account_ids(com, :all) do
    from(a in Account,
      where: a.company_id == ^com.id and a.account_type in ^@liquid_types,
      select: a.id
    )
    |> QueryRepo.all()
  end

  def liquid_account_ids(com, ids) when is_list(ids) do
    from(a in Account,
      where:
        a.company_id == ^com.id and a.account_type in ^@liquid_types and a.id in ^ids,
      select: a.id
    )
    |> QueryRepo.all()
  end

  @doc "Balance of liquid accounts strictly before `start_date`."
  def opening_liquid_balance(account_ids, start_date, com) do
    from(t in Transaction,
      where:
        t.company_id == ^com.id and t.account_id in ^account_ids and
          t.doc_date < ^start_date,
      select: coalesce(sum(t.amount), 0)
    )
    |> QueryRepo.one()
    |> to_decimal()
  end

  defp to_decimal(nil), do: @zero
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n), do: Decimal.new("#{n}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/cash_forecast.ex test/full_circle/reporting/cash_forecast_test.exs
git commit -m "feat: cash forecast liquid accounts + opening balance query"
```

---

## Task 4: Query — posted future-dated liquid flows & baseline run-rate

**Files:**
- Modify: `lib/full_circle/reporting/cash_forecast.ex`
- Test: `test/full_circle/reporting/cash_forecast_test.exs`

Two queries:
1. `posted_future_flows/4` — liquid txns with `doc_date >= start_date` within the
   horizon, returned as dated events (positive amount → `in`, negative → `out`).
2. `baseline_flows/4` — trailing-window average weekly in/out from liquid txns with
   **`contact_id IS NULL`** (operational flows: payroll, utilities, bank charges —
   customer/supplier settlements are modeled separately as known commitments).

- [ ] **Step 1: Write the failing test** (add to `CashForecastDBTest`)

```elixir
  describe "posted_future_flows/4" do
    test "returns dated events split by sign within horizon", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-10], d(1000))
      txn!(com, bank.id, ~D[2026-06-12], d(-400))
      txn!(com, bank.id, ~D[2026-12-31], d(5000)) # beyond 13 weeks -> excluded

      ids = CashForecast.liquid_account_ids(com, :all)
      end_date = ~D[2026-09-06]  # ~13 weeks from 2026-06-08
      events = CashForecast.posted_future_flows(ids, ~D[2026-06-08], end_date, com)

      ins = Enum.filter(events, &(Decimal.compare(&1.in, d(0)) == :gt))
      outs = Enum.filter(events, &(Decimal.compare(&1.out, d(0)) == :gt))
      assert Enum.any?(ins, &(&1.date == ~D[2026-06-10] and &1.in == d(1000)))
      assert Enum.any?(outs, &(&1.date == ~D[2026-06-12] and &1.out == d(400)))
      refute Enum.any?(events, &(&1.date == ~D[2026-12-31]))
    end
  end

  describe "baseline_flows/4" do
    test "averages contact-null liquid flows over the trailing window", %{com: com, bank: bank} do
      # 13-week trailing window before 2026-06-08
      txn!(com, bank.id, ~D[2026-04-01], d(1300))   # contact_id nil -> in
      txn!(com, bank.id, ~D[2026-05-01], d(-650))   # contact_id nil -> out
      # contact-bearing flow must be ignored: insert with a contact
      cont =
        Repo.one!(
          from c in FullCircle.Accounting.Contact,
            where: c.company_id == ^com.id, limit: 1
        )
      txn!(com, bank.id, ~D[2026-05-02], d(9999), %{contact_id: cont.id})

      {bin, bout} = CashForecast.baseline_flows(
        CashForecast.liquid_account_ids(com, :all), ~D[2026-06-08], 13, com)

      assert bin == Decimal.div(d(1300), d(13))   # 100/week
      assert bout == Decimal.div(d(650), d(13))   # 50/week
    end
  end
```

> Note: if `company_fixture` seeds no Contact, create one via the accounting
> fixtures or skip the contact-bearing assertion line. Confirm before running.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: FAIL — `posted_future_flows/4` undefined.

- [ ] **Step 3: Write implementation**

```elixir
  @doc "Already-posted liquid transactions dated on/after start within the horizon."
  def posted_future_flows(account_ids, start_date, end_date, com) do
    from(t in Transaction,
      where:
        t.company_id == ^com.id and t.account_id in ^account_ids and
          t.doc_date >= ^start_date and t.doc_date <= ^end_date,
      select: %{date: t.doc_date, amount: t.amount}
    )
    |> QueryRepo.all()
    |> Enum.map(fn %{date: date, amount: amt} ->
      amt = to_decimal(amt)
      if Decimal.compare(amt, @zero) == :lt do
        %{date: date, in: @zero, out: Decimal.abs(amt), kind: :posted}
      else
        %{date: date, in: amt, out: @zero, kind: :posted}
      end
    end)
  end

  @doc """
  Average weekly in/out from contact-null liquid txns over the `weeks`-long
  window ending the day before `start_date`. Returns `{baseline_in, baseline_out}`.
  """
  def baseline_flows(account_ids, start_date, weeks, com) do
    window_start = Date.add(start_date, -weeks * 7)

    rows =
      from(t in Transaction,
        where:
          t.company_id == ^com.id and t.account_id in ^account_ids and
            is_nil(t.contact_id) and
            t.doc_date >= ^window_start and t.doc_date < ^start_date,
        select: %{
          ins: sum(fragment("case when ? > 0 then ? else 0 end", t.amount, t.amount)),
          outs: sum(fragment("case when ? < 0 then -? else 0 end", t.amount, t.amount))
        }
      )
      |> QueryRepo.one()

    ins = to_decimal(rows && rows.ins)
    outs = to_decimal(rows && rows.outs)
    wk = Decimal.new("#{weeks}")
    {Decimal.div(ins, wk), Decimal.div(outs, wk)}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/cash_forecast.ex test/full_circle/reporting/cash_forecast_test.exs
git commit -m "feat: cash forecast posted-future + baseline run-rate queries"
```

---

## Task 5: Query — known inflow cheques + outstanding AR/AP by due date

**Files:**
- Modify: `lib/full_circle/reporting/cash_forecast.ex`
- Test: `test/full_circle/reporting/cash_forecast_test.exs`

This task reuses the **matcher-based outstanding-balance CTE** from
`FullCircle.Reporting.contact_bucket_transactions/5` (see `lib/full_circle/reporting.ex`),
generalized to return ALL outstanding documents (no age bucket filter) and joined
to `invoices` / `pur_invoices` for `due_date`. Past-due unpaid items (due_date <
start_date) are clamped to `start_date` so they land in week 1.

Because seeding fully-matched invoices/receipts through triggers is heavy, the
**due-date placement logic is extracted into a pure helper** `clamp_due/2` that is
unit-tested, and the SQL function is covered by one integration test that inserts
an unmatched invoice transaction directly.

- [ ] **Step 1: Write the failing test**

Pure helper test (add to `CashForecastTest`, no DB):

```elixir
  describe "clamp_due/2" do
    test "past-due dates clamp to start_date, future dates pass through" do
      start = ~D[2026-06-08]
      assert FullCircle.Reporting.CashForecast.clamp_due(~D[2026-05-01], start) == start
      assert FullCircle.Reporting.CashForecast.clamp_due(~D[2026-07-01], start) == ~D[2026-07-01]
    end
  end
```

Integration test (add to `CashForecastDBTest`): insert a single AR-side
transaction (an Invoice doc_type with a positive contact balance and matching
`invoices` row) and assert it surfaces as a known inflow on its due date.

```elixir
  describe "outstanding_ar_events/3" do
    test "unpaid sales invoice surfaces as inflow on its due_date", %{com: com, bank: _bank} do
      cont =
        Repo.one!(from c in FullCircle.Accounting.Contact,
          where: c.company_id == ^com.id, limit: 1)

      debtor =
        Repo.one!(from a in FullCircle.Accounting.Account,
          where: a.company_id == ^com.id and a.account_type == "Current Asset",
          limit: 1)

      inv =
        %FullCircle.Billing.Invoice{}
        |> Ecto.Changeset.change(%{
          invoice_no: "INV-T1", invoice_date: ~D[2026-06-01], due_date: ~D[2026-06-20],
          company_id: com.id, contact_id: cont.id
        })
        |> Repo.insert!()

      # AR transaction: positive contact balance, doc_id points to the invoice
      %Transaction{}
      |> Transaction.changeset(%{
        doc_type: "Invoice", doc_no: "INV-T1", doc_date: ~D[2026-06-01],
        particulars: "sale", amount: d(800),
        company_id: com.id, account_id: debtor.id, contact_id: cont.id
      })
      |> Repo.insert!()
      |> Ecto.Changeset.change(%{doc_id: inv.id})
      |> Repo.update!()

      end_date = ~D[2026-09-06]
      events = CashForecast.outstanding_ar_events(~D[2026-06-08], end_date, com)

      assert Enum.any?(events, &(&1.date == ~D[2026-06-20] and &1.in == d(800)))
    end
  end
```

> Note: `Transaction.changeset` does not cast `doc_id`; the test sets it via a
> follow-up `change/update`. Confirm `Billing.Invoice` field names
> (`invoice_no`, `invoice_date`, `due_date`, `contact_id`) before running — they
> are listed in `lib/full_circle/billing/invoice.ex`.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: FAIL — `clamp_due/2` / `outstanding_ar_events/3` undefined.

- [ ] **Step 3: Write implementation**

```elixir
  @doc "Clamp a due date to the forecast start (past-due items become due immediately)."
  def clamp_due(due_date, start_date) do
    if Date.compare(due_date, start_date) == :lt, do: start_date, else: due_date
  end

  @doc "Unpaid sales-invoice balances as inflow events on their (clamped) due_date."
  def outstanding_ar_events(start_date, end_date, com),
    do: outstanding_invoice_events(:ar, start_date, end_date, com)

  @doc "Unpaid purchase-invoice balances as outflow events on their (clamped) due_date."
  def outstanding_ap_events(start_date, end_date, com),
    do: outstanding_invoice_events(:ap, start_date, end_date, com)

  # direction: :ar -> sales invoices, inflow; :ap -> purchase invoices, outflow
  defp outstanding_invoice_events(direction, start_date, end_date, com) do
    {doc_type, inv_table, date_col} =
      case direction do
        :ar -> {"Invoice", "invoices", "due_date"}
        :ap -> {"PurInvoice", "pur_invoices", "due_date"}
      end

    com_id_bin = dump_uuid!(com.id)

    # Net outstanding per document via the same matcher logic the aging report uses,
    # joined to the source document for its due_date.
    sql = """
      with outstanding as (
        select t.doc_id,
               t.amount
                 + coalesce(sum(stm.match_amount), 0)
                 + coalesce(sum(tm.match_amount), 0) as balance
          from transactions t
          left outer join seed_transaction_matchers stm on stm.transaction_id = t.id
          left outer join transaction_matchers tm on tm.transaction_id = t.id
         where t.company_id = $1
           and t.doc_type = $2
           and t.doc_id is not null
         group by t.id
        having t.amount
                 + coalesce(sum(stm.match_amount), 0)
                 + coalesce(sum(tm.match_amount), 0) <> 0
      )
      select inv.#{date_col} as due_date, sum(o.balance) as balance
        from outstanding o
        join #{inv_table} inv on inv.id = o.doc_id
       group by inv.#{date_col}
      having sum(o.balance) <> 0
    """

    exec_query_map(sql, [com_id_bin, doc_type], FullCircle.QueryRepo)
    |> Enum.map(fn %{due_date: due, balance: bal} ->
      due = clamp_due(due, start_date)
      bal = Decimal.abs(to_decimal(bal))
      %{date: due, balance: bal}
    end)
    |> Enum.reject(&(Date.compare(&1.date, end_date) == :gt))
    |> Enum.map(fn %{date: due, balance: bal} ->
      case direction do
        :ar -> %{date: due, in: bal, out: @zero, kind: :known}
        :ap -> %{date: due, in: @zero, out: bal, kind: :known}
      end
    end)
  end

  @doc "In-hand received cheques (not deposited, not returned) as inflow on due_date."
  def known_inflow_cheques(start_date, end_date, com) do
    FullCircle.Reporting.post_dated_cheques("", "In-Hand", "", Date.to_iso8601(end_date), com)
    |> Enum.filter(fn c -> c.due_date && Date.compare(c.due_date, end_date) != :gt end)
    |> Enum.map(fn c ->
      %{date: clamp_due(c.due_date, start_date), in: to_decimal(c.amount), out: @zero, kind: :known}
    end)
  end
```

> Note on `match_amount` column name: the existing
> `contact_bucket_transactions/5` SQL uses `stm.match_amount` and `tm.match_amount`.
> Reuse those exact column names. If compilation/SQL errors on a column, copy the
> precise expression from `lib/full_circle/reporting.ex` `contact_bucket_transactions`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/cash_forecast.ex test/full_circle/reporting/cash_forecast_test.exs
git commit -m "feat: cash forecast known commitments (AR/AP due dates + in-hand cheques)"
```

---

## Task 6: Top-level assembly `cash_forecast/2`

**Files:**
- Modify: `lib/full_circle/reporting/cash_forecast.ex`
- Modify: `lib/full_circle/reporting.ex` (delegate)
- Test: `test/full_circle/reporting/cash_forecast_test.exs`

- [ ] **Step 1: Write the failing test** (add to `CashForecastDBTest`)

```elixir
  describe "cash_forecast/2 end-to-end" do
    test "produces 13 weeks, opening, and a ladder", %{com: com, bank: bank} do
      txn!(com, bank.id, ~D[2026-06-01], d(10_000))     # opening
      txn!(com, bank.id, ~D[2026-06-10], d(2000))       # posted future inflow

      res =
        CashForecast.cash_forecast(
          %{start_date: ~D[2026-06-08], weeks_count: 13, buffer_weeks: 2,
            trailing_weeks: 13, account_ids: :all},
          com
        )

      assert res.opening == d(10_000)
      assert length(res.weeks) == 13
      assert hd(res.weeks).opening == d(10_000)
      assert Map.has_key?(res.ladder, :place_3mo)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: FAIL — `cash_forecast/2` undefined.

- [ ] **Step 3: Write implementation**

```elixir
  @doc """
  Full forecast. `opts` is a map with `:start_date`, `:weeks_count` (default 13),
  `:buffer_weeks` (default 2), `:trailing_weeks` (default 52), `:account_ids`
  (`:all` or list).
  """
  def cash_forecast(opts, com) do
    start_date = Map.fetch!(opts, :start_date)
    weeks_count = Map.get(opts, :weeks_count, 13)
    buffer_weeks = Map.get(opts, :buffer_weeks, 2)
    trailing_weeks = Map.get(opts, :trailing_weeks, 52)
    account_sel = Map.get(opts, :account_ids, :all)

    end_date = Date.add(start_date, weeks_count * 7 - 1)
    ids = liquid_account_ids(com, account_sel)

    opening = opening_liquid_balance(ids, start_date, com)
    {bin, bout} = baseline_flows(ids, start_date, trailing_weeks, com)

    events =
      posted_future_flows(ids, start_date, end_date, com) ++
        known_inflow_cheques(start_date, end_date, com) ++
        outstanding_ar_events(start_date, end_date, com) ++
        outstanding_ap_events(start_date, end_date, com)

    build_forecast(
      %{opening: opening, baseline_in: bin, baseline_out: bout, events: events},
      start_date,
      weeks_count: weeks_count, buffer_weeks: buffer_weeks
    )
  end
```

Add the delegate to `lib/full_circle/reporting.ex` (anywhere among the public defs):

```elixir
  defdelegate cash_forecast(opts, com), to: FullCircle.Reporting.CashForecast
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/full_circle/reporting/cash_forecast_test.exs -v`
Expected: PASS (whole suite green).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/reporting/cash_forecast.ex lib/full_circle/reporting.ex test/full_circle/reporting/cash_forecast_test.exs
git commit -m "feat: cash forecast top-level assembly + reporting delegate"
```

---

## Task 7: LiveView — form, weekly table, ladder box

**Files:**
- Create: `lib/full_circle_web/live/report_live/cash_forecast.ex`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/live/cash_forecast_live_test.exs`

- [ ] **Step 1: Add the route**

In `lib/full_circle_web/router.ex`, next to the other report routes (~line 226):

```elixir
      live("/cash_forecast", ReportLive.CashForecast, :index)
```

- [ ] **Step 2: Write the failing LiveView test**

```elixir
defmodule FullCircleWeb.CashForecastLiveTest do
  use FullCircleWeb.ConnCase
  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    conn = log_in_user(conn, admin)   # confirm helper name in ConnCase/auth test support
    %{conn: conn, com: com, admin: admin}
  end

  test "renders the cash forecast form and runs a query", %{conn: conn, com: com} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/cash_forecast")
    assert html =~ "Cash Forecast"

    lv
    |> form("#search-form", search: %{s_date: "2026-06-08"})
    |> render_submit()

    assert render(lv) =~ "Free Cash"
  end
end
```

> Note: confirm the login helper used by other LiveView tests (search
> `test/` for `log_in_user` or `register_and_log_in_user`) and the company-scoped
> path helper. Mirror an existing report LiveView test if present.

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/full_circle_web/live/cash_forecast_live_test.exs -v`
Expected: FAIL — module/route missing.

- [ ] **Step 4: Write the LiveView**

Model on `lib/full_circle_web/live/report_live/fixed_assets.ex` and
`post_dated_cheques.ex` (form → `push_navigate` with query params →
`handle_params` runs the query via `assign_async`). Create
`lib/full_circle_web/live/report_live/cash_forecast.ex`:

```elixir
defmodule FullCircleWeb.ReportLive.CashForecast do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Cash Forecast"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    p = params["search"] || %{}
    s_date = p["s_date"] || Date.to_iso8601(Date.utc_today())
    buffer_weeks = p["buffer_weeks"] || "2"
    trailing_weeks = p["trailing_weeks"] || "52"

    {:noreply,
     socket
     |> assign(search: %{s_date: s_date, buffer_weeks: buffer_weeks, trailing_weeks: trailing_weeks})
     |> run_forecast(s_date, buffer_weeks, trailing_weeks)}
  end

  @impl true
  def handle_event("query", %{"search" => s}, socket) do
    qry = %{
      "search[s_date]" => s["s_date"],
      "search[buffer_weeks]" => s["buffer_weeks"],
      "search[trailing_weeks]" => s["trailing_weeks"]
    }

    {:noreply,
     push_navigate(socket,
       to:
         "/companies/#{socket.assigns.current_company.id}/cash_forecast?#{URI.encode_query(qry)}"
     )}
  end

  defp run_forecast(socket, s_date, buffer_weeks, trailing_weeks) do
    com = socket.assigns.current_company

    parsed =
      with {:ok, date} <- Date.from_iso8601(s_date) do
        %{
          start_date: date,
          weeks_count: 13,
          buffer_weeks: String.to_integer(buffer_weeks),
          trailing_weeks: String.to_integer(trailing_weeks),
          account_ids: :all
        }
      else
        _ -> nil
      end

    assign_async(socket, :result, fn ->
      {:ok, %{result: if(parsed, do: Reporting.cash_forecast(parsed, com), else: nil)}}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-10/12 mx-auto mb-10">
      <p class="text-2xl text-center font-medium">{@page_title}</p>

      <div class="border rounded bg-amber-200 dark:bg-amber-900 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 gap-2 tracking-tighter">
            <div class="col-span-3">
              <.input label={gettext("Start Date")} name="search[s_date]" type="date"
                id="search_s_date" value={@search.s_date} />
            </div>
            <div class="col-span-3">
              <.input label={gettext("Buffer Weeks")} name="search[buffer_weeks]" type="number"
                id="search_buffer_weeks" value={@search.buffer_weeks} />
            </div>
            <div class="col-span-3">
              <.input label={gettext("Trailing Weeks")} name="search[trailing_weeks]" type="number"
                id="search_trailing_weeks" value={@search.trailing_weeks} />
            </div>
            <div class="col-span-3 mt-6">
              <.button>{gettext("Query")}</.button>
            </div>
          </div>
        </.form>
      </div>

      <.async_html result={@result}>
        <:result_html>
          <% f = @result.result %>
          <div :if={f}>
            <.ladder_box ladder={f.ladder} />
            <.week_table weeks={f.weeks} opening={f.opening} />
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end

  attr :ladder, :map, required: true
  defp ladder_box(assigns) do
    ~H"""
    <div class="my-4 p-3 border rounded bg-green-100 dark:bg-green-900">
      <p class="font-bold text-center">{gettext("Fixed Deposit Tenure Ladder")}</p>
      <div class="grid grid-cols-3 text-center mt-2">
        <div>~1 mo (4 wk): <span class="font-mono">{fmt(@ladder.place_1mo)}</span></div>
        <div>~2 mo (8 wk): <span class="font-mono">{fmt(@ladder.place_2mo)}</span></div>
        <div>~3 mo (13 wk): <span class="font-mono">{fmt(@ladder.place_3mo)}</span></div>
      </div>
    </div>
    """
  end

  attr :weeks, :list, required: true
  attr :opening, :any, required: true
  defp week_table(assigns) do
    ~H"""
    <table class="w-full text-sm text-right border">
      <thead class="bg-gray-200 dark:bg-gray-700">
        <tr>
          <th class="text-center">{gettext("Wk")}</th>
          <th class="text-center">{gettext("Start")}</th>
          <th>{gettext("Opening")}</th>
          <th>{gettext("Known In")}</th>
          <th>{gettext("Base In")}</th>
          <th>{gettext("Known Out")}</th>
          <th>{gettext("Base Out")}</th>
          <th>{gettext("Closing")}</th>
          <th>{gettext("Buffer")}</th>
          <th>{gettext("Free Cash")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={w <- @weeks} class="border-b odd:bg-white even:bg-gray-50 dark:odd:bg-gray-800 dark:even:bg-gray-900">
          <td class="text-center">{w.n}</td>
          <td class="text-center">{Date.to_iso8601(w.week_start)}</td>
          <td class="font-mono">{fmt(w.opening)}</td>
          <td class="font-mono">{fmt(w.known_in)}</td>
          <td class="font-mono text-gray-500">{fmt(w.baseline_in)}</td>
          <td class="font-mono">{fmt(w.known_out)}</td>
          <td class="font-mono text-gray-500">{fmt(w.baseline_out)}</td>
          <td class="font-mono font-bold">{fmt(w.closing)}</td>
          <td class="font-mono">{fmt(w.buffer)}</td>
          <td class="font-mono font-bold text-green-700 dark:text-green-400">{fmt(w.free_cash)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp fmt(%Decimal{} = d), do: Number.Delimit.number_to_delimited(d)
  defp fmt(other), do: to_string(other)
end
```

> Note: `Number.Delimit.number_to_delimited/1` is used widely in this app for
> money formatting — confirm by grepping existing LiveViews; if a project helper
> like `FullCircleWeb.Helpers` or a `~H` money component exists, use that instead.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/full_circle_web/live/cash_forecast_live_test.exs -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle_web/live/report_live/cash_forecast.ex lib/full_circle_web/router.ex test/full_circle_web/live/cash_forecast_live_test.exs
git commit -m "feat: cash forecast LiveView (form, weekly table, FD ladder)"
```

---

## Task 8: Print view + navigation menu link

**Files:**
- Create: `lib/full_circle_web/live/report_live/cash_forecast_print.ex`
- Modify: `lib/full_circle_web/router.ex` (print route)
- Modify: the reports menu template (find where report links are listed)

- [ ] **Step 1: Add the print route**

In `router.ex`, in the print/`print_root` scope (near line 357):

```elixir
      live("/print/cash_forecast", ReportLive.CashForecastPrint, :print)
```

- [ ] **Step 2: Create the print LiveView**

Model on an existing `*_print.ex` (e.g. `tbplbs` print path uses the `print_root`
layout). Create `lib/full_circle_web/live/report_live/cash_forecast_print.ex` that
reads the same params, calls `Reporting.cash_forecast/2`, and renders the ladder +
week table inside `{:print_root}` layout (no nav). Reuse the table markup from
Task 7 (extract a shared function component if convenient, else repeat).

```elixir
defmodule FullCircleWeb.ReportLive.CashForecastPrint do
  use FullCircleWeb, :live_view
  alias FullCircle.Reporting

  @impl true
  def mount(%{"s_date" => s_date} = params, _session, socket) do
    com = socket.assigns.current_company

    opts = %{
      start_date: Date.from_iso8601!(s_date),
      weeks_count: 13,
      buffer_weeks: String.to_integer(params["buffer_weeks"] || "2"),
      trailing_weeks: String.to_integer(params["trailing_weeks"] || "52"),
      account_ids: :all
    }

    {:ok,
     socket
     |> assign(:forecast, Reporting.cash_forecast(opts, com))
     |> assign(:page_title, "Cash Forecast"),
     layout: {FullCircleWeb.Layouts, :print_root}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="print-content">
      <h1 class="text-center font-bold">{gettext("Cash Forecast & Free Cash Flow")}</h1>
      <p class="text-center">{Date.to_iso8601(@forecast.start_date)} — 13 weeks</p>
      <!-- ladder + table markup, reuse from Task 7 -->
    </div>
    """
  end
end
```

> Note: confirm the exact print layout tuple other print views use (grep for
> `:print_root` in `lib/full_circle_web/live/report_live/*print*.ex`). Match it.

- [ ] **Step 3: Add the menu link**

Find the reports navigation (grep for `post_dated_cheque_listing` or `aging` in
`lib/full_circle_web/components/` / layout templates). Add a link to
`~p"/companies/#{@current_company.id}/cash_forecast"` labelled
`gettext("Cash Forecast")` alongside the other report links. Add a print link from
the report results page to `~p"/companies/#{@current_company.id}/print/cash_forecast?#{...params...}"`
opening in a new tab, mirroring the CSV/print links in other reports.

- [ ] **Step 4: Manual verification**

Run: `mix phx.server`, log in, open the Reports menu, click **Cash Forecast**,
run a query, click **Print**. Confirm the print view renders without nav and the
table/ladder appear. Confirm both light and dark themes look correct on the
report page.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/live/report_live/cash_forecast_print.ex lib/full_circle_web/router.ex lib/full_circle_web/components
git commit -m "feat: cash forecast print view + reports menu link"
```

---

## Task 9: Full suite + credo

- [ ] **Step 1: Run the whole test suite**

Run: `mix test`
Expected: all pass.

- [ ] **Step 2: Static analysis**

Run: `mix credo`
Expected: no new issues in the created files (fix any flagged).

- [ ] **Step 3: Commit any fixes**

```bash
git add -A
git commit -m "chore: credo cleanup for cash forecast"
```

---

## Self-Review Notes

- **Spec coverage:** liquid scope (T3), opening balance (T3), Stream A known
  commitments — posted future (T4), in-hand cheques + AR/AP due dates (T5),
  Stream B baseline (T4, refined to `contact_id IS NULL` rule — see spec update),
  weekly roll-forward & buffer (T1), FD ladder (T2), assembly (T6), LiveView +
  table + ladder + theming (T7), print + menu (T8), tests throughout, credo (T9).
- **Baseline rule refinement:** spec Stream B originally said "exclude doc_types";
  this plan uses the cleaner, equivalent `contact_id IS NULL` rule (customer/
  supplier settlements are contact-bearing and already modeled as known
  commitments). Spec section 2 (Stream B) updated to match.
- **Chart:** spec mentioned a line chart; v1 ships the table + ladder box (CSS
  styling). A closing-vs-buffer chart can be a fast-follow; left out to avoid a JS
  charting dependency (YAGNI for v1).
- **Confirm-before-run flags** are noted inline (fixture/login helper names, money
  formatter, `match_amount` column, print layout tuple) — the executor verifies
  each against the existing code it mirrors.
