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
  - **Level** = long trailing-window rate × `(1 + yoy_ratio)/2`, where
    `yoy_ratio` = last-90-days operating flow ÷ same 90 days one year earlier
    (`trend_level`/`leveled`; ratio clamped to [0.25, 4]). The ratio compares
    like calendar windows, so it is seasonality-free — a naive "blend with the
    recent 90-day rate" reads a seasonally strong quarter as growth (backtested:
    that pushed the level the WRONG direction). Falls back to the naive 50/50
    blend when the prior-year window is empty; skipped when `trailing_days ≤ 90`.
  - **Shape** = seasonal factors from the same calendar windows one year
    earlier (`seasonal_shape` → `seasonal_factors/1`): normalized to mean 1
    (level preserved), shrunk 50% toward flat so a gap or spike last year
    can't zero out or dominate a period. No data a year back → flat.
    (A multi-year equal-weighted shape was tried and reverted by user choice —
    ask before reintroducing.)
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

## Backtesting the model

Run the report blind (as_of = start_date) and compare against a later as_of
where those periods are actual. But compare like-for-like: actual Base In/Out
are UNFILTERED (they include treasury transfers and excluded discretionary
docs), while forecast rows are operating-only. A raw comparison wildly
overstates error — e.g. one real January showed 12.76M "Base In" of which
8.6M was FD redemptions, and 13.6M "Base Out" of which 7.0M was dividends on
an excluded account. Strip both (contact-null + treasury filter + exclude
list) to get the model's true target. Also: forecast-period closings are on
this operating basis — real closings additionally move with treasury and
discretionary flows, by design.

## Gotchas

- `"Post Dated Cheques"` is deliberately NOT in `@asset_types`: a cheque
  clearing (Dr Bank / Cr PDC) is real operating cash, not a treasury transfer.
- The Receivable/Payable columns are contact-balance levels (actual balances
  for elapsed periods, trailing trend projected forward) — informational only,
  they do NOT feed the closing/free-cash math.
- Every period also carries a display split (`oper_/treas_/disc_ in/out`):
  actual rows partition their total Base In/Out into operating + treasury +
  discretionary (excluded-account docs), shown as the small "op · tr · di"
  line under actual Base In/Out; forecast rows carry zeros. Display-only —
  the roll-forward uses `baseline_in/out`. (A "Discr. Out (LY)" memo column
  for forecast rows was tried and reverted by user choice.)
- Tests asserting forecast amounts must mirror the implementation's Decimal
  operation order (e.g. `Decimal.mult(sum, Decimal.div(d(30), d(365)))`, not
  `sum × 30 ÷ 365`) or 28-digit rounding breaks `Decimal.equal?`; use a
  tolerance when summing shaped periods.
- Seasonality shift is fixed at 365 days regardless of `trailing_days`; shape
  windows for a test must not accidentally contain fixture transactions
  (horizon bounds minus 365 days).
