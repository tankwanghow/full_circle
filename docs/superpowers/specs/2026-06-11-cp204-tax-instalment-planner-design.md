# CP204 Tax Instalment Planner

**Date:** 2026-06-11
**Status:** Approved (pending spec review)

## Goal

Give a company a planning tool for Malaysia's CP204 monthly income-tax
instalments: take the P&L forecast's estimated annual tax, apply a user-entered
under-estimation tolerance to derive a safe minimum estimate, divide it into
monthly instalments over the financial year, let the user record tax already
paid, and re-spread the remaining balance over the remaining months whenever the
estimate is revised (at any month).

This is a **planning aid**, not the certified CP204 figure: the estimated annual
tax comes from the forecast's accounting-net-profit proxy (see
`2026-06-11-pl-forecast-tax-estimation-design.md`), not a filed tax computation.

## Background (Malaysia CP204 / CP204A)

- Estimated annual tax is paid in **equal monthly instalments**, due by the 15th
  of each month.
- The estimate may be revised (CP204A); we allow revision at **any month**
  (free-form), not just the statutory 6th/9th/11th.
- **Under-estimation penalty:** a 10% penalty applies on the portion where actual
  tax payable exceeds the estimate by more than 30%. So the penalty-free floor is
  `forecast_tax / 1.30`. The tolerance is user-entered (default 30) to future-proof
  and to support non-Malaysian companies.

Decisions taken during brainstorming:
- Placement: a **new planner sub-page** (forecast report stays read-only).
- Tolerance **reduces the estimate**: `suggested = forecast_tax / (1 + tolerance/100)`.
- Revision timing: **any month** (free-form).
- Tax paid: **manual entry with GL prefill** from a nominated account.
- **No revision history** kept (store only the current estimate + the FY month it
  was set/last revised).
- Schedule maps to the company's **financial-year months** (closing-day anchored).
- **CP204 print view deferred** (not in this scope).

## Data model

New context `FullCircle.Tax`. New table `tax_instalment_plans`, one row per
company + financial year (binary_id PK per `FullCircle.Schema`).

Schema `FullCircle.Tax.InstalmentPlan`:

| Field | Type | Notes |
|---|---|---|
| `company_id` | binary_id | FK Company; scoped |
| `fy_year` | integer | the FY this plan covers (the year the FY ends, matching `ProfitLossForecast` `fy_year` convention) |
| `tolerance_pct` | decimal | under-estimation tolerance; default 30, must be >= 0 |
| `tax_paid_account_id` | binary_id | nullable FK Account — GL account to prefill "tax paid" |
| `estimate` | decimal | current chosen CP204 estimate in force; default 0 |
| `estimate_month` | integer | FY month number (1..12) the current `estimate` was set/last revised; the "from" month for re-spreading the balance; default 1 |
| embeds_many `:paid_overrides` | — | manual overrides of GL-prefilled paid amounts |

Embedded `FullCircle.Tax.InstalmentPayment` (`embeds_many :paid_overrides`):

| Field | Type | Notes |
|---|---|---|
| `month_no` | integer | 1..12 within the FY |
| `amount` | decimal | overrides the GL-summed paid amount for that month |

Unique constraint on `(company_id, fy_year)`. Standard audit/timestamps as other
schemas use.

## Computation (`FullCircle.Tax`)

All amounts `Decimal`. The FY's 12 month boundaries are derived from the company's
`closing_month`/`closing_day` exactly as `ProfitLossForecast` does (reuse its
`prev_close/2` and month-stepping; expose a small shared helper if needed rather
than duplicating).

- `forecast_annual_tax(com, fy_year, as_of)` →
  `ProfitLossForecast.pl_forecast(%{fy_year: fy_year, granularity: :monthly, as_of: as_of}, com).totals.estimated_tax`.
- `suggested_estimate(forecast_tax, tolerance_pct)` →
  `forecast_tax / (1 + tolerance_pct/100)` (returns 0 when forecast_tax <= 0).
- `paid_by_month(plan, com)` → `%{month_no => Decimal}`: sum of GL postings to
  `tax_paid_account_id` falling in each FY month, then override with any
  `paid_overrides`. When no account is set, all GL amounts are 0 (overrides still
  apply).
