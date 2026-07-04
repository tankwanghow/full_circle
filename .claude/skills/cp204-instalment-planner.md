---
name: cp204-instalment-planner
description: Use when working on FullCircle.Tax, InstalmentPlan, the CP204 tax plan section of FullCircleWeb.ReportLive.ProfitLossForecast, or answering LHDN CP204/CP204A estimate-revision questions — schedule math, revision windows, 85% floor, penalty checks.
---

# CP204 Instalment Planner

Corporate tax instalment planning inside the Profit & Loss Forecast report.
A planning aid, not a filed tax computation. Spec history (with dated
amendments): `docs/superpowers/specs/2026-07-03-cp204a-revisions-design.md`.

## LHDN rules as encoded

- **Initial CP204 floor (s.107C(3))**: original estimate must be ≥ 85% of the
  preceding YA's *latest* estimate. Warn-only amber banner; never blocks
  (an LHDN appeal can override). Floor base: manually entered
  `prior_year_estimate` wins when > 0, else prior-year plan's
  `latest_estimate`.
- **CP204A windows**: basis-period months **6, 9, 11** only (11th permanent
  from YA 2024, s.107C amendment). `Tax.revision_months/0` is the single
  source of truth.
- **Filing month is locked**: a revision filed in window `r` cannot change
  instalments 1..r. Re-spread from `r + 1`:
  `(E_r − payable through r) ÷ (12 − r)`, floored at 0.
- **Payable** = per-month `max(scheduled instalment, actual paid)` — LHDN
  deducts payments made, so overpaying kills later dues; scheduled covers
  future months when planning ahead.
- **Penalty (s.107C(10))**: only the *latest* revision counts. Safe while
  final estimate ≥ forecast tax ÷ (1 + tolerance/100), tolerance default 30.
- **Not modeled**: s.107C(9) 10% late-payment increase, 15th-of-month due
  dates (table rows are basis months 1–12), DGIR appeal workflow.

## Code map

| What | Where |
|---|---|
| Schedule math (pure) | `Tax.build_schedule/5` — rows carry `scheduled`, `instalment_due`, `paid`, `estimate_in_force`, `balance` |
| Plan → schedule | `Tax.schedule/2` |
| Revision parse | `Tax.revisions_by_month/1` — only 6/9/11; blank/junk/0 dropped (**0 = not revised**, a deliberate money-input decision) |
| Estimate in force | `Tax.latest_estimate/1` — precedence 11 → 9 → 6 → original |
| Suggest plan | `Tax.suggest_revisions/4` — park at earliest open window (= payable through it), clear middle; penalty floor at last window **only when useful** (in-force estimate below floor, or it cuts remaining dues — a no-op downward filing is skipped); window open iff `r ≥ cur_month`, `r ≥ estimate_month`, and **no tax paid for any month after r** |
| Schema | `Tax.InstalmentPlan`: `estimate` (original filed), `estimate_month`, `revisions` (string-keyed map), `paid_overrides`, `prior_year_estimate` |
| UI | `ReportLive.ProfitLossForecast.tax_plan_section` — Suggest button fills fields **without saving**; `plan_changed` live-previews via `changeset |> apply_changes` |
| Tests | `test/full_circle/tax_test.exs`, `test/full_circle_web/live/profit_loss_forecast_live_test.exs` |

## Gotchas

- **Display vs math**: a month with `paid > 0` *displays* Instalment Due 0
  ("settled") but its scheduled amount still counts toward payable.
- **`_unused_*` form keys**: LiveView `phx-change` params carry
  `_unused_<field>` tracking keys — never `String.to_integer` a form map key;
  parse with `to_month/1` / `Decimal.parse` and sanitize on save
  (`sanitize_overrides/1`, `sanitize_revisions/1`). See also
  [[liveview-computed-field-gotchas]].
- **Suggest is a trap if half-followed**: parking low at the first window
  REQUIRES filing the last suggested window, or the year ends penalty-exposed.
  The info flash says so — keep it.
- All money math is `Decimal`; all copy `gettext`; UI must pass light + dark.
