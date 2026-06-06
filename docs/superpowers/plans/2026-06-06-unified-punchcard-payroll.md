# Unified PunchCard Payroll Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PunchCard screen the single per-employee/month payroll workspace — pick payment account, Calculate/Recal statutory (in-memory preview + net pay), mark "Correct", and Pay — backed by a new `pay_preps` confirmation record with context-level auto-clear.

**Architecture:** A new `PayPrep` schema/table (`company × employee × pay_month × pay_year` → payment account + `verified` flag). Editing notes/advances (public context ops) auto-clears `verified`. New tested `PaySlipOp.preview/5` and `PaySlipOp.pay/6` wrappers reuse the existing payroll engine. The PunchCard LiveView wires these together (account, calculate, correct, pay, stale warning).

**Tech Stack:** Elixir, Phoenix LiveView, Ecto (binary_id schemas via `use FullCircle.Schema`), `Decimal`, `Ecto.Multi`, `PaySlipOp`.

Spec: [docs/superpowers/specs/2026-06-06-unified-punchcard-payroll-design.md](../specs/2026-06-06-unified-punchcard-payroll-design.md).

---

## File Structure

- **Create** `lib/full_circle/HR/pay_prep.ex` — `PayPrep` schema + changeset.
- **Create** `priv/repo/migrations/<ts>_create_pay_preps.exs` — table + unique index.
- **Modify** `lib/full_circle/hr.ex` — pay_prep context fns + auto-clear hooks in public note/advance ops.
- **Modify** `lib/full_circle/pay_slip_op.ex` — `preview/5`, `pay/6`, `changeset_to_pay_attrs/3`.
- **Modify** `lib/full_circle_web/live/time_attend_live/punch_card.ex` — account/calculate/correct/pay/stale UI.
- **Tests:** `test/full_circle/pay_prep_test.exs`, additions to `test/full_circle/pay_slip_op_test.exs`.

**Testing posture:** Tasks 1–4 (schema, context, auto-clear, PaySlipOp wrappers) are fully TDD'd — that's where correctness lives. Task 5 (LiveView) is verified by `mix compile --warnings-as-errors` + manual, per the codebase's lack of company-scoped LiveView tests.

---

## Task 1: `PayPrep` schema + migration

**Files:**
- Create: `lib/full_circle/HR/pay_prep.ex`
- Create: `priv/repo/migrations/<ts>_create_pay_preps.exs`
- Test: `test/full_circle/pay_prep_test.exs`

- [ ] **Step 1: Write the failing changeset test**

Create `test/full_circle/pay_prep_test.exs`:

```elixir
defmodule FullCircle.PayPrepTest do
  use FullCircle.DataCase, async: true

  alias FullCircle.HR.PayPrep

  defp base(attrs) do
    PayPrep.changeset(%PayPrep{}, Map.merge(%{
      "company_id" => Ecto.UUID.generate(),
      "employee_id" => Ecto.UUID.generate(),
      "pay_month" => 5,
      "pay_year" => 2026
    }, attrs))
  end

  test "valid without verification" do
    assert base(%{}).valid?
  end

  test "verified=true requires a funds_account_id" do
    refute base(%{"verified" => true}).valid?
    assert base(%{"verified" => true, "funds_account_id" => Ecto.UUID.generate()}).valid?
  end

  test "requires period and scope" do
    refute PayPrep.changeset(%PayPrep{}, %{}).valid?
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/full_circle/pay_prep_test.exs`
Expected: FAIL — `FullCircle.HR.PayPrep` does not exist.

- [ ] **Step 3: Create the schema**

Create `lib/full_circle/HR/pay_prep.ex`:

