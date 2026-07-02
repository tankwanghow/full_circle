# Zero-Redeploy Statutory Payroll: PayScript + FileSpec

**Date:** 2026-07-02
**Status:** Approved design, pending implementation plan

## Goal

When the Malaysian government changes, creates, or removes any statutory rate,
calculation, or submission-file layout (EPF, SOCSO, EIS, SKBBK, PCB, or something
that does not exist yet), a company admin fixes it by editing data in the app.
No code change, no redeploy.

## Current state (what this replaces)

- `lib/full_circle/salary_note_cal_func.ex` hardcodes the SOCSO, EIS, and PCB
  bracket tables and one `calculate_value/3` clause per statutory code
  (`:epf_employee`, `:socso_24hour`, ...). PCB uses YTD DB queries over
  `salary_notes` and cross-calls `calculate_value(:epf_employee, ...)`.
- `lib/full_circle/pay_slip_op.ex` `calculate_pay/2` dispatches via
  `String.to_atom(cal_func)`.
- `lib/full_circle/HR/salary_type.ex` validates `statutory_code` against a
  hardcoded `@statutory_codes` list.
- `lib/full_circle/hr.ex` `statutory_contributions/3` builds report SQL columns
  from a hardcoded `@statutory_categories` list.
- `lib/full_circle/hr/statutory/*.ex` hardcode the five submission file formats
  (fixed-width text via `fixed_width.ex`).

The June 2026 SKBBK (SOCSO Lindung 24 Jam) change required touching all of the
above and redeploying. That is the failure mode this design removes.

## Decisions (confirmed with user)

1. **All** statutory calculations, including full PCB, are expressed in the
   payroll language — nothing statutory stays hardcoded.
2. Rates/calcs/formats are **per-company** (multi-tenant, like `SalaryType`).
3. Submission file layouts are also data, via a **file format description
   language**.
4. Language shape: **small script language** (sequence of assignments, no
   loops, no user functions) — not expression-only nesting, not embedded Lua.
5. File formats: **fixed-width + delimited text now**, with a `renderer` field
   on each spec so xlsx/PDF renderers can be added later without changing
   existing specs.
6. FileSpec editing in v1: **JSON textarea with save-time validation and
   on-screen preview**; a structured form editor may come later.
7. No `Code.eval` anywhere; no atom creation from user data.

## 1. Data model

Three new tables. All are per-company (`company_id` FK), use `binary_id` via
`FullCircle.Schema`, are managed through `StdInterface` (audit logging), and
are restricted to the `admin` role via `Authorization.can?/3`.

All three are **effective-dated**: a row is a version of its `code`, and the
version used for a pay slip is the one with the greatest
`effective_from <= end_of_month(pay_year, pay_month)`. This lets history
recompute correctly (a May 2026 slip never sees SKBBK) and lets future changes
be staged in advance.

### `statutory_rate_tables`

| column | type | notes |
|---|---|---|
| `company_id` | FK | |
| `code` | string | e.g. `socso`, `eis`, `pcb_normal`; must match `^[a-z0-9_]+$` |
| `effective_from` | date | |
| `columns` | jsonb | ordered list of column names, e.g. `["wage_from","wage_to","employer","employee","employer_only","employee_24hour"]`; first two are always the bracket bounds |
| `rows` | jsonb | list of numeric lists, one per bracket |

Unique index on `(company_id, code, effective_from)`. Uploaded as CSV with a
header row; stored parsed.

### `statutory_calcs`

| column | type | notes |
|---|---|---|
| `company_id` | FK | |
| `code` | string | e.g. `socso_employee`, `pcb_employee`, `epf_relief_cap`; `^[a-z0-9_]+$` |
| `name` | string | display name |
| `effective_from` | date | |
| `script` | text | PayScript source |

Unique index on `(company_id, code, effective_from)`. Constants are just calcs
with a one-line script (`result = 4000`) — one mechanism, no separate
constants table.

### `statutory_file_formats`

| column | type | notes |
|---|---|---|
| `company_id` | FK | |
| `code` | string | e.g. `epf_form_a`, `socso_eis_text`; `^[a-z0-9_]+$` |
| `name` | string | display name |
| `effective_from` | date | |
| `renderer` | string | `"text"` only in v1 |
| `spec` | jsonb | FileSpec document (section 4) |

Unique index on `(company_id, code, effective_from)`.

### Caching

Parsed scripts, rate tables, and file specs are cached in ETS keyed by
`(company_id, code)` holding all versions sorted by `effective_from`;
invalidated on any save for that company+code. Payroll volume is low, so the
cache is a nicety, not a requirement — correctness comes from the DB.

## 2. PayScript — the calculation language

A purpose-built, guaranteed-terminating script language.

### Shape

