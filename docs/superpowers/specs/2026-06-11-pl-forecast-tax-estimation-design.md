# P&L Forecast — Flat-Rate Tax Estimation

**Date:** 2026-06-11
**Status:** Approved (pending spec review)

## Goal

Add an estimated income-tax line to the Profit & Loss forecast report so the
forecast can show **net profit after tax**. Malaysia's resident-SME corporate
rates are tiered (15% / 17% / 24%) and the standard rate is a flat 24%, but per
the user's decision this feature uses a **single per-company flat rate** — simple,
and general enough for non-Malaysian companies that operate under a different
regime.

This is an **estimate**: the tax base is the forecast accounting net profit used
as a proxy for chargeable income. It does not perform a real tax computation
(no depreciation add-back, capital allowances, or non-deductible adjustments).

## Background

Reference (current, YA 2024–2026):
- Resident SME (paid-up capital ≤ RM2.5M and gross business income ≤ RM50M):
  first RM150,000 @ 15%, RM150,001–600,000 @ 17%, above @ 24%.
- All other companies: flat 24%.

Sources: LHDN (hasil.gov.my) and PwC Tax Summaries. The flat-rate design lets a
Malaysian SME approximate this with one blended rate, and lets any other company
use its own rate.

## Settings

One new key in `company.settings`: `pl_forecast_tax_rate`, a percent stored as a
number (e.g. `24`). Lives alongside the existing `pl_forecast_trailing` key.

- **Default when unset: `0`.** A `0` (or blank/invalid) rate **disables** the
  feature — the tax rows do not render. Tax estimation is therefore **opt-in**.
- A non-Malaysian company simply sets its own rate.

New functions in `FullCircle.Reporting.ProfitLossForecast`, mirroring the
existing trailing-days helpers:
- `tax_rate(com)` → `Decimal` percent (0 when unset/invalid).
- `save_tax_rate(com, value)` → persists into settings (clamped: non-negative,
  blank/invalid → 0).

The tax rate is saved through the **same** `save_settings` event/path that
already persists the trailing-days map (one settings write), so no new event is
introduced.

## Computation (`ProfitLossForecast.pl_forecast/2`)

1. Read `rate = tax_rate(com)`.
2. Compute the full-year tax base = `totals.net_profit` (already computed).
   `estimated_tax_total = max(net_profit, 0) × rate / 100` — a loss year ⇒ 0 tax.
3. Effective rate `eff = estimated_tax_total / net_profit` when `net_profit > 0`,
   else `0`. (With a flat rate this is just `rate%` on profitable years and `0`
   on loss years; the effective-rate form exists so the loss-floor is honoured
   while per-period figures still sum exactly to the annual total.)
4. Per period: `estimated_tax = period.net_profit × eff`,
   `net_profit_after_tax = period.net_profit − estimated_tax`.
5. Add to the result:
   - per-period: `estimated_tax`, `net_profit_after_tax` (in `build_periods`).
   - `totals.estimated_tax = estimated_tax_total`,
     `totals.net_profit_after_tax = net_profit − estimated_tax_total`.
   - `tax_rate` (echoed into the result map so the view can label the row and
     decide whether to render the rows).

When `rate == 0` the two values are still computed as `0` but the **view** hides
the rows (keyed off `tax_rate == 0`).

## Display changes (`profit_loss_forecast.ex` + print view)

In the `@rows` list:
- **Remove the `Cumulative (YTD)` row entirely** (and its now-dead plumbing:
  the `:cumulative` `total_cell/3` clause, and the `cumulative_net` field/
  `cum` accumulator in `build_periods`, `:cumulative` row-class/label-bg, and the
  `@sum_keys` entry if present). Net Profit becomes effectively the last
  pre-tax line.
- **Add two rows after `Net Profit`:**
  - `%{label: "Estimated Tax", key: :estimated_tax, kind: :subtotal}`
  - `%{label: "Net Profit After Tax", key: :net_profit_after_tax, kind: :subtotal}`
- The two tax rows render **only when `tax_rate > 0`** (filter `@rows` against the
  forecast's `tax_rate`, or pass a flag). The label may include the rate, e.g.
  `Estimated Tax (24%)`.

Both the interactive view (`profit_loss_forecast.ex`) and the print view
(`profit_loss_forecast_print.ex`) get the same row changes.

## Settings UI

Extend the existing **Trailing** settings modal (`settings_modal/1` in
`profit_loss_forecast.ex`): add a single labelled number input
`Estimated tax rate %` (`name="tax_rate"`, `min=0`, `step` allowing decimals)
pre-filled from `tax_rate(com)`. On `save_settings`, persist both the trailing
map and the tax rate, then re-run the forecast.

A short helper note under the field: tax is estimated as a flat percentage of
forecast net profit (a planning estimate, not a tax computation); `0` hides the
rows.

## Out of scope (YAGNI)

- Tiered/banded rates and per-country band tables.
- Depreciation add-back, capital allowances, non-deductible adjustments.
- Quarterly instalment (CP204) modelling.
- Any change to the cash forecast report.

## Testing

- `tax_rate/1` and `save_tax_rate/2`: unset → 0; blank/invalid → 0; valid number
  round-trips; negative clamped to 0.
- `pl_forecast/2`: with rate 0 → no tax keys affect output (tax totals 0);
  with rate 24 and a profitable year → `estimated_tax_total = net_profit × 0.24`,
  `net_profit_after_tax` correct, and per-period `estimated_tax` sums to the
  total; with an annual loss → tax 0 and after-tax == net profit.