```elixir
defmodule FullCircle.HR.PayPrep do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "pay_preps" do
    field(:pay_month, :integer)
    field(:pay_year, :integer)
    field(:verified, :boolean, default: false)
    field(:verified_at, :utc_datetime)

    belongs_to(:company, FullCircle.Sys.Company)
    belongs_to(:employee, FullCircle.HR.Employee)
    belongs_to(:funds_account, FullCircle.Accounting.Account)
    belongs_to(:verified_by, FullCircle.UserAccounts.User)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(pp, attrs) do
    pp
    |> cast(attrs, [
      :pay_month,
      :pay_year,
      :verified,
      :verified_at,
      :company_id,
      :employee_id,
      :funds_account_id,
      :verified_by_id
    ])
    |> validate_required([:pay_month, :pay_year, :company_id, :employee_id])
    |> validate_inclusion(:pay_month, 1..12)
    |> then(fn cs ->
      if get_field(cs, :verified) do
        validate_required(cs, [:funds_account_id])
      else
        cs
      end
    end)
    |> unique_constraint([:company_id, :employee_id, :pay_month, :pay_year],
      name: :pay_preps_unique_period,
      message: "already exists"
    )
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/pay_prep_test.exs`
Expected: PASS.

- [ ] **Step 5: Create the migration**

Run: `mix ecto.gen.migration create_pay_preps`, then replace its body:

```elixir
defmodule FullCircle.Repo.Migrations.CreatePayPreps do
  use Ecto.Migration

  def change do
    create table(:pay_preps) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all), null: false
      add :employee_id, references(:employees, type: :binary_id, on_delete: :delete_all), null: false
      add :funds_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)
      add :verified_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :pay_month, :integer, null: false
      add :pay_year, :integer, null: false
      add :verified, :boolean, null: false, default: false
      add :verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pay_preps, [:company_id, :employee_id, :pay_month, :pay_year],
             name: :pay_preps_unique_period
           )
  end
end
```

- [ ] **Step 6: Migrate dev + test DBs**

