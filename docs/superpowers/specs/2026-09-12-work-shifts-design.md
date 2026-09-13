# Work shifts — Design

**Date:** 2026-09-12
**Status:** Draft
**App:** FullCircle (`full_circle`)
**Related:** `docs/superpowers/specs/2026-09-09-punch-ingest-logs-design.md`, `.claude/skills/punch-card-payroll.md`, `.claude/skills/qr-gate-punch.md`, `.claude/skills/finger-print-import.md`
**Does not change:** overtime rates or thresholds, `Employee.work_hours_per_day`, PaySlip money math, the QR gate API, the Android APK.

## Problem

Attendance is keyed to the **local calendar day**, everywhere. `rebuild_day_flags/3` buckets a day, the `emp_time_list` CTE buckets a day (`where ta.punch_time between ds.dd and (ds.dd + interval '23 hours 59 minutes 59 seconds')`), and `make_timeattend_list/2` renders a day. A *shift* is not a day, and the gap breaks two things.

**A shift that crosses midnight pays zero.** Measured on the real functions:

| Punches | Result |
|---|---|
| IN 5/5 08:00, OUT 6/5 17:00 | 5/5 = **0.0 h**, 6/5 = **0.0 h** |
| the same two punches inside one day | 33.0 h |
| Night 17:00→02:00 with a break, grouped by shift | **9.083 h** |
| the same four punches grouped by calendar day | 3.25 h + 0.0 h = **3.25 h** |

Each day ends up with an odd punch count, so `count_hours_work/1`'s `[[ti | _], [to | _]] = t` raises `MatchError`, is rescued, and returns `0.0`. Both days render `bg-red-300`, so it is visible — but the only repair available is to falsify a punch time to drag it inside one calendar day.

**More than 3 IN/OUT pairs in a day silently truncates.** `rebuild_day_flags/3` wraps (`rem(i, 6)`, `punch_gate.ex:213`), so punch 7 is labelled `1_IN_1` again. `make_timeattend_list/2` (`helpers.ex:295`) keeps the **first** row per flag, so punches 7+ vanish. `PunchTimeComponent` destructures a fixed 6-element list and recomputes `wh` from it (`punch_time_component.ex:185-204`), and that truncated figure is merged back over the query's correct one on any edit (`punch_card.ex:677-700`).

The same ceiling bites the other two entry paths harder:

- **Fingerprint import** assigns `flag: nil` past index 6 (`finger_print_import.ex:99-110`). `finger_print_log_changeset` has `validate_required([:flag, ...])`, and `insert_time_attendence_from_log/2` never checks the insert result — so **punches 7+ are silently discarded and never stored**. Its dedupe also compares `ta.flag == ^entry.flag`, which is `flag = NULL` for those rows and never true.
- **Manual entry** hard-codes six options (`form_component.ex:195`), so a clerk cannot key a 7th punch even to correct a day.

## What the data says

23,902 punches, oldest 2025-01-31; **6,619 employee-days** (measured 2026-09-12 on a restore of production, punches through 2026-09-09).

| Measure | Value |
|---|---|
| Punches by hour (local) | 07: 3,366 · 08: 3,179 · 09–11: 350 · 12: 9,524 · 13: 1,282 · 14–16: 476 · 17: 5,723 · 20–21: 2 |
| Outside 08:00–17:00 | 8,240 (34.5%) |
| Punches 22:00–06:59 | **0** |
| Daily span | avg 8.92 h · p95 9.53 · p99 9.68 · max 10.15 |
| Employee-days over 9 h span | 3,625 (57%) · over 10 h: 1 · over 11 h: 0 |
| Worked hours | avg 8.15 h · median 8.28 · max 9.93 |
| Employee-days over 7.5 h worked | 5,955 (94%) |
| Punches per employee-day | 1: **283** · 2: 845 · 3: **40** · 4: 5,446 · 5: **5** · 6+: 0 |
| Employee-days with an **odd** punch count | **328** (5.0%) |
| Employee-days with more than 3 pairs | **0** |

> An earlier draft of this table said 6,336 employee-days and drew the conclusion that nothing in history is anomalous. That count silently excluded every single-punch day — exactly 283 of them — which is the bulk of the odd-count population. The corrected figures are above, and they change the rollout, not the design.

