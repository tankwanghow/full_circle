# Work shifts — Design

**Date:** 2026-09-12
**Status:** Draft
**App:** FullCircle (`full_circle`)
**Related:** `docs/superpowers/specs/2026-09-09-punch-ingest-logs-design.md`, `.claude/skills/punch-card-payroll.md`, `.claude/skills/qr-gate-punch.md`, `.claude/skills/finger-print-import.md`
**Does not change:** overtime rates or thresholds, `Employee.work_hours_per_day`, PaySlip money math, the QR gate API, the Android APK.

## Problem

Attendance is keyed to the **local calendar day**, everywhere. `rebuild_day_flags/3` buckets a day, the `emp_time_list` CTE buckets a day (`where ta.punch_time between ds.dd and ds.dd + interval '23:59:59'`), and `make_timeattend_list/2` renders a day. A *shift* is not a day, and the gap breaks two things.

**A shift that crosses midnight pays zero.** Measured on the real functions:

| Punches | Result |
|---|---|
| IN 5/5 08:00, OUT 6/5 17:00 | 5/5 = **0.0 h**, 6/5 = **0.0 h** |
| the same two punches inside one day | 33.0 h |
| Night 17:00→02:00 with a break, grouped by shift | **9.083 h** |
| the same four punches grouped by calendar day | 3.25 h + 0.0 h = **3.25 h** |

Each day ends up with an odd punch count, so `count_hours_work/1`'s `[[ti | _], [to | _]] = t` raises `MatchError`, is rescued, and returns `0.0`. Both days render `bg-red-300`, so it is visible — but the only repair available to a clerk is to falsify a punch time to drag it inside one calendar day.

**More than 3 IN/OUT pairs in a day silently truncates.** `rebuild_day_flags/3` wraps (`rem(i, 6)`, `punch_gate.ex:213`), so punch 7 is labelled `1_IN_1` again. `make_timeattend_list/2` (`helpers.ex:295`) keeps the **first** row per flag, so punches 7+ vanish. `PunchTimeComponent` destructures a fixed 6-element list and recomputes `wh` from it (`punch_time_component.ex:185-204`), and that truncated figure is merged back over the query's correct one on any edit (`punch_card.ex:677-700`).

The same ceiling bites the other two entry paths harder:

- **Fingerprint import** assigns `flag: nil` past index 6 (`finger_print_import.ex:99-110`). `finger_print_log_changeset` has `validate_required([:flag, ...])`, and `insert_time_attendence_from_log/2` never checks the insert result — so **punches 7+ are silently discarded and never stored**. Its dedupe also compares `ta.flag == ^entry.flag`, which is `flag = NULL` for those rows and never true.
- **Manual entry** hard-codes six options (`form_component.ex:195`), so a clerk cannot key a 7th punch even to correct a day.

## What the data says

23,902 punches, oldest 2025-01-31; 6,336 employee-days.

| Measure | Value |
|---|---|
| Punches by hour (local) | 07: 3,366 · 08: 3,179 · 09–11: 350 · 12: 9,524 · 13: 1,282 · 14–16: 476 · 17: 5,723 · 20–21: 2 |
| Outside 08:00–17:00 | 8,240 (34.5%) |
| Punches 22:00–06:59 | **0** |
| Daily span | avg 8.92 h · p95 9.53 · p99 9.68 · max 10.15 |
| Employee-days over 9 h span | 3,625 (57%) · over 10 h: 1 · over 11 h: 0 |
| Worked hours | avg 8.15 h · median 8.28 · max 9.93 |
| Employee-days over 7.5 h worked | 5,955 (94%) |
| Employee-days with more than 3 pairs | **0** |

Three conclusions drive the design:

1. **Neither bug is currently costing money.** No day has ever exceeded 3 pairs, and there are no night punches at all. This is enablement for a night shift that does not exist yet, not repair.
2. **The nominal window is not the real one.** People arrive at 07:00, not 08:00, and 34.5% of punches sit outside 08:00–17:00. A shift window must never constrain punch times.
3. **There is a nine-hour dead band (22:00–07:00) with zero punches.** Any instance boundary placed inside it reproduces today's grouping exactly, which is what makes a full backfill provably safe.

## Decisions taken during brainstorming