Run: `mix ecto.migrate && MIX_ENV=test mix ecto.migrate`
Expected: both apply cleanly.

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle/HR/pay_prep.ex priv/repo/migrations test/full_circle/pay_prep_test.exs
git commit -m "Add PayPrep schema + pay_preps table"
```

---

## Task 2: pay_prep context functions

**Files:**
- Modify: `lib/full_circle/hr.ex`
- Test: `test/full_circle/pay_prep_test.exs`

- [ ] **Step 1: Write failing context tests**

Append to `test/full_circle/pay_prep_test.exs`:

```elixir
  describe "pay_prep context" do
    import FullCircle.SysFixtures
    import FullCircle.UserAccountsFixtures
    import FullCircle.HRFixtures
    alias FullCircle.HR

    setup do
      admin = user_fixture()
      com = company_fixture(admin, %{})
      emp = employee_fixture(%{}, com, admin)
      %{admin: admin, com: com, emp: emp}
    end

    test "get_or_init returns an unsaved struct when none exists", %{com: com, emp: emp} do
      pp = HR.get_or_init_pay_prep(emp.id, 5, 2026, com)
      assert pp.pay_month == 5 and pp.pay_year == 2026
      assert is_nil(pp.id)
      refute pp.verified
    end

    test "set account persists and round-trips", %{com: com, emp: emp, admin: admin} do
      {:ok, pp} = HR.set_pay_prep_account(emp.id, 5, 2026, Ecto.UUID.generate(), com, admin)
      assert pp.id
      assert HR.get_or_init_pay_prep(emp.id, 5, 2026, com).funds_account_id == pp.funds_account_id
    end

    test "set verified records audit; clear unsets", %{com: com, emp: emp, admin: admin} do
      acc = Ecto.UUID.generate()
      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, acc, com, admin)
      {:ok, pp} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      assert pp.verified and pp.verified_by_id == admin.id and pp.verified_at

      HR.clear_pay_prep(com, emp.id, 5, 2026)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/pay_prep_test.exs`
Expected: FAIL — `HR.get_or_init_pay_prep/4` undefined.

- [ ] **Step 3: Implement the context functions**

Add to `lib/full_circle/hr.ex` (ensure `alias FullCircle.HR.PayPrep` exists near the top with the other aliases; if HR aliases schemas inline, use the fully-qualified name instead):

```elixir
  def get_or_init_pay_prep(employee_id, month, year, com) do
    Repo.get_by(FullCircle.HR.PayPrep,
      company_id: com.id,
      employee_id: employee_id,
      pay_month: month,
      pay_year: year
    ) ||
      %FullCircle.HR.PayPrep{
        company_id: com.id,
        employee_id: employee_id,
        pay_month: month,
        pay_year: year,
        verified: false
      }
  end

  def set_pay_prep_account(employee_id, month, year, funds_account_id, com, _user) do
    get_or_init_pay_prep(employee_id, month, year, com)
    |> FullCircle.HR.PayPrep.changeset(%{"funds_account_id" => funds_account_id})
    |> Repo.insert_or_update()
  end

  def set_pay_prep_verified(employee_id, month, year, verified, com, user) do
    attrs =
      if verified do
        %{"verified" => true, "verified_at" => DateTime.utc_now() |> DateTime.truncate(:second),
          "verified_by_id" => user.id}
      else
        %{"verified" => false, "verified_at" => nil, "verified_by_id" => nil}
      end

    get_or_init_pay_prep(employee_id, month, year, com)
    |> FullCircle.HR.PayPrep.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def clear_pay_prep(com, employee_id, month, year) do
    from(p in FullCircle.HR.PayPrep,
      where:
        p.company_id == ^com.id and p.employee_id == ^employee_id and
          p.pay_month == ^month and p.pay_year == ^year
    )
    |> Repo.update_all(set: [verified: false, verified_at: nil, verified_by_id: nil])
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/pay_prep_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/hr.ex test/full_circle/pay_prep_test.exs
git commit -m "Add pay_prep context: get_or_init, set account/verified, clear"
```

---

## Task 3: Auto-clear hooks (and the Pay-doesn't-clear guard)

**Files:**
- Modify: `lib/full_circle/hr.ex` (public `create/update/delete_salary_note`, `create/update_advance`)
- Test: `test/full_circle/pay_prep_test.exs`

The clear is hooked into the **public** single-row ops only — NOT the `_multi` building blocks
(`create_salary_note_multi`/`update_salary_note_multi`) that `create_pay_slip` uses to link notes,
so that **paying does not unverify**.

- [ ] **Step 1: Write failing tests**

Append to `test/full_circle/pay_prep_test.exs` (inside the `describe "pay_prep context"` block, which already has setup):

```elixir
    test "creating/updating/deleting a salary note clears verified for that month", %{
      com: com, emp: emp, admin: admin
    } do
      st = HR.get_salary_type_by_name("Monthly Salary", com, admin)
      acc = Ecto.UUID.generate()
      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, acc, com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)

      sn_attrs = %{
        "note_date" => "2026-05-15", "quantity" => "1", "unit_price" => "100",
        "employee_name" => emp.name, "employee_id" => emp.id,
        "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "x"
      }

      {:ok, %{create_salary_note: sn}} = HR.create_salary_note(sn_attrs, com, admin)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified

      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      {:ok, _} = HR.update_salary_note(sn, Map.put(sn_attrs, "unit_price", "200"), com, admin)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified

      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)
      sn = FullCircle.Repo.get!(FullCircle.HR.SalaryNote, sn.id)
      {:ok, _} = HR.delete_salary_note(sn, com, admin)
      refute HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end

    test "note in a different month does not clear another month's prep", %{
      com: com, emp: emp, admin: admin
    } do
      st = HR.get_salary_type_by_name("Monthly Salary", com, admin)
      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, Ecto.UUID.generate(), com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)

      {:ok, _} =
        HR.create_salary_note(%{
          "note_date" => "2026-05-15", "quantity" => "1", "unit_price" => "100",
          "employee_name" => emp.name, "employee_id" => emp.id,
          "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "x"
        }, com, admin)

      # the May prep cleared (same month); make a fresh June prep stays verified
      {:ok, _} = HR.set_pay_prep_account(emp.id, 6, 2026, Ecto.UUID.generate(), com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 6, 2026, true, com, admin)

      {:ok, _} =
        HR.create_salary_note(%{
          "note_date" => "2026-05-20", "quantity" => "1", "unit_price" => "100",
          "employee_name" => emp.name, "employee_id" => emp.id,
          "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "x"
        }, com, admin)

      assert HR.get_or_init_pay_prep(emp.id, 6, 2026, com).verified
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/pay_prep_test.exs`
Expected: FAIL — verified stays true (no clear hooked yet).

- [ ] **Step 3: Add the clear step to public ops**

In `lib/full_circle/hr.ex`, add a private helper:

```elixir
  defp clear_pay_prep_step(multi, entity_key, com) do
    Ecto.Multi.run(multi, {:clear_pay_prep, entity_key}, fn _repo, changes ->
      case Map.get(changes, entity_key) do
        %{employee_id: emp_id, note_date: %Date{} = d} ->
          clear_pay_prep(com, emp_id, d.month, d.year)
          {:ok, :cleared}

        %{employee_id: emp_id, slip_date: %Date{} = d} ->
          clear_pay_prep(com, emp_id, d.month, d.year)
          {:ok, :cleared}

        _ ->
          {:ok, :noop}
      end
    end)
  end
