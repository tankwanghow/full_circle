---
name: punch-card-payroll
description: Use when working on FullCircle payroll prep in the Punch Card screen (time_attend_live/punch_card.ex), PaySlipOp (preview/pay/void/recal), pay_preps/PayPrep, salary-note/advance editing or linking, statutory (EPF/SOCSO/EIS/PCB) recompute, or "statutory didn't update / recurring not shown / can't edit linked note" bugs.
---

# Punch Card Payroll Prep

The Punch Card screen is the single per-employee/month payroll workspace: add salary notes &
advances → the statutory preview updates live → **Save PaySlip**. Below are the non-obvious rules
behind it (most caused real bugs).

## Where create / edit / void live (Punch Card vs PaySlip Form)

The Punch Card is the **only** create/edit path; the PaySlip Form (`pay_slip_live/form.ex`) is a
**view/print-only document** screen. There are no `:new`/`:recal` form routes — only
`/PaySlip/:id/view`. Don't re-add form-based create/edit (it would be a second editing path → the
`cal_func`/duplicate-statutory bugs below).

- **Save PaySlip** (Punch Card `pay` event) `push_navigate`s to the saved slip's `/PaySlip/:id/view`
  (extracts the slip from the multi result's `:create_pay_slip`/`:update_pay_slip` key).
- **Void** lives on the PaySlip Form, not the Punch Card (the Punch Card has no void button/handler).
  It calls `PaySlipOp.void_pay_slip/3`, then returns to wherever the user came from via
  `push_event(socket, "history_back", %{})` → `window.history.back()` (listener in `app.js`).
- The Form's `mount` rescues `Ecto.NoResultsError` and redirects to Pay Run — so Back/refresh into a
  just-voided slip URL never 500s.
- Pay Run's "New Pay"/"Card" links and the Form's "Edit in Punch Card" button all route to the Punch
  Card for that employee/month/year (note: if a slip already exists, its notes are linked & locked —
  void to unlock for re-edit).

## Auto-derived statutory preview (no manual "Calculate")

- `filter_punches/4` computes `@statutory_preview = PaySlipOp.preview(emp, m, y, com, user) |> Ecto.Changeset.apply_changes()` on **every load and after every note/advance change**, so it's never stale.
- **Save PaySlip** (`PaySlipOp.pay/6`) recomputes internally before persisting — saving is always correct regardless of what's displayed. There is no Calculate button and no stale/verify gating to track.
- `pay/6` requires a **payment account** (`pay_prep.funds_account_id`); that's the only Save guard.

## `cal_func` is VIRTUAL — re-merge it or recompute silently breaks

- `SalaryNote.cal_func` is `field(:cal_func, :string, virtual: true)` — **lost when a note is saved**.
- `salary_note_query/2` MUST `select_merge: %{cal_func: st.cal_func}` so loaded statutory notes carry their cal_func. Without it, `get_recal_pay_slip` keeps zero-cal_func statutory lines and `calculate_pay` skips them → changing income has **no effect** on saved statutory. (This was a real bug.)

## Statutory vs earnings split (in the Punch Card list)

- **Statutory = lines with a `cal_func`** (`epf_employer/epf_employee/socso_*/eis_*/pcb_employee`). They are recomputed by `calculate_pay`; shown read-only from the preview; zero ones omitted (deleted on Save).
- **Earnings/manual = no `cal_func`** (Daily/Monthly/OT/etc.). User-entered, survive `calculate_pay` unchanged, rendered as editable components.
- Reporting (EPF/SOCSO/EIS/PCB submission files in `HR.Statutory`) keys off a **separate** `SalaryType.statutory_code` field, not `cal_func`.

## Reading preview children: always `Map.get`

`get_recal_pay_slip` builds partial "fake structs" via `Map.merge(map, %{__struct__: SalaryNote})`
that are **missing keys** (e.g. `:descriptions`). Dot-access raises `KeyError`. Read children with
`Map.get/2`. It also dedupes generated lines by `salary_type_id` across additions/bonuses/deductions/
contributions/leaves, so the merged preview has no internal repeats.

## Save semantics (`process_notes`)

- New notes (`_id == ""`) with **amount 0 are NOT saved** (`Enum.reject(... String.to_float(a["amount"]) == 0)`). So zero recurring/template/statutory lines silently drop.
- Recurrings come from `get_uncount_recurrings/4` as `note_no "...new..."`, fixed amount, **no cal_func**, gated by `target_amount > sum(existing)`.

## Editing linked items is locked to the Punch Card

- `HR.update_salary_note` / `delete_salary_note` / `update_advance` take `from_punchcard? \\ false` and return `{:error, :on_payslip}` when the item has a `pay_slip_id` and the flag is false.
- The Punch Card modal components pass `from_punchcard?: true`; standalone Salary Note / Advance pages show a linked item **read-only** (a `@readonly` assign hides Save/Delete and sets inputs readonly) — edit it via the Punch Card.
- **Never** add this guard (or the `clear_pay_prep` auto-clear) to the `*_multi` builders — `PaySlipOp` uses those to link notes during Pay, so guarding them would break/clear on Pay.
- `SalaryNote` changeset also has `validate_has_pay_slip_no_cannot_change_after_days(7)` — a linked note locks 7 days after, everywhere (incl. Punch Card).

## Void (un-pay) a slip

`PaySlipOp.void_pay_slip/3`:
- **Deletes** the computed (cal_func) statutory notes + their `"SalaryNote"` GL — they're derived;
  unlinking them would leave them unprocessed and the auto-preview would regenerate them on top →
  **duplicate** EPF/SOCSO/EIS/PCB lines (real bug). Identify via join to `salary_types` where
  `cal_func` is set (cal_func is virtual, so query the salary type, not the note).
- **Unlinks** the rest (earnings, recurrings) and advances (`pay_slip_id → nil`, kept as unprocessed).
- Reverses the slip's `doc_type: "PaySlip"` GL, then deletes the slip.
Delete/unlink BEFORE the slip delete — do **not** rely on the schema `has_many on_delete: :delete_all`
cascade (it would delete the earning notes).

## Punch (attendance) editing — frozen once a payslip exists

The per-day time inputs (`PunchTimeComponent`, rendered via `PunchCardComponent`) create/update/delete
`time_attendences` inline on blur (`phx-change="punch_time_changed"`). Rules:
- **No fixed date window.** `TimeAttend.data_entry_changeset` has NO `days_before` cap (only
  `days_after: 0`, no future-dating) — historical/imported months are editable. (There used to be a
  `days_before: 40` cap that silently blocked editing imported attendance; removed.)
- **Frozen by payslip, not by age.** `HR.create_time_attendence_by_entry` / `update_time_attendence` /
  `delete_time_attendence_by_id` return `{:error, :on_payslip}` when `HR.pay_slip_exists_for_period?(emp_id, date, com)`
  is true (a PaySlip exists for that punch's employee + month/year). **Void the payslip to re-open editing.**
- The Punch Card computes `@payslip_locked?` (via `PaySlipOp.get_pay_slip_by_period/4`) in `filter_punches`
  and passes it down so the inputs render **read-only + greyed with a tooltip** when locked — belt to the
  backend guard's braces.
- The kiosk path (`create_time_attendence_by_punch`) is NOT guarded — live punches are for the current
  month, which has no payslip yet.

## Holiday pay days (`punch_card.ex` `holiday_pay_days/2` → `HR.punch_by_date/3`)

Only runs for a day with a holiday (`sholi_list`) where hours worked exceed half a workday — so it stays
dormant until an employee actually has **punches on a holiday** (which fingerprint import can produce).
Because it was dormant it shipped broken; when touching it: `holiday_pay_days` must be passed the **company
struct** (not `current_company.id`), and `punch_by_date(emp_id, date, com)` needs a **`Date`** (it coerces
via `Timex.to_date/1`) and filters on **`eidsh.id`** (the CTE has no `employee_id` column). It returns a
per-day map with `:wh`/`:nh`; the rule pays the holiday only if both adjacent days were worked (`wh > 0`).

## pay_preps / PayPrep (currently dormant gating)

- `pay_preps` is keyed by `(company, employee, pay_month, pay_year)` and holds `funds_account_id` +
  `verified` (+ audit). The payment account is live; the `verified` flag, `set_pay_prep_verified`,
  and the `clear_pay_prep` auto-clear hooks are **dormant** (UI dropped the "Correct" gate) but kept
  as the seed for a future **batch pay** ("all ready employees for month X").

## Conventions
- Multi-tenant: all record/account lookups must be company-scoped (`company_id`).
- UI colors must work in light AND dark themes (see app.css global dark remaps).
