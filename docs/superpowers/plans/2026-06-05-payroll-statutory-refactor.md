# Payroll Statutory Reports Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor EPF/SOCSO/EIS statutory file generation onto a single structured query + tested Elixir formatters keyed by a new `SalaryType.statutory_code`, add the PCB/CP39 file, and auto-fill the employer code per agency.

**Architecture:** Add `statutory_code` to `salary_types` (backfilled from known names). One `HR.statutory_contributions/3` query returns per-employee per-category sums. Per-agency formatter modules turn that into each file; a golden test proves the EPF/SOCSO/EIS output is byte-identical to the current SQL functions (the oracle) before they're deleted. PCB is a new fixed-width formatter verified against the LHDN spec. The report screen auto-fills the employer code per agency from `Sys` settings.

**Tech Stack:** Elixir, Phoenix LiveView, raw SQL via `FullCircle.Helpers.exec_query_map/1` and `exec_query_row_col/1`, `Decimal`, `NimbleCSV`, Ecto migrations, `FullCircle.Sys` settings.

Spec: [docs/superpowers/specs/2026-06-05-payroll-statutory-refactor-design.md](../specs/2026-06-05-payroll-statutory-refactor-design.md).

---

## File Structure

- **Modify** `lib/full_circle/HR/salary_type.ex` — add `statutory_code` field + changeset cast/validation.
- **Create** `priv/repo/migrations/<ts>_add_statutory_code_to_salary_types.exs` — column + backfill.
- **Modify** `lib/full_circle_web/live/salary_type_live/form.ex` — `statutory_code` select.
- **Modify** `lib/full_circle/hr.ex` — add `statutory_contributions/3`; later remove the four `*_submit_file_format_query/4`.
- **Create** `lib/full_circle/hr/statutory/epf_format.ex`, `socso_format.ex`, `eis_format.ex`, `socso_eis_format.ex`, `pcb_format.ex`.
- **Create** `lib/full_circle/hr/statutory.ex` — dispatcher (`file/5`, code-key mapping).
- **Modify** `lib/full_circle_web/controllers/csv_controller.ex` — `epfsocsoeis` branch routes through the dispatcher; PCB downloads as `.txt`.
- **Modify** `lib/full_circle_web/live/report_live/epf_socso_eis.ex` — PCB option, structured preview, per-agency code auto-fill.
- **Modify** `lib/full_circle/sys/user_setting.ex` — `EpfSocsoEis` default settings: add `PCB`, replace single `code` with per-agency codes.
- **Tests:** `test/full_circle/statutory_test.exs` (query + formatters + golden parity + PCB), `test/full_circle/salary_type_statutory_test.exs` (changeset).

**Testing posture:** context/formatter logic is fully TDD'd. The LiveView screen (`epf_socso_eis.ex`) has no company-scoped test harness in this codebase, so it's verified by `mix compile --warnings-as-errors` + manual check (consistent with existing practice).

---

## Task 1: Add `statutory_code` to SalaryType (schema + changeset)

**Files:**
- Modify: `lib/full_circle/HR/salary_type.ex`
- Test: `test/full_circle/salary_type_statutory_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/full_circle/salary_type_statutory_test.exs`:

```elixir
defmodule FullCircle.SalaryTypeStatutoryTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.HR.SalaryType

  defp change(attrs) do
    SalaryType.changeset(%SalaryType{}, Map.merge(%{
      "name" => "X", "type" => "Deduction", "company_id" => Ecto.UUID.generate()
    }, attrs))
  end

  test "accepts a valid statutory_code" do
    cs = change(%{"statutory_code" => "epf_employer"})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :statutory_code) == "epf_employer"
  end

  test "accepts blank/nil statutory_code (non-statutory type)" do
    assert change(%{"statutory_code" => ""}).valid?
    assert change(%{}).valid?
  end

  test "rejects an unknown statutory_code" do
    cs = change(%{"statutory_code" => "bogus"})
    refute cs.valid?
    assert %{statutory_code: _} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle/salary_type_statutory_test.exs`
Expected: FAIL — `statutory_code` is not a field / not cast.

- [ ] **Step 3: Add the field and changeset rules**

In `lib/full_circle/HR/salary_type.ex`, add the field to the schema (after `field(:cal_func, :string)`):

```elixir
    field(:statutory_code, :string)
```

Add a module attribute near the top of the module (after `use`/`import` lines):

```elixir
  @statutory_codes ~w(epf_employer epf_employee socso_employer socso_employee
                      socso_employer_only eis_employer eis_employee eis_employer_only
                      pcb_employee)

  def statutory_codes, do: @statutory_codes
```

In `changeset/2`, add `:statutory_code` to the `cast` list and add a validation after `validate_required(...)`:

```elixir
    |> validate_inclusion(:statutory_code, @statutory_codes,
      message: gettext("is not a valid statutory code")
    )
```

`validate_inclusion` ignores `nil`; treat blank string as nil first by adding, immediately before that line:

```elixir
    |> update_change(:statutory_code, fn v -> if v in ["", nil], do: nil, else: v end)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle/salary_type_statutory_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/HR/salary_type.ex test/full_circle/salary_type_statutory_test.exs
git commit -m "Add statutory_code field + validation to SalaryType"
```

---

## Task 2: Migration — add column + backfill from names

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_statutory_code_to_salary_types.exs`

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration add_statutory_code_to_salary_types`
This creates `priv/repo/migrations/<timestamp>_add_statutory_code_to_salary_types.exs`.

- [ ] **Step 2: Write the migration (column + data backfill)**

Replace the generated file's body with:

