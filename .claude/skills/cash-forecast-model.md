---
name: cash-forecast-model
description: Use when working on FullCircle.Reporting.CashForecast, the Cash Forecast report LiveView/print, the FD tenure ladder, or anything about forecast Base In/Base Out, run-rate, seasonality, buffer, or free cash — including any attempt to make the forecast "more precise" with AR/AP due dates.
---

# Cash Forecast Model

Rolling liquid-cash forecast in `lib/full_circle/reporting/cash_forecast.ex`,
LiveView at `report_live/cash_forecast.ex` (+ `_print`). "Trailing From" in the
UI is the `as_of` date: it anchors both the trailing window and the
actual/forecast split.

## Model semantics

- **Actual periods** (period end ≤ as_of): real total flow on liquid accounts
  (`Cash or Equivalent`, `Bank`), *no filters* — positives = Base In,
  negatives = Base Out.
- **Forecast periods**: run-rate backbone, two parts:
  - **Level** = 50/50 blend of the trailing-window rate and a 90-day rate
    (`blended_run_rate`; skipped when `trailing_days ≤ 90`). Tracks recent
    growth/decline instead of lagging by half a year.
  - **Shape** = seasonal factors from the same calendar windows one year
    earlier (`seasonal_shape` → `seasonal_factors/1`): normalized to mean 1
    (level preserved), shrunk 50% toward flat so a gap or spike last year
    can't zero out or dominate a period. No data a year back → flat.
- **Run-rate operating filter** (`operating_only`): contact-null rows only
  (bank-side legs), pure treasury transfers excluded (no contact + all legs
  asset-type), plus documents touching user-listed discretionary accounts
  (company setting `cash_forecast_exclude_accounts`).
- **Buffer** = projected *net* drain (out − in, floored at 0) over the next
  `buffer_periods`; free cash = closing − buffer. FD ladder = rolling minimum
  of free cash over the *forecast* periods only.

## The double-counting trap (learned the hard way)

Commit `fd0fc72` overlaid open AR/AP invoices and undeposited cheques by due
date **on top of** the unchanged run-rate — and was reverted (`406998b`). The
trailing run-rate average *already contains* the cash from invoices being
collected and suppliers paid; adding the outstanding book on top inflates both
Base In and Base Out, and piling overdue items into the first forecast period
creates a fake spike.

If a known-items overlay is ever attempted again, the run-rate must first be
**decomposed**: forecast = open items by due date + run-rate of only the
non-settlement ("other") flows, blending back to full run-rate once the
horizon outruns the AR/AP book. Never add open items to the full run-rate.

## Gotchas

- `"Post Dated Cheques"` is deliberately NOT in `@asset_types`: a cheque
  clearing (Dr Bank / Cr PDC) is real operating cash, not a treasury transfer.
- The Receivable/Payable columns are contact-balance levels (actual balances
  for elapsed periods, trailing trend projected forward) — informational only,
  they do NOT feed the closing/free-cash math.
- Tests asserting forecast amounts must mirror the implementation's Decimal
  operation order (e.g. `Decimal.mult(sum, Decimal.div(d(30), d(365)))`, not
  `sum × 30 ÷ 365`) or 28-digit rounding breaks `Decimal.equal?`; use a
  tolerance when summing shaped periods.
- Seasonality shift is fixed at 365 days regardless of `trailing_days`; shape
  windows for a test must not accidentally contain fixture transactions
  (horizon bounds minus 365 days).