| Topic | Decision |
|---|---|
| Model | Declarative shift definitions, not inference from punch gaps. Inference needed a rest-gap threshold, a max-length backstop, a re-derivation window and a staleness story; stated data replaces all four. |
| `work_shifts` | `name`, `start_time`, `normal_hour`, `max_hour`. No `end_time` — it is derivable and nothing needs it stored. |
| Assignment | `employee_work_shifts`, dated. **No row (or none effective) ⇒ General.** |
| Seeding | One General row per company: `start_time` 08:00, `normal_hour` 9, `max_hour` 12. |
| Grouping | Persisted on the punch: `work_shift_id` + `work_shift_date`. Hours, pay date and anomalies are **derived on read** from that grouping, so nothing can go stale when a clerk edits a punch. |
| Instance boundary | A derived **cutover**, not a stored field. |
| Attribution | The calendar day the shift **ended**. |
| Window's job | Grouping only. A punch is never anomalous for falling outside the window. |
| Overtime | **Unchanged.** Still `worked − Employee.work_hours_per_day`. |
| Anomalies | Odd punch count in a closed instance, or span > `max_hour`. |
| On anomaly | Worked hours **blank** (nil, not 0.0) and the pay slip is **blocked** until resolved. |
| Pairs per shift | No ceiling. |
| Backfill | All 23,902 rows to General, `work_shift_date` = local date. |

## Non-goals

- Changing OT rates, thresholds, or any PaySlip money math.
- Rotating-roster patterns, shift swaps, or a scheduling UI. Assignment is a dated row a human creates.
- Lateness / early-leave reporting. The window deliberately does **not** judge punch times; if that is wanted later it needs its own tolerances and its own spec.
- Night-shift allowances or clock-time-based pay rates.
- Changing the QR gate API, the APK, or the ingest-log feature.
- Removing the `flag` column. It becomes a derived label; retiring it is a later cleanup.

## Data model

### `work_shifts`

`use FullCircle.Schema`.

| Column | Type | Notes |
|---|---|---|
| `id` | `binary_id` | |
| `company_id` | FK `companies` `on_delete: :delete_all` | required |
| `name` | `:string` | required, unique per company |
| `start_time` | `:time` | when the shift nominally begins |
| `normal_hour` | `:decimal` | nominal length. **Display only** — `start_time + normal_hour` is the human-readable end (08:00 + 9 = 17:00). Never an operand in pay. |
| `max_hour` | `:decimal` | tolerance. Drives the anomaly threshold **and** the cutover. |

`normal_hour` and `max_hour` are deliberately separate. Nine is the nominal length that makes 08:00 → 17:00 come out right, and **57% of existing employee-days already exceed a 9-hour span**. One field doing both jobs would either produce a meaningless end time or flag more than half of history.

> **`normal_hour` must never become the OT threshold.** OT today is `worked − work_hours_per_day` (7.5 by default), and 94% of employee-days exceed it. Switching OT to a 9-hour `normal_hour` would erase that OT on nearly every day — a large, silent pay cut. `work_hours_per_day` stays the OT threshold.

### `employee_work_shifts`

| Column | Type | Notes |
|---|---|---|
| `id` | `binary_id` | |
| `employee_id` | FK `employees` `on_delete: :delete_all` | required |
| `work_shift_id` | FK `work_shifts` `on_delete: :delete_all` | required |
| `effective_from` | `:date` | required |
| `effective_to` | `:date` | nullable = open-ended |

Dated so a re-run of May payroll still sees May's roster. Overlapping ranges for one employee are rejected in the changeset. **An employee with no effective row resolves to that company's General shift**, so the majority of staff need no row at all.

### `time_attendences`

| Change | Notes |
|---|---|
| add `work_shift_id` | FK `work_shifts` `on_delete: :nilify_all` |
| add `work_shift_date` | `:date` — the instance anchor (see below) |
| add `punch_kind` | `:string` — `IN` \| `OUT`, derived from position within the instance |
| **drop `shift_id`** | Dead `:string` column from `20230923032909_create_timeattend.exs:14`; never mapped in the schema, its index already dropped in `20260609000823` as "unused anywhere in lib/". |

Index: `(company_id, employee_id, work_shift_id, work_shift_date)` — the grouping key.

`flag` stays, written as a **derived label**: within an instance, pair *n* gets `n_IN_n` / `n_OUT_n`, with no ceiling at 3. It is no longer the pairing key and no longer needs to be required.

## Cutover and instance assignment

