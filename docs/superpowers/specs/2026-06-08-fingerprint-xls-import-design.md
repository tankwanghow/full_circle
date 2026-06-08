# Fingerprint `.xls` Attendance Import — Design

**Date:** 2026-06-08
**Scope:** Automate importing the fingerprint machines' monthly attendance files into
`time_attendences`, so HR no longer reads punch grids by hand. After import, the existing
**Punch Card → PaySlip** flow is unchanged.

## Problem

Each month HR receives attendance exports from **two** fingerprint machines and currently reads
them by eye to count days worked, then creates salary notes and pay. Two things block the existing
`/import_attend` importer from being usable on these files:

1. **Format** — the files are legacy `.xls` (BIFF8 / OLE2; `file` reports *CDFV2 Microsoft Excel*).
   The current importer accepts `.xlsx` only and uses `xlsx_reader`, which **cannot read `.xls`**.
2. **Two machines** — the importer takes one file; the two machine exports must both be ingested.

A third, ongoing pain is **employee matching**: the machine's employee names are frequently
truncated / inexact (e.g. `Nnrhamira Binti Abd Rah`, `HazriqDaniel Bin Abdull`,
`Isrol Shamil Bin Mohama`), so they don't equal the FullCircle `employees.name`.

### Decisions taken during brainstorming

- **Automation depth:** *Import punches only.* Land punches in `time_attendences`; HR then continues
  in the Punch Card as today (days-worked is already auto-computed there). No auto salary notes, no
  batch PaySlips.
- **No overlapping employees:** the two machines cover **disjoint** employee populations (base file =
  Nepali farm workers; `a` file = a different group). A given person punches on exactly one machine,
  so no cross-file per-employee punch merging is required — the two files' parsed results are simply
  unioned.
- **`.xls` without a server dependency:** convert `.xls`→`.xlsx` **in the browser** (SheetJS), so the
  server never needs LibreOffice or a BIFF parser and HR does no manual "Save As".
- **Matching persists:** a confirmed match writes the fingerprint `punch_card_id` onto the chosen
  employee, making future months auto-match.

## Existing pipeline (reused as-is)

- `FullCircleWeb.UploadPunchLog.Index` — `lib/full_circle_web/live/time_attend_live/upload_punch_log.ex`,
  route `/import_attend`. Reads the **`Att.log report`** sheet, splits each day-cell's concatenated
  times (e.g. `07:5512:0112:5417:01`), dedups punches within 10 min, assigns positional IN/OUT flags
  (`1_IN_1`, `1_OUT_1`, `2_IN_2`, …), matches employees by `punch_card_id`, inserts.
- `HR.insert_time_attendence_from_log/2` — `lib/full_circle/hr.ex:237`. **Idempotent**: skips insert
  when a same-`flag` punch already exists within ±5 min for that employee/company. Re-imports and
  re-runs are safe.
- `HR.get_employees_by_punch_card_ids/3` — `lib/full_circle/hr.ex:1091`. Exact `punch_card_id`
  lookup, **no status filter** (so already-matched resigned employees still resolve).
- Punch Card day/hour computation — `HR.punch_card_query/4` → `punch_query_by_company_id/3`
  (`lib/full_circle/hr.ex:1145`). Untouched.
- `similarity_order/2` (`lib/full_circle/helpers.ex:92`) — pg_trgm fuzzy ordering, already used for
  employee search (`lib/full_circle/hr.ex:174`). Reused for fuzzy match suggestions.
- Employees are updated via `StdInterface`; `punch_card_id` is a cast field on the employee
  changeset (`lib/full_circle/HR/employee.ex:67`).

## The `punch_card_id` key

`punch_card_id` is generated from the file as `"<Name>.<ID>.<Dept>"` with spaces removed
(e.g. `GurungBirBahadur.7.ChickenFarm`). It is **stable month-to-month per machine** — the export
software truncates names consistently and the fingerprint ID/department don't change — so storing it
on the employee gives reliable future auto-matching. This is the field's intended purpose; the fuzzy
layer exists only to make the **first** match fast.

> **ID reuse across machines is safe:** the same numeric ID means different people on different
> machines, but because the *name* is part of the key, the two produce different `punch_card_id`s.
> When a machine reassigns a resigned person's ID to a new hire, the name changes → a new key → it
> surfaces as a new unmatched person to match to the new employee; the resignee's old key stays
> harmlessly on the old record.

## Components & data flow

### 1. In-browser `.xls`→`.xlsx` conversion (new JS)