- `schedule(plan, com, as_of)` → a list of 12 maps, one per FY month:
  `%{month_no, period_start, period_end, instalment_due, paid, balance}`. Given the
  "no revision history" decision, the whole schedule reflects only the **current**
  estimate re-spread from `estimate_month`:
  - `paid[m]` = the GL-or-override paid amount for month `m`.
  - `paid_to_date` = sum of `paid[m]` for `m < estimate_month` (what was already paid
    before the current estimate took effect).
  - `remaining_months` = `12 - estimate_month + 1`.
  - `forward_instalment` = `max(estimate - paid_to_date, 0) / remaining_months`.
  - `instalment_due[m]` = `forward_instalment` for `m >= estimate_month`, else `0`
    (no stored figure exists for an earlier, replaced estimate).
  - `balance[m]` = `estimate - (cumulative paid through month m)` — the outstanding
    estimate liability, decreasing as instalments are paid.
- `penalty_floor(forecast_tax, tolerance_pct)` → `forecast_tax / (1 + tolerance_pct/100)`
  — identical to `suggested_estimate/2`.
- `under_estimated?(estimate, forecast_tax, tolerance_pct)` →
  `estimate < suggested_estimate(forecast_tax, tolerance_pct)`.

### Revise / refresh action
"Revise" sets `estimate_month` to the current FY month (derived from `as_of`),
recomputes `forecast_annual_tax` and `suggested_estimate`, sets `estimate` to the
suggested value (user may edit before saving), and persists. The schedule then
re-spreads `(estimate - paid_to_date)` across months `estimate_month..12`.

## CRUD

Use the existing `StdInterface`/context conventions: `FullCircle.Tax.get_plan/2`
(by company+fy), `create_or_update_plan/3`, with authorization + audit logging as
other contexts. A plan is auto-initialised (tolerance 30, estimate 0,
estimate_month = current FY month) on first open for a FY.

## LiveView (`FullCircleWeb.TaxLive.InstalmentPlan`)

Route `/companies/:company_id/tax_instalment_plan`, admin-restricted in the report
menu (consistent with the recent "restrict some report menu links to admin"
change). Single page (no separate index/form — it's a per-FY singleton editor).

Layout:
- Controls: `fy_year` (number), `as_of` (date, default today), `tolerance_pct`
  (number, default 30), tax-paid account picker (existing `tri_autocomplete`
  account component).
- Summary: forecast annual tax (read-only, from the forecast), **suggested
  estimate**, **chosen estimate** (editable), an **under-estimation warning banner**
  when `under_estimated?` is true.
- Buttons: **Revise** (re-pull forecast + reset estimate to suggested + set
  estimate_month to current month), **Save**.
- 12-month schedule table: Month (FY period start→end), Instalment Due, Tax Paid
  (editable input, prefilled from GL), Balance. Editing a paid cell creates/updates
  a `paid_overrides` entry.
- Both light and dark theme styling (project requirement).

## Out of scope (YAGNI)

- CP204 / schedule print view (deferred).
- Revision history / audit trail of past estimates.
- Statutory 6th/9th/11th-month enforcement and the 11th-month penalty special case.
- Auto-posting instalment payments to the GL (the planner only reads paid amounts).
- Non-monthly instalment patterns.

## Testing

Context (`FullCircle.Tax`):
- `suggested_estimate/2`: `forecast 130000, tol 30 -> 100000`; `forecast 0 -> 0`;
  `tol 0 -> forecast`.
- `paid_by_month/2`: GL sums grouped into FY months; `paid_overrides` take
  precedence; no account → zeros + overrides only.
- `schedule/3`: instalment = `(estimate - paid_to_date)/remaining_months`;
  re-spread after estimate_month changes; balance runs correctly; estimate 0 → all
  zeros; paid >= estimate → forward instalment floored at 0.
- `under_estimated?/3` boundary at `forecast/(1+tol/100)`.
- DB: `create_or_update_plan/3` round-trip incl. `paid_overrides`; unique
  (company, fy_year).

LiveView:
- Page renders with auto-initialised plan (tolerance 30, suggested estimate shown).
- Revise resets chosen estimate to suggested and re-spreads the schedule.
- Editing a paid cell updates the balance and persists an override.
- Under-estimation banner appears when chosen estimate is set below the floor.