```

Then add `|> clear_pay_prep_step(<entity_key>, com)` before `Repo.transaction()` in each PUBLIC op:

- `create_salary_note/3`: `|> create_salary_note_multi(attrs, com, user) |> clear_pay_prep_step(:create_salary_note, com) |> Repo.transaction()`
- `update_salary_note/4`: `|> update_salary_note_multi(salary_note, attrs, com, user) |> clear_pay_prep_step(:update_salary_note, com) |> Repo.transaction()`
- `delete_salary_note/3`: `|> delete_salary_note_multi(salary_note, com, user) |> clear_pay_prep_step(:delete_salary_note, com) |> Repo.transaction()`
- `create_advance/3`: add `|> clear_pay_prep_step(:create_advance, com)` before its `Repo.transaction()`
- `update_advance/4`: add `|> clear_pay_prep_step(:update_advance, com)` before its `Repo.transaction()`

(The entity keys match the `Multi.insert/update/delete` step names used in each `_multi` builder:
`:create_salary_note`, `:update_salary_note`, `:delete_salary_note`, `:create_advance`,
`:update_advance`. Verify each builder's primary step name and use it.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/full_circle/pay_prep_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the critical "Pay does not clear" guard test**

Append to the `describe "pay_prep context"` block. This proves linking notes during payment (via
the `_multi` path, not the public ops) does NOT clear verification:

```elixir
    test "paying (linking notes) does NOT clear verified", %{com: com, emp: emp, admin: admin} do
      alias FullCircle.{PaySlipOp, Accounting}
      cr = Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)
      funds = FullCircle.AccountingFixtures.account_fixture(
        %{name: "Cash on Hand", account_type: "Cash or Equivalent"}, com, admin)
      st = HR.get_salary_type_by_name("Monthly Salary", com, admin)

      # PCB type required by generate_new_changeset_for
      FullCircle.HRFixtures.salary_type_fixture(%{name: "Employee PCB", type: "Deduction",
        cal_func: "pcb_employee", db_ac_name: cr.name, db_ac_id: cr.id,
        cr_ac_name: cr.name, cr_ac_id: cr.id}, com, admin)

      {:ok, %{create_salary_note: _}} =
        HR.create_salary_note(%{
          "note_date" => "2026-05-31", "quantity" => "1", "unit_price" => "3000",
          "employee_name" => emp.name, "employee_id" => emp.id,
          "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "salary"
        }, com, admin)

      {:ok, _} = HR.set_pay_prep_account(emp.id, 5, 2026, funds.id, com, admin)
      {:ok, _} = HR.set_pay_prep_verified(emp.id, 5, 2026, true, com, admin)

      {:ok, _} = PaySlipOp.pay(emp, 5, 2026, funds.id, com, admin)

      assert HR.get_or_init_pay_prep(emp.id, 5, 2026, com).verified
    end
```

> This test depends on `PaySlipOp.pay/6` from Task 4. If running tasks strictly in order, write
> this test at the start of Task 4 instead and keep Task 3 to the note/advance clear tests. Either
> way it MUST exist and pass before the feature is considered done.

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle/hr.ex test/full_circle/pay_prep_test.exs
git commit -m "Auto-clear pay_prep verification on note/advance edits (not on pay)"
```

---

## Task 4: `PaySlipOp.preview/5` and `pay/6`

**Files:**
- Modify: `lib/full_circle/pay_slip_op.ex`
- Test: `test/full_circle/pay_slip_op_test.exs`