A shift instance is the half-open interval `[cutover(D), cutover(D+1))` in company-local time. Everything an employee punches inside one interval is one shift.

**Cutover is derived, never configured:**

```
cutover_time = (start_time + (24 + max_hour) / 2) mod 24
```

That is the midpoint between the latest possible end (`start_time + max_hour`) and the next day's `start_time`, so it sits in the deadest part of the off-period.

| Shift | start | max_hour | latest end | cutover | drift needed to mis-group |
|---|---|---|---|---|---|
| General | 08:00 | 12 | 20:00 | **02:00** | ~9 h past a 17:00 finish |
| Night | 17:00 | 12 | 05:00 | **11:00** | 9 h past a 02:00 finish |

General's 02:00 cutover falls inside the empty 22:00–07:00 band, so **grouping is bit-identical to today for every existing row** — which is what makes the backfill safe. It also means General stops splitting at midnight, so an employee held back to 00:30 on an emergency is paid properly, with no assignment and no configuration.

**Assigning a punch.** On insert or edit: resolve the employee's shift for the punch's local date (their effective `employee_work_shifts` row, else General); compute that shift's cutover; set `work_shift_id` and `work_shift_date` to the anchor date of the interval containing the punch, where the anchor is the local date of the interval's **start** boundary.

**Pay date.** The instance's hours land on the local date of its **last** punch — the day the shift ended, as decided. For General that is the same day as the anchor; for Night it is the anchor plus one. Deriving it from the last punch rather than from `crosses_midnight` means it self-corrects when a clerk edits a punch.

## Derivation on read

Persisted: which instance each punch belongs to. Derived at read time: pairing, hours, pay date, anomaly. Nothing derived is stored, so a clerk editing a punch cannot leave a stale total behind — the failure mode `rebuild_day_flags/3` has today.

One function is the single source of truth and is called by the punch card, the hours math and the pay-slip gate alike:

```
group punches by (employee_id, work_shift_id, work_shift_date)
  order by punch_time
  pair them positionally: 1st with 2nd, 3rd with 4th, ... (no ceiling)
  worked  = sum of pair durations
  pay_date = local date of the last punch
  anomaly  = :missing_punch  when the count is odd
           | :too_long       when (last - first) > max_hour
           | nil
  worked   = nil when anomaly != nil
```

`punch_kind` is `IN` on odd positions, `OUT` on even. `flag` is written as `n_IN_n` / `n_OUT_n` from the same positions.

**Re-derivation triggers:** inserting, editing or deleting a punch re-resolves that punch's instance (and, on a time edit, the instance it left). Changing or adding an `employee_work_shifts` row re-resolves that employee's punches over the affected date range. This replaces `rebuild_day_flags/3` entirely.

## Anomalies, hours and the payroll gate

`worked` is **nil**, never `0.0`, on an anomalous instance — a real zero (an employee who punched in and straight out) must stay distinguishable from "we don't know".

The five monthly totals in `punch_card.ex:875-921` (`total_day_worked`, `normal_pay_days`, `ot_day_worked`, `holiday_pay_days`, `sunday_pay_days`) all divide `x.wh` / `x.nh` / `x.ot` by `work_hours_per_day` and **would crash on nil**. Each needs an explicit rule: an anomalous instance contributes nothing, and the month is not payable while one exists.

`holiday_pay_days/2` needs more than a nil-guard: it calls `HR.punch_by_date/3` for the **previous and next calendar day** and checks `px.wh == 0.0 or nx.wh == 0.0` to decide whether a holiday is paid. Once instances are keyed by pay date, "the previous day" must mean *the previous instance for that employee*, not the previous calendar date — otherwise a night worker whose shifts land on consecutive pay dates with nothing in between reads as absent. Rewrite it against the instance sequence, and treat a neighbouring anomalous instance (`wh` nil) as unknown rather than as zero, since nil and 0.0 mean opposite things here.

**Pay slip generation is blocked** for an employee-month containing any anomalous instance, listing the offending dates. A clerk resolves by adding the missing punch or correcting a time; there is no "mark reviewed" escape hatch and no override.

The day renders in the existing `bg-red-300` anomaly style (`punch_time_component.ex:246-250`) rather than inventing a new visual language.

## UI

### The punch row

`make_timeattend_list/2` and `PunchTimeComponent`'s 6-element destructure go, but "render every punch" is not sufficient on its own — it would break two things.