```elixir
defmodule FullCircle.Repo.Migrations.AddStatutoryCodeToSalaryTypes do
  use Ecto.Migration

  @map %{
    "epf by employer" => "epf_employer",
    "epf by employee" => "epf_employee",
    "epf employee self" => "epf_employee",
    "socso by employer" => "socso_employer",
    "socso by employee" => "socso_employee",
    "socso employer only" => "socso_employer_only",
    "eis by employer" => "eis_employer",
    "eis by employee" => "eis_employee",
    "eis employer only" => "eis_employer_only",
    "employee pcb" => "pcb_employee"
  }

  def up do
    alter table(:salary_types) do
      add :statutory_code, :string
    end

    flush()

    for {name, code} <- @map do
      execute("""
      update salary_types set statutory_code = '#{code}'
       where lower(name) = '#{name}'
      """)
    end
  end

  def down do
    alter table(:salary_types) do
      remove :statutory_code
    end
  end
end
```

- [ ] **Step 3: Run the migration and verify it applies**

Run: `mix ecto.migrate`
Expected: migration runs without error (`* running ... AddStatutoryCodeToSalaryTypes`).

- [ ] **Step 4: Verify the test DB picks up the column**

Run: `MIX_ENV=test mix ecto.migrate`
Expected: applies cleanly (the column now exists for tests).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations
git commit -m "Migrate: add statutory_code column and backfill from salary-type names"
```

---

## Task 3: `HR.statutory_contributions/3` aggregation query

**Files:**
- Modify: `lib/full_circle/hr.ex`
- Test: `test/full_circle/statutory_test.exs`

- [ ] **Step 1: Add the shared test setup + a failing query test**

Create `test/full_circle/statutory_test.exs`:

```elixir
defmodule FullCircle.StatutoryTest do
  use FullCircle.DataCase

  alias FullCircle.{HR, PaySlipOp, Accounting}
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.HRFixtures

  # Builds: company, a "Salaries and Wages" account, a Monthly Salary type,
  # and the statutory salary types with BOTH legacy name AND statutory_code set.
  def setup_statutory(_ctx) do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    cr_ac = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)
    funds_ac = account_fixture(%{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)
    monthly = HR.get_salary_type_by_name("Monthly Salary", com, admin)

    salary_type_fixture(%{name: "Employee PCB", type: "Deduction", cal_func: "pcb_employee",
      statutory_code: "pcb_employee", db_ac_name: cr_ac.name, db_ac_id: cr_ac.id,
      cr_ac_name: cr_ac.name, cr_ac_id: cr_ac.id}, com, admin)

    stat = fn name, code ->
      salary_type_fixture(%{name: name, type: "Deduction", statutory_code: code,
        db_ac_name: cr_ac.name, db_ac_id: cr_ac.id, cr_ac_name: cr_ac.name, cr_ac_id: cr_ac.id},
        com, admin)
    end

    %{
      admin: admin, com: com, funds_ac: funds_ac, monthly: monthly,
      st: %{
        "EPF By Employer" => stat.("EPF By Employer", "epf_employer"),
        "EPF By Employee" => stat.("EPF By Employee", "epf_employee"),
        "SOCSO By Employer" => stat.("SOCSO By Employer", "socso_employer"),
        "SOCSO By Employee" => stat.("SOCSO By Employee", "socso_employee"),
        "EIS By Employer" => stat.("EIS By Employer", "eis_employer"),
        "EIS By Employee" => stat.("EIS By Employee", "eis_employee")
      }
    }
  end

  # Create a pay slip in (mth/yr) for `emp` with given line amounts:
  # %{"Monthly Salary" => "3000", "EPF By Employer" => "390", ...}
  def slip(emp, mth, yr, lines, ctx) do
    date = Timex.end_of_month(yr, mth)

    additions =
      lines
      |> Enum.filter(fn {n, _} -> n == "Monthly Salary" end)
      |> Enum.with_index()
      |> Map.new(fn {{n, amt}, i} ->
        st = ctx.monthly
        {"#{i}", %{"_id" => nil, "note_no" => "...new...", "note_date" => to_string(date),
          "quantity" => "1", "unit_price" => amt, "amount" => amt,
          "salary_type_name" => n, "salary_type_id" => st.id, "salary_type_type" => "Addition",
          "employee_id" => emp.id, "descriptions" => n}}
      end)

    deductions =
      lines
      |> Enum.reject(fn {n, _} -> n == "Monthly Salary" end)
      |> Enum.with_index()
      |> Map.new(fn {{n, amt}, i} ->
        st = ctx.st[n]
        {"#{i}", %{"_id" => nil, "note_no" => "...new...", "note_date" => to_string(date),
          "quantity" => "1", "unit_price" => amt, "amount" => amt,
          "salary_type_name" => n, "salary_type_id" => st.id, "salary_type_type" => "Deduction",
          "employee_id" => emp.id, "descriptions" => n}}
      end)

    attrs = %{"slip_date" => to_string(date), "pay_month" => to_string(mth),
      "pay_year" => to_string(yr), "employee_name" => emp.name, "employee_id" => emp.id,
      "funds_account_name" => ctx.funds_ac.name, "funds_account_id" => ctx.funds_ac.id,
      "pay_slip_amount" => "0", "additions" => additions, "deductions" => deductions}

    {:ok, %{create_pay_slip: ps}} = PaySlipOp.create_pay_slip(attrs, ctx.com, ctx.admin)
    ps
  end

  describe "statutory_contributions/3" do
    setup :setup_statutory

    test "sums wages and each statutory category per employee", ctx do
      emp = employee_fixture(%{epf_no: "E123", socso_no: "S123", tax_no: "55491986090",
        id_no: "890703085395"}, ctx.com, ctx.admin)

      slip(emp, 5, 2026, %{"Monthly Salary" => "3000", "EPF By Employer" => "390",
        "EPF By Employee" => "330", "SOCSO By Employer" => "51.65",
        "SOCSO By Employee" => "14.75"}, ctx)

      rows = HR.statutory_contributions(5, 2026, ctx.com.id)
      row = Enum.find(rows, &(&1.name == emp.name))

      assert Decimal.eq?(row.wages, Decimal.new("3000"))
      assert Decimal.eq?(row.epf_employer, Decimal.new("390"))
      assert Decimal.eq?(row.epf_employee, Decimal.new("330"))
      assert Decimal.eq?(row.socso_employer, Decimal.new("51.65"))
      assert Decimal.eq?(row.socso_employee, Decimal.new("14.75"))
      assert Decimal.eq?(row.eis_employer, Decimal.new("0"))
      assert row.tax_no == "55491986090"
      assert row.id_no == "890703085395"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: FAIL — `HR.statutory_contributions/3` is undefined.

- [ ] **Step 3: Implement the query**

In `lib/full_circle/hr.ex`, add:

```elixir
  @statutory_categories ~w(epf_employer epf_employee socso_employer socso_employee
                           socso_employer_only eis_employer eis_employee eis_employer_only
                           pcb_employee)

  def statutory_contributions(month, year, com_id) do
    sums =
      Enum.map_join(@statutory_categories, ",\n", fn c ->
        """
        coalesce((select sum(sn.quantity * sn.unit_price)
                    from salary_notes sn join salary_types st on st.id = sn.salary_type_id
                   where sn.pay_slip_id = ps.id and st.statutory_code = '#{c}'), 0) as #{c}
        """
      end)

    """
    select emp.name, emp.id_no, emp.tax_no, emp.socso_no, emp.epf_no, emp.service_since,
           ps.pay_month, ps.pay_year,
           coalesce((select sum(sn.quantity * sn.unit_price)
                       from salary_notes sn join salary_types st on st.id = sn.salary_type_id
                      where sn.pay_slip_id = ps.id and st.type = 'Addition'), 0) as wages,
           #{sums}
      from pay_slips ps join employees emp on emp.id = ps.employee_id
     where ps.pay_month = #{month} and ps.pay_year = #{year} and ps.company_id = '#{com_id}'
     order by emp.name
    """
    |> FullCircle.Helpers.exec_query_map()
  end
```

(`exec_query_map/1` returns a list of maps keyed by atom column name, casting `*_id`/`id` columns; numeric sums come back as `Decimal`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/hr.ex test/full_circle/statutory_test.exs
git commit -m "Add HR.statutory_contributions/3 unified aggregation query"
```

---

## Task 4: EPF/SOCSO/EIS formatters + golden parity vs old SQL

**Files:**
- Create: `lib/full_circle/hr/statutory/epf_format.ex`, `socso_format.ex`, `eis_format.ex`, `socso_eis_format.ex`
- Test: `test/full_circle/statutory_test.exs` (add a `describe`)

The legacy functions (`HR.epf_submit_file_format_query/4` etc., [hr.ex:131-242](../../../lib/full_circle/hr.ex#L131-L242)) are the **oracle**: each new formatter, fed `statutory_contributions/3` output, must return the same `{col, rows}` the legacy function returns for the same data.

- [ ] **Step 1: Write the failing golden test**

Add to `test/full_circle/statutory_test.exs`:

```elixir
  alias FullCircle.HR.Statutory.{EpfFormat, SocsoFormat, EisFormat, SocsoEisFormat}

  # Normalize cells to strings so Decimal vs string differences don't mask real diffs.
  defp norm({col, rows}), do: {col, Enum.map(rows, fn r -> Enum.map(r, &to_string/1) end)}

  describe "formatter parity with legacy SQL" do
    setup :setup_statutory

    setup ctx do
      e1 = employee_fixture(%{name: "Bbb", epf_no: "E1", socso_no: "S1",
        tax_no: "111", id_no: "900101015555"}, ctx.com, ctx.admin)
      e2 = employee_fixture(%{name: "Aaa", epf_no: "E2", socso_no: "",
        tax_no: "222", id_no: "910202025555"}, ctx.com, ctx.admin)

      slip(e1, 5, 2026, %{"Monthly Salary" => "3000", "EPF By Employer" => "390",
        "EPF By Employee" => "330", "SOCSO By Employer" => "51.65", "SOCSO By Employee" => "14.75",
        "EIS By Employer" => "5.90", "EIS By Employee" => "5.90"}, ctx)
      slip(e2, 5, 2026, %{"Monthly Salary" => "2000", "EPF By Employer" => "260",
        "EPF By Employee" => "220", "SOCSO By Employer" => "34.45", "SOCSO By Employee" => "9.85",
        "EIS By Employer" => "3.90", "EIS By Employee" => "3.90"}, ctx)

      contribs = HR.statutory_contributions(5, 2026, ctx.com.id)
      Map.put(ctx, :contribs, contribs)
    end

    test "EPF matches legacy", ctx do
      assert norm(EpfFormat.rows(ctx.contribs, "EPFCODE")) ==
               norm(HR.epf_submit_file_format_query(5, 2026, "EPFCODE", ctx.com.id))
    end

    test "SOCSO matches legacy", ctx do
      assert norm(SocsoFormat.rows(ctx.contribs, "SOCSOCODE")) ==
               norm(HR.socso_submit_file_format_query(5, 2026, "SOCSOCODE", ctx.com.id))
    end

    test "EIS matches legacy", ctx do
      assert norm(EisFormat.rows(ctx.contribs, "EISCODE")) ==
               norm(HR.eis_submit_file_format_query(5, 2026, "EISCODE", ctx.com.id))
    end

    test "SOCSO+EIS matches legacy", ctx do
      assert norm(SocsoEisFormat.rows(ctx.contribs, "EMPCODE")) ==
               norm(HR.socso_eis_submit_file_format_query(5, 2026, "EMPCODE", ctx.com.id))
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: FAIL — the `EpfFormat`/`SocsoFormat`/`EisFormat`/`SocsoEisFormat` modules don't exist.

- [ ] **Step 3: Implement `EpfFormat`**

Create `lib/full_circle/hr/statutory/epf_format.ex`. EPF legacy output columns are
`["epf_no","id_number","name","wages","employer","employee"]`, filtered to rows where
`epf_employer > 0 or epf_employee > 0`, with `wages` rounded to 2 dp and employer/employee to 0 dp:

```elixir
defmodule FullCircle.HR.Statutory.EpfFormat do
  @moduledoc "EPF (KWSP) submission rows. Output mirrors the legacy epf_submit_file_format_query."

  @cols ["epf_no", "id_number", "name", "wages", "employer", "employee"]

  # _code is unused for EPF (the legacy query computes but never emits it).
  def rows(contribs, _code) do
    rows =
      contribs
      |> Enum.filter(fn c -> pos?(c.epf_employer) or pos?(c.epf_employee) end)
      |> Enum.map(fn c ->
        [
          c.epf_no,
          c.id_no,
          c.name,
          Decimal.round(to_dec(c.wages), 2),
          Decimal.round(to_dec(c.epf_employer), 0),
          Decimal.round(to_dec(c.epf_employee), 0)
        ]
      end)

    {@cols, rows}
  end

  defp to_dec(%Decimal{} = d), do: d
  defp to_dec(n), do: Decimal.new("#{n}")
  defp pos?(v), do: Decimal.gt?(to_dec(v), 0)
end
```

- [ ] **Step 4: Implement the fixed-width formatters**

Create `lib/full_circle/hr/statutory/socso_format.ex`:

```elixir
defmodule FullCircle.HR.Statutory.SocsoFormat do
  @moduledoc "SOCSO submission. Single 'textstr' fixed-width line per employee, mirroring legacy."
  import FullCircle.HR.Statutory.FixedWidth

  def rows(contribs, code) do
    lines =
      contribs
      |> Enum.filter(fn c ->
        pos?(c.socso_employer) or pos?(c.socso_employee) or pos?(c.socso_employer_only)
      end)
      |> Enum.map(fn c ->
        total = c.socso_employer |> dec() |> add(c.socso_employee) |> add(c.socso_employer_only)

        [
          pad_t(code, 12),
          pad_t("", 20),
          pad_t(String.replace(idnum(c), "-", ""), 12),
          pad_t(String.upcase(c.name), 150),
          two(c.pay_month),
          four(c.pay_year),
          cents(total, 14),
          pad_t("", 9)
        ]
        |> Enum.join()
      end)
      |> Enum.map(&[&1])

    {["textstr"], lines}
  end
end
```

Create `lib/full_circle/hr/statutory/eis_format.ex` (identical shape, EIS amounts):

```elixir
defmodule FullCircle.HR.Statutory.EisFormat do
  @moduledoc "EIS submission. Single 'textstr' fixed-width line per employee, mirroring legacy."
  import FullCircle.HR.Statutory.FixedWidth

  def rows(contribs, code) do
    lines =
      contribs
      |> Enum.filter(fn c ->
        pos?(c.eis_employer) or pos?(c.eis_employee) or pos?(c.eis_employer_only)
      end)
      |> Enum.map(fn c ->
        total = c.eis_employer |> dec() |> add(c.eis_employee) |> add(c.eis_employer_only)

        [
          pad_t(code, 12),
          pad_t("", 20),
          pad_t(String.replace(idnum(c), "-", ""), 12),
          pad_t(String.upcase(c.name), 150),
          two(c.pay_month),
          four(c.pay_year),
          cents(total, 14),
          pad_t("", 9)
        ]
        |> Enum.join()
      end)
      |> Enum.map(&[&1])

    {["textstr"], lines}
  end
end
```

Create `lib/full_circle/hr/statutory/socso_eis_format.ex`:

```elixir
defmodule FullCircle.HR.Statutory.SocsoEisFormat do
  @moduledoc "Combined SOCSO+EIS submission line, mirroring legacy socso_eis_submit_file_format_query."
  import FullCircle.HR.Statutory.FixedWidth

  def rows(contribs, code) do
    lines =
      contribs
      |> Enum.filter(fn c ->
        pos?(c.socso_employer) or pos?(c.socso_employee) or pos?(c.socso_employer_only) or
          pos?(c.eis_employer) or pos?(c.eis_employee) or pos?(c.eis_employer_only)
      end)
      |> Enum.map(fn c ->
        socso_er = c.socso_employer |> dec() |> add(c.socso_employer_only)
        eis_er = c.eis_employer |> dec() |> add(c.eis_employer_only)

        [
          pad_t(code, 12),
          pad_t("", 20),
          pad_t(String.replace(idnum(c), "-", ""), 12),
          pad_t(String.upcase(c.name), 150),
          two(c.pay_month),
          four(c.pay_year),
          cents(c.wages, 14),
          cents(socso_er, 6),
          cents(c.socso_employee, 6),
          cents(eis_er, 6),
          cents(c.eis_employee, 6),
          pad_t("", 40)
        ]
        |> Enum.join()
      end)
      |> Enum.map(&[&1])

    {["textstr"], lines}
  end
end
```

Create the shared helper `lib/full_circle/hr/statutory/fixed_width.ex`:

```elixir
defmodule FullCircle.HR.Statutory.FixedWidth do
  @moduledoc "Padding/number helpers shared by the fixed-width statutory formatters."

  def dec(%Decimal{} = d), do: d
  def dec(nil), do: Decimal.new(0)
  def dec(n), do: Decimal.new("#{n}")

  def add(a, b), do: Decimal.add(dec(a), dec(b))
  def pos?(v), do: Decimal.gt?(dec(v), 0)

  # SOCSO/EIS legacy: id_number = socso_no, falling back to id_no when blank/"-"/null.
  def idnum(%{socso_no: s, id_no: id}) do
    case s do
      nil -> id
      "" -> id
      "-" -> id
      v -> v
    end
  end

  def pad_t(str, n), do: String.pad_trailing(to_string(str), n)

  # to_char(month,'00') |> trim  -> 2-digit zero-padded
  def two(n), do: String.pad_leading("#{n}", 2, "0")
  def four(n), do: String.pad_leading("#{n}", 4, "0")

  # to_char(amount*100,'0...0') |> trim : amount in cents, zero-padded to width.
  def cents(amount, width) do
    cents = dec(amount) |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    String.pad_leading(Integer.to_string(cents), width, "0")
  end
end
```

- [ ] **Step 5: Run the golden tests; iterate until byte-identical**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: PASS. If a parity assertion fails, the diff shows exactly which field differs — adjust the formatter (rounding, padding width, upcase, id fallback) until each `norm(Format.rows(...)) == norm(legacy(...))`. Do not change the legacy functions.

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle/hr/statutory test/full_circle/statutory_test.exs
git commit -m "Add EPF/SOCSO/EIS Elixir formatters with golden parity tests"
```

---

## Task 5: PCB / CP39 formatter

**Files:**
- Create: `lib/full_circle/hr/statutory/pcb_format.ex`
- Test: `test/full_circle/statutory_test.exs` (add a `describe`)

CP39 spec (LHDN e-Data PCB manual, verified against real files): ASCII, CRLF lines, amounts in cents.
Header (57): `H` + tin(10) + tin(10) + year(4) + month(2) + totalPcbCents(10) + countPcb(5) + totalCp38Cents(10) + countCp38(5).
Detail (136): `D` + taxno(11,zero-pad) + name(60,space-pad) + kpLama(12,blank) + kpBaru(12,id_no) + passport(12,blank) + `MY`(2) + pcbCents(8) + cp38Cents(8,`0`) + noPekerja(10,blank). CP38 always 0. Only employees with `pcb_employee > 0` are included.

- [ ] **Step 1: Write the failing test**

Add to `test/full_circle/statutory_test.exs`:

```elixir
  alias FullCircle.HR.Statutory.PcbFormat

  describe "PcbFormat (CP39 / e-Data PCB)" do
    setup :setup_statutory

    test "produces a spec-correct header and detail lines", ctx do
      e1 = employee_fixture(%{name: "Nasrul Bin Nayan", tax_no: "55491986090",
        id_no: "890703085395"}, ctx.com, ctx.admin)
      e2 = employee_fixture(%{name: "Tan Su Yen", tax_no: "50358107000",
        id_no: "001206080961"}, ctx.com, ctx.admin)
      # employee with zero PCB must be excluded
      e3 = employee_fixture(%{name: "Zero Pcb", tax_no: "999", id_no: "000101010000"}, ctx.com, ctx.admin)

      slip(e1, 4, 2026, %{"Monthly Salary" => "5000", "Employee PCB" => "79.20"}, ctx)
      slip(e2, 4, 2026, %{"Monthly Salary" => "8000", "Employee PCB" => "318.90"}, ctx)
      slip(e3, 4, 2026, %{"Monthly Salary" => "1000"}, ctx)

      contribs = HR.statutory_contributions(4, 2026, ctx.com.id)
      text = PcbFormat.text(contribs, "0093787203", 4, 2026)
      lines = String.split(text, "\r\n", trim: true)

      # CRLF used, no other line endings
      assert text =~ "\r\n"
      refute String.contains?(String.replace(text, "\r\n", ""), "\n")

      [header | details] = lines
      assert String.length(header) == 57
      # H + tin(10) + tin(10) + year(4) + month(2) is fully deterministic:
      assert String.starts_with?(header, "H00937872030093787203202604")
      assert String.slice(header, 1, 10) == "0093787203"
      assert String.slice(header, 11, 10) == "0093787203"
      assert String.slice(header, 21, 4) == "2026"
      assert String.slice(header, 25, 2) == "04"
      assert String.slice(header, 27, 10) == "0000039810"  # 79.20 + 318.90 = 398.10 -> 39810 cents
      assert String.slice(header, 37, 5) == "00002"        # 2 PCB records
      assert String.slice(header, 42, 10) == "0000000000"  # total CP38 = 0
      assert String.slice(header, 52, 5) == "00000"        # 0 CP38 records

      assert length(details) == 2                          # e3 excluded (zero PCB)
      d = Enum.find(details, &String.contains?(&1, "Nasrul"))
      assert String.length(d) == 136
      assert String.starts_with?(d, "D55491986090")        # D + 11-char tax no
      assert String.slice(d, 12, 60) == String.pad_trailing("Nasrul Bin Nayan", 60)
      assert String.slice(d, 72, 12) == String.pad_trailing("", 12)   # KP Lama blank
      assert String.slice(d, 84, 12) == "890703085395"               # KP Baru = IC
      assert String.slice(d, 96, 12) == String.pad_trailing("", 12)   # passport blank
      assert String.slice(d, 108, 2) == "MY"
      assert String.slice(d, 110, 8) == "00007920"                    # 79.20 -> cents
      assert String.slice(d, 118, 8) == "00000000"                    # CP38
      assert String.slice(d, 126, 10) == String.pad_trailing("", 10)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: FAIL — `PcbFormat` is undefined.

- [ ] **Step 3: Implement `PcbFormat`**

Create `lib/full_circle/hr/statutory/pcb_format.ex`:

```elixir
defmodule FullCircle.HR.Statutory.PcbFormat do
  @moduledoc """
  LHDN e-Data PCB (CP39) monthly file. ASCII, CRLF line endings, amounts in cents.
  Header 57 chars; detail 136 chars. CP38 is always zero (system computes PCB only).
  """
  import FullCircle.HR.Statutory.FixedWidth, only: [dec: 1, pos?: 1]

  @doc "Full file text. `tin` = 10-digit employer TIN (digits of the E-number)."
  def text(contribs, tin, month, year) do
    details = Enum.filter(contribs, fn c -> pos?(c.pcb_employee) end)

    total_cents =
      details
      |> Enum.reduce(Decimal.new(0), fn c, acc -> Decimal.add(acc, dec(c.pcb_employee)) end)
      |> to_cents()

    header =
      "H" <>
        pad0(tin, 10) <>
        pad0(tin, 10) <>
        pad0(year, 4) <>
        pad0(month, 2) <>
        zfill(total_cents, 10) <>
        zfill(length(details), 5) <>
        zfill(0, 10) <>
        zfill(0, 5)

    detail_lines = Enum.map(details, &detail/1)

    ([header] ++ detail_lines)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  @doc "Filename matching the existing tool: `pcb List_<YYYYMMDDhhmmss>.txt`."
  def filename(now \\ NaiveDateTime.utc_now()) do
    stamp = Calendar.strftime(now, "%Y%m%d%H%M%S")
    "pcb List_#{stamp}.txt"
  end

  defp detail(c) do
    "D" <>
      pad0(digits(c.tax_no), 11) <>
      String.pad_trailing(c.name, 60) <>
      String.pad_trailing("", 12) <>
      String.pad_trailing(digits(c.id_no), 12) <>
      String.pad_trailing("", 12) <>
      "MY" <>
      zfill(to_cents(c.pcb_employee), 8) <>
      zfill(0, 8) <>
      String.pad_trailing("", 10)
  end

  defp to_cents(amount), do: dec(amount) |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
  defp digits(nil), do: ""
  defp digits(s), do: String.replace(to_string(s), ~r/[^0-9]/, "")
  defp pad0(v, n), do: String.pad_leading(digits(v), n, "0")
  defp zfill(int, n), do: String.pad_leading(Integer.to_string(int), n, "0")
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/hr/statutory/pcb_format.ex test/full_circle/statutory_test.exs
git commit -m "Add PCB/CP39 e-Data formatter with spec-verified tests"
```

---

## Task 6: Dispatcher + CSV controller wiring; remove legacy SQL

**Files:**
- Create: `lib/full_circle/hr/statutory.ex`
- Modify: `lib/full_circle_web/controllers/csv_controller.ex`
- Modify: `lib/full_circle/hr.ex` (remove the four legacy functions)
- Test: `test/full_circle/statutory_test.exs` (dispatcher describe)

- [ ] **Step 1: Write a failing dispatcher test**

Add to `test/full_circle/statutory_test.exs`:

```elixir
  alias FullCircle.HR.Statutory

  describe "Statutory dispatcher" do
    setup :setup_statutory

    test "report->setting-key mapping" do
      assert Statutory.code_key("EPF") == "epf_code"
      assert Statutory.code_key("SOCSO") == "socso_code"
      assert Statutory.code_key("EIS") == "eis_code"
      assert Statutory.code_key("SOCSO+EIS") == "socso_code"
      assert Statutory.code_key("PCB") == "pcb_code"
    end

    test "rows/5 returns {col, rows} for EPF", ctx do
      e1 = employee_fixture(%{name: "Aaa", epf_no: "E1", tax_no: "1", id_no: "900101015555"}, ctx.com, ctx.admin)
      slip(e1, 5, 2026, %{"Monthly Salary" => "3000", "EPF By Employee" => "330"}, ctx)
      {col, rows} = Statutory.rows("EPF", 5, 2026, "EPFCODE", ctx.com.id)
      assert col == ["epf_no", "id_number", "name", "wages", "employer", "employee"]
      assert length(rows) == 1
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: FAIL — `FullCircle.HR.Statutory` is undefined.

- [ ] **Step 3: Implement the dispatcher**

Create `lib/full_circle/hr/statutory.ex`:

```elixir
defmodule FullCircle.HR.Statutory do
  @moduledoc "Entry point for statutory submission files (EPF/SOCSO/EIS/SOCSO+EIS/PCB)."

  alias FullCircle.HR
  alias FullCircle.HR.Statutory.{EpfFormat, SocsoFormat, EisFormat, SocsoEisFormat, PcbFormat}

  @doc "Settings key holding the employer code for a report."
  def code_key("EPF"), do: "epf_code"
  def code_key("SOCSO"), do: "socso_code"
  def code_key("EIS"), do: "eis_code"
  def code_key("SOCSO+EIS"), do: "socso_code"
  def code_key("PCB"), do: "pcb_code"

  @doc "{col, rows} for the CSV-style reports (EPF/SOCSO/EIS/SOCSO+EIS)."
  def rows(report, month, year, code, com_id) do
    contribs = HR.statutory_contributions(month, year, com_id)

    case report do
      "EPF" -> EpfFormat.rows(contribs, code)
      "SOCSO" -> SocsoFormat.rows(contribs, code)
      "EIS" -> EisFormat.rows(contribs, code)
      "SOCSO+EIS" -> SocsoEisFormat.rows(contribs, code)
    end
  end

  @doc "Raw CP39 text for PCB."
  def pcb_text(month, year, code, com_id) do
    contribs = HR.statutory_contributions(month, year, com_id)
    PcbFormat.text(contribs, code, month, year)
  end
end
```

- [ ] **Step 4: Run the dispatcher test**

Run: `mix test test/full_circle/statutory_test.exs`
Expected: PASS.

- [ ] **Step 5: Wire the CSV controller**

In `lib/full_circle_web/controllers/csv_controller.ex`, replace the `report => "epfsocsoeis"` clause
(lines 4-53) with:

```elixir
  def show(conn, %{
        "company_id" => com_id,
        "report" => "epfsocsoeis",
        "rep" => "PCB",
        "code" => code,
        "month" => month,
        "year" => year
      }) do
    text = FullCircle.HR.Statutory.pcb_text(String.to_integer(month), String.to_integer(year), code, com_id)

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("content-disposition",
      "attachment; filename=\"#{FullCircle.HR.Statutory.PcbFormat.filename()}\"")
    |> put_root_layout(false)
    |> send_resp(200, text)
  end

  def show(conn, %{
        "company_id" => com_id,
        "report" => "epfsocsoeis",
        "rep" => rep,
        "code" => code,
        "month" => month,
        "year" => year
      }) do
    {col, row} =
      FullCircle.HR.Statutory.rows(rep, String.to_integer(month), String.to_integer(year), code, com_id)

    send_csv_row_col(conn, row, col, "#{rep}_#{month}_#{year}")
  end
```

- [ ] **Step 6: Remove the legacy SQL functions**

In `lib/full_circle/hr.ex`, delete `epf_submit_file_format_query/4`, `socso_submit_file_format_query/4`,
`eis_submit_file_format_query/4`, and `socso_eis_submit_file_format_query/4` (the legacy oracle is no
longer referenced by app code). Update the golden parity test from Task 4: since the oracle functions
are gone, **freeze** the now-passing expected output by capturing it. Replace each parity assertion's
right-hand side with the previously-captured expected `{col, rows}` value inlined into the test (run
the test once before deletion, copy the actual values). This keeps the formatters under regression test
without the legacy code.

> If inlining the frozen expected values is impractical for the SOCSO/EIS 150-char lines, instead keep
> the four legacy private functions in a test-support module `test/support/legacy_statutory.ex` and have
> the parity test call those. Choose whichever the implementer finds cleaner; the requirement is that the
> parity tests still run after the app no longer uses the legacy code.

- [ ] **Step 7: Run the full statutory suite + compile**

Run: `mix test test/full_circle/statutory_test.exs && mix compile --warnings-as-errors`
Expected: PASS and clean compile.

- [ ] **Step 8: Commit**

```bash
git add lib/full_circle/hr/statutory.ex lib/full_circle_web/controllers/csv_controller.ex lib/full_circle/hr.ex test
git commit -m "Route statutory downloads through dispatcher; add PCB download; remove legacy SQL"
```

---

## Task 7: Per-agency code settings + LiveView (PCB option, auto-fill, preview)

**Files:**
- Modify: `lib/full_circle/sys/user_setting.ex` (EpfSocsoEis default settings)
- Modify: `lib/full_circle_web/live/report_live/epf_socso_eis.ex`
- Modify: `lib/full_circle_web/live/salary_type_live/form.ex` (statutory_code select)

- [ ] **Step 1: Update default settings (PCB + per-agency codes)**

In `lib/full_circle/sys/user_setting.ex`, replace the `default_settings("EpfSocsoEis", cuid)` clause
with:

```elixir
  def default_settings("EpfSocsoEis", cuid) do
    [
      %{page: "EpfSocsoEis", code: "report", display_name: "Report",
        values: %{"EPF" => "EPF", "SOCSO" => "SOCSO", "EIS" => "EIS",
                  "SOCSO+EIS" => "SOCSO+EIS", "PCB" => "PCB"},
        value: "EPF", company_user_id: cuid},
      %{page: "EpfSocsoEis", code: "epf_code", display_name: "EPF Employer No.",
        values: %{"default" => ""}, value: "", company_user_id: cuid},
      %{page: "EpfSocsoEis", code: "socso_code", display_name: "SOCSO Employer Code",
        values: %{"default" => ""}, value: "", company_user_id: cuid},
      %{page: "EpfSocsoEis", code: "eis_code", display_name: "EIS Employer Code",
        values: %{"default" => ""}, value: "", company_user_id: cuid},
      %{page: "EpfSocsoEis", code: "pcb_code", display_name: "PCB Employer TIN",
        values: %{"default" => ""}, value: "", company_user_id: cuid}
    ]
  end
```

> Existing companies already have the old `report`/`code` settings rows; `load_settings` only inserts
> defaults when **none** exist for the page. Add a tiny helper so missing per-agency keys are tolerated:
> the LiveView reads codes with a safe default (see Step 2), so no data migration of settings is needed.

- [ ] **Step 2: Rewrite the LiveView to auto-fill the code per agency**

In `lib/full_circle_web/live/report_live/epf_socso_eis.ex`, make these changes:

Replace `handle_params/3`, `persist_settings/2`, and `find_setting/2` with code that resolves the code
from the report-specific key and persists it back:

```elixir
  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"] || %{}

    report = params["report"] || setting_value(socket.assigns.settings, "report", "EPF")
    month = params["month"] || Timex.today().month
    year = params["year"] || Timex.today().year
    code = params["code"] || setting_value(socket.assigns.settings, code_key(report), "")

    {:noreply,
     socket
     |> assign(search: %{report: report, month: month, year: year, code: code})
     |> persist_settings(report, code)
     |> filter_transactions(report, month, year, code)}
  end

  defp code_key(report), do: FullCircle.HR.Statutory.code_key(report)

  defp setting_value(settings, key, default) do
    case Enum.find(settings, fn s -> s.code == key end) do
      nil -> default
      s -> s.value
    end
  end

  defp persist_settings(socket, report, code) do
    settings =
      Enum.map(socket.assigns.settings, fn s ->
        cond do
          s.code == "report" and s.value != report -> FullCircle.Sys.update_setting(s, report)
          s.code == code_key(report) and s.value != code -> FullCircle.Sys.update_setting(s, code)
          true -> s
        end
      end)

    assign(socket, settings: settings)
  end
```

In `handle_event("query", ...)`, the existing code already pushes `report/month/year/code` into the
URL — leave it. Add a `handle_event("changed", ...)` body that auto-fills the code when the report
select changes (replace the existing no-op `changed` handler):

```elixir
  @impl true
  def handle_event("changed", %{"search" => %{"report" => report}}, socket) do
    code = setting_value(socket.assigns.settings, code_key(report), "")

    {:noreply,
     socket
     |> assign(search: %{socket.assigns.search | report: report, code: code})
     |> assign(row: [])
     |> assign(col: [])}
  end

  @impl true
  def handle_event("changed", _params, socket) do
    {:noreply, socket |> assign(row: []) |> assign(col: [])}
  end
```

In `filter_transactions/5`, replace the `cond` over the four legacy `HR.*_query` calls with a single
dispatch plus PCB handling:

```elixir
  defp filter_transactions(socket, report, month, year, code) do
    {col, row} =
      if report == "PCB" do
        text =
          FullCircle.HR.Statutory.pcb_text(
            String.to_integer("#{month}"), String.to_integer("#{year}"), code,
            socket.assigns.current_company.id
          )

        rows = text |> String.split("\r\n", trim: true) |> Enum.map(&[&1])
        {["textstr"], rows}
      else
        FullCircle.HR.Statutory.rows(
          report, String.to_integer("#{month}"), String.to_integer("#{year}"), code,
          socket.assigns.current_company.id
        )
      end

    socket
    |> assign(row: row)
    |> assign(col: col)
    |> assign(row_count: Enum.count(row))
  end
```

Add `PCB` to the report select `options` in `render/1` (the `<.input name="search[report]" ...>`):

```elixir
                options={["EPF", "SOCSO", "EIS", "SOCSO+EIS", "PCB"]}
```

- [ ] **Step 3: Add the statutory_code select to the salary-type form**

In `lib/full_circle_web/live/salary_type_live/form.ex`, after the `cal_func` input block
(`<.input field={@form[:cal_func]} ... />`), add a select:

```elixir
          <div class="col-span-4">
            <.input
              field={@form[:statutory_code]}
              type="select"
              label={gettext("Statutory Code")}
              prompt={gettext("— none —")}
              options={FullCircle.HR.SalaryType.statutory_codes()}
            />
          </div>
```

(Adjust the surrounding grid `col-span-*` if needed so the row still fits 12 columns.)

- [ ] **Step 4: Compile and verify no warnings**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 5: Manual verification in the running app**

Run `iex -S mix phx.server`, open `…/companies/<id>/epfsocsoeis`, and confirm:
- The report dropdown includes **PCB**; switching report auto-fills the saved code for that agency.
- Editing the code and clicking Query persists it (re-selecting that report shows the saved value).
- EPF/SOCSO/EIS/SOCSO+EIS preview + CSV download still work; PCB shows the H/D lines and the CSV link
  downloads a `pcb List_*.txt` file with CRLF lines.
- On the salary-type form, the **Statutory Code** select shows the options and saves.

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle/sys/user_setting.ex lib/full_circle_web/live/report_live/epf_socso_eis.ex lib/full_circle_web/live/salary_type_live/form.ex
git commit -m "Statutory report: PCB option, per-agency code auto-fill, statutory_code select"
```

---

## Self-Review Notes

- **Spec coverage:** `statutory_code` field + form (T1, T7) + backfill migration (T2); unified
  `statutory_contributions/3` (T3); per-agency Elixir formatters (T4) + PCB/CP39 (T5); dispatcher +
  CSV wiring + legacy removal (T6); per-agency stored codes + auto-fill + PCB option + preview (T7).
  Byte-identical requirement enforced by the golden parity tests (T4). PCB verified against the
  documented spec with synthetic data; **no real PII files are committed**.
- **Oracle removal:** T6 Step 6 explicitly preserves the parity tests after deleting the legacy
  functions (frozen expected values or a test-support copy).
- **Type consistency:** formatters consume the `statutory_contributions/3` map keys (`:name, :id_no,
  :tax_no, :socso_no, :epf_no, :wages, :pay_month, :pay_year, :epf_employer, :epf_employee,
  :socso_employer, :socso_employee, :socso_employer_only, :eis_employer, :eis_employee,
  :eis_employer_only, :pcb_employee`); the dispatcher returns `{col, rows}` for CSV reports and raw
  text for PCB; `code_key/1` values match the settings keys added in T7.
- **Known follow-ups (out of scope):** one-screen-all-agencies, default-to-last-month, CP38.