These reuse the existing engine: `preview` returns the calculated changeset; `pay` serializes it to
the params `create_pay_slip`/`update_pay_slip` already accept (via `Ecto.Changeset.apply_changes`).

- [ ] **Step 1: Write failing tests**

Append to `test/full_circle/pay_slip_op_test.exs` a new describe (reuse its `setup_payroll`):

```elixir
  describe "preview/pay" do
    setup :setup_payroll

    setup %{com: com, admin: admin} do
      cr = FullCircle.Accounting.get_account_by_name("Salaries and Wages Payable", com, admin)
      # statutory types so calculate_pay has cal_func lines to compute
      for {n, f} <- [{"EPF By Employee", "epf_employee"}, {"EPF By Employer", "epf_employer"}] do
        FullCircle.HRFixtures.salary_type_fixture(%{name: n, type: "Deduction", cal_func: f,
          db_ac_name: cr.name, db_ac_id: cr.id, cr_ac_name: cr.name, cr_ac_id: cr.id}, com, admin)
      end
      :ok
    end

    test "preview returns a calculated changeset with the salary", %{
      com: com, admin: admin, employee: emp, salary_type: st
    } do
      {:ok, _} = FullCircle.HR.create_salary_note(%{
        "note_date" => "2026-05-31", "quantity" => "1", "unit_price" => "3000",
        "employee_name" => emp.name, "employee_id" => emp.id,
        "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "salary"
      }, com, admin)

      cs = PaySlipOp.preview(emp, 5, 2026, com, admin)
      ps = Ecto.Changeset.apply_changes(cs)
      assert Enum.any?(ps.additions, fn a -> Decimal.eq?(a.amount, Decimal.new("3000")) end)
      assert Decimal.gt?(ps.pay_slip_amount, Decimal.new("0"))
    end

    test "pay creates a slip; second pay updates it", %{
      com: com, admin: admin, employee: emp, salary_type: st, funds_ac: funds
    } do
      {:ok, _} = FullCircle.HR.create_salary_note(%{
        "note_date" => "2026-05-31", "quantity" => "1", "unit_price" => "3000",
        "employee_name" => emp.name, "employee_id" => emp.id,
        "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "salary"
      }, com, admin)

      {:ok, %{create_pay_slip: ps}} = PaySlipOp.pay(emp, 5, 2026, funds.id, com, admin)
      loaded = PaySlipOp.get_pay_slip!(ps.id, com)
      assert loaded.slip_no =~ "PS-"
      assert Enum.count(loaded.additions) >= 1

      # change input, pay again -> update (slip count stays 1 for the period)
      {:ok, _} = FullCircle.HR.create_salary_note(%{
        "note_date" => "2026-05-30", "quantity" => "1", "unit_price" => "100",
        "employee_name" => emp.name, "employee_id" => emp.id,
        "salary_type_name" => st.name, "salary_type_id" => st.id, "descriptions" => "bonus-ish"
      }, com, admin)

      assert {:ok, %{update_pay_slip: _}} = PaySlipOp.pay(emp, 5, 2026, funds.id, com, admin)
      assert PaySlipOp.get_pay_slip_by_period(emp, 5, 2026, com)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/full_circle/pay_slip_op_test.exs`
Expected: FAIL — `PaySlipOp.preview/5` undefined.

- [ ] **Step 3: Implement preview, pay, and the serializer**

Add to `lib/full_circle/pay_slip_op.ex` (it already aliases `PaySlip`, `HR`, `SalaryNote`; add
`alias FullCircle.Accounting` if not present):

