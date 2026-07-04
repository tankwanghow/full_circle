# CP204A Revisions in the Profit & Loss Forecast Instalment Plan

Date: 2026-07-03
Status: approved design, pending implementation

## Goal

Model the real CP204 lifecycle in `FullCircleWeb.ReportLive.ProfitLossForecast`:
an **original estimate** filed for the year, plus optional **CP204A revisions**
in the 6th, 9th and 11th months of the basis period. The instalment table shows
the pre- and post-revision instalments (e.g. file 8,500 → 708.33/month, revise
to 5,000 at month 6 → 208.34/month), and the plan warns about the 85% floor
against the prior year's estimate.

Decisions made with the user:

1. Revisions are entered as a **revised annual estimate** per revision month
   (what Form CP204A actually files) — not as a monthly instalment amount.
2. The **Revise** button fills the **next available revision slot** at/after
   the report's as-of month with the forecast-suggested estimate; past month 11
   it flashes "no CP204A window left this year". It no longer overwrites
   `estimate`/`estimate_month`.
3. The **85% floor** rule (original estimate ≥ 85% of prior year's latest
   estimate) is a **warning banner only** — never blocking, since an LHDN
   appeal can override the floor.
4. Storage is a `revisions` map on the existing `InstalmentPlan` row
   (approach A) — no new table.

## Data model

Migration: add to `tax_instalment_plans`:

```elixir
add :revisions, :map, default: %{}, null: false
```

`FullCircle.Tax.InstalmentPlan`: new field `revisions :map, default: %{}`,
added to `cast`. Shape: `%{"6" => "5000", "9" => "...", "11" => "..."}` —
string month keys → revised annual estimate. Only keys 6/9/11 are honoured.
Existing fields keep their meaning: `estimate` is now explicitly the
**original** filed estimate; `estimate_month` keeps its mid-year-adoption
semantics (months before it have no scheduled instalment).

On save, `Tax.create_or_update_plan/3` sanitizes `"revisions"` exactly like
`"paid_overrides"`: LiveView `_unused_*` tracking keys and non-month keys are
stripped; blank values are dropped (blank = "not revised"; an explicit `0` is
kept — it is a valid revised estimate).

## Schedule math (`FullCircle.Tax`)

- `@revision_months [6, 9, 11]` with public `revision_months/0`; the LiveView
  badge helper delegates to it (single source of truth).
- `revisions_by_month/1` → `%{6 => Decimal, ...}`: tolerant parse
  (`Decimal.parse`), drops non-revision-month keys and blank/unparseable
  values.
- `latest_estimate/1` → the estimate in force at year end:
  `revisions[11] || revisions[9] || revisions[6] || estimate`.
- `build_schedule/5` gains an optional `revisions` argument (default `%{}`).
  It walks months 1..12 tracking the instalment and estimate **in force**:
  - Months `< estimate_month`: scheduled instalment 0 (unchanged).
  - From `estimate_month`: instalment = `(estimate − paid before
    estimate_month) ÷ remaining months`, floored at 0 (unchanged).
  - At each revision month `r` (only when `r ≥ estimate_month`), with revised
    estimate `E_r`: instalment from `r` onward =
    `max(E_r − payable_before_r, 0) ÷ (12 − r + 1)`, where **payable**
    accumulates, per month before `r`, the **higher of the scheduled
    instalment and the actual paid amount**. LHDN's CP204A formula deducts
    payments made — so payments exceeding the schedule reduce future dues
    (possibly to 0) — while the scheduled amount still counts for future
    months not yet paid when planning ahead. A later revision supersedes an
    earlier one. *(Amended 2026-07-04: originally scheduled-only, which
    wrongly kept charging instalments after actual payments already exceeded
    the revised estimate.)*
  - Display rule (existing): a month with `paid > 0` shows Instalment Due 0
    ("settled"); it counts toward payable at `max(scheduled, paid)`.
  - Row shape gains `estimate_in_force`; `balance(m) = estimate_in_force(m) −
    cumulative paid(m)`. With no revisions this equals today's
    `estimate − cum_paid` exactly (no behavior change).

Worked example (calendar FY, estimate 8,500 from month 1, revision `%{6 =>
5,000}`): months 1–5 due 708.33; payable before 6 = 3,541.67 (rounding via
Decimal, not floats); months 6–12 due = (5,000 − 3,541.67) ÷ 7 ≈ 208.33;
balance from month 6 tracks 5,000.

## LiveView changes (`profit_loss_forecast.ex`)

**Plan panel**: the "Chosen estimate" input is relabelled **"Original
estimate"** (`plan[estimate]`; still prefills the suggested estimate when the
saved value is 0). Three new inputs — **Revision @ 6th / 9th / 11th month**
(`plan[revisions][6|9|11]`), blank = not revised. All live inside `plan-form`,
so the existing `phx-change="plan_changed"` live recompute covers them with no
new wiring; `plan_changed`'s changeset-apply already casts the new map field.

**Analysis panels**: `chosen` (penalty banner, remedy comparison, headroom)
becomes `latest_estimate(plan)`, falling back to the suggested estimate when
≤ 0 (current fallback behavior preserved).

**Revise button** (`revise_plan`): finds the first `r ∈ [6, 9, 11]` with
`r ≥ current_fy_month(com, fy_year, as_of)`. If none, flash error ("No CP204A
window left this year."). Otherwise it merges `revisions[r] = suggested` into
the on-screen plan's attrs and saves via `create_or_update_plan` (audit-logged
as today). `estimate` and `estimate_month` are not touched.

**85% floor banner**: `handle_params` loads `get_plan(com, fy_year − 1)` and
assigns `prior_latest = latest_estimate(prev_plan)` (nil when no prior plan).
`tax_plan_section` shows an amber warning when `plan.estimate > 0` and
`plan.estimate < 0.85 × prior_latest`: states the prior-year latest estimate,
the floor amount, and the remedy (file ≥ floor then revise down at month 6, or
appeal to LHDN). Warning only.

**Table**: no structural change — dues now step at revision months naturally.
Footnote extended to say revisions are entered in the CP204A fields above.
All new UI must look right in light and dark themes.

## Out of scope

- No enforcement of the 85% floor or of revision-window deadlines.
- No per-revision audit trail beyond the existing plan save log.
- Print view unchanged (it has no instalment table).

## Testing

`test/full_circle/tax_test.exs` (pure, plus existing DB cases):

- `build_schedule/5`: single revision at 6 (worked example above, dues and
  balances); stacked revisions 6 + 9 (later supersedes); revision smaller than
  payable → remaining dues 0; revision at month < `estimate_month` ignored;
  no revisions → identical to today's output (regression).
- `revisions_by_month/1`: drops `_unused_*`/non-revision keys and blanks,
  keeps explicit 0.
- `latest_estimate/1`: precedence 11 → 9 → 6 → original.
- Changeset accepts `revisions`; save strips junk keys (mirrors existing
  paid_overrides tests).
- Floor: `Decimal` math for `0.85 × prior_latest` compared against estimate.
- Manual verification via tidewave `project_eval` with raw form params
  (including `_unused_*` keys), as done for the live-balance work.