**The blank slots are the add-a-punch affordance, not padding.** `make_timeattend_list/2` emits `_new_` placeholders, and typing into one fires `new_time_attendence/2` (`punch_time_component.ex:34-35, 80-92`). Rendering only real punches would leave a clerk nothing to type into — removing the single action the anomaly flow requires of them.

**The row grid budgets to exactly 100%.** It is one `flex flex-nowrap` row: six punch slots at `w-[11.666%]` = 70%, then HW / NH / OT at `w-[10%]` each (`punch_time_component.ex:273-324`). Eight punches is 93.3% inside a 70% budget, so `flex-nowrap` would shove the hours columns off the row.

The rule is therefore:

```
slots = max(6, punch_count + 1)     # never fewer slots than today
```

with the punch forms nested in their **own** `w-[70%] flex flex-wrap` wrapper, and HW / NH / OT left outside it at `w-[10%]` so wrapping can never displace them.

| Day | Today | After |
|---|---|---|
| 4 punches (the typical day) | 4 filled + 2 blank | **identical** |
| 6 punches | 6 filled | **identical** |
| 8 punches | 6 shown, 2 silently dropped | 8 filled + 1 blank, wraps to a second line |

**No day in the existing 20 months renders differently** — zero of 6,336 employee-days exceed 6 punches. The layout grows a second line only on days that are already red-flagged and already blocking the pay slip, where a taller row is a feature. Keeping a 6-slot minimum preserves the blank-slot add affordance for free, and a night shift is an ordinary 4-punch day that never wraps.

- Punch Card rows are keyed by **pay date**, so a night shift appears once, on the day it ended, with all its punches together.
- Punch IO keeps listing punches; the photo toggle, `.punch-photo` CSS and infinite scroll are untouched.
- **Work Shifts** maintenance page (admin/manager/supervisor): list, create, edit. Name, start time, normal hour, max hour, and a read-only derived line showing the nominal end and the cutover, so the arithmetic is never a mystery.
- **Assignment** is a small section on the employee form: the employee's dated shift rows, with "no row = General" stated in the UI.
- `form_component.ex:195`'s hard-coded flag dropdown is removed; flag is derived, not chosen.
- Gettext for all new labels (en + zh).

## Migration and rollout

1. Create `work_shifts`, `employee_work_shifts`; add the three `time_attendences` columns; drop the dead `shift_id`.
2. Seed one General row per company (08:00 / 9 / 12).
3. Backfill all 23,902 rows: `work_shift_id` = that company's General, `work_shift_date` = the punch's local date, `punch_kind` and `flag` from position within the instance.
4. Because General's cutover (02:00) sits in the empty band, step 3 reproduces today's grouping exactly. **Verification gate: recompute `wh` for every existing employee-day before and after, and assert they match to the cent.** If they do not, the backfill is wrong and must not ship.
5. Night shifts are created and assigned by hand afterwards. Nothing changes for anyone until someone does.

## Testing

**Grouping and cutover**
- General: 08:00 → 17:00 with a lunch pair groups into one instance, pay date = same day, hours identical to today's calendar-day result.
- Night 17:00 → 02:00 groups across midnight into one instance; pay date = the second day; hours = 9.083 for the drifted example above.
- The 33-hour case (IN 5/5 08:00, OUT 6/5 17:00) exceeds `max_hour` → `:too_long`, hours nil.
- Early-in / late-out drift does not change grouping: punch-out at 01:00, 02:00 and 04:00 all land in the same Night instance.
- A punch exactly on a cutover boundary lands in the later instance (half-open interval).
- `cutover_time` arithmetic: General 02:00, Night 11:00.

**Pairs**
- 4 pairs (8 punches) in one instance: all 8 stored, all 8 rendered, hours = sum of 4 intervals, no wraparound, flags run `1_IN_1` … `4_OUT_4`.
- A 4-punch day renders 6 slots (4 filled, 2 blank) — byte-identical markup to today.
- An 8-punch day renders 9 slots and wraps, and the HW / NH / OT columns stay on the first line at their existing widths.
- Typing into a blank slot still creates a punch, and clearing a filled slot still deletes one, at every slot count.
- Fingerprint import of 8 punches stores all 8 (today it silently discards 7 and 8).
- Re-importing the same fingerprint file creates no duplicates.