```elixir
  @doc "In-memory calculated changeset for an employee/month (no save)."
  def preview(emp, mth, yr, com, user) do
    case get_pay_slip_by_period(emp, mth, yr, com) do
      nil ->
        generate_new_changeset_for(emp, mth, yr, com, user) |> calculate_pay(emp)

      ps ->
        get_recal_pay_slip(ps.id, com, user)
        |> PaySlip.changeset(%{})
        |> calculate_pay(emp)
    end
  end

  @doc "Create or update the payslip for an employee/month from the calculated preview."
  def pay(emp, mth, yr, funds_account_id, com, user) do
    acc = Accounting.get_account!(funds_account_id, com, user)
    attrs = changeset_to_pay_attrs(preview(emp, mth, yr, com, user), acc)

    case get_pay_slip_by_period(emp, mth, yr, com) do
      nil -> create_pay_slip(attrs, com, user)
      ps -> update_pay_slip(ps, attrs, com, user)
    end
  end

  @doc false
  def changeset_to_pay_attrs(cs, acc) do
    ps = Ecto.Changeset.apply_changes(cs)

    %{
      "employee_id" => ps.employee_id,
      "employee_name" => ps.employee_name,
      "slip_date" => to_string(ps.slip_date || Date.utc_today()),
      "pay_month" => "#{ps.pay_month}",
      "pay_year" => "#{ps.pay_year}",
      "funds_account_id" => acc.id,
      "funds_account_name" => acc.name,
      "pay_slip_amount" => to_string(ps.pay_slip_amount || 0),
      "slip_no" => ps.slip_no,
      "additions" => index_notes(ps.additions),
      "bonuses" => index_notes(ps.bonuses),
      "deductions" => index_notes(ps.deductions),
      "contributions" => index_notes(ps.contributions),
      "leaves" => index_notes(ps.leaves),
      "advances" => index_advances(ps.advances)
    }
  end

  defp index_notes(list), do: list |> Enum.with_index() |> Map.new(fn {n, i} -> {"#{i}", note_attrs(n)} end)
  defp index_advances(list), do: list |> Enum.with_index() |> Map.new(fn {a, i} -> {"#{i}", adv_attrs(a)} end)

  defp note_attrs(n) do
    %{
      "_id" => n._id,
      "note_no" => n.note_no,
      "note_date" => to_string(n.note_date),
      "quantity" => to_string(n.quantity),
      "unit_price" => to_string(n.unit_price),
      "amount" => to_string(n.amount),
      "salary_type_id" => n.salary_type_id,
      "salary_type_name" => n.salary_type_name,
      "salary_type_type" => n.salary_type_type,
      "cal_func" => n.cal_func,
      "recurring_id" => n.recurring_id,
      "employee_id" => n.employee_id,
      "descriptions" => n.descriptions
    }
  end

  defp adv_attrs(a) do
    %{
      "_id" => a._id,
      "slip_no" => a.slip_no,
      "slip_date" => to_string(a.slip_date),
      "amount" => to_string(a.amount),
      "employee_id" => a.employee_id,
      "note" => a.note
    }
  end
```

> Verify `Accounting.get_account!/3` arity/signature (some contexts use `get_account!(id, com, user)`).
> If it differs, use the matching getter; the only need is `acc.id` + `acc.name`.

- [ ] **Step 4: Run to verify it passes; iterate**

Run: `mix test test/full_circle/pay_slip_op_test.exs`
Expected: PASS. If `create_pay_slip` rejects an attr, compare `note_attrs` keys against what the
PaySlip form submits (see `salary_note_component.ex`: `_id, note_no, note_date, quantity,
unit_price, amount, salary_type_id, salary_type_name, salary_type_type, cal_func, recurring_id,
employee_id, descriptions`) and align. The test (create → reload → assert) is the oracle.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_slip_op.ex test/full_circle/pay_slip_op_test.exs
git commit -m "Add PaySlipOp.preview/5 and pay/6 wrappers over the payroll engine"
```

---

## Task 5: PunchCard LiveView wiring

**Files:**
- Modify: `lib/full_circle_web/live/time_attend_live/punch_card.ex`

Adds: load the `pay_prep`; a payment-account autocomplete; Calculate/Recal Statutory (preview +
net pay); a Correct toggle (gated); a Pay button (gated on verified); and a stale warning.

- [ ] **Step 1: Load pay_prep + preview state in `filter_punches`**

In `filter_punches/4`, in the branch that loads an employee (after `pay_slip: ps`), add assigns:

```elixir
        |> assign(pay_prep: FullCircle.HR.get_or_init_pay_prep(
             emp.id, String.to_integer(month), String.to_integer(year), socket.assigns.current_company))
        |> assign(statutory_preview: nil)
        |> assign(net_pay: nil)