Four conclusions drive the design:

1. **The pairing bugs are not currently costing money, and neither is the anomaly rule.** No day has ever exceeded 3 pairs and there are no night punches, so the grouping change is enablement for a night shift that does not exist yet. The anomaly rule touches far more: 328 existing employee-days are odd today, spread over **68 employee-months**, 61 of which are already paid. Those days already render red and already contribute `0.0`; blanking their hours changes the cell from `0.00` to empty and nothing else. Blocking them would have been the expensive part, and this design does not block — see “Why nothing is blocked”.
2. **The nominal window is not the real one.** People arrive at 07:00, not 08:00, and 34.5% of punches sit outside 08:00–17:00. A shift window must never constrain punch times.
3. **There is a nine-hour dead band (22:00–07:00) with zero punches.** Any instance boundary placed inside it reproduces today's grouping exactly, which is what makes a full backfill provably safe.
4. **An odd day is often not an error at all.** Three employees account for 218 of the 283 single-punch days and punch once on *every* day they work — Rajeswari 115 of 115 at ~08:16 (Monthly Salary), Hazriq 75 of 75 at ~08:23 (Daily Salary), Isrol 28 of 65 at 12:00 (Daily Salary). Lorry drivers and other off-site staff cannot record hours: there is no second punch to recover. A design that treats every odd day as a fault to be cleared would be demanding repairs that are impossible, on days where the pay is fixed-wage and does not read the hours anyway.

## Decisions taken during brainstorming

| Topic | Decision |
|---|---|
| Model | Declarative shift definitions, not inference from punch gaps. Inference needed a rest-gap threshold, a max-length backstop, a re-derivation window and a staleness story; stated data replaces all four. |
| `work_shifts` | `name`, `start_time`, `normal_hour`, `max_hour`, `is_default`. No `end_time` — it is derivable and nothing needs it stored. |
| Assignment | `employee_work_shifts`, dated. **No row (or none effective) ⇒ the company's default shift.** |
| Default shift | Resolved by `is_default` (one true row per company, partial unique index), **not** by the name `"General"` — the fallback runs on every punch and must survive a rename. The default row cannot be deleted. |
| Seeding | One General row per company: `start_time` 08:00, `normal_hour` 9, `max_hour` 12. Seeded by the migration for existing companies **and by `Sys.create_company/2` for every new one**, alongside the default accounts, tax codes and salary types. |
| Grouping | Persisted on the punch: `work_shift_id` + `work_shift_date`. Hours, pay date and anomalies are **derived on read** from that grouping, so nothing can go stale when a clerk edits a punch. |
| Instance boundary | A derived **cutover**, not a stored field. |
| Attribution | The calendar day the shift **ended**. |
| Window's job | Grouping only. A punch is never anomalous for falling outside the window. |
| Overtime | **Unchanged.** Still `worked − Employee.work_hours_per_day`. |
| Anomalies | Odd punch count in a closed instance, or span > `max_hour`. |
| On anomaly | Worked hours **blank** (nil, not 0.0) and the row red. The pay slip is **not blocked** — see “Why nothing is blocked”. |
| Off-site staff | Not modelled. Drivers and other staff who punch once or not at all keep reading exactly as they do today: blank hours, red row, no effect on pay. Nothing blocks, so nothing needs an exemption. |
| Editing a punch | Punch rows are keyed by pay date, so a slot's typed time is resolved **inside the instance window**, not against the row's date. |
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

**Re-derivation triggers:** inserting, editing or deleting a punch re-resolves that punch's instance (and, on a time edit, the instance it left) — via **both** delete paths, `delete_time_attendence/3` and `delete_time_attendence_by_id/3`, the latter being the one the punch row actually calls. Changing or adding an `employee_work_shifts` row re-resolves that employee's punches over the affected date range. **Editing a `work_shift`'s `start_time` or `max_hour` moves its cutover, so it re-resolves every punch attached to that shift** — otherwise stored anchors silently disagree with the arithmetic that produced them. This replaces `rebuild_day_flags/3` entirely.

## Anomalies, hours and the payroll gate

`worked` is **nil**, never `0.0`, on an anomalous instance — a real zero (an employee who punched in and straight out) must stay distinguishable from "we don't know".

