# Payroll Statutory Reports Refactor — Design

**Date:** 2026-06-05
**Status:** Approved design, pending spec review

## Problem

The EPF/SOCSO/EIS statutory submission files are produced by four near-identical raw-SQL
functions ([hr.ex:131-242](../../../lib/full_circle/hr.ex#L131-L242)) driven by
[epf_socso_eis.ex](../../../lib/full_circle_web/live/report_live/epf_socso_eis.ex). The current
design is fragile and manual:

1. **Statutory amounts are matched by hardcoded salary-type names** in SQL
   (`st.name = 'EPF By Employer'`, `'EPF Employee Self'`, `'SOCSO By Employer'`, …). A rename,
   typo, or locale change silently produces a wrong/empty file.
2. **File formatting is encoded inside SQL** with `rpad`/`to_char` padding — unreadable against
   the agency spec, untestable, and brittle (e.g. breaks if a name exceeds the pad width).
3. **Four ~95% identical query functions** — adding PCB means a fifth copy.
4. **The employer `code` is retyped every run** (single shared setting), and reports are run one
   at a time. *(UX deferred — see Non-Goals.)*
5. **No PCB (LHDN CP39) monthly file** at all, despite the PCB amount already being computed.

## Goal

Refactor statutory reporting onto a single, testable pipeline, and add PCB:

- Identify statutory amounts by an explicit **`statutory_code` on `SalaryType`**, not by name.
- Replace the four SQL blobs with **one structured aggregation query**.
- Move file formatting into **per-agency Elixir formatter modules**, unit-tested.
- Add the **PCB / CP39 (e-Data PCB)** file.

**Hard requirement:** the new EPF/SOCSO/EIS/SOCSO+EIS output must be **byte-identical** to the
current SQL output for the same data, so existing portal uploads keep working. This is enforced
by a golden test comparing old vs new.

## Non-Goals (YAGNI)

- **UX improvements** (per-agency stored employer codes, one-screen-all-agencies, default to last
  month) — a separate follow-up increment. Employer codes stay in `Sys` settings as today.
- **CP38** support — the system computes PCB only; CP38 amounts/counts are always zero.
- **GL reconciliation**, e-PCB payment flow, statutory rate-table management — out of scope.

## Architecture

### 1. `statutory_code` on `SalaryType`

Add a nullable string `statutory_code` to `salary_types`. Allowed values (validated by an
`Ecto.Enum`-style inclusion check; blank/`nil` = not statutory):

```
epf_employer, epf_employee,
socso_employer, socso_employee, socso_employer_only,
eis_employer, eis_employee, eis_employer_only,
pcb_employee
```

- **Form:** the salary-type form ([salary_type_live/form.ex](../../../lib/full_circle_web/live/salary_type_live/form.ex))
  gets a `statutory_code` select (options above + a blank "— none —").
- **Changeset:** cast + `validate_inclusion` against the allowed list (allowing `nil`/"").
- **Backfill data migration:** for every existing salary type, set `statutory_code` from a
  name map:

  | Name (case-insensitive) | statutory_code |
  |---|---|
  | EPF By Employer | epf_employer |
  | EPF By Employee, EPF Employee Self | epf_employee |
  | SOCSO By Employer | socso_employer |
  | SOCSO By Employee | socso_employee |
  | SOCSO Employer Only | socso_employer_only |
  | EIS By Employer | eis_employer |
  | EIS By Employee | eis_employee |
  | EIS Employer Only | eis_employer_only |
  | Employee PCB | pcb_employee |

  Anything unmatched stays `nil` for the user to set on the form.

### 2. One structured aggregation query

New `FullCircle.HR.statutory_contributions(month, year, com_id)` returns one row per employee
who has a pay slip that month, with the columns the formatters need:

- `name, id_no, tax_no, socso_no, epf_no, service_since`
- `wages` — sum of `Addition`-type salary notes on the slip
- one summed amount per `statutory_code` (`epf_employer`, `epf_employee`,
  `socso_employer`, `socso_employee`, `socso_employer_only`, `eis_employer`, `eis_employee`,
  `eis_employer_only`, `pcb_employee`) — each = `Σ quantity*unit_price` of that month's slip's
  salary notes whose salary type carries that `statutory_code`.

It joins `pay_slips → employees`, and per category sums `salary_notes` joined to `salary_types`
on `statutory_code`. No formatting in SQL — amounts come back as decimals/numbers.

### 3. Per-agency formatter modules

`lib/full_circle/hr/statutory/` with one module per file:

- `EpfFormat` — current EPF multi-column CSV rows.
- `SocsoFormat`, `EisFormat`, `SocsoEisFormat` — current fixed-width `textstr` lines.
- `PcbFormat` — the CP39 / e-Data PCB file (spec below).

Each exposes `rows(contributions, opts)` (and/or `lines/2`) taking the structured query output +
employer code, returning the exact text the agency expects. The brittle `rpad`/`to_char` logic
becomes readable Elixir (`String.pad_leading/pad_trailing`, integer cents).

A thin `FullCircle.HR.statutory_file(report, month, year, code, com_id)` dispatches to the right
formatter, used by both the LiveView preview and the CSV controller download.

### 4. CP39 / e-Data PCB format (authoritative)

From the LHDN *Manual Pengguna e-Data PCB* (pages 15–16), reconciled byte-for-byte against two
real submitted files (Mar 2026: 13 employees, total RM 5,380.10; Apr 2026: 10 employees,
RM 5,020.40). ASCII, **CRLF** line endings. Amounts are **cents** (value × 100). Employer code =
the 10-digit numeric employer TIN (the digits of the `E…` number, left-zero-padded to 10).

**Header line — 57 chars:**

| Field | Width | Notes |
|---|---|---|
| Record type | 1 | `H` |
| No. Tin Ibu Pejabat | 10 | employer TIN, left-zero-pad to 10 |
| No. Tin Cawangan | 10 | branch TIN (same value) |
| Tahun | 4 | `YYYY` |
| Bulan | 2 | `MM` |
| Amaun PCB | 10 | total PCB cents = Σ detail PCB |
| Bilangan PCB | 5 | count of detail records |
| Amaun CP38 | 10 | total CP38 cents = `0` |
| Bilangan CP38 | 5 | count with CP38 > 0 = `0` |

**Detail line — 136 chars (one per employee with PCB > 0):**

| Field | Width | Notes |
|---|---|---|
| Record type | 1 | `D` |
| No. Tin Pekerja | 11 | employee tax no (digits), left-zero-pad to 11 |
| Nama Pekerja | 60 | name, left-justify space-pad, **no digits** |
| No. KP Lama | 12 | old IC — blank |
| No. KP Baru | 12 | new IC (`id_no` digits) — **IC goes here** |
| No. Pasport | 12 | blank |
| Kod Negara | 2 | `MY` |
| Amaun PCB | 8 | PCB cents |
| Amaun CP38 | 8 | `0` |
| No. Pekerja | 10 | employee no — blank (not mandatory) |

Rule enforced by data: besides Nama, at least two of {tax no, old IC, new IC, passport} must be
filled — we supply **tax no + new IC**. Only employees with `pcb_employee` amount > 0 are
included. Filename pattern: `pcb List_<YYYYMMDDhhmmss>.txt` (matching the existing tool).

### 5. Screen + CSV wiring

- [epf_socso_eis.ex](../../../lib/full_circle_web/live/report_live/epf_socso_eis.ex): add `PCB`
  to the report dropdown; call `statutory_contributions/3` and render a **human-readable preview
  table** (employee, IC, wages, employer/employee amounts per category) instead of raw
  fixed-width strings. Employer `code` still from settings (unchanged).
- [csv_controller.ex](../../../lib/full_circle_web/controllers/csv_controller.ex): the
  `report=epfsocsoeis` branch calls `HR.statutory_file/5` (which now also handles `PCB`) instead
  of the four old functions. Download bytes are produced by the formatters.
- The four old `*_submit_file_format_query/4` functions are removed once the golden test confirms
  parity.

## Testing

- **Golden parity (EPF/SOCSO/EIS/SOCSO+EIS):** seed a company with employees, statutory salary
  types (tagged via `statutory_code`), and pay slips; assert each new formatter's output equals
  the **current** `*_submit_file_format_query/4` output for the same data, character-for-character.
  Run this before deleting the old functions.
- **CP39 (`PcbFormat`):** with **synthetic** employees (no real PII), assert:
  - header is exactly 57 chars with correct field widths, total-PCB cents = Σ details, and
    `Bilangan PCB` = detail count;
  - each detail is exactly 136 chars with tax no, name (60, space-padded), IC in the No. KP Baru
    field, `MY`, and PCB cents in the right columns;
  - CRLF line endings; only PCB > 0 employees included.
  Expected lines are hand-built from the spec table (the two real LHDN files are used only as the
  reference for deriving the spec — they are **not** committed, to avoid storing employee PII).
- **`statutory_code`:** changeset validates inclusion and allows blank; backfill migration sets
  codes from the name map and leaves unknowns blank.
- **Aggregation query:** an employee with tagged statutory salary notes reports the correct
  per-category sums and `wages`; untagged notes are excluded.

## Open Questions

None.