A script is a sequence of `name = expression` lines. The last binding must be
`result`. Blank lines and `#` comments allowed. Later lines may reference
earlier bindings. No loops, no user-defined functions, no reassignment.

### Expressions

- Literals: numbers (`0.11`, `4000`), strings (`"Single"`), booleans
  (`true`, `false`).
- Operators (by precedence, low→high): `or`, `and`, `not`,
  comparisons `== != > >= < <=`, `+ -`, `* /`, unary `-`, parentheses.
- `if(condition, then_expr, else_expr)` — the only branching construct.

### Builtins

| builtin | semantics |
|---|---|
| `lookup(table, value, column)` | Bracket lookup in the company's rate table `table` (effective-dated): the row where `value > wage_from and value <= wage_to`; returns the named `column`. No matching row → `0.0` (matches current behavior). Unknown table/column → save-time error. |
| `ytd_sum(code: c)` / `ytd_sum(type: t)` / `ytd_sum(name: n)` | Sum of `quantity * unit_price` over the employee's `salary_notes` where `year(note_date) = pay_year` and `month(note_date) < pay_month`, filtered by the salary type's `statutory_code`, `type`, or `name`. The argument may be a string or a list of strings (e.g. `ytd_sum(name: ["Employee PCB", "PCB Current Year"])`). Covers PCB's Y, K, X, Z queries. |
| `calc("code")` | Evaluates another statutory calc in the same employee/changeset context. Memoized per pay-slip calculation. Cycles rejected at save time. |
| `min(a,b)` `max(a,b)` `ceil(x)` `floor(x)` `abs(x)` `round(x, n)` | Standard math. |

### Context variables