The five monthly totals in `punch_card.ex:875-921` (`total_day_worked`, `normal_pay_days`, `ot_day_worked`, `holiday_pay_days`, `sunday_pay_days`) all divide `x.wh` / `x.nh` / `x.ot` by `work_hours_per_day` and **would crash on nil**. Each needs an explicit rule: an anomalous instance contributes nothing — the same total it contributes today via the rescued `0.0`.

`holiday_pay_days/2` needs more than a nil-guard: it calls `HR.punch_by_date/3` for the **previous and next calendar day** and checks `px.wh == 0.0 or nx.wh == 0.0` to decide whether a holiday is paid. Once instances are keyed by pay date, "the previous day" must mean *the previous instance for that employee*, not the previous calendar date — otherwise a night worker whose shifts land on consecutive pay dates with nothing in between reads as absent. Rewrite it against the instance sequence, and treat a neighbouring anomalous instance (`wh` nil) as unknown rather than as zero, since nil and 0.0 mean opposite things here. **It must keep crossing the month boundary**: today's `punch_by_date/3` call happily reads the last day of the previous month for a holiday on the 1st. Walking only the month's own rows would make the 1st and the last day of every month unpayable-by-default, so the neighbours for those two days are still fetched, not indexed out of the in-memory list.

### Why nothing is blocked

**Pay slip generation is never blocked by an anomaly.** An unresolved instance shows blank hours and a red row, and the Save PaySlip button sits directly beneath those rows on the same Punch Card screen — the signal is already in front of the person deciding to pay. An earlier draft of this design blocked the month and offered no override. Three things killed that:

- **The repair is often impossible.** Lorry drivers and other off-site staff punch once, on every day they work; there is no missing punch to recover. Blocking would demand a correction that cannot honestly be made, and the only way to satisfy it would be to invent a punch time — falsifying the attendance record to unlock payroll is a worse outcome than a red row.
- **The pay does not read the hours anyway.** All three of the heaviest single-punch employees draw FixedWages (Monthly or Daily Salary). Their `wh` has been `0.0` for 20 months and their pay slips have been correct throughout.
- **It would have been retroactive.** 61 of the 68 affected employee-months are already paid. A block makes re-running any of them impossible until someone reconstructs punches from 2025.

So: no gate date, no `unresolved_shift_dates` query, no `{:error, :unresolved_shifts, _}` return, no per-slip override to design, and **no exemption flag on employees or shifts** — with nothing to block, "this person's attendance is not measured" needs no representation in the schema. `PaySlipOp.pay/6`, `create_pay_slip/3` and `update_pay_slip/4` are untouched by this spec.

What replaces it is exactly what exists today: the red row. It is not weaker than the status quo — a 1-punch day is already red (`tl_ok?` falls through to `false` for any pattern that is not a complete ordered pair set, `punch_time_component.ex:241`), so the people who need fixing look the same after this change as before it.

Repair, when it *is* possible, needs `:create_time_attendence` / `:update_time_attendence` — **admin / manager / supervisor**. A clerk can see the red row but cannot fix it.

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

**No day in the existing 20 months renders differently** — zero of 6,619 employee-days exceed 6 punches (the busiest is 5). The layout grows a second line only on days that are already red-flagged, where a taller row is a feature. Keeping a 6-slot minimum preserves the blank-slot add affordance for free, and a night shift is an ordinary 4-punch day that never wraps.

**A typed time belongs to the instance, not to the row's date.** The slot input is `type="time"` — hours and minutes only — and `add_date_to/2` (`punch_time_component.ex:258-262`) currently stitches it onto `obj.dd`, the row's date. That is correct while a row *is* a calendar day. Once rows are keyed by pay date it is wrong for every night shift: the 17:00 punch of a Night instance that ended at 02:00 on 6 May is displayed on the 6 May row, so re-typing it would store *6 May 17:00* — the next instance, since Night's cutover is 11:00. The clerk's one repair action would corrupt the very shift they are repairing.