```

And in the empty branch (no employee), add `|> assign(pay_prep: nil) |> assign(statutory_preview: nil) |> assign(net_pay: nil)`.

- [ ] **Step 2: Add the action-bar handlers**

Add these `handle_event` clauses to `punch_card.ex`:

```elixir
  @impl true
  def handle_event("select_account", %{"funds_account_id" => id}, socket) do
    %{employee: emp, search: s, current_company: com, current_user: user} = socket.assigns
    {:ok, pp} = FullCircle.HR.set_pay_prep_account(
      emp.id, String.to_integer("#{s.month}"), String.to_integer("#{s.year}"), id, com, user)

    {:noreply, socket |> assign(pay_prep: pp)}
  end

  @impl true
  def handle_event("calculate_statutory", _, socket) do
    %{employee: emp, search: s, current_company: com, current_user: user} = socket.assigns
    cs = FullCircle.PaySlipOp.preview(emp, String.to_integer("#{s.month}"),
           String.to_integer("#{s.year}"), com, user)
    ps = Ecto.Changeset.apply_changes(cs)

    {:noreply,
     socket
     |> assign(statutory_preview: ps)
     |> assign(net_pay: ps.pay_slip_amount)}
  end

  @impl true
  def handle_event("toggle_correct", _, socket) do
    %{employee: emp, search: s, pay_prep: pp, current_company: com, current_user: user} = socket.assigns
    {:ok, pp} = FullCircle.HR.set_pay_prep_verified(
      emp.id, String.to_integer("#{s.month}"), String.to_integer("#{s.year}"),
      !pp.verified, com, user)

    {:noreply, socket |> assign(pay_prep: pp)}
  end

  @impl true
  def handle_event("pay", _, socket) do
    %{employee: emp, search: s, pay_prep: pp, current_company: com, current_user: user} = socket.assigns

    if pp && pp.verified && pp.funds_account_id do
      case FullCircle.PaySlipOp.pay(emp, String.to_integer("#{s.month}"),
             String.to_integer("#{s.year}"), pp.funds_account_id, com, user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Pay Slip saved."))
           |> push_navigate(to: "/companies/#{com.id}/PunchCard?#{URI.encode_query(%{
                "search[employee_name]" => emp.name, "search[month]" => s.month, "search[year]" => s.year})}")}

        {:error, _op, cs, _} ->
          {:noreply, socket |> put_flash(:error, list_errors_to_string(cs.errors))}

        other ->
          {:noreply, socket |> put_flash(:error, "#{inspect(other)}")}
      end
    else
      {:noreply, socket |> put_flash(:error, gettext("Mark Correct (with a payment account) before paying."))}
    end
  end
```

- [ ] **Step 3: Add the action/summary bar to `render/1`**

Replace the existing `+ Pay` / `Recal Pay` link block (the two `<.link>`s at
[punch_card.ex:83-98](../../../lib/full_circle_web/live/time_attend_live/punch_card.ex#L83-L98))
with a payment-account input + Calculate + Correct + Pay, and add a stale-warning line. Insert
after the employee summary block:

```elixir
      <div :if={@employee} class="flex flex-row gap-2 items-end justify-center my-2">
        <div class="w-[24%]">
          <.input
            name="pay_prep[funds_account_name]"
            value={@pay_prep && @pay_prep.funds_account_id && account_name(@pay_prep.funds_account_id, @current_company, @current_user)}
            label={gettext("Payment Account")}
            phx-hook="tributeAutoComplete"
            phx-update="ignore"
            id="pay_prep_account"
            url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=fundsaccount&name="}
          />
        </div>
        <.link phx-click="calculate_statutory" class="h-10 blue button">
          {gettext("Calculate Statutory")}
        </.link>
        <label class="h-10 mt-5 flex items-center gap-1 px-2 border rounded">
          <input type="checkbox" checked={@pay_prep && @pay_prep.verified} phx-click="toggle_correct" />
          {gettext("Correct")}
        </label>
        <.link
          :if={@pay_prep && @pay_prep.verified}
          phx-click="pay"
          class="h-10 green button"
        >
          {gettext("Pay")}
        </.link>
        <span :if={@net_pay} class="h-10 mt-5 font-bold">
          {gettext("Net Pay")}: {@net_pay |> Number.Delimit.number_to_delimited()}
        </span>
      </div>

      <div :if={@employee && @pay_slip && @pay_prep && !@pay_prep.verified}
           class="text-center bg-amber-200 border border-amber-500 rounded p-1 mb-2">
        ⚠ {gettext("Inputs changed since last pay — recalculate and re-pay.")}
      </div>

      <div :if={@statutory_preview} class="text-center text-sm mb-2">
        <%= for n <- @statutory_preview.deductions ++ @statutory_preview.contributions, !is_nil(n.cal_func) do %>
          <span class="mx-1">{n.salary_type_name}: {n.amount |> Number.Delimit.number_to_delimited()}</span>
        <% end %>
      </div>
