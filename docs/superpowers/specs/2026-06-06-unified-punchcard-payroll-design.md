# Unified PunchCard Payroll Screen — Design

**Date:** 2026-06-06
**Status:** Approved design, pending spec review

## Problem

Payroll for one employee/month is split across two screens. The **PunchCard** page
([punch_card.ex](../../../lib/full_circle_web/live/time_attend_live/punch_card.ex)) is where you
build the inputs — it shows the punch grid and computed totals (worked/OT/Normal/Sunday/Holiday
days, each clickable to spawn a pre-filled salary note), lets you add Salary Notes and Advances
via modals, and lists them. But to compute statutory deductions and create the payslip you must
**leave the page**: "+ Pay" navigates to the standalone PaySlip form
([pay_slip_live/form.ex](../../../lib/full_circle_web/live/pay_slip_live/form.ex)), which is where
`PaySlipOp.calculate_pay` runs the `cal_func` lines (EPF/SOCSO/EIS/PCB) and the slip is created.

The user wants one screen: build inputs → calculate statutory (preview) → confirm → pay, with
ongoing edits — and a per-employee "correct" confirmation that will later enable a **batch** run.

## Goal

Make the PunchCard screen the single end-to-end payroll workspace for an employee/month:

1. Add/edit Salary Notes and Advances (existing, via modals).
2. Select the **payment account** here.
3. **Calculate Statutory** — in-memory preview of EPF/SOCSO/EIS/PCB + **Net Pay**, no save.
4. **Recal Statutory** — same action after any change.
5. Mark **Correct** — a persisted per-employee-month confirmation flag.
6. **Pay** — create/update the actual PaySlip; enabled only when Correct.
7. Keep editing afterward; any change auto-clears Correct.

The "correct" flag + payment account persist in a new `pay_preps` table so a **future batch mode**
can sweep "all employees marked correct for month X" — batch itself is out of scope here.

## Non-Goals (YAGNI)

- **Batch mode** (bulk Calculate/Pay across confirmed employees) — future; this increment only
  populates the `pay_preps` table per employee.
- The standalone **PaySlip form is left unchanged** this increment; its fate is decided later.
- **Inline-editable** note/advance line fields — notes/advances are edited only through their
  existing modals.

## Architecture

### 1. `pay_preps` table + `FullCircle.HR.PayPrep`

One row per `company × employee × pay_month × pay_year`:

| Field | Purpose |
|-------|---------|
| `company_id`, `employee_id` | scope (belongs_to) |
| `pay_month` (int), `pay_year` (int) | the pay period |
| `funds_account_id` | the payment ("Funds From") account selected on the screen |
| `verified` (boolean, default false) | the "correct" flag |
| `verified_at` (utc_datetime, null), `verified_by_id` (user, null) | audit of confirmation |

- Unique index `(company_id, employee_id, pay_month, pay_year)`.
- Schema `FullCircle.HR.PayPrep` (`use FullCircle.Schema`) with changeset casting the above and
  validating the period + that `verified` true requires a `funds_account_id`.
- Context helpers in `HR`: `get_or_init_pay_prep(employee_id, month, year, company)` (returns the
  row or an unsaved default struct), `upsert_pay_prep/...` (set payment account / verified),
  `clear_pay_prep(company, employee_id, month, year)` (set `verified = false` if a row exists).

### 2. Auto-clear (context-level)

`HR.clear_pay_prep/4` is invoked from the functions that change inputs, deriving the period from
the changed row's date:

- `create_salary_note`, `update_salary_note`, `delete_salary_note` → month/year from `note_date`.
- `create_advance`, `update_advance` → month/year from `slip_date`. (There is no `delete_advance`
  today; if one is added, hook it too.)
- Changing the payment account on the screen also clears `verified`.

Because these context functions commit only on success, a change rejected by the existing
`validate_has_pay_slip_no_cannot_change_after_days(7)` guard leaves `verified` untouched.