The rule is therefore: a typed time resolves to the date that places it **inside `[cutover(anchor), cutover(anchor + 1))`** for that row's instance, where the anchor is the instance's `work_shift_date`. For General (anchor = pay date) this is identical to today's behaviour. Each slot already carries a hidden `datetime` field — currently written and then ignored by all three handlers — which is where the instance context belongs.

- Punch Card rows are keyed by **pay date**, so a night shift appears once, on the day it ended, with all its punches together.
- The pay-slip edit lock (`pay_slip_exists_for_period?/3`, reached from both the create/update path and `delete_time_attendence_by_id/3`) must test the **instance's pay date**, not the punch's own calendar date. A Night OUT at 02:00 on 1 June belongs to May's pay slip; keyed on its own date it would be locked by June's and left editable by May's — backwards in both directions.
- Punch IO keeps listing punches; the photo toggle, `.punch-photo` CSS and infinite scroll are untouched.
- **Work Shifts** maintenance page (admin/manager/supervisor): list, create, edit. Name, start time, normal hour, max hour, and a read-only derived line showing the nominal end and the cutover, so the arithmetic is never a mystery. Editing start time or max hour re-resolves that shift's punches; the default row cannot be deleted, and deleting any other shift is refused while punches or assignments still point at it.
- **Assignment** is a small section on the employee form: the employee's dated shift rows, with "no row = General" stated in the UI. The employee form is open to **clerks**, who may not manage shifts — the section is read-only for them, and hidden entirely on a new employee, which has no id to attach an assignment to until it is saved.
- `form_component.ex:195`'s hard-coded flag dropdown is removed; flag is derived, not chosen.
- Gettext for all new labels (en + zh).

## Migration and rollout

1. Create `work_shifts`, `employee_work_shifts`; add the three `time_attendences` columns; drop the dead `shift_id`.
2. Seed one General row per company (08:00 / 9 / 12).
3. Backfill all 23,902 rows: `work_shift_id` = that company's General, `work_shift_date` = the punch's local date, `punch_kind` and `flag` from position within the instance.
4. Because General's cutover (02:00) sits in the empty band, step 3 reproduces today's grouping exactly. **The migration asserts that rather than assuming it**, and aborts if it is false.

   The gate must compare the backfilled anchor against *the cutover*, not against the expression it was just assigned from. Setting `work_shift_date = (punch_time at time zone tz)::date` and then asserting `work_shift_date = (punch_time at time zone tz)::date` is a tautology that passes on any data, including data it was written to reject. The property that actually matters is:

   > no punch's local time falls before its shift's cutover — i.e. `count(*) where (punch_time at time zone tz)::time < cutover` must be 0.

   For the seeded General that cutover is 02:00, and the measured count is 0 (there are no punches at all between 22:00 and 06:59). Any non-zero count means at least one punch would move to the previous day's instance and the backfill is **not** behaviour-preserving.

   A second, independent check compares worked hours before and after for every employee-day. It must treat the two representations of "we don't know" as equal: today an odd day is rescued to `0.0`, and after this change it is `nil`. Compare `coalesce(after, 0.0)` with `before`, or the 328 odd days fail a gate they are not evidence against.
5. Night shifts are created and assigned by hand afterwards. Nothing changes for anyone until someone does: no existing row regroups, no existing month stops being payable, and the only visible difference on the 328 odd days is a blank hours cell where `0.00` used to be.

## Testing

**Grouping and cutover**
- General: 08:00 → 17:00 with a lunch pair groups into one instance, pay date = same day, hours identical to today's calendar-day result.
- Night 17:00 → 02:00 groups across midnight into one instance; pay date = the second day; hours = 9.083 for the drifted example above.
- The 33-hour case (IN 5/5 08:00, OUT 6/5 17:00) under General is **two** instances, each holding one punch → two `:missing_punch` dates, hours nil on both. This is the cutover doing its job: 08:00 and 17:00 both sit after 02:00 on their own days, so nothing pairs them. (An earlier draft called this one `:too_long` instance; it is not, and a test asserting that would fail.)
- `:too_long` needs both punches inside one window: IN 07:00 and OUT 21:00 on the same day is a 14-hour General instance → `:too_long`, hours nil.
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

- Typing a time into a blank slot on a Night row that ended at 02:00 stores it in **that** instance: 17:00 typed on the 6 May row is saved as 5 May 17:00, and the instance still holds two punches afterwards.
- The same edit on a General row is unchanged: the typed time keeps the row's own date.