**Anomalies**
- Odd punch count → `:missing_punch`, hours nil, pay slip blocked with the date listed.
- Adding the missing punch clears it and unblocks the month.
- The five monthly totals skip anomalous instances instead of crashing on nil.
- `holiday_pay_days/2` reads the previous/next *instance*, not the previous/next calendar date, and treats a nil neighbour as unknown rather than as a zero-hour absence.
- A genuine 0-hour day (in and straight out) stays `0.0`, not nil, and does not block.

**Assignment**
- No `employee_work_shifts` row → General.
- A dated assignment applies only inside its range; a May re-run sees May's roster.
- Overlapping ranges for one employee are rejected.
- Deleting an assignment re-resolves affected punches back to General.

**Backfill**
- Every pre-existing employee-day's `wh` is identical before and after migration (the gate in step 4).
- `time_attendences.shift_id` is gone.

## Files (expected)

- `priv/repo/migrations/*_create_work_shifts.exs` — tables, columns, drop dead `shift_id`, seed General, backfill
- `lib/full_circle/hr/work_shift.ex`, `lib/full_circle/hr/employee_work_shift.ex`
- `lib/full_circle/hr.ex` — grouping function, hours/anomaly derivation, monthly totals, fingerprint import and its dedupe, `punch_query_by_company_id` CTE
- `lib/full_circle/punch_gate.ex` — replace `rebuild_day_flags/3` with instance re-resolution
- `lib/full_circle/HR/timeattend.ex` — new fields; `flag` no longer required
- `lib/full_circle_web/live/helpers.ex` — delete `make_timeattend_list/2`
- `lib/full_circle_web/live/time_attend_live/punch_time_component.ex` — render N punches, drop the 6-tuple destructure
- `lib/full_circle_web/live/time_attend_live/{punch_index_component,punch_card_component,punch_card,form_component}.ex`
- `lib/full_circle_web/live/work_shift_live/` — maintenance page
- `lib/full_circle_web/live/employee_live/form.ex` — assignment section
- `lib/full_circle/authorization.ex`, `lib/full_circle_web/router.ex`, dashboard link
- `priv/gettext/{en,zh}/LC_MESSAGES/default.po`
- `.claude/skills/punch-card-payroll.md`, `.claude/skills/finger-print-import.md`, `.claude/skills/qr-gate-punch.md`
- tests as above

## Key decisions

1. **Declarative shifts, not inferred ones** — inference needed a rest gap, a max length, a re-derivation window and a staleness story. Stated data replaces all four, and this floor has only a handful of shift workers, so the roster is near-zero maintenance.
2. **Persist the grouping, derive everything else** — `work_shift_id` + `work_shift_date` make the grouping queryable in SQL; hours, pay date and anomalies are computed on read so a clerk's edit can never leave a stale total. This is the specific trap `rebuild_day_flags/3` falls into today.
3. **The window groups, it never judges** — 34.5% of real punches fall outside 08:00–17:00. A window that constrained punch times would flag a third of history on day one.
4. **`normal_hour` and `max_hour` are different numbers** — 57% of employee-days exceed a 9-hour span, so the nominal length cannot also be the tolerance.
5. **OT is untouched** — 94% of employee-days book OT against `work_hours_per_day`. Moving that threshold would be a silent pay cut.
6. **Cutover is derived, not configured** — one less field to get wrong, and it lands General inside the empty 22:00–07:00 band, which is what makes the backfill provably safe.
7. **No assignment means General** — the majority of staff need no row, so the change is opt-in and rolls back by clearing assignments.
8. **Blank, not zero, and block the pay slip** — an unknown must not be payable, and must stay distinguishable from a real zero.

## Implementation order (for the later plan)

1. Tables, columns, drop dead `shift_id`, seed General, backfill + the before/after `wh` equality gate.
2. Grouping function, hours/anomaly derivation, `punch_kind` and derived `flag`; replace `rebuild_day_flags/3`; re-derivation on insert/edit/delete.
3. Remove the six-slot ceiling: `make_timeattend_list/2`, `PunchTimeComponent`, the two index components, the flag dropdown. Fix the fingerprint importer's silent discard and its dedupe.
4. Monthly totals skip anomalous instances; pay-slip gate with the offending dates.
5. Work Shifts maintenance page, employee assignment section, authorization, dashboard link, gettext.
6. Skill updates.