```

Add a small helper for the account name (used above):

```elixir
  defp account_name(id, com, user) do
    case FullCircle.Accounting.get_account!(id, com, user) do
      nil -> ""
      acc -> acc.name
    end
  end
```

The funds-account autocomplete posts back the chosen id; wire its change to `select_account`.
Follow the PaySlip form's pattern ([pay_slip_live/form.ex:118-133](../../../lib/full_circle_web/live/pay_slip_live/form.ex#L118-L133)):
the autocomplete sets a hidden `funds_account_id` and a `validate`/change event resolves it. Add a
`handle_event("validate", %{"_target" => ["pay_prep", "funds_account_name"], ...})` clause mirroring
that pattern that calls `assign_autocomplete_id` then `select_account`. Keep the existing PunchCard
`new_salarynote`/`new_advance` flows unchanged.

- [ ] **Step 4: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean compile. Fix any assign/arity mismatches (e.g. `account_name`/`get_account!`
signature) until clean.

- [ ] **Step 5: Run the payroll suites (no regressions)**

Run: `mix test test/full_circle/pay_prep_test.exs test/full_circle/pay_slip_op_test.exs test/full_circle/pay_run_test.exs`
Expected: PASS.

- [ ] **Step 6: Manual verification**

`iex -S mix phx.server`, open a PunchCard for an employee/month, and confirm:
- Add a Salary Note / Advance via the existing modals; pick a Payment Account.
- **Calculate Statutory** shows the EPF/SOCSO/EIS/PCB lines + **Net Pay**.
- **Correct** can be ticked only with an account set; ticking enables **Pay**.
- **Pay** creates the slip (flash + the slip-no link appears on the notes).
- Edit a note → the **Correct** tick clears and the **"inputs changed since last pay"** warning
  appears; Calculate → Correct → Pay updates the slip.

- [ ] **Step 7: Commit**

```bash
git add lib/full_circle_web/live/time_attend_live/punch_card.ex
git commit -m "Unified PunchCard: payment account, Calculate Statutory, Correct, Pay, stale warning"
```

---

## Self-Review Notes

- **Spec coverage:** `pay_preps` table + schema (T1); context get_or_init/set-account/set-verified/
  clear (T2); context-level auto-clear on public note/advance ops + the **Pay-doesn't-clear** guard
  (T3); in-memory preview + create/update Pay reusing the engine (T4); screen wiring with payment
  account, Calculate/Recal, Correct (gated), Pay (gated on verified), and the Paid+stale warning (T5).
- **Critical correctness:** auto-clear is hooked only in the **public** single-row ops, never the
  `_multi` builders used by `create_pay_slip` — proven by the "paying does NOT clear verified" test.
- **Type consistency:** `PayPrep` fields (`pay_month, pay_year, verified, verified_at, funds_account_id,
  verified_by_id`) used consistently across context, tests, and LiveView; `PaySlipOp.pay/6` returns the
  same `{:ok, %{create_pay_slip|update_pay_slip: ps}}` shape `create_pay_slip`/`update_pay_slip` already
  return, which T5's `handle_event("pay", ...)` matches.
- **Out of scope (noted):** batch mode; PaySlip form changes; inline-editable note fields.
- **Verify-at-implementation:** `Accounting.get_account!/3` signature; each `_multi` builder's primary
  step-name (entity keys for `clear_pay_prep_step`).