**Anomalies**
- Odd punch count → `:missing_punch`, hours nil, row red.
- Adding the missing punch clears it and the hours appear.
- The five monthly totals skip anomalous instances instead of crashing on nil.
- `holiday_pay_days/2` reads the previous/next *instance*, not the previous/next calendar date, and treats a nil neighbour as unknown rather than as a zero-hour absence.
- A holiday on the **1st** of a month reads the previous month's last day as its previous neighbour, and one on the last day reads the next month's first — the month's own list is not the whole world, and index `-1` is not "yesterday".
- A genuine 0-hour day (in and straight out) stays `0.0`, not nil — `holiday_pay_days/2` must still read it as a real absence.

**Nothing blocks**
- An employee-month containing an odd instance still generates a pay slip, and re-generates one.
- An employee who punches once a day for a whole month (the off-site case) is payable, every month, with no assignment row and no flag.
- That month's `total_day_worked` is the same number before and after this change — the anomalous day contributes nothing either way.

**Assignment**
- No `employee_work_shifts` row → the company default.
- A dated assignment applies only inside its range; a May re-run sees May's roster.
- Overlapping ranges for one employee are rejected.
- Deleting an assignment re-resolves affected punches back to the default.
- Editing a shift's `start_time` or `max_hour` re-resolves that shift's punches, and a punch that changes instance is renumbered in both.
- The default shift cannot be deleted.

**Seeding**
- A company created **after** this migration has exactly one default shift — `Sys.create_company/2` seeds it, so `default_work_shift/1` never raises on a fresh tenant, and every test fixture company has one.
- A second `is_default` row for the same company is rejected by the partial unique index.

**Backfill**
- No punch's local time falls before its shift's cutover (the real gate in step 4).
- Every pre-existing employee-day's `wh` is identical before and after migration, with `nil` treated as the old rescued `0.0`.
- `time_attendences.shift_id` is gone.

## Files (expected)

- `priv/repo/migrations/*_create_work_shifts.exs` — tables, columns, drop dead `shift_id`, seed General, backfill
- `lib/full_circle/hr/work_shift.ex`, `lib/full_circle/hr/employee_work_shift.ex`
- `lib/full_circle/hr/shift_instance.ex` — the grouping and derivation maths as pure functions (`hr.ex` is already ~1,400 lines)
- `lib/full_circle/sys.ex` — seed the default shift in `create_company/2`
- `lib/full_circle/hr.ex` — grouping function, hours/anomaly derivation, monthly totals, fingerprint import and its dedupe, `punch_query_by_company_id` CTE, pay-slip edit lock keyed to the pay date
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
7. **No assignment means the default shift, resolved by `is_default`** — the majority of staff need no row, so the change is opt-in and rolls back by clearing assignments. The flag, not the name, is the key: the fallback runs on every punch and must survive a rename.
8. **Blank, not zero** — an unknown must stay distinguishable from a real zero, because `holiday_pay_days/2` reads `0.0` as a genuine absence.
9. **Blank, but never blocked** — 328 existing employee-days are odd, and most of them are off-site staff for whom no missing punch exists to recover. The red row is the whole enforcement mechanism, as it is today. This also removes the need to model attendance exemption at all.

## Implementation order (for the later plan)

1. Tables, columns, drop dead `shift_id`, seed General (migration **and** `Sys.create_company/2`), backfill + the cutover gate and the `wh` parity check.
2. Grouping function, hours/anomaly derivation, `punch_kind` and derived `flag`; replace `rebuild_day_flags/3`; re-derivation on insert/edit/delete (both delete paths) and on shift-definition edits.
3. Remove the six-slot ceiling: `make_timeattend_list/2`, `PunchTimeComponent`, the parent's `{:updated_punch, ...}` handler, the two index components, the flag dropdown. Resolve a typed time inside its instance window. Fix the fingerprint importer's silent discard and its dedupe.
4. Monthly totals skip anomalous instances (no pay-slip gate — `PaySlipOp` is untouched).
5. Work Shifts maintenance page, employee assignment section, authorization, dashboard link, gettext.
6. Skill updates.
