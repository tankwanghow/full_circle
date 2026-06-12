# CP204 Remedy Analysis — Design Spec

**Date:** 2026-06-12  
**Status:** Approved for implementation

## Goal

Extend the embedded CP204 planner on the Profit & Loss Forecast page with a
**Remedy Analysis** panel that compares planning options when the chosen CP204
estimate diverges from the forecast tax — for **any financial year** (`fy_year`
+ `as_of`), not a hard-coded year.

Two divergence modes:

| Mode | Condition | Problem | Remedies compared |
|------|-----------|---------|-------------------|
| **Under-estimated** | `forecast_tax > estimate × (1 + tolerance%)` | S.107C 10% penalty on tax excess | Pay penalty **vs** backdated director fee |
| **Over-estimated** | `forecast_tax < estimate` (and not under-estimated) | Excess instalments → refund; cash tied up | Accept refund **vs** defer director remuneration **vs** revise estimate down |

This is a **planning aid** (same disclaimer tier as the existing penalty banner).
It does not file CP204, compute audited tax, or model EPF/reliefs.

## Estimate position (three states)

Given `forecast_tax`, `chosen_estimate`, `tolerance_pct`:

```
suggested_floor = forecast_tax / (1 + tolerance/100)     # existing suggested_estimate/2
penalty_ceiling = chosen_estimate × (1 + tolerance/100)

:under       chosen < suggested_floor
             AND forecast_tax > penalty_ceiling

:over        forecast_tax < chosen_estimate
             AND NOT :under

:within      otherwise (no penalty, no material overpayment vs estimate)
```

`:within` shows the existing green banner only; remedy panel hidden.

## Under-estimation formulas

```
excess_tax          = max(forecast_tax − penalty_ceiling, 0)
penalty             = excess_tax × 10%
director_fee_needed = excess_tax / (corp_rate / 100)

Scenario A (pay penalty):
  company_tax  = forecast_tax
  penalty      = penalty
  personal_tax = 0
  total        = forecast_tax + penalty

Scenario B (director fee — minimum to clear penalty):
  company_tax  = penalty_ceiling          # = forecast_tax − excess_tax
  penalty      = 0
  personal_tax = Σ personal_tax(existing_income_i + fee_share_i)
  total        = company_tax + personal_tax

breakeven_effective_rate = corp_rate + (penalty / director_fee_needed) × 100
```

Director fee **reduces** profit → only valid under-estimation remedy.

## Over-estimation formulas

```
overpayment_tax = chosen_estimate − forecast_tax          # > 0 when :over
instalments_paid = sum(paid_overrides)                  # from plan; 0 if empty
expected_refund  = max(instalments_paid − forecast_tax, 0)
                  # when paid tracks estimate, ≈ overpayment_tax

# Room to raise tax before under-estimation penalty (if estimate stays filed):
headroom_tax     = max(penalty_ceiling − forecast_tax, 0)
deferral_needed  = overpayment_tax / (corp_rate / 100)   # profit to retain by deferring fees

Scenario A (accept refund):
  company_tax  = forecast_tax
  refund       = expected_refund
  personal_tax = 0
  group_cost   = forecast_tax                    # refund is cash return, not extra tax

Scenario B (defer remuneration — align tax to estimate):
  company_tax  = chosen_estimate               # tax rises by overpayment_tax
  refund       = max(instalments_paid − chosen_estimate, 0)
  personal_tax = 0                             # fees paid next YA
  group_cost   = chosen_estimate               # same ultimate tax, different timing

Scenario C (revise estimate down — mid-year / planning):
  revised_estimate = forecast_tax              # or suggested_floor for safety margin
  future_instalment_saving = chosen_estimate − revised_estimate
  # informational only; links to existing Revise button
```

Deferring fees **increases** profit → valid over-estimation remedy.  
Paying additional director fees when over-estimated **worsens** overpayment; show
as a warning row, not a recommended remedy.

## Director scenario inputs (per FY plan)

Stored on `tax_instalment_plans` (same row as CP204 estimate):

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `remedy_director_count` | integer | 1 | Split fee/deferral amount |
| `remedy_existing_income` | decimal | 0 | Per-director YA income before remedy |

Optional later: JSON `remedy_directors` for unequal splits.

Optional GL prefill (YAGNI for v1): company setting
`pl_forecast_director_accounts` → sum FY director expense accounts ÷ count.

## Module layout

```
lib/full_circle/tax/personal_income.ex   # MY resident brackets, pure Decimal
lib/full_circle/tax/remedy.ex            # penalty_analysis, over_analysis, comparisons
lib/full_circle/tax.ex                   # thin delegates + existing CP204 functions
```

`Remedy.estimate_position/3` returns `:under | :over | :within` plus the shared
intermediate values (ceiling, floor, excess, overpayment).

## UI

Inside `tax_plan_section/1` in `profit_loss_forecast.ex`:

- **Under banner** (existing) — unchanged text.
- **Remedy panel** — shown when position is `:under` or `:over`:
  - Inputs: director count, existing income/director (saved with plan).
  - Side-by-side comparison table (scenario columns vary by position).
  - Recommendation line (`:pay_penalty`, `:director_fee`, `:accept_refund`,
    `:defer_remuneration`, `:marginal` if |delta| < RM 5,000).
  - `breakeven_effective_rate` (under) or `deferral_needed` + `expected_refund` (over).
  - `extra_cash_movement` (under: fee payout − tax saving − penalty saved).
  - Disclaimer footer.

**Not** added to print view.

## Out of scope (v1)

- EPF / SOCSO / PCB / personal reliefs
- Multi-director unequal split JSON
- GL auto-prefill of director income
- Opportunity-cost interest on overpayment
- Statutory 6th/9th/11th-month CP204A rules
- Auto-posting journal entries for director fees

## Testing

Pure tests in `test/full_circle/tax/remedy_test.exs` with Kim Poh FY2025 numbers as
one fixture. LiveView tests in `profit_loss_forecast_live_test.exs` for panel
visibility by position and fy_year switching.