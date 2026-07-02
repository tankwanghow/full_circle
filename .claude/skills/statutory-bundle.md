---
name: statutory-bundle
description: Use when preparing a government statutory rate change, SOCSO / EPF / EIS / PCB / SKBBK update, or producing a statutory bundle JSON for FullCircle import.
---

# Statutory Bundle Workflow

FullCircle stores Malaysia statutory payroll config (rate tables, PayScript calcs, file-format specs) as **versioned database rows**. A **statutory bundle** is the portable JSON handoff between an agent and an admin — no deploy required.

## Bundle JSON shape

```json
{
  "bundle_version": 1,
  "source": "PERKESO circular 3/2026 — SKBBK rate revision",
  "rate_tables": [
    {
      "code": "socso",
      "effective_from": "2026-06-01",
      "columns": ["wage_from", "wage_to", "employer", "employee_invalidity", "employer_only", "employee_24hour"],
      "rows": [[0.0, 30.0, 0.4, 0.1, 0.2, 0.075]]
    }
  ],
  "calcs": [
    {
      "code": "socso_24hour",
      "name": "SOCSO Lindung 24 Jam",
      "effective_from": "2026-06-01",
      "script": "result = lookup(\"socso\", wages, \"employee_24hour\")"
    }
  ],
  "file_formats": [
    {
      "code": "socso_eis_text",
      "name": "SOCSO+EIS text file",
      "effective_from": "2026-06-01",
      "renderer": "text",
      "spec": {}
    }
  ]
}
```

- `bundle_version` must be `1`.
- `source` — record the official circular / URL / PDF reference (KWSP, PERKESO, LHDN).
- Each entry is keyed by `(code, effective_from)`; importing the same key replaces content.

## PayScript grammar (calcs)

Scripts are line-oriented `name = expression` statements; the last binding must be `result`.

**Operators** (low→high precedence): `or`, `and`, `not`, comparisons, `+ -`, `* /`, unary `-`.

**Branching:** `if(condition, then_expr, else_expr)` only.

**Builtins:**

| Builtin | Signature / semantics |
|---|---|
| `lookup` | `lookup(table, value, column)` — bracket row where `value > wage_from and value <= wage_to` |
| `ytd_sum` | `ytd_sum(code: c)` / `ytd_sum(type: t)` / `ytd_sum(name: n)` — YTD sum before current month |
| `calc` | `calc("code")` — evaluate another statutory calc (no cycles) |
| Math | `min(a,b)`, `max(a,b)`, `ceil(x)`, `floor(x)`, `abs(x)`, `round(x, n)` |

**Context variables:** `wages`, `bonus`, `age`, `malaysian`, `nationality`, `marital_status`, `partner_working`, `children`, `pay_month`, `pay_year`, `service_years`.

Save-time validation rejects parse errors, unknown identifiers/tables, missing `result`, and `calc()` cycles. Runtime errors (e.g. division by zero) surface on the Punch Card preview — never silent zero.

## Effective-date semantics

- For pay month M / year Y, the engine uses the calc/table/format version where `effective_from <= end_of_month(Y, M)` and is the latest such version per `code`.
- New rates take effect on the **first day** of the month in `effective_from` (or later if the circular says so).
- Append a new row with a later `effective_from` rather than editing history.

## Workflow

1. **Export** current config from the admin UI (`Statutory Calcs` → Export bundle) **or** start from `priv/statutory_templates/malaysia.json`.
2. Edit `rate_tables`, `calcs`, and/or `file_formats` for the government change.
3. Validate offline: `mix statutory.validate bundle.json` (must pass before handoff).
4. Admin **imports** via `Statutory Calcs` → Import bundle → review diff → **Apply**.

Rates must come from official circulars; put the reference in `"source"`.

## Worked example: EPF employee rate change

Suppose KWSP raises the Malaysian employee rate from 11% to 11.5% for wages ≤ RM5,000 (effective 2027-01-01).

1. Export the company bundle or copy `priv/statutory_templates/malaysia.json`.
2. Find the `epf_employee` calc entry; add a **new** version (do not delete the old one):

```json
{
  "code": "epf_employee",
  "name": "EPF Employee",
  "effective_from": "2027-01-01",
  "script": "total = wages + bonus\nrate = if(total <= 10, 0,\n       if(not malaysian, 0.02,\n       if(age >= 60, 0, 0.115)))\nresult = ceil(total * rate)"
}
```

3. Set `"source": "KWSP circular … — EPF employee 11.5%"`.
4. Run `mix statutory.validate bundle.json`.
5. Hand `bundle.json` to the admin for import; they verify preview values against the circular, then Apply.

No application redeploy is needed — only the bundle import.