### 3. Unified PunchCard screen additions

An action/summary bar on the existing page:

```
[Payment Account ▾ ............]  [Calculate Statutory]  ☐ Correct  [ Pay ]
EPF er/ee · SOCSO er/ee · EIS er/ee · PCB ...                Net Pay: 2,450.00
⚠ inputs changed since last pay — recalculate and re-pay      (shown when slip exists & !verified)
```

- **Payment Account** — `tributeAutoComplete` against the existing `fundsaccount` source (same as
  the PaySlip form); selection persists to `pay_prep.funds_account_id` and clears `verified`.
- **Calculate Statutory** — in memory, nothing saved:
  - no slip yet → `PaySlipOp.generate_new_changeset_for(emp, m, y, com, user) |> PaySlipOp.calculate_pay(emp)`
  - slip exists → `PaySlipOp.get_recal_pay_slip(slip.id, com, user) |> PaySlipOp.calculate_pay(emp)`
  Display the computed statutory lines and **Net Pay** (additions + bonuses − deductions −
  advances, from `PaySlip.compute_fields`). Held in a socket assign; recomputed each click.
- **☐ Correct** — toggles `pay_prep.verified`; the tick is enabled only when a payment account is
  set **and** statutory has been calculated this session. Sets `verified_at`/`verified_by_id`.
- **Pay** — enabled **only when `verified`**; runs `PaySlipOp.create_pay_slip` (no slip yet) or
  `PaySlipOp.update_pay_slip` (slip exists) with the previewed lines + payment account.

### 4. Lifecycle & the Paid+stale state

attendance → notes/advances (modals) + payment account → **Calculate Statutory** → **Correct** →
**Pay**. After paying, the notes/advances link to the slip (existing `create_pay_slip` behavior).

If a note/advance changes afterward **and the change is permitted** (a new unprocessed item, or a
linked item edited within the 7-day window):
1. auto-clear sets `verified = false`;
2. the existing payslip is **untouched** and now holds **stale** numbers;
3. the screen shows the **"inputs changed since last pay — recalculate and re-pay"** warning
   whenever a slip exists but `verified` is false;
4. reconcile: Calculate Statutory → re-tick Correct → **Pay**, which runs `update_pay_slip`
   (re-saves the slip and adjusts its GL transactions — existing recal behavior).

If the change is **blocked** by the 7-day lock, the changeset is rejected, nothing commits, and
`verified` is unchanged. The 7-day rule is the backstop that eventually freezes a paid period.

### 5. Reuse & isolation

- All compute/persist reuses existing `PaySlipOp` (`generate_new_changeset_for`, `calculate_pay`,
  `create_pay_slip`, `get_recal_pay_slip`, `update_pay_slip`) — no duplicated payroll logic.
- New code is isolated: the `PayPrep` schema/context (data + auto-clear) and the PunchCard
  LiveView additions (payment account, calculate/recal, correct, pay, stale warning).
- The PaySlip form, its routes, view, and print are untouched.

## Testing

- **`PayPrep`**: changeset validates the period and that `verified` requires `funds_account_id`;
  migration creates the table + unique index.
- **Auto-clear (context)**: creating/updating/deleting a salary note, and creating/updating an
  advance, each set `verified = false` on the matching `pay_prep`; deriving the period from
  `note_date` / `slip_date`. A note/advance change for a *different* month does not clear another
  month's prep. A 7-day-locked rejected edit leaves `verified` unchanged.
- **`get_or_init_pay_prep` / upsert**: returns existing row or default; persists payment account
  and verified with audit fields.
- **Pay-gating** (context level): the action used by Pay refuses to proceed unless the prep is
  verified (so the rule holds independent of the button's disabled state).
- **PunchCard LiveView wiring** (calculate/recal preview, correct toggle enablement, pay, stale
  warning): verified by `mix compile --warnings-as-errors` + manual check, consistent with the
  codebase's lack of company-scoped LiveView tests.

## Open Questions

None.