- Vendor **SheetJS** (`xlsx.full.min.js`, MIT) into `assets/vendor/`. SheetJS reads legacy `.xls`
  (BIFF8/OLE2) and `.xlsx`.
- Isolate SheetJS + the conversion hook as its **own esbuild entry** (mirroring `take_photo_human.js`
  / `qr_attend.js`) so the main `app.js` bundle isn't bloated; loaded only on the import page.
- A LiveView hook on the import page's file input:
  - native `<input type="file">` accepts `.xls,.xlsx` (multiple);
  - on selection, for each file: read its bytes, `XLSX.read(buf, {type:'array'})`, re-emit as an
    `.xlsx` blob via `XLSX.write(wb, {bookType:'xlsx', type:'array'})`, wrap as a `File` named
    `*.xlsx`;
  - hand the converted blob(s) to LiveView with a **programmatic upload**:
    `this.upload("xlsx_file", [convertedFile, …])`.
- The server's `allow_upload(:xlsx_file, accept: ~w(.xlsx))` therefore only ever receives `.xlsx`;
  **the server read path is unchanged**.

### 2. Multi-file upload (server)

- `allow_upload(:xlsx_file, accept: ~w(.xlsx), max_entries: 4, auto_upload: true)`.
- `handle_progress` waits until **all** selected entries are `done?`, consumes each to its sheet rows
  (one row-list per file), keeping a list of files.
- Parse **each file independently** with the existing per-file logic (10-min dedup + positional
  flags — correct because no employee spans machines), then **concatenate** the parsed attendance
  lists into one set.
- Guard: if files' `Att.log report` date-ranges differ, surface a warning rather than silently
  mixing different months.

### 3. Matching panel (the new value)

For each **distinct fingerprint person** in the upload that has **at least one punch** (zero-punch
people — e.g. enrolled-but-didn't-work resignees — are filtered out so they never appear), resolve to
a FullCircle employee in three tiers:

1. **Exact (auto):** an employee already has this `punch_card_id` → matched (green), no action.
   Status-agnostic, so previously-matched resigned employees with final-month punches resolve here.
2. **Fuzzy suggest (auto):** otherwise rank employees by `similarity_order` on the fingerprint name
   and present the **top 3** candidates, each with a one-click **Confirm**. The candidate pool
   **includes resigned employees**, with **Active ranked first**, so a mid-month resignee who was
   never mapped can still be matched.
3. **Manual:** an autocomplete (status-agnostic employee search) to pick any employee.

Confirm / manual-pick **writes `punch_card_id` onto the chosen employee** via `StdInterface`, so the
person auto-matches at the Exact tier next month. People left unresolved are simply **skipped** at
import (existing behaviour).

### 4. Import (unchanged)

`insert_time_attendence_from_log/2` per resolved attendance entry; the ±5-min/same-flag guard keeps
it idempotent.

## What is *not* changing

- No DB migration, no new schema, no route changes.
- Punch Card / PaySlip / statutory flow untouched.
- `HR.employees/3` (Active-only) is left as-is — other screens depend on it; the panel uses a
  separate status-agnostic employee search.

## Resigned-employee handling (summary)

| Case | Behaviour |
|------|-----------|
| Enrolled but no punches this month | Filtered out (zero punches) — never shown, nothing imported. |
| Already matched, resigns mid-month, has final punches | Exact tier (no status filter) resolves; final punches import. |
| Not yet matched, resigned, has real punches | Matchable via fuzzy/manual (resigned included, Active first). |
| Machine ID reused for a new hire | New name → new key → surfaces as new unmatched person. |

## Edge cases & guards

- **Different months across files** → warn, don't merge.
- **Re-import same month** → safe (idempotent insert).
- **Unmatched people** → skipped; visible in the panel for matching.
- **Multi-tenant** → all employee/insert lookups remain company-scoped.

## Verification

Using the dev DB (which already holds the **correct** PaySlips/salary notes for these employees and
periods):

1. Convert + import the `JAN 2026` + `JAN 2026a` pair.
2. Match employees (exercise all three tiers, including one resigned employee if present).
3. Spot-check the Punch Card's computed **days-worked** for a sample (a couple of single-machine
   employees from each machine) against the known-correct PaySlips/salary notes in the dev DB.
4. Re-run the import to confirm idempotency (no duplicate punches).

## Out of scope

- Auto-generating salary notes or PaySlips (explicitly deferred — "import punches only").
- Server-side `.xls` parsing / LibreOffice.
- Changing the `punch_card_id` scheme or adding a separate machine-mapping table.
</content>
</invoke>