`wages` (changeset `addition_amount`), `bonus` (`bonus_amount`), `age`
(full years at end of pay month, from `emp.dob`), `malaysian` (boolean:
`emp.nationality` trimmed/downcased starts with `"malays"`), `nationality`
(string), `marital_status` (string), `partner_working` (boolean, normalizing
today's `"true"/"Yes"/"false"/"No"` values), `children` (number),
`pay_month`, `pay_year`, `service_years` (full years from
`emp.service_since` to end of pay month).

### Semantics & errors

- Arithmetic is float internally (parity with current code); the final
  `result` is converted to `Decimal` for the salary note.
- **Save-time validation** (rejected before the version can be created):
  parse errors, unknown identifiers/functions/table codes/column names,
  missing `result`, `calc()` dependency cycles.
- **Run-time errors** (division by zero, `calc()` of a code with no version
  effective for the month): the pay-slip calculation surfaces a named error
  on the form ("socso_employee: division by zero"); it never silently
  produces 0.

### Implementation

Hand-rolled lexer + Pratt parser producing a plain-tuple AST; a tree-walking
evaluator over a context map. Scripts are stored as source text and parsed on
load (cached). Roughly: `FullCircle.PayScript.{Lexer, Parser, Evaluator}` plus
`FullCircle.PayScript` as the public API (`validate/2`, `eval/3`).

### Reference: PCB script (mirrors the LHDN formula sheet)

```text
cap = calc("epf_relief_cap")
y   = ytd_sum(type: "Addition") + ytd_sum(name: "Employee Current Year Income")
k   = min(ytd_sum(name: ["EPF By Employee", "EPF By Employee Current Year"]), cap)
y1  = wages
k1  = if(k >= cap, 0, min(calc("epf_employee"), cap - k))
y2  = y1
n   = 12 - pay_month
k2  = if(k + k1 == 0, 0, max(min(k1, (cap - (k + k1 * n)) ), 0))
yt  = bonus
kt  = if(k + k1 + k2 >= cap, 0, min(calc("epf_employee"), cap - (k + k1 + k2)))
d   = calc("pcb_individual_deduction")
s   = if(marital_status == "Married" and not partner_working, calc("pcb_spouse_deduction"), 0)
q   = calc("pcb_child_deduction")
p   = y - k + (y1 - k1) + (y2 - k2) * n + (yt - kt) - (d + s + q * children)
m   = lookup("pcb_normal", p, "m")
r   = lookup("pcb_normal", p, "r")
b   = if(marital_status == "Married" and not partner_working,
         lookup("pcb_normal", p, "b2"), lookup("pcb_normal", p, "b13"))
x   = ytd_sum(name: ["Employee PCB", "PCB Current Year"])
z   = ytd_sum(name: ["Employee Zakat", "Zakat Current Year"])
pcb = ((p - m) * r + b - (z + x)) / (n + 1)
result = if(pcb > 0, round(pcb, 1), 0)
```

(The seeded script must reproduce the exact K1/K2/Kt conditional structure of
`salary_note_cal_func.ex`; the above shows expressiveness, and the golden
parity tests in section 6 are the authority on exactness.)

## 3. Dispatch & schema integration

- **`PaySlipOp.calculate_pay/2`**: for a line with non-empty `cal_func`, look
  up the company's `statutory_calcs` by that string code and evaluate the
  effective version's script. If no calc exists for the code, fall back to the
  legacy `SalaryNoteCalFunc.calculate_value/3` atom dispatch **during the
  transition only**; once golden-parity tests pass and companies are seeded,
  the hardcoded module and the `String.to_atom` call are deleted.
- **`SalaryType.statutory_code`**: validated against the company's
  `statutory_calcs` codes (plus nil) instead of the hardcoded list — creating
  a brand-new statutory line is: upload table (if any) → create calc → create
  salary type referencing it. No deploy.
- **`HR.statutory_contributions/3`**: column list built from the company's
  distinct `statutory_calcs` codes instead of `@statutory_categories`. Codes
  are interpolated into SQL, so the `^[a-z0-9_]+$` constraint is enforced both
  at changeset level and again defensively in the query builder. The statutory
  report LiveView renders its columns dynamically from the result keys.
- A code the government abolishes is simply no longer referenced by any
  salary type; old versions stay for historical recomputation.

## 4. FileSpec — file format description language

A declarative JSON document per format version, replacing
`hr/statutory/{epf,socso,eis,socso_eis,pcb}_format.ex`.

```json
{
  "renderer": "text",
  "line_ending": "\r\n",
  "delimiter": null,
  "sections": [
    { "kind": "header",
      "fields": [ {"expr": "\"00\"", "width": 2},
                  {"expr": "company_epf_no", "width": 19, "pad": " ", "align": "left"} ] },
    { "kind": "detail", "source": "statutory_rows",
      "filter": "socso_employee > 0 or socso_24hour > 0",
      "sort": "employee_name",
      "fields": [
        {"expr": "socso_no", "width": 12, "pad": " ", "align": "left"},
        {"expr": "socso_employee + socso_employer", "width": 10,
         "format": "cents", "pad": "0", "align": "right"} ] },
    { "kind": "footer",
      "fields": [ {"expr": "count()", "width": 7, "pad": "0", "align": "right"},
                  {"expr": "sum(\"socso_employee\")", "width": 10, "format": "cents"} ] }
  ]
}
```

- **One grammar**: every `expr` and `filter` is a PayScript *expression*
  (single expression, not a script), evaluated by the same evaluator.
- **Detail context** (`source: "statutory_rows"`): one row per
  `statutory_contributions/3` result — employee fields (`employee_name`,
  `id_no`, `tax_no`, `socso_no`, `epf_no`, ...), `wages`, and one variable per
  statutory code sum. `filter` keeps/drops rows; `sort` orders them.
- **Header/footer context**: company fields (name, registration/agency
  numbers), `pay_month`, `pay_year`, and aggregates `sum("column")`,
  `count()` over the filtered detail rows.
- **Field rules**: fixed-width when `width` is set (with `pad`, `align`);
  delimited when the document sets `delimiter` and fields omit `width`.
  `format`: `"cents"` (amount ×100, integer), `"date:YYYYMMDD"`-style date
  patterns, default text.
- **Renderer**: `"text"` is the only v1 renderer; the field exists so xlsx/PDF
  can be added later without touching existing specs.
- Save-time validation: JSON shape, expression parses, unknown variables,
  format/width consistency. Download points in the existing statutory
  LiveViews switch to: pick format code → resolve effective version → render.

## 5. Admin UI

Per company, `admin` role, following the standard LiveView folder pattern
(`index.ex` / `form.ex` / `index_component.ex`). Three modest screens — no
heavy grid editing:

1. **Statutory calcs** — versions listed per code; script edited in a
   textarea; a **preview panel** picks a real employee + pay month/year and
   shows the computed value next to the currently-effective value before
   saving. Validation errors shown inline.
2. **Rate tables** — CSV upload with `effective_from`; parsed-bracket preview;
   validates numeric cells, monotonic non-overlapping contiguous brackets.
3. **File formats** — JSON spec textarea + generated-file preview for a chosen
   month/year.

Plus an **"Install/refresh standard Malaysia set"** action that seeds or
updates all three kinds from templates shipped in the app (same pattern as
`HR.default_salary_types/1`). Groups running multiple companies copy config
between companies via bundle export/import (section 7). Shipped templates are
a convenience; companies can always hand-edit ahead of an app release.

## 6. Seeding, migration, rollout

- Migrations create the three tables.
- A data migration seeds **every existing company** with the standard
  Malaysia set: `socso` (6-column, effective 2026-06-01) plus the pre-SKBBK
  5-column version (effective earlier), `eis`, `pcb_normal` tables; scripts
  for all 10 current codes plus the PCB constants
  (`epf_relief_cap`, `pcb_individual_deduction`, `pcb_spouse_deduction`,
  `pcb_child_deduction`); five file format specs matching the current
  formatters. New companies are seeded on creation.
- Rollout order: registry dispatch with legacy fallback → parity verified →
  hardcoded `SalaryNoteCalFunc` and `hr/statutory/*_format.ex` deleted.

## 7. Agent-assisted updates: statutory bundles

Because every statutory artifact is validated data, a coding agent (e.g.
Claude Code) can prepare a government update without DB or production access.
The handoff surface is a **statutory bundle** — one canonical JSON file
carrying a complete or partial set:

```json
{
  "bundle_version": 1,
  "source": "PERKESO circular 3/2026 — SKBBK rate revision",
  "rate_tables":  [ { "code": "socso", "effective_from": "2026-06-01",
                      "columns": ["wage_from", "wage_to", "..."], "rows": [[1, 30, 0.4]] } ],
  "calcs":        [ { "code": "socso_24hour", "name": "SOCSO Lindung 24 Jam",
                      "effective_from": "2026-06-01", "script": "result = ..." } ],
  "file_formats": [ { "code": "socso_eis_text", "name": "SOCSO+EIS text file",
                      "effective_from": "2026-06-01", "renderer": "text", "spec": {} } ]
}
```

Three touchpoints:

1. **Export** (admin UI): download the company's currently effective set as a
   bundle. Doubles as backup and as the copy-between-companies mechanism
   (section 5), and gives an agent ground truth to edit from.
2. **Import** (admin UI): upload a bundle. The app runs the same save-time
   validation as manual editing (script parsing, bracket contiguity, `calc()`
   cycles, FileSpec shape), then shows a **diff and computed-value preview**
   against the currently effective versions. Versions are created only when
   the admin clicks Apply — the human stays the activation gate.
3. **Offline validator**: `mix statutory.validate bundle.json`, reusing the
   exact validation code, so an agent can iterate locally until the bundle is
   clean before anyone touches the app.

Agent workflow: the user tells the agent about a government change (circular
URL/PDF); the agent starts from an exported bundle, edits the affected
tables/scripts/specs, runs `mix statutory.validate`, and hands back
`bundle.json`; the admin imports, checks the preview values against the
circular, and applies. No deploy.

To make agents reliable at this, a project skill
(`.claude/skills/statutory-bundle.md`) documents the bundle schema, PayScript
grammar, FileSpec rules, and the validate command, per this repo's skill
authoring convention.

## 8. Testing

- **PayScript unit tests**: lexer/parser (precedence, associativity, errors),
  evaluator, each builtin, save-time validation (unknown identifier, missing
  result, cycles), runtime error surfacing.
- **Golden parity tests**: seeded scripts vs the current hardcoded functions —
  every bracket boundary of SOCSO/EIS/SKBBK, ages 59/60, Malaysian/foreign,
  wages at RM10 / RM5,000 / RM6,000 edges, and PCB against YTD fixtures
  (including the EPF relief cap saturation branches). Must match exactly.
- **FileSpec parity tests**: byte-identical output vs the five current
  formatters for a fixture month.
- **Effective-date tests**: May 2026 slip uses the 5-column SOCSO table;
  June 2026 uses the 6-column one.
- **Upload validation tests**: bracket gap/overlap, bad column count,
  non-numeric cell, invalid JSON spec.
- **Bundle tests**: export → import round-trip is lossless; import rejects the
  same invalid inputs as manual editing; `mix statutory.validate` agrees with
  in-app validation; import preview diff reflects exactly the versions that
  Apply creates.

## 9. Implementation phases

Each phase gets its own implementation plan and lands independently:

1. **PayScript engine** — lexer, parser, evaluator, builtins behind a
   behaviour so `lookup`/`ytd_sum`/`calc` can be stubbed in tests; pure
   library, heavily unit-tested.
2. **Statutory config** — three schemas + migrations, effective-date
   resolution, ETS cache, `calculate_pay` dispatch with legacy fallback,
   seeding templates + data migration, golden parity tests; bundle format,
   export, and `mix statutory.validate`.
3. **Admin LiveViews + dynamic reporting** — the three screens, preview
   panels, bundle import with diff/preview/apply, `SalaryType` validation
   change, dynamic `statutory_contributions` columns and report rendering;
   write the `statutory-bundle` project skill.
4. **FileSpec** — spec validation + text renderer, seed five formats, switch
   download points, byte-parity tests, delete legacy formatter modules and
   `SalaryNoteCalFunc`.

## Out of scope

- Excel/PDF renderers (the `renderer` field reserves the slot).
- Structured (non-JSON) FileSpec editor.
- E-invoice, non-statutory payroll behavior, and pay-slip printing are
  untouched.
- Cross-company template distribution beyond the shipped defaults and
  bundle export/import.
- A direct API/MCP endpoint for agents to push draft versions into the app —
  the human-reviewed bundle import achieves the same outcome with far less
  security surface; revisit only if the manual import step proves burdensome.
