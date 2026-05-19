Create a new report (data query + LiveView + optional print view): $ARGUMENTS

Provide the report name, purpose, input parameters (date ranges, IDs, flags), output columns, and whether it needs drill-down or print.

## When to use this vs other skills

- This skill is for **read-only reporting** — aggregations, listings, financial statements, operational summaries.
- For full CRUD with a form, use `new-simple-entity` or `new-document-entity` instead.

## Decision: where the query lives

Pick one of three patterns based on complexity:

| Pattern | Use when | Example |
|---------|----------|---------|
| **Ecto composition** in `FullCircle.Reporting` | Filters compose dynamically (terms, dates, flags), joins are straightforward | `post_dated_cheques/4`, `debtors_balance/3` |
| **Parameterized raw SQL** via `exec_query_map/3` in `FullCircle.Reporting` | Heavy CTEs, window functions, recursive logic, or PG-specific features. **Always** use `$1, $2, ...` placeholders — never string-interpolate `com.id` or dates | `contact_aging_query/4`, `contact_bucket_transactions/5` |
| **Query helper module** under `lib/full_circle/reporting/<name>.ex` | Report has its own config (buckets, presets, parsing) — keep the helper separate from the query | `FullCircle.Reporting.AgingBuckets` |

**Hard rule**: every query MUST scope by `company_id` (passed as `com.id` or `com_id`). This is the multi-tenant boundary — a missing scope is a data leak. Use `dump_uuid!/1` when binding company/contact IDs into raw SQL.

**Repo choice**: heavy/long-running reports use `FullCircle.QueryRepo` (read-only DB user). Most reports use `FullCircle.Repo` via `exec_query_map(sql, params, FullCircle.Repo)`.

## Steps

### 1. Add the query function(s) to `lib/full_circle/reporting.ex`

Signature convention: `report_name(filter1, filter2, ..., com)` returning a list of maps with stringly-stable keys (the LiveView and print view both consume them).

```elixir
def my_report(edate, some_flag, com) do
  edate = to_date!(edate)
  com_id_bin = dump_uuid!(com.id)

  sql = """
    select ...
      from ...
     where company_id = $1
       and doc_date <= $2
       ...
  """

  exec_query_map(sql, [com_id_bin, edate], FullCircle.Repo)
end
```

For Ecto-composed reports, follow the `post_dated_cheques/4` pattern: build a base subquery, then apply conditional `from ... where:` rebinds for each non-empty filter.

If the report has tunable buckets/presets/cutoffs, put parsing & defaults in a small helper module:

```elixir
# lib/full_circle/reporting/<name>_buckets.ex
defmodule FullCircle.Reporting.MyReportBuckets do
  def presets, do: %{"default" => [30, 60, 90, 120], ...}
  def parse_cutoffs(params), do: ...
  def preset_for(cutoffs), do: ...
end
```

### 2. Create the LiveView

Location: `lib/full_circle_web/live/report_live/<name>.ex`

Skeleton (mirrors `FullCircleWeb.ReportLive.Aging`):

```elixir
defmodule FullCircleWeb.ReportLive.MyReport do
  use FullCircleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "My Report")
     |> assign(selected_ids: MapSet.new())
     |> assign(sort_by: :name)
     |> assign(sort_dir: :asc)
     |> assign(drill: nil)}  # nil = list view, %{...} = drill-down view
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = parse_search(params["search"] || %{})
    {:noreply,
     socket
     |> assign(search: search)
     |> filter_report(search)}
  end

  defp filter_report(socket, %{t_date: t_date} = _search) do
    rows = FullCircle.Reporting.my_report(t_date, socket.assigns.current_company)
    stream(socket, :rows, rows, reset: true)
  end
end
```

Conventions to follow:
- Search params live in a single `:search` assign and are reflected in the URL via `push_patch`
- List rendering uses `stream/3` for large result sets
- Sort state is `:sort_by` + `:sort_dir`; click headers to toggle
- For drill-down, assign `:drill` to the row context and conditionally render a detail component (see aging report)
- Selected row IDs go in a `MapSet` named `:selected_ids` so "Print selected" is cheap

### 3. Add the route

In `lib/full_circle_web/router.ex`, under `:require_authenticated_user_n_active_company`:

```elixir
live("/<companies>/:company_id/reports/my_report", ReportLive.MyReport)
```

If the report should be reachable from the menu, add a link in the relevant layout/navigation component (search existing menus for "Aging" or "Trial Balance" as reference).

### 4. Print view (optional)

Only add if users need a paper/PDF version. Two files:

- `lib/full_circle_web/live/report_live/<name>_print.ex` — uses `print_root` layout, accepts the same filters via URL params, calls the same `Reporting.<name>/n` function, renders print-only HTML.
- Add route: `live("/<companies>/:company_id/reports/my_report/print", ReportLive.MyReportPrint)`
- Support a `pre_print=true` URL param if pre-printed letterhead is a thing for this report (data-only rendering).

Reference: `FullCircleWeb.ReportLive.HouseFeedPrint`, `StatementPrint`.

### 5. Authorization

Most reports need read access. In `lib/full_circle/authorization.ex`:

```elixir
def can?(user, :view_my_report, company),
  do: allow_roles(~w(admin manager supervisor auditor clerk), company, user)
```

Then guard mount with `Authorization.can?/3` (look at any existing report LiveView for the pattern).

### 6. Tests

- Context test in `test/full_circle/reporting_test.exs` — assert the query returns expected shape, scopes by company, handles empty filters.
- **Tenant isolation test** is mandatory: seed two companies, insert rows for both, call the report for company A, assert no company B rows leak.
- LiveView smoke test in `test/full_circle_web/live/report_live/<name>_test.exs` — mount with a logged-in user, assert page renders, filters update results.

### 7. Run

```bash
mise exec -- mix format
mise exec -- mix test test/full_circle/reporting_test.exs
mise exec -- mix phx.server
```

## Checklist before merging

- [ ] Every query in `Reporting` scopes by `company_id`
- [ ] Raw SQL uses `$1, $2, ...` placeholders — no string interpolation of user/tenant data
- [ ] UUID bindings go through `dump_uuid!/1`
- [ ] Dates parsed through `to_date!/1`
- [ ] Bucket/cutoff parsing has explicit validation (see `to_cutoffs!/1`)
- [ ] Tenant isolation test present
- [ ] Authorization check in LiveView `mount`
- [ ] Heavy reports route through `FullCircle.QueryRepo`

## Reference files

- Context module: `lib/full_circle/reporting.ex`
- Bucket helper pattern: `lib/full_circle/reporting/aging_buckets.ex`
- LiveView pattern: `lib/full_circle_web/live/report_live/aging.ex`
- Print pattern: `lib/full_circle_web/live/report_live/statement_print.ex`
- Drill-down pattern: aging report's `:drill` assign + `contact_bucket_transactions/5`
- Raw-SQL CTE pattern: `Reporting.contact_aging_query/4`
