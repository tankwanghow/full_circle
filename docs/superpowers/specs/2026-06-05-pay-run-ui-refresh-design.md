# Pay Run UI Refresh — Two-Month Rich Rows

**Date:** 2026-06-05
**Status:** Approved design, pending spec review

## Problem

The Pay Run screen ([pay_run_live/index.ex](../../../lib/full_circle_web/live/pay_run_live/index.ex))
is the month-end hub for payroll, but it is hard to work from day-to-day:

- **Clunky month navigation** — two number `<input>` boxes + a magnifier button; no
  prev/next arrows or "jump to current month".
- **No money visible** — the grid shows slip numbers but never the pay amounts, so figures
  can't be sanity-checked without opening each slip.
- **No status at a glance** — nothing summarises how many slips are done vs pending, and there
  are no totals.
- **Pending work is invisible** — unprocessed salary notes and advances (entered but not yet
  pulled into a payslip) don't show, so the user can't tell who has pending items to process.

Root cause: the current grid is a Name column + **three** narrow month cells, each cramming
two links together. It's too narrow to carry status + money + pending-item signals.

## Goal

Redesign Pay Run as **two-month rich rows**: the selected pay month plus the previous month,
side by side, each month block showing status, net pay, and unprocessed notes/advances, with
a summary band and totals.

## Non-Goals (YAGNI)

- Batch generate / batch recalculate payslips — separate feature.
- Print-cap changes (current 15-slip checkbox print stays as-is).
- Department grouping — no `department` field exists on `Employee`.
- **No-punch warning** (zero attendance that month) — deferred; would need a
  `time_attendances` join. May be added later.

## Layout

```
Pay Run        ◀  May–Apr 2026  ▶   [ This month ]

 May 2026  ·  Done 42 · Pending 8 · Payroll 128,540.00
 Apr 2026  ·  Done 45 · Pending 5 · Payroll 130,200.00
──────────────────────────────────────────────────────────────
              │            May 2026          │            Apr 2026
 Name         │ Status NetPay  Notes  Adv  ▸ │ Status NetPay  Notes  Adv  ▸
──────────────────────────────────────────────────────────────
 Ali bin Abu  │ ●Done 2,450.00   –     –  PS │ ●Done 2,450.00   –     –  PS
 Siti Aminah  │ ○Pend    –     2/300 1/500 New │ ●Done 1,980.00   –     –  PS
 Lim (resgnd) │ — Resigned                   │ ●Done 2,100.00   –     –  PS
──────────────────────────────────────────────────────────────
 TOTAL        │       128,540.00             │       130,200.00
```

- **Header:** `◀` / `▶` shift the two-month window one month at a time. **This month** resets
  to current + previous month. Window state lives in URL query params (`base_month`,
  `base_year`), preserving the existing `push_navigate` + shareable-URL pattern.
- **Frozen Name column** on the left, then two month blocks.
- **Column order: latest month leftmost.** The window is `[base_month, base_month − 1]`, with
  `base_month` shown in the **left** block and the previous month on the right.
- **Summary band:** one line per month — Done count, Pending count, payroll total.
- **Totals row** at the bottom — payroll total per month.

## Per-Month Cell Behaviour

- **Done** (green ●): show `net_pay`, the slip-no as a link to the slip view, a **Card** link to
  the punch card, and the existing print checkbox.
- **Pending** (amber ○): show a **New Pay** link + **Card** link. If unprocessed items exist,
  show badges:
  - **Notes** `count/sum` (amber)
  - **Adv** `count/sum` (blue)

  Net pay is blank when pending.
- **Resigned, no activity** (muted `—`): for a `Resigned` employee, a month with **no payslip
  and no unprocessed items** shows a muted "Resigned" marker — **no New Pay link** — so a slip
  can't be created for a month they weren't working. (A resigned employee with a payslip or
  unprocessed items in that month still renders as Done / Pending normally.)
- "Unprocessed" = `salary_notes` (by `note_date`) or `advances` (by `slip_date`) dated in that
  pay month with `pay_slip_id IS NULL`.

## Data Layer — rewrite `pay_run_index/3`

In [pay_run.ex](../../../lib/full_circle/pay_run.ex). Change the window from 3 months (`-2..0`)
to 2 months (`-1..0`), with the base (latest) month leftmost.

**Employee selection (fixes the resigned-employee bug).** Today the query hard-filters
`e0.status = 'Active'`, so an employee who resigned in April is dropped from an Apr–May window
even though they worked (and were paid) in April. There is no resignation-date field
(status is only `Active` / `Resigned`), so selection must be data-driven. Include an employee
in the window when **either**:

- `status = 'Active'` (always shown, as today), **or**
- they have any payslip, any `salary_note` (by `note_date`), or any `advance` (by `slip_date`)
  in **either** window month.

Also return each employee's `status` so the component can render the muted "Resigned" marker
for empty cells.

For each employee × month, in addition to today's `slip_no` / `slip_id`, return:

| Field | Meaning |
|-------|---------|
| `net_pay` | For an existing slip: `Σ additions + Σ bonuses − Σ deductions − Σ advances` over rows linked by `pay_slip_id`. Matches `PaySlip.compute_fields/1`. Salary-note amount = `quantity * unit_price`; advance amount = `advances.amount`. |
| `unproc_note_count`, `unproc_note_sum` | `salary_notes` with `pay_slip_id IS NULL`, `note_date` in the month. |
| `unproc_adv_count`, `unproc_adv_sum` | `advances` with `pay_slip_id IS NULL`, `slip_date` in the month. |

Per-month aggregates (done count, pending count, payroll total) for the summary band and totals
row — computed in Elixir from the returned rows, or via a small companion query. Net pay must
exclude `Contribution` and `LeaveTaken` salary types (they don't affect take-home), consistent
with `compute_fields/1`.

## UI Files

- [pay_run_live/index.ex](../../../lib/full_circle_web/live/pay_run_live/index.ex):
  replace the number-box search form with window state (`base_month` / `base_year`) and
  `prev` / `next` / `this_month` events that `push_navigate` with query params. Render the
  summary band and totals row. Keep the existing checkbox-selection + print/pre-print links.
- [pay_run_live/index_component.ex](../../../lib/full_circle_web/live/pay_run_live/index_component.ex):
  render the two rich month blocks per employee, with status badges, net pay, unprocessed-item
  badges, and the Card / New Pay / slip links.

## Testing

- `pay_run_index/2` (context): an employee with an existing slip reports correct `net_pay`
  (additions + bonuses − deductions − advances; contributions/leaves excluded); an employee with
  unlinked salary notes / advances in the month reports correct unprocessed counts and sums;
  per-month done/pending counts and payroll totals are correct.
- **Resigned employee:** one who resigned in April but has an April payslip appears in an
  Apr–May window; their April cell renders Done with net pay, and their May cell renders the
  muted "Resigned" marker (no New Pay link). A resigned employee with unprocessed April items
  still appears and shows the badges.
- LiveView: prev/next/this-month navigation updates the two-month window and URL params; the
  base (latest) month renders in the left block; Done cells link to the slip and expose the
  print checkbox; Pending cells show New Pay + unprocessed badges; summary band and totals
  render expected numbers.
