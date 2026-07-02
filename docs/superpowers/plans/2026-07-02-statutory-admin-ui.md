# Statutory Admin UI + Dynamic Reporting Implementation Plan (Phase 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin LiveViews for statutory calcs and rate tables (with computed-value previews), bundle export/import with diff preview, `SalaryType.statutory_code` validated against the company's calc registry, dynamic statutory report columns, graceful surfacing of script runtime errors on the pay-slip form, and the `statutory-bundle` project skill.

**Architecture:** Two LiveView feature folders following the repo's standard pattern (`index.ex` / `form.ex` / `index_component.ex`), routed under `/companies/:company_id/`, gated by `can?(user, :manage_statutory_config, company)`. Bundle import/export lives on the calc index screen. Reporting goes dynamic by deriving columns from `StatutoryConfig.calc_codes/1`.

**Tech Stack:** Phoenix LiveView 1.1 (existing patterns), `Phoenix.LiveView.allow_upload` for CSV/JSON uploads, Phase 2 `FullCircle.StatutoryConfig` API.

## Global Constraints

- Phases 1–2 complete and green (`PayScript.*`, `StatutoryConfig.*` as specified in their plans).
- **Before writing any LiveView, read one existing feature as the canonical pattern**: `lib/full_circle_web/live/salary_type_live/{index.ex,form.ex,index_component.ex}` and its router entries. Match its socket assigns naming, `handle_params` structure, gettext usage, Tailwind classes, and `FullCircleWeb.Helpers` usage. UI must look right in **both light and dark themes** (existing classes already handle this — reuse them, don't invent new palettes).
- File-format screens are **not** in this phase (they need the Phase 4 renderer for preview; Phase 4 builds them).
- The pay-slip form must never crash on a script error; it shows the error message instead.
- All user-facing strings wrapped in `gettext`.
- Known pre-existing failures: 2 `pay_run_test` failures; credo not installed.

## File Structure

| File | Responsibility |
|---|---|
| `lib/full_circle_web/live/statutory_calc_live/index.ex` | Calc list grouped by code (versions newest-first), search, links to new/edit, bundle export/import section |
| `lib/full_circle_web/live/statutory_calc_live/index_component.ex` | Row component |
| `lib/full_circle_web/live/statutory_calc_live/form.ex` | New-version form: code, name, effective_from, script textarea, preview panel |
| `lib/full_circle_web/live/statutory_rate_table_live/index.ex` | Table list grouped by code |
| `lib/full_circle_web/live/statutory_rate_table_live/index_component.ex` | Row component |
| `lib/full_circle_web/live/statutory_rate_table_live/form.ex` | CSV upload + parsed bracket preview + effective_from |
| `lib/full_circle_web/live/statutory_bundle_live/import.ex` | Bundle upload → validate → diff → Apply |
| Modify: `lib/full_circle_web/router.ex` | live routes |
| Modify: `lib/full_circle/statutory_config.ex` | `preview_calc/5`, `parse_table_csv/1`, `bundle_diff/2` |
| Modify: `lib/full_circle/HR/salary_type.ex` | registry-based `statutory_code` validation |
| Modify: `lib/full_circle/hr.ex` | dynamic `statutory_contributions/3` |
| Modify: `lib/full_circle_web/live/report_live/epf_socso_eis.ex` | dynamic columns |
| Modify: `lib/full_circle_web/live/pay_slip_live/form.ex` (find the `calculate_pay` caller) | rescue `PayScript.Error` → flash |
| Create: `.claude/skills/statutory-bundle.md` | Agent skill for producing bundles |

---

### Task 1: Context support functions (preview, CSV parse, diff)

**Files:**
- Modify: `lib/full_circle/statutory_config.ex`
- Test: extend `test/full_circle/statutory_config_test.exs`

**Interfaces (produced, consumed by the LiveViews below):**
- `StatutoryConfig.preview_calc(script, code, employee, month, year) :: {:ok, Decimal.t()} | {:error, String.t()}` — builds a synthetic pay-slip changeset for the employee/month/year the same way `PaySlipOp.generate_new_changeset_for/5` does its amounts (sum the employee's would-be additions; simplest faithful approach: reuse `StatutoryConfig.script_context/2` with a changeset built from `%{pay_month: month, pay_year: year, addition_amount: <sum of employee salary-type Addition amounts>, bonus_amount: 0}`), evaluates the **given source** (not the saved one) with `DbEnv` — table/other-calc references resolve against saved config. Errors return `Exception.message`.
- `StatutoryConfig.current_value(code, employee, month, year)` — same but using the saved effective script; `nil` when none. (Preview panel shows both side by side.)
- `StatutoryConfig.parse_table_csv(binary) :: {:ok, %{columns: [String.t()], rows: [[float]]}} | {:error, String.t()}` — first line = header (column names), remaining lines numeric; uses `String.split` on `,` with trimming (no CSV dep — reject quoted/embedded-comma content with a clear error since rate tables never need it); errors name the line number.
- `StatutoryConfig.bundle_diff(bundle_map, company_id) :: [%{kind: :table | :calc | :file_format, code: String.t(), effective_from: Date.t(), status: :new | :replaces | :unchanged}]` — `:replaces` when a row with the same `(code, effective_from)` exists with different content, `:unchanged` when identical, `:new` otherwise. Used by the import screen.

- [ ] **Step 1: Failing tests** for the four functions: preview with a known seeded calc equals `calculate/3` on the same inputs; preview of edited source differs; `parse_table_csv` happy path / bad number ("line 3: ...") / short row; `bundle_diff` statuses (seed a company, diff the template → all `:unchanged`; bump one script in the map → that code `:replaces`; add a code → `:new`).
- [ ] **Step 2: verify failures. Step 3: implement. Step 4: green.**
- [ ] **Step 5: Commit** — `git commit -m "feat(statutory): preview, csv parsing and bundle diff support"`

---

### Task 2: Rate table LiveViews (CSV upload + bracket preview)

**Files:**
- Create: `lib/full_circle_web/live/statutory_rate_table_live/{index.ex,index_component.ex,form.ex}`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/live/statutory_rate_table_live_test.exs`

**Routes** (inside the existing `scope "/companies/:company_id", FullCircleWeb do` block, in the authenticated `live_session` all other company LiveViews use — match the `salary_type` route lines exactly):

```elixir
      live "/statutory_rate_tables", StatutoryRateTableLive.Index, :index
      live "/statutory_rate_tables/new", StatutoryRateTableLive.Form, :new
```

**Behavior:**
- Index: rows = `StatutoryConfig.list_versions(:table, company_id)` grouped by `code`; each row shows code, effective_from, column names, row count. No edit/delete of past versions (append-only versioning — corrections are a new version with the same effective_from, which upserts via bundle import, or a later effective_from via this form). A "New Version" button links to the form.
- Form: fields `code` (text input with datalist of existing codes), `effective_from` (date), CSV via `allow_upload(:csv, accept: ~w(.csv .txt), max_entries: 1)`. On upload completion, run `parse_table_csv`, assign `%{columns:, rows:}` and render a **preview table** (all columns, first 15 + last 2 rows, with a row count); validation errors from `save_rate_table` render on the form. Save → `push_navigate` to index with flash.
- Authorization: both mount via the same `Authorization.can?(user, :manage_statutory_config, company)` guard pattern used in `salary_type_live/form.ex` mounts (read it; copy the redirect-if-unauthorized idiom).

**Tests** (`use FullCircleWeb.ConnCase`, `Phoenix.LiveViewTest`, following an existing LiveView test in `test/full_circle_web/live/` as the setup pattern): admin sees index; clerk is redirected; uploading a valid CSV shows the preview and saves (row appears in index); a CSV with a bracket gap shows the changeset error and does not save.

- [ ] Steps: failing tests → verify → implement (copy structure from `salary_type_live`, replacing fields; the upload/preview `handle_event`s are the only novel part) → green → commit `feat(statutory): rate table admin ui with csv upload`.

---

### Task 3: Calc LiveViews (script editor + preview panel)

**Files:**
- Create: `lib/full_circle_web/live/statutory_calc_live/{index.ex,index_component.ex,form.ex}`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/live/statutory_calc_live_test.exs`

**Routes:**

```elixir
      live "/statutory_calcs", StatutoryCalcLive.Index, :index
      live "/statutory_calcs/new", StatutoryCalcLive.Form, :new
```

**Behavior:**
- Index: `list_versions(:calc, company_id)` grouped by code; shows code, name, effective_from, first line of script. "New Version" pre-fills the form with the newest version's script for a chosen code (`/statutory_calcs/new?code=socso_employee`).
- Form: `code`, `name`, `effective_from`, `script` in a `<textarea rows="18" class="font-mono text-sm ...">`. **Preview panel**: employee picker (reuse the app's autocomplete input pattern for employee name — see how `pay_slip_live` or `salary_note` forms do employee lookup and copy that component usage), month + year selects, a "Preview" button → `handle_event("preview", ...)` calls `StatutoryConfig.preview_calc(draft_script, code, employee, month, year)` and `current_value/4`, renders both ("New: 64.10 / Current: 63.80") or the error message in red. Save path = `save_calc/3`; script errors render under the textarea.
- Bundle section on the index page: an "Export bundle" link (`href` to a controller-less LiveView download is awkward — add a small route to the existing `CsvController`-style pattern: `get "/statutory_bundle/export"` in the same scope, a `BundleController.export/2` that sends `Jason.encode!(StatutoryConfig.export_bundle(com_id, Date.utc_today()), pretty: true)` as `application/json` attachment `statutory_bundle_<date>.json`) and an "Import bundle" link to Task 4's screen.

**Tests:** index lists seeded calcs; form saves a new version (visible in index); invalid script shows the PayScript error message; preview event renders a value for a seeded employee; non-admin redirected; export endpoint returns JSON containing `"bundle_version"`.

- [ ] Steps: failing tests → verify → implement → green → commit `feat(statutory): calc admin ui with script preview and bundle export`.

---

### Task 4: Bundle import screen (validate → diff → apply)

**Files:**
- Create: `lib/full_circle_web/live/statutory_bundle_live/import.ex`
- Modify: `lib/full_circle_web/router.ex` (`live "/statutory_bundle/import", StatutoryBundleLive.Import, :new`)
- Test: `test/full_circle_web/live/statutory_bundle_live_test.exs`

**Behavior:** single LiveView, three states in one screen:
1. Upload state: `allow_upload(:bundle, accept: ~w(.json), max_entries: 1)`; on upload, `Jason.decode` (decode error → red message) then `StatutoryConfig.validate_bundle/1`; errors listed verbatim.
2. Diff state (validation passed): render `bundle_diff/2` as a table — kind, code, effective_from, status badge (`new` green / `replaces` amber / `unchanged` gray); an Apply button (disabled when everything is `:unchanged`).
3. Applied state: `import_bundle/3` result counts as a flash + link back to calc index. `:not_authorise` never reachable (mount guard) but handled with a flash anyway.

**Tests:** valid bundle upload shows diff rows and Apply persists (calc_codes grows); invalid bundle (cycle) shows the cycle error and no Apply; unchanged template bundle shows all-unchanged and Apply is disabled.

- [ ] Steps: failing tests → verify → implement → green → commit `feat(statutory): bundle import with diff preview`.

---

### Task 5: SalaryType registry validation + pay-slip error surfacing

**Files:**
- Modify: `lib/full_circle/HR/salary_type.ex`
- Modify: the LiveView that calls `PaySlipOp.calculate_pay/2` (find with `grep -rn "calculate_pay" lib/full_circle_web/` — it's the pay-slip form LiveView)
- Test: extend `test/full_circle/salary_type_statutory_test.exs` (this file already tests statutory_code validation — read it first); extend the pay-slip form LiveView test if one exists, else add a focused test in `test/full_circle/pay_slip_op_test.exs`

**Interfaces / changes:**
- `SalaryType.changeset/2`: replace `validate_inclusion(:statutory_code, @statutory_codes, ...)` with a company-aware check:

```elixir
    |> validate_statutory_code()
...
  defp validate_statutory_code(cs) do
    code = fetch_field!(cs, :statutory_code)
    com_id = fetch_field!(cs, :company_id)

    cond do
      is_nil(code) ->
        cs

      code in @statutory_codes ->
        cs

      not is_nil(com_id) and code in FullCircle.StatutoryConfig.calc_codes(com_id) ->
        cs

      true ->
        add_error(cs, :statutory_code, gettext("is not a valid statutory code"))
    end
  end
```

  Keep `@statutory_codes` as the legacy floor (companies mid-migration); `statutory_codes/0` stays but Phase 4 removes the hardcoded list.
- Pay-slip form: wrap the `calculate_pay` call:

```elixir
    socket =
      try do
        ...existing calculate_pay + assign flow...
      rescue
        e in FullCircle.PayScript.Error ->
          put_flash(socket, :error, Exception.message(e))
      end
```

  (Adapt to the actual `handle_event` shape found; the requirement is: a seeded script that divides by zero produces a flash with `"in '<binding>': division by zero"` and the form stays usable.)

**Tests:** salary type accepts a novel code once a calc with that code is saved for the company, rejects a code that exists in neither the legacy list nor the registry; pay-slip recalculation with a poisoned script (save a calc `result = 1/0` for a code the employee uses) flashes the error and does not crash the LiveView process.

- [ ] Steps: failing tests → verify → implement → green (also rerun `test/full_circle/salary_type_statutory_test.exs` whole file) → commit `feat(statutory): registry-backed statutory codes and script error surfacing`.

---

### Task 6: Dynamic statutory report columns

**Files:**
- Modify: `lib/full_circle/hr.ex` (`statutory_contributions/3`)
- Modify: `lib/full_circle_web/live/report_live/epf_socso_eis.ex`
- Test: extend `test/full_circle/statutory_test.exs` (existing statutory reporting tests — read first)

**Changes:**
- `hr.ex`: replace the `@statutory_categories` module attribute usage:

```elixir
  def statutory_contributions(month, year, com_id) do
    categories = statutory_categories(com_id)
    ...same SQL builder, iterating `categories`...
  end

  def statutory_categories(com_id) do
    (FullCircle.HR.SalaryType.statutory_codes() ++ FullCircle.StatutoryConfig.calc_codes(com_id))
    |> Enum.uniq()
    |> Enum.filter(&Regex.match?(~r/^[a-z0-9_]+$/, &1))
  end
```

  The regex filter is the defense-in-depth for SQL interpolation (changesets already enforce it; filter, don't raise). Keep column order stable: legacy codes first (fixed order), then new codes sorted.
- `epf_socso_eis.ex`: replace any hardcoded per-code column headers/cells with a loop over `HR.statutory_categories(com_id)` (assign `@categories` in `handle_params`), header cells humanized (`String.replace(c, "_", " ") |> String.upcase()`), row cells via `Map.get(row, c)`. Read the current `render/1` first; keep the existing wages/employee columns as-is.
- Tests: seed a company + a novel calc code `hrdf_levy` + a salary type + a pay slip note carrying it → `statutory_contributions/3` result maps include the `"hrdf_levy"` key with the summed amount; a malicious-looking code never reaches SQL (insert a calc row with a bad code directly via Repo to bypass the changeset, assert it is filtered out).

- [ ] Steps: failing tests → verify → implement → green → commit `feat(statutory): dynamic statutory report columns`.

---

### Task 7: `statutory-bundle` project skill

**Files:**
- Create: `.claude/skills/statutory-bundle.md`

Content requirements (write it, using superpowers:writing-skills for structure): frontmatter `name: statutory-bundle`, `description` triggering on "government statutory rate change / SOCSO / EPF / EIS / PCB / SKBBK update / statutory bundle". Body documents: the bundle JSON shape (copy the example from spec section 7), the PayScript grammar summary (statements, operators, builtins with signatures, standard variables — condensed from spec section 2), effective-date semantics, the workflow (export current bundle from the app or start from `priv/statutory_templates/malaysia.json` → edit → `mix statutory.validate bundle.json` → hand to admin for import), and the rule that rates come from official circulars (KWSP/PERKESO/LHDN) with the source recorded in the bundle's `"source"` field. Include one worked example: changing the EPF employee rate.

- [ ] Steps: write skill → verify `mix statutory.validate priv/statutory_templates/malaysia.json` passes (the skill references it) → commit `docs(skill): statutory-bundle agent workflow`.

---

## Out of scope

- File-format admin screen and FileSpec preview — Phase 4.
- Deleting legacy `@statutory_codes` / `SalaryNoteCalFunc` — Phase 4.
- Structured (non-textarea) editors, xlsx renderers, API/MCP push.
