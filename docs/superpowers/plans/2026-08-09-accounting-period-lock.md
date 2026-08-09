# Accounting Period Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give administrators a cutoff date per company that blocks writing or deleting general-ledger rows dated on or before it, across the eight core accounting documents plus Journal.

**Architecture:** The cutoff lives in `company.settings["period"]["closed_through"]`, set only through an admin-gated, logged function on `FullCircle.Sys`. Enforcement is a single `Ecto.Multi.run` step inserted immediately before the two operations that touch the GL in every document context — the transaction build and the transaction `delete_all` — so a save that changes nothing GL-affecting is never blocked. Two thin delete wrappers cover Receipt and Payment, the only documents with a document-level delete.

**Tech Stack:** Elixir 1.19.5, Phoenix 1.8.3, Phoenix LiveView 1.1.x, Ecto/Postgres, ExUnit.

Spec: `docs/superpowers/specs/2026-08-09-accounting-period-lock-design.md`

## Global Constraints

- Never run bare `mix format` — it rewrites roughly 14 already-unformatted files on master. Format only the files you touched: `mix format path/to/file.ex`.
- Commit directly to `master`. No feature branches.
- LiveView flash kind must be `:warn`. `:warning` renders nothing, silently.
- All new user-facing strings go through `gettext/1`.
- Schemas use `use FullCircle.Schema` (binary_id primary keys), not `use Ecto.Schema`.
- The existing `transactions.closed` flag means "seeded opening balance". Do not repurpose it, and do not write to it.
- Run tests with `mix test`. The suite was green at 1105 tests as of 2026-08-08.

---

## File Structure

**Created:**
- `priv/repo/migrations/<timestamp>_add_update_closed_transaction_trigger.exs` — the missing `BEFORE UPDATE` trigger.
- `test/full_circle/period_lock_test.exs` — cutoff storage, the guard function, and per-document enforcement.
- `test/full_circle_web/live/period_lock_live_test.exs` — company-form control and a blocked save's flash.

**Modified:**
- `lib/full_circle/sys.ex` — `period_closed_through/1`, `close_period_through/3`.
- `lib/full_circle/accounting.ex` — `assert_period_open/2`, `multi_assert_period_open/3`.
- `lib/full_circle/billing.ex` — guard in the Invoice and PurInvoice create paths and in `update_doc_multi/9`'s rebuild branch.
- `lib/full_circle/debcre.ex` — guard in the CreditNote and DebitNote create paths and in `update_note_multi/8`'s rebuild branch.
- `lib/full_circle/bill_pay.ex` — guard in `create_payment_multi/4` and `update_payment_multi/5`; new `delete_payment/3`.
- `lib/full_circle/receive_fund.ex` — guard in the Receipt create path and `update_doc_multi/8`; new `delete_receipt/3`.
- `lib/full_circle/cheque.ex` — guard in the Deposit and ReturnCheque create and update multis.
- `lib/full_circle/journal_entry.ex` — guard in `create_journal_multi/4` and `update_journal_multi/5`.
- `lib/full_circle_web/live/{invoice,pur_invoice,receipt,payment,credit_note,debit_note,journal}_live/form.ex` — a `{:error, :period_closed}` clause each; Receipt and Payment forms also switch their delete to the new context wrapper.
- `lib/full_circle_web/live/company_live/form.ex` — the admin-only cutoff control.

---

## Task 1: Cutoff storage and the administrator action

**Files:**
- Modify: `lib/full_circle/sys.ex` (near `get_company_settings/2` at line 262)
- Test: `test/full_circle/period_lock_test.exs` (create)

**Interfaces:**
- Consumes: `Sys.get_company_settings/2`, `Sys.update_company_settings/3`, `Sys.log_changeset/5`, `Sys.user_role_in_company/2` — all already exist in `sys.ex`.
- Produces:
  - `Sys.period_closed_through(company) :: Date.t() | nil`
  - `Sys.close_period_through(company, Date.t() | nil, user) :: {:ok, Company.t()} | {:error, :future_date} | :not_authorise`

- [ ] **Step 1: Write the failing tests**

Create `test/full_circle/period_lock_test.exs`:

```elixir
defmodule FullCircle.PeriodLockTest do
  use FullCircle.DataCase

  alias FullCircle.Sys

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  describe "period cutoff storage" do
    setup do
      admin = user_fixture()
      company = company_fixture(admin, %{})
      %{admin: admin, company: company}
    end

    test "no cutoff by default", %{company: company} do
      assert Sys.period_closed_through(company) == nil
    end

    test "an admin can close a period", %{company: company, admin: admin} do
      assert {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      assert Sys.period_closed_through(company) == ~D[2025-12-31]
    end

    test "a non-admin cannot close a period", %{company: company, admin: admin} do
      clerk = user_fixture()
      {:ok, _} = Sys.allow_user_to_access(company, clerk, "clerk", admin)

      assert :not_authorise = Sys.close_period_through(company, ~D[2025-12-31], clerk)
      assert Sys.period_closed_through(company) == nil
    end

    test "a future date is rejected", %{company: company, admin: admin} do
      future = Date.add(Date.utc_today(), 1)
      assert {:error, :future_date} = Sys.close_period_through(company, future, admin)
      assert Sys.period_closed_through(company) == nil
    end

    test "nil clears the cutoff", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      assert {:ok, company} = Sys.close_period_through(company, nil, admin)
      assert Sys.period_closed_through(company) == nil
    end

    test "closing and reopening are both logged", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      {:ok, company} = Sys.close_period_through(company, ~D[2025-06-30], admin)

      logs =
        Repo.all(
          from l in FullCircle.Sys.Log,
            where: l.company_id == ^company.id and l.action == "close_period"
        )

      assert length(logs) == 2
      assert Enum.any?(logs, &(&1.delta =~ "2025-12-31"))
      assert Enum.any?(logs, &(&1.delta =~ "2025-06-30"))
    end

    test "a malformed stored value reads as no cutoff", %{company: company} do
      {:ok, company} = Sys.update_company_settings(company, "period", %{"closed_through" => "rubbish"})
      assert Sys.period_closed_through(company) == nil
    end
  end
end
```

`Sys.allow_user_to_access(company, user, role, granting_admin)` is the existing role-granting helper — arity 4, with the granting admin last. `test/full_circle/sys_test.exs:117` shows it in use.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL with `function FullCircle.Sys.period_closed_through/1 is undefined`.

- [ ] **Step 3: Implement**

Add to `lib/full_circle/sys.ex`, directly after `update_company_settings/3` (line 273):

```elixir
@period_settings_key "period"
@closed_through_key "closed_through"

@doc """
The date through which this company's accounting period is closed, or `nil`.

Returns `nil` for an unset or unparseable value — an unreadable setting must not
lock a company out of its own books.
"""
def period_closed_through(company) do
  company
  |> get_company_settings(@period_settings_key)
  |> Map.get(@closed_through_key)
  |> case do
    nil ->
      nil

    str when is_binary(str) ->
      case Date.from_iso8601(str) do
        {:ok, date} -> date
        {:error, _} -> nil
      end

    _ ->
      nil
  end
end

@doc """
Close (or reopen) this company's accounting period through `date`.

Admin only. `nil` clears the cutoff. A date in the future is rejected — a period
that has not finished cannot be closed; "future" is judged in the company's own
timezone, not the server's.

Writes the setting and a `close_period` log entry in one transaction, so a reopen
is as visible in the log as a close.
"""
def close_period_through(company, date, user) do
  cond do
    user_role_in_company(user.id, company.id) != "admin" ->
      :not_authorise

    not is_nil(date) and Date.compare(date, company_today(company)) == :gt ->
      {:error, :future_date}

    true ->
      previous = period_closed_through(company)
      values = if is_nil(date), do: %{}, else: %{@closed_through_key => Date.to_iso8601(date)}

      Ecto.Multi.new()
      |> Ecto.Multi.run(:company, fn _repo, _ ->
        update_company_settings(company, @period_settings_key, values)
      end)
      |> Ecto.Multi.insert(:close_period_log, fn %{company: com} ->
        log_changeset(
          :close_period,
          com,
          %{"from" => to_string(previous), "to" => to_string(date)},
          com,
          user
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{company: com}} -> {:ok, com}
        {:error, _, reason, _} -> {:error, reason}
      end
  end
end

# Today in the company's own timezone. A server in UTC and a company in
# Asia/Kuala_Lumpur disagree for eight hours a day, and "is this date in the
# future" must follow the company.
defp company_today(company) do
  case company.timezone do
    tz when is_binary(tz) and tz != "" ->
      case DateTime.now(tz) do
        {:ok, dt} -> DateTime.to_date(dt)
        _ -> Date.utc_today()
      end

    _ ->
      Date.utc_today()
  end
end
```

`log_changeset/5` builds its `entity`/`entity_id` from the struct passed in, so passing the company gives a log row anchored to the company — which is what we want here.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/sys.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/sys.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): admin-set accounting period cutoff on the company"
```

---

## Task 2: The guard function

**Files:**
- Modify: `lib/full_circle/accounting.ex` (near `assert_doc_editable/4` at line 30)
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Sys.period_closed_through/1` from Task 1.
- Produces:
  - `Accounting.assert_period_open([Date.t() | nil], company) :: :ok | {:error, :period_closed}`
  - `Accounting.multi_assert_period_open(Ecto.Multi.t(), (map() -> [Date.t() | nil]), company) :: Ecto.Multi.t()` — adds a `:assert_period_open` step.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`, inside the module:

```elixir
  describe "assert_period_open/2" do
    setup do
      admin = user_fixture()
      company = company_fixture(admin, %{})
      {:ok, company} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      %{admin: admin, company: company}
    end

    test "a date on the cutoff is closed", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2025-12-31]], company)
    end

    test "a date before the cutoff is closed", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2025-11-04]], company)
    end

    test "the day after the cutoff is open", %{company: company} do
      assert :ok = FullCircle.Accounting.assert_period_open([~D[2026-01-01]], company)
    end

    test "any closed date in the list closes the write", %{company: company} do
      assert {:error, :period_closed} =
               FullCircle.Accounting.assert_period_open([~D[2026-01-01], ~D[2025-11-04]], company)
    end

    test "nils are ignored", %{company: company} do
      assert :ok = FullCircle.Accounting.assert_period_open([nil], company)
      assert :ok = FullCircle.Accounting.assert_period_open([], company)
    end

    test "no cutoff means everything is open", %{admin: admin} do
      open_company = company_fixture(admin, %{})
      assert :ok = FullCircle.Accounting.assert_period_open([~D[2019-01-01]], open_company)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL with `function FullCircle.Accounting.assert_period_open/2 is undefined`.

- [ ] **Step 3: Implement**

Add to `lib/full_circle/accounting.ex`, immediately after `assert_doc_editable/4` (which ends around line 50):

```elixir
@doc """
Returns `:ok` if every date in `dates` sits after the company's closed-period
cutoff, or `{:error, :period_closed}` otherwise.

`dates` are the posting dates involved in a GL write: the new document date on
create, and both the old and new dates on update, so that neither moving a
document into a closed period nor out of one is possible. `nil` entries are
ignored, as is an empty list. `:ok` when the company has no cutoff set.
"""
def assert_period_open(dates, company) do
  case FullCircle.Sys.period_closed_through(company) do
    nil ->
      :ok

    cutoff ->
      if Enum.any?(dates, fn d -> not is_nil(d) and Date.compare(d, cutoff) != :gt end) do
        {:error, :period_closed}
      else
        :ok
      end
  end
end

@doc """
Adds an `:assert_period_open` step to `multi` that aborts the transaction when the
write would touch a closed period.

`dates_fun` receives the multi's changes so far and returns the posting dates to
check — this is how the step reads a document that an earlier step just inserted
or updated.

Place this immediately before the transaction build and the transaction
`delete_all`, so that a save which changes nothing GL-affecting is never blocked.
"""
def multi_assert_period_open(multi, dates_fun, company) do
  Ecto.Multi.run(multi, :assert_period_open, fn _repo, changes ->
    case assert_period_open(dates_fun.(changes), company) do
      :ok -> {:ok, :period_open}
      {:error, reason} -> {:error, reason}
    end
  end)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: PASS, 13 tests.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/accounting.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/accounting.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): assert_period_open guard and its Multi wrapper"
```

---

## Task 3: Wire Invoice and PurInvoice

**Files:**
- Modify: `lib/full_circle/billing.ex:274-302` (`update_doc_multi/9`), `:444-485` (`create_invoice_multi/4`), and the PurInvoice create multi near `:900`
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Accounting.multi_assert_period_open/3` from Task 2.
- Produces: `Billing.create_invoice/4`, `update_invoice/5` and their PurInvoice counterparts return `{:error, :assert_period_open, :period_closed, _changes}` when the write touches a closed period.

`billing.ex` has the `doc_transactions_unchanged?` fast path, so a description-only edit must still succeed. The guard goes inside the `else` branch only.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`:

```elixir
  describe "Invoice under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    defp close_through(company, admin, date) do
      {:ok, company} = Sys.close_period_through(company, date, admin)
      company
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      company = close_through(company, admin, Date.utc_today())

      assert {:error, :assert_period_open, :period_closed, _} =
               create_invoice_dated(company, admin, Date.utc_today())
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      company = close_through(company, admin, Date.add(Date.utc_today(), -30))

      assert {:ok, %{create_invoice: _}} =
               create_invoice_dated(company, admin, Date.utc_today())
    end

    test "editing a GL field on a closed-period invoice is rejected",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      company = close_through(company, admin, Date.utc_today())

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)
      attrs = gl_changing_attrs(invoice)

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.Billing.update_invoice(invoice, attrs, company, admin)
    end

    test "a description-only edit on a closed-period invoice still succeeds",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      company = close_through(company, admin, Date.utc_today())

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)
      attrs = description_only_attrs(invoice, "edited after closing")

      assert {:ok, %{update_invoice: updated}} =
               FullCircle.Billing.update_invoice(invoice, attrs, company, admin)

      assert updated.descriptions == "edited after closing"
    end

    test "moving an open invoice into a closed period is rejected",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      company = close_through(company, admin, Date.add(Date.utc_today(), -30))

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)
      attrs = date_change_attrs(invoice, Date.add(Date.utc_today(), -60))

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.Billing.update_invoice(invoice, attrs, company, admin)
    end
  end
```

The three helpers build attrs from a loaded invoice. Add them as private functions at the bottom of the test module. `invoice_attrs/5` in `test/support/fixtures/billing_fixtures.ex:109` shows the exact attrs shape a save expects — build these by loading the invoice, converting it to that shape, and changing the one field each helper names:

```elixir
  # Rebuild the attrs map a save expects from a loaded invoice. The detail rows
  # must carry their `id` so cast_assoc updates rather than replaces them.
  defp invoice_to_attrs(invoice) do
    details =
      invoice.invoice_details
      |> Enum.with_index()
      |> Enum.into(%{}, fn {d, i} ->
        {to_string(i),
         %{
           "id" => d.id,
           "good_id" => d.good_id,
           "good_name" => d.good_name,
           "account_id" => d.account_id,
           "account_name" => d.account_name,
           "tax_code_id" => d.tax_code_id,
           "tax_code_name" => d.tax_code_name,
           "package_id" => d.package_id,
           "package_name" => d.package_name,
           "quantity" => to_string(d.quantity),
           "unit_price" => to_string(d.unit_price),
           "discount" => to_string(d.discount),
           "tax_rate" => to_string(d.tax_rate),
           "unit_multiplier" => to_string(d.unit_multiplier),
           "_persistent_id" => to_string(i)
         }}
      end)

    %{
      "invoice_date" => Date.to_string(invoice.invoice_date),
      "due_date" => Date.to_string(invoice.due_date),
      "contact_name" => invoice.contact_name,
      "contact_id" => invoice.contact_id,
      "descriptions" => invoice.descriptions,
      "invoice_details" => details
    }
  end

  defp description_only_attrs(invoice, text) do
    invoice |> invoice_to_attrs() |> Map.put("descriptions", text)
  end

  defp gl_changing_attrs(invoice) do
    attrs = invoice_to_attrs(invoice)
    details =
      Map.update!(attrs["invoice_details"], "0", &Map.put(&1, "unit_price", "99.00"))
    Map.put(attrs, "invoice_details", details)
  end

  defp date_change_attrs(invoice, date) do
    invoice |> invoice_to_attrs() |> Map.put("invoice_date", Date.to_string(date))
  end

  defp create_invoice_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    attrs =
      FullCircle.BillingFixtures.invoice_attrs(contact, good, acct, tc, tax_rate: "0")
      |> Map.put("invoice_date", Date.to_string(date))

    FullCircle.Billing.create_invoice(attrs, company, user)
  end
```

If `invoice.lock_version` is required by the changeset (see `.claude/skills/optimistic-locking.md`), add `"lock_version" => to_string(invoice.lock_version)` to `invoice_to_attrs/1`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the create and edit tests return `{:ok, _}` where `{:error, :assert_period_open, ...}` is asserted. The description-only test should already pass; that is the behaviour being protected.

- [ ] **Step 3: Implement**

In `lib/full_circle/billing.ex`, in `update_doc_multi/9`, replace the `else` branch (starting line 291):

```elixir
    else
      doc_date_key = Keyword.fetch!(txn_opts, :doc_date_key)

      multi
      |> Accounting.multi_assert_period_open(
        fn changes ->
          [Map.get(doc, doc_date_key), Map.get(Map.get(changes, step_name, doc), doc_date_key)]
        end,
        com
      )
      |> Multi.delete_all(
        :delete_transaction,
        from(txn in Transaction,
          where: txn.doc_type == ^doc_type,
          where: txn.doc_no == ^doc_no,
          where: txn.company_id == ^com.id
        )
      )
      |> create_doc_transactions(step_name, com, user, txn_opts)
    end
```

In `create_invoice_multi/4`, insert the guard before the final `create_doc_transactions` call (line 484):

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^invoice_name => doc} -> [doc.invoice_date] end,
      com
    )
    |> create_doc_transactions(invoice_name, com, user, @invoice_txn_opts)
```

Do the same in the PurInvoice create multi near line 900, using `doc.pur_invoice_date` and its own step-name variable.

Confirm `alias FullCircle.Accounting` is already present at the top of `billing.ex` — it is, since `assert_doc_editable` is referenced elsewhere in the file. If it is aliased differently, match the existing usage.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/billing_test.exs`
Expected: PASS. `billing_test.exs` must stay green — no company in it sets a cutoff, so the guard is a no-op there.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/billing.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/billing.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Invoice and PurInvoice"
```

---

## Task 4: Wire CreditNote and DebitNote

**Files:**
- Modify: `lib/full_circle/debcre.ex:212-237` (`create_credit_note_multi/4`), `:436` (`create_debit_note_multi/4`), `:600-623` (`update_note_multi/8`)
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Accounting.multi_assert_period_open/3` from Task 2.
- Produces: the four `create_/update_` note functions return `{:error, :assert_period_open, :period_closed, _changes}` on a closed-period write.

`debcre.ex` also has a fingerprint fast path (`note_transactions_unchanged?/6`), so the same rule applies: guard the rebuild branch only.

Note `@credit_note_txn_opts` has **no** `doc_date_key` — unlike `billing.ex`'s opts. Both notes use `:note_date`, so reference the field directly rather than inventing an opts key.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`. `FullCircle.DebCreFixtures.credit_note_attrs(contact, account, tax_code, opts)` builds the attrs map with `"note_date"` defaulted to today; the helper below overrides that date.

```elixir
  describe "CreditNote under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)

      attrs = credit_note_attrs_dated(company, admin, Date.utc_today())

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.DebCre.create_credit_note(attrs, company, admin)
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      attrs = credit_note_attrs_dated(company, admin, Date.utc_today())

      assert {:ok, %{create_credit_note: _}} =
               FullCircle.DebCre.create_credit_note(attrs, company, admin)
    end
  end
```

Add this private helper at the bottom of the test module:

```elixir
  defp credit_note_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    FullCircle.DebCreFixtures.credit_note_attrs(contact, acct, tc, tax_rate: "0")
    |> Map.put("note_date", Date.to_string(date))
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the create test returns `{:ok, _}`.

- [ ] **Step 3: Implement**

In `update_note_multi/8`, replace the `else` branch:

```elixir
    else
      multi
      |> Accounting.multi_assert_period_open(
        fn changes ->
          [note.note_date, Map.get(changes, step_name, note).note_date]
        end,
        com
      )
      |> Multi.delete_all(
        :delete_transaction,
        from(txn in Transaction,
          where: txn.doc_type == ^doc_type,
          where: txn.doc_no == ^note.note_no,
          where: txn.company_id == ^com.id
        )
      )
      |> create_note_transactions(step_name, com, user, txn_opts)
    end
```

In `create_credit_note_multi/4`, before the final `create_note_transactions` call:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^note_name => doc} -> [doc.note_date] end,
      com
    )
    |> create_note_transactions(note_name, com, user, @credit_note_txn_opts)
```

Repeat verbatim in `create_debit_note_multi/4` with `@debit_note_txn_opts`.

Add `alias FullCircle.Accounting` at the top of `debcre.ex` if it is not already there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/debcre_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/debcre.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/debcre.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on CreditNote and DebitNote"
```

---

## Task 5: Wire Payment, and guard its delete

**Files:**
- Modify: `lib/full_circle/bill_pay.ex:331-350` (`create_payment_multi/4`), `:370-386` (`update_payment_multi/5`), and add `delete_payment/3`
- Modify: `lib/full_circle_web/live/payment_live/form.ex:509-520`
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Accounting.multi_assert_period_open/3`, `Accounting.assert_period_open/2` from Task 2.
- Produces: `BillPay.delete_payment(payment, com, user) :: {:ok, Payment.t()} | {:error, :period_closed} | :not_authorise | {:error, atom(), any(), map()}`

Payment has **no** fingerprint fast path — every save rewrites its transactions, so every save into a closed period is blocked. That asymmetry is intended and documented in the spec.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`. `FullCircle.BillPayFixtures` exposes `payment_fixture(company, user, opts)`, `payment_attrs(contact, good, purchase_account, purchase_tax_code, funds_account, opts)` and `pay_funds_account_fixture(company, user)`; `payment_attrs/6` defaults `"payment_date"` to today.

```elixir
  describe "Payment under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)
      attrs = payment_attrs_dated(company, admin, Date.utc_today())

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.BillPay.create_payment(attrs, company, admin)
    end

    test "deleting a closed-period payment is rejected", %{company: company, admin: admin} do
      payment = FullCircle.BillPayFixtures.payment_fixture(company, admin)
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.BillPay.delete_payment(payment, company, admin)
    end

    test "deleting a payment after the cutoff still succeeds", %{company: company, admin: admin} do
      payment = FullCircle.BillPayFixtures.payment_fixture(company, admin)
      {:ok, company} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, _} = FullCircle.BillPay.delete_payment(payment, company, admin)
    end
  end
```

Add this private helper at the bottom of the test module:

```elixir
  defp payment_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)
    funds_acct = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoPTax"
      )

    FullCircle.BillPayFixtures.payment_attrs(contact, good, pur_acct, tc, funds_acct,
      tax_rate: "0"
    )
    |> Map.put("payment_date", Date.to_string(date))
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL with `function FullCircle.BillPay.delete_payment/3 is undefined`.

- [ ] **Step 3: Implement**

In `create_payment_multi/4`, before the final `create_payment_transactions` call:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^payment_name => doc} -> [doc.payment_date] end,
      com
    )
    |> create_payment_transactions(payment_name, com, user)
```

In `update_payment_multi/5`, insert the guard between the `Multi.update` and the `Multi.delete_all`:

```elixir
    |> Accounting.multi_assert_period_open(
      fn changes ->
        [payment.payment_date, Map.get(changes, payment_name, payment).payment_date]
      end,
      com
    )
    |> Multi.delete_all(
```

Add `delete_payment/3` next to `update_payment/4`:

```elixir
@doc """
Delete a payment, refusing when its posting date sits inside a closed period.

`StdInterface.delete/6` does not pass through this context's multi, so the period
guard has to live here rather than in `update_payment_multi/5`.
"""
def delete_payment(%Payment{} = payment, com, user) do
  case Accounting.assert_period_open([payment.payment_date], com) do
    :ok -> StdInterface.delete(Payment, "payment", payment, com, user)
    {:error, reason} -> {:error, reason}
  end
end
```

In `lib/full_circle_web/live/payment_live/form.ex`, change the `handle_event("delete", ...)` clause at line 509 to call `FullCircle.BillPay.delete_payment(socket.assigns.form.data, socket.assigns.current_company, socket.assigns.current_user)` in place of `StdInterface.delete(...)`, keeping the existing result-matching clauses and adding one for `{:error, :period_closed}` (Task 9 covers the message).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/bill_pay_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/form.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/form.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Payment, including delete"
```

---

## Task 6: Wire Receipt, and guard its delete

**Files:**
- Modify: `lib/full_circle/receive_fund.ex:590-605` (`update_doc_multi/8`), the Receipt create multi above it, and add `delete_receipt/3`
- Modify: `lib/full_circle_web/live/receipt_live/form.ex:513-524`
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Accounting.multi_assert_period_open/3`, `Accounting.assert_period_open/2` from Task 2.
- Produces: `ReceiveFund.delete_receipt(receipt, com, user) :: {:ok, Receipt.t()} | {:error, :period_closed} | :not_authorise | {:error, atom(), any(), map()}`

Structurally identical to Task 5 — Receipt has no fingerprint fast path either. Repeated in full rather than cross-referenced, since tasks may be read out of order.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`. `FullCircle.ReceiveFundFixtures` exposes `receipt_fixture(company, user, opts)` and `receipt_attrs(contact, good, sales_account, sales_tax_code, opts)`, which defaults `"receipt_date"` to today.

```elixir
  describe "Receipt under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)
      attrs = receipt_attrs_dated(company, admin, Date.utc_today())

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.ReceiveFund.create_receipt(attrs, company, admin)
    end

    test "deleting a closed-period receipt is rejected", %{company: company, admin: admin} do
      receipt = FullCircle.ReceiveFundFixtures.receipt_fixture(company, admin)
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.ReceiveFund.delete_receipt(receipt, company, admin)
    end

    test "a description-only edit on a closed-period receipt is rejected", %{company: company, admin: admin} do
      # Documents the known asymmetry: Receipt has no fingerprint fast path, so
      # even a non-GL edit is blocked. If this test starts failing, the fast path
      # was extended here and the spec's asymmetry section needs updating.
      receipt = FullCircle.ReceiveFundFixtures.receipt_fixture(company, admin)
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)

      receipt = FullCircle.ReceiveFund.get_receipt!(receipt.id, company, admin)
      attrs = receipt_description_attrs(receipt, "edited after closing")

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.ReceiveFund.update_receipt(receipt, attrs, company, admin)
    end
  end
```

Add one more test to the same `describe`, covering the spec's requirement that settling an old invoice stays possible:

```elixir
    test "a new receipt can still match a closed-period invoice",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)

      # Dated after the cutoff, so the receipt itself is in an open period, but
      # it matches a transaction that is not. Matching writes new
      # transaction_matchers rows without altering the closed transactions, so
      # this must succeed — otherwise prior-year receivables become uncollectable.
      attrs = receipt_attrs_matching(company, admin, invoice, Date.add(Date.utc_today(), 1))

      assert {:ok, %{create_receipt: _}} =
               FullCircle.ReceiveFund.create_receipt(attrs, company, admin)
    end
```

Build `receipt_attrs_matching/4` from `receipt_attrs/5` plus a `"transaction_matchers"` entry pointing at the invoice's receivable transaction. `test/full_circle/receive_fund_test.exs` already contains a matching test — copy its matcher-map shape rather than inventing one.

Add these private helpers at the bottom of the test module:

```elixir
  defp receipt_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    FullCircle.ReceiveFundFixtures.receipt_attrs(contact, good, sales_acct, tc, tax_rate: "0")
    |> Map.put("receipt_date", Date.to_string(date))
  end

  defp receipt_description_attrs(receipt, text) do
    %{
      "receipt_date" => Date.to_string(receipt.receipt_date),
      "contact_name" => receipt.contact_name,
      "contact_id" => receipt.contact_id,
      "descriptions" => text
    }
  end
```

If the Receipt changeset rejects `receipt_description_attrs/2` for missing detail lines, rebuild the detail and cheque maps from the loaded receipt the way Task 3's `invoice_to_attrs/1` does for Invoice.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL with `function FullCircle.ReceiveFund.delete_receipt/3 is undefined`.

- [ ] **Step 3: Implement**

In `update_doc_multi/8`, insert the guard between the `Multi.update` and the `Multi.delete_all`:

```elixir
    |> Accounting.multi_assert_period_open(
      fn changes ->
        [doc.receipt_date, Map.get(changes, step_name, doc).receipt_date]
      end,
      com
    )
    |> Multi.delete_all(
```

In the Receipt create multi, insert the guard before its `create_receipt_transactions` call:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^receipt_name => doc} -> [doc.receipt_date] end,
      com
    )
    |> create_receipt_transactions(receipt_name, com, user)
```

Match the actual step-name variable used in that function.

Add `delete_receipt/3` next to `update_receipt/4`:

```elixir
@doc """
Delete a receipt, refusing when its posting date sits inside a closed period.

`StdInterface.delete/6` does not pass through this context's multi, so the period
guard has to live here rather than in `update_doc_multi/8`.
"""
def delete_receipt(%Receipt{} = receipt, com, user) do
  case Accounting.assert_period_open([receipt.receipt_date], com) do
    :ok -> StdInterface.delete(Receipt, "receipt", receipt, com, user)
    {:error, reason} -> {:error, reason}
  end
end
```

In `lib/full_circle_web/live/receipt_live/form.ex`, change the `handle_event("delete", ...)` clause at line 513 to call `FullCircle.ReceiveFund.delete_receipt(...)` in place of `StdInterface.delete(...)`, keeping the existing result-matching clauses.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/receive_fund_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/receive_fund.ex lib/full_circle_web/live/receipt_live/form.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/receive_fund.ex lib/full_circle_web/live/receipt_live/form.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Receipt, including delete"
```

---

## Task 7: Wire Deposit and ReturnCheque

**Files:**
- Modify: `lib/full_circle/cheque.ex:168-187` (`create_deposit_multi/4`), `:209-228` (`update_deposit_multi/5`), `:243-266` (`create_return_cheque_multi/4`), `:290-310` (`update_return_cheque_multi/5`)
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Accounting.multi_assert_period_open/3` from Task 2.
- Produces: the four functions return `{:error, :assert_period_open, :period_closed, _changes}` on a closed-period write.

Neither document has a fingerprint fast path, and neither has any non-GL persisted field, so a full block is the correct behaviour here.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`. `FullCircle.ChequeFixtures` has `deposit_fixture(company, user, opts)` but **no** `deposit_attrs` builder — `deposit_fixture/3` inlines its attrs and hardcodes today's date. The helper below reproduces that attrs map with the date parameterised.

```elixir
  describe "Deposit under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)
      attrs = deposit_attrs_dated(company, admin, Date.utc_today())

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.Cheque.create_deposit(attrs, company, admin)
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)
      attrs = deposit_attrs_dated(company, admin, Date.utc_today())

      assert {:ok, %{create_deposit: _}} =
               FullCircle.Cheque.create_deposit(attrs, company, admin)
    end
  end
```

Add this private helper at the bottom of the test module:

```elixir
  defp deposit_attrs_dated(company, user, date) do
    bank_acct = FullCircle.ChequeFixtures.bank_account_fixture(company, user)
    funds_from_acct = FullCircle.ReceiveFundFixtures.funds_account_fixture(company, user)

    %{
      "deposit_date" => Date.to_string(date),
      "bank_name" => bank_acct.name,
      "bank_id" => bank_acct.id,
      "funds_from_name" => funds_from_acct.name,
      "funds_from_id" => funds_from_acct.id,
      "funds_amount" => "100.00",
      "descriptions" => "Test deposit"
    }
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the create test returns `{:ok, _}`.

- [ ] **Step 3: Implement**

In `create_deposit_multi/4`, before the final `create_deposit_transactions` call:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^deposit_name => doc} -> [doc.deposit_date] end,
      com
    )
    |> create_deposit_transactions(deposit_name, com, user)
```

In `update_deposit_multi/5`, between `Sys.insert_log_for` and `Multi.delete_all`:

```elixir
    |> Accounting.multi_assert_period_open(
      fn changes ->
        [deposit.deposit_date, Map.get(changes, deposit_name, deposit).deposit_date]
      end,
      com
    )
    |> Multi.delete_all(
```

In `create_return_cheque_multi/4`, before the final `create_return_cheque_transactions` call:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^return_name => doc} -> [doc.return_date] end,
      com
    )
    |> create_return_cheque_transactions(return_name, com, user)
```

In `update_return_cheque_multi/5`, between `Sys.insert_log_for` and `Multi.delete_all`:

```elixir
    |> Accounting.multi_assert_period_open(
      fn changes ->
        [
          return_cheque.return_date,
          Map.get(changes, return_cheque_name, return_cheque).return_date
        ]
      end,
      com
    )
    |> Multi.delete_all(
```

Add `alias FullCircle.Accounting` at the top of `cheque.ex` if not already present.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/cheque_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/cheque.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/cheque.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Deposit and ReturnCheque"
```

---

## Task 8: Wire Journal

**Files:**
- Modify: `lib/full_circle/journal_entry.ex:140-172` (`create_journal_multi/4`), `:195-225` (`update_journal_multi/5`)
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Accounting.multi_assert_period_open/3` from Task 2.
- Produces: `JournalEntry.create_journal/3` and `update_journal/4` return `{:error, :assert_period_open, :period_closed, _changes}` on a closed-period write.

Journal is shaped differently from every other document: its transactions are a `has_many` with `on_replace: :delete`, written by `cast_assoc` inside the Journal changeset. There is no separate transaction build step and no `Multi.delete_all`. The guard therefore goes immediately **after** the `Multi.insert` / `Multi.update`, reading the resulting struct; a failing step aborts and rolls the whole transaction back.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/period_lock_test.exs`. Build journal attrs the way `journal_live` tests or `accounting_fixtures.ex` do — a Journal needs a balanced `"transactions"` map:

```elixir
  describe "Journal under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.utc_today(), admin)
      attrs = journal_attrs_dated(company, admin, Date.utc_today())

      assert {:error, :assert_period_open, :period_closed, _} =
               FullCircle.JournalEntry.create_journal(attrs, company, admin)
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, company} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)
      attrs = journal_attrs_dated(company, admin, Date.utc_today())

      assert {:ok, %{create_journal: _}} =
               FullCircle.JournalEntry.create_journal(attrs, company, admin)
    end
  end
```

The context module is `FullCircle.JournalEntry` (verified). `create_journal_multi/4` merges `"doc_no"`, `"doc_type"`, `"doc_date"`, `"contact_particulars"` and `"company_id"` into each transaction row itself, so the attrs only need the per-row fields the Journal changeset casts. Add this private helper, adjusting the row keys to whatever `FullCircle.Accounting.Transaction`'s changeset actually casts — read `lib/full_circle/accounting/transaction.ex:88` for the cast list:

```elixir
  defp journal_attrs_dated(company, user, date) do
    debit = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)
    credit = FullCircle.Accounting.get_account_by_name("General Sales", company, user)

    %{
      "journal_date" => Date.to_string(date),
      "transactions" => %{
        "0" => %{
          "account_id" => debit.id,
          "account_name" => debit.name,
          "particulars" => "Test journal debit",
          "amount" => "100.00",
          "_persistent_id" => "0"
        },
        "1" => %{
          "account_id" => credit.id,
          "account_name" => credit.name,
          "particulars" => "Test journal credit",
          "amount" => "-100.00",
          "_persistent_id" => "1"
        }
      }
    }
  end
```

If no existing test creates a Journal, drive `lib/full_circle_web/live/journal_live/form.ex` in the browser once and copy the params it submits — that is the authoritative shape.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the create test returns `{:ok, _}`.

- [ ] **Step 3: Implement**

In `create_journal_multi/4`, append the guard after the log insert at the end of the pipeline:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^journal_name => doc} -> [doc.journal_date] end,
      com
    )
```

In `update_journal_multi/5`, insert the guard between the `Multi.update` and `Sys.insert_log_for`:

```elixir
    multi
    |> Multi.update(journal_name, StdInterface.changeset(Journal, journal, attrs, com))
    |> Accounting.multi_assert_period_open(
      fn changes ->
        [journal.journal_date, Map.get(changes, journal_name, journal).journal_date]
      end,
      com
    )
    |> Sys.insert_log_for(journal_name, attrs, com, user)
```

Add `alias FullCircle.Accounting` at the top of `journal_entry.ex` if not already present.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/journal_entry.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/journal_entry.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Journal"
```

---

## Task 9: Surface the rejection in the document forms

**Files:**
- Modify: `lib/full_circle_web/live/invoice_live/form.ex:786` and the equivalent result-matching clause in `pur_invoice_live/form.ex:940`, `receipt_live/form.ex:617`, `payment_live/form.ex:613`, `credit_note_live/form.ex:314`, `debit_note_live/form.ex:364`, and `journal_live/form.ex`
- Test: `test/full_circle_web/live/period_lock_live_test.exs` (create)

**Interfaces:**
- Consumes: the `{:error, :assert_period_open, :period_closed, _changes}` and `{:error, :period_closed}` returns from Tasks 3–8.
- Produces: no new module interface; user-visible flash only.

Each of these forms already has an `{:error, :closed} ->` clause. Add a sibling clause beside it.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/period_lock_live_test.exs`. Model the setup on `test/full_circle_web/live/stale_save_live_test.exs`, which already drives a document form to a save failure — read it and follow its login and navigation helpers:

```elixir
defmodule FullCircleWeb.PeriodLockLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.BillingFixtures

  alias FullCircle.Sys

  test "a GL-affecting save into a closed period flashes the cutoff", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    invoice = invoice_fixture(company, admin)
    {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

    conn = log_in_user(conn, admin)

    {:ok, view, _html} =
      live(conn, ~p"/companies/#{company.id}/Invoice/#{invoice.id}/edit")

    # Must change a GL-affecting field. Invoice has the fingerprint fast path, so
    # a descriptions-only edit still succeeds by design (see Task 3) and would
    # not exercise this clause.
    html =
      view
      |> form("#object-form",
        invoice: %{invoice_details: %{"0" => %{unit_price: "99.00"}}}
      )
      |> render_submit()

    assert html =~ "Accounting period is closed"
  end
end
```

The form id, param key and route must match what the invoice form actually uses — read `lib/full_circle_web/live/invoice_live/form.ex` and the router before finalising them.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs`
Expected: FAIL — no flash matching "Accounting period is closed".

- [ ] **Step 3: Implement**

In each of the seven forms, beside the existing `{:error, :closed} ->` clause in the save result `case`, add:

```elixir
      {:error, :assert_period_open, :period_closed, _} ->
        {:noreply,
         socket
         |> put_flash(
           :warn,
           gettext("Accounting period is closed on or before %{date}.",
             date:
               to_string(
                 FullCircle.Sys.period_closed_through(socket.assigns.current_company)
               )
           )
         )}
```

In the Receipt and Payment forms, add the same message for the delete path's `{:error, :period_closed}` return from Task 5 and Task 6:

```elixir
      {:error, :period_closed} ->
        {:noreply,
         socket
         |> put_flash(
           :warn,
           gettext("Accounting period is closed on or before %{date}.",
             date:
               to_string(
                 FullCircle.Sys.period_closed_through(socket.assigns.current_company)
               )
           )
         )}
```

The flash kind must be `:warn`. `:warning` renders nothing.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle_web/live/invoice_live/form.ex lib/full_circle_web/live/pur_invoice_live/form.ex lib/full_circle_web/live/receipt_live/form.ex lib/full_circle_web/live/payment_live/form.ex lib/full_circle_web/live/credit_note_live/form.ex lib/full_circle_web/live/debit_note_live/form.ex lib/full_circle_web/live/journal_live/form.ex test/full_circle_web/live/period_lock_live_test.exs
git add lib/full_circle_web/live/ test/full_circle_web/live/period_lock_live_test.exs
git commit -m "feat(period-lock): flash the cutoff date when a save is blocked"
```

---

## Task 10: The administrator control on the company form

**Files:**
- Modify: `lib/full_circle_web/live/company_live/form.ex` (near the LLM settings block at lines 118-170 and its `handle_event` at line 274)
- Test: `test/full_circle_web/live/period_lock_live_test.exs`

**Interfaces:**
- Consumes: `Sys.period_closed_through/1`, `Sys.close_period_through/3` from Task 1.
- Produces: no new module interface.

The LLM settings block in this file is the pattern to follow — it reads a namespaced settings map in `mount`, renders its own form, and saves through a dedicated `handle_event`.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle_web/live/period_lock_live_test.exs`:

```elixir
  test "an admin sees the period cutoff control", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    conn = log_in_user(conn, admin)

    {:ok, _view, html} = live(conn, ~p"/companies/#{company.id}/edit")

    assert html =~ "Close Accounting Period"
  end

  test "a clerk does not see the period cutoff control", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    clerk = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, _} = Sys.allow_user_to_access(company, clerk, "clerk")

    conn = log_in_user(conn, clerk)

    {:ok, _view, html} = live(conn, ~p"/companies/#{company.id}/edit")

    refute html =~ "Close Accounting Period"
  end

  test "an admin can set the cutoff from the form", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    conn = log_in_user(conn, admin)

    {:ok, view, _html} = live(conn, ~p"/companies/#{company.id}/edit")

    view
    |> form("#period-lock-form", period: %{closed_through: "2025-12-31"})
    |> render_submit()

    company = FullCircle.Sys.get_company!(company.id)
    assert Sys.period_closed_through(company) == ~D[2025-12-31]
  end
```

Confirm the company edit route from the router before finalising the `~p` paths, and match `allow_user_to_access/3` to whatever `sys.ex` actually exposes.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs`
Expected: FAIL — no "Close Accounting Period" text in the rendered form.

- [ ] **Step 3: Implement**

Add to `mount/3` in `company_live/form.ex`, beside the existing `:llm_settings` assign:

```elixir
|> assign(:closed_through, Sys.period_closed_through(company))
|> assign(:is_admin, Sys.user_role_in_company(current_user.id, company.id) == "admin")
```

Use whichever variable names the surrounding `mount/3` already binds for the company and the current user.

Add the block to `render/1`, near the existing closing_month/closing_day fields:

```heex
<div :if={@is_admin} class="mt-6 rounded border border-amber-400 p-4">
  <div class="font-medium text-lg">{gettext("Close Accounting Period")}</div>
  <p class="text-sm mb-2">
    {gettext(
      "Blocks creating, amending or deleting any document dated on or before this date. This is separate from the financial-year closing month and day above. Clear the field to reopen."
    )}
  </p>
  <p :if={@closed_through} class="text-sm mb-2 font-medium">
    {gettext("Currently closed through %{date}", date: to_string(@closed_through))}
  </p>
  <.form id="period-lock-form" for={%{}} as={:period} phx-submit="save_period_lock">
    <input
      type="date"
      name="period[closed_through]"
      value={to_string(@closed_through)}
      class="rounded border p-2"
    />
    <button
      class="button orange"
      data-confirm={
        gettext("Closing a period blocks all edits to documents dated on or before it. Continue?")
      }
    >
      {gettext("Save")}
    </button>
  </.form>
</div>
```

Match the surrounding file's Tailwind conventions, and check both light and dark themes render acceptably.

Add the `handle_event`:

```elixir
def handle_event("save_period_lock", %{"period" => %{"closed_through" => str}}, socket) do
  date =
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      {:error, _} -> nil
    end

  case Sys.close_period_through(
         socket.assigns.company,
         date,
         socket.assigns.current_user
       ) do
    {:ok, company} ->
      {:noreply,
       socket
       |> assign(:company, company)
       |> assign(:closed_through, Sys.period_closed_through(company))
       |> put_flash(:info, gettext("Accounting period updated."))}

    {:error, :future_date} ->
      {:noreply, put_flash(socket, :warn, gettext("Cannot close a period that has not ended."))}

    :not_authorise ->
      {:noreply, put_flash(socket, :warn, gettext("Not authorised."))}
  end
end
```

Match the socket assign names the file already uses for the company and current user.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs test/full_circle_web/live/company_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle_web/live/company_live/form.ex test/full_circle_web/live/period_lock_live_test.exs
git add lib/full_circle_web/live/company_live/form.ex test/full_circle_web/live/period_lock_live_test.exs
git commit -m "feat(period-lock): admin control for the cutoff on the company form"
```

---

## Task 11: The missing BEFORE UPDATE trigger

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_update_closed_transaction_trigger.exs`
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: nothing. Independent of Tasks 1–10 and safe to do in any order.
- Produces: no module interface. A direct `UPDATE` of a transaction with `closed = true` now raises.

Migration `20230421072511_create_transaction_trigger.exs` defines a function named `cannot_update_or_delete_closed_transaction` whose message reads "Cannot update or delete a CLOSED transaction!", but only ever creates `BEFORE DELETE`. The function itself already handles the `OLD.closed = true` case and needs no change.

- [ ] **Step 1: Write the failing test**

Append to `test/full_circle/period_lock_test.exs`:

```elixir
  describe "closed transaction trigger" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "a closed transaction cannot be updated", %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)

      txn =
        Repo.one!(
          from t in FullCircle.Accounting.Transaction,
            where: t.doc_type == "Invoice" and t.doc_id == ^invoice.id,
            limit: 1
        )

      {1, _} =
        Repo.update_all(
          from(t in FullCircle.Accounting.Transaction, where: t.id == ^txn.id),
          set: [closed: true]
        )

      assert_raise Postgrex.Error, ~r/CLOSED transaction/, fn ->
        Repo.update_all(
          from(t in FullCircle.Accounting.Transaction, where: t.id == ^txn.id),
          set: [particulars: "tampered"]
        )
      end
    end

    test "an open transaction updates normally", %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)

      txn =
        Repo.one!(
          from t in FullCircle.Accounting.Transaction,
            where: t.doc_type == "Invoice" and t.doc_id == ^invoice.id,
            limit: 1
        )

      assert {1, _} =
               Repo.update_all(
                 from(t in FullCircle.Accounting.Transaction, where: t.id == ^txn.id),
                 set: [particulars: "fine"]
               )
    end
  end
```

The first `update_all` that sets `closed: true` must run **before** the trigger exists to bite — it sets `closed` on a row whose `OLD.closed` is still `false`, so it passes the trigger check either way.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the update succeeds where `Postgrex.Error` is asserted.

- [ ] **Step 3: Implement**

Generate the migration:

```bash
mix ecto.gen.migration add_update_closed_transaction_trigger
```

Fill it in:

```elixir
defmodule FullCircle.Repo.Migrations.AddUpdateClosedTransactionTrigger do
  use Ecto.Migration

  # 20230421072511 created cannot_update_or_delete_closed_transaction/0 and a
  # BEFORE DELETE trigger, but never the BEFORE UPDATE half its name and error
  # message promise. A direct UPDATE of a closed transaction has succeeded
  # silently since then. The function is unchanged; only the trigger is added.

  def up do
    execute """
    CREATE TRIGGER update_closed_transaction_trigger
      BEFORE UPDATE ON transactions FOR EACH ROW
      EXECUTE PROCEDURE cannot_update_or_delete_closed_transaction();
    """
  end

  def down do
    execute "DROP TRIGGER update_closed_transaction_trigger ON transactions;"
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix ecto.migrate && mix test test/full_circle/period_lock_test.exs`
Expected: PASS.

Then run the whole suite — this trigger is global and could catch an existing test that updates a seeded closed transaction:

Run: `mix test`
Expected: PASS, no regressions against the 1105-test baseline. If a seeding or reporting test now fails, the trigger has found a real write to a closed transaction; report it rather than weakening the trigger.

- [ ] **Step 5: Format and commit**

```bash
mix format test/full_circle/period_lock_test.exs
git add priv/repo/migrations/ test/full_circle/period_lock_test.exs
git commit -m "fix(accounting): add the BEFORE UPDATE trigger for closed transactions"
```

---

## Task 12: Document the contract as a skill

**Files:**
- Create: `.claude/skills/accounting-period-lock.md`
- Modify: `CLAUDE.md` (the project-skills list under "Domain Contexts")

**Interfaces:**
- Consumes: the finished behaviour from Tasks 1–11.
- Produces: no code interface.

Per the project's Skill Authoring Convention, a non-obvious contract like this belongs in a skill. **Ask the user to confirm before finalising** — do not create it silently.

- [ ] **Step 1: Draft the skill**

Create `.claude/skills/accounting-period-lock.md` with frontmatter whose `description` names the trigger conditions — editing a document context's save path, adding a new GL-posting document type, or debugging a `:period_closed` error. Contents:

- Where the cutoff lives and the two `Sys` functions that read and write it.
- The rule, stated once: a save is blocked when it would write or delete GL rows dated on or before the cutoff.
- Why the guard sits in the multi and not in `make_changeset/5`.
- The `doc_transactions_unchanged?` asymmetry: Invoice, PurInvoice, CreditNote and DebitNote keep non-GL editability; Payment, Receipt, Deposit, ReturnCheque and Journal do not.
- **Any new GL-posting document type must add the guard** before its transaction build and its transaction `delete_all`, or it silently bypasses the lock.
- That `transactions.closed` is unrelated and means "seeded opening balance".

- [ ] **Step 2: Add the pointer to CLAUDE.md**

Append `accounting-period-lock.md` to the project-skills list in the "Domain Contexts" section.

- [ ] **Step 3: Ask the user to confirm, then commit**

```bash
git add .claude/skills/accounting-period-lock.md CLAUDE.md
git commit -m "docs: accounting period lock skill"
```

---

## Final verification

- [ ] Run the full suite: `mix test`. Expected: PASS, no regressions against the 1105-test baseline.
- [ ] Confirm `git status` is clean and no unrelated file was reformatted (`git diff --stat HEAD~12..HEAD` should list only the files named in this plan).
- [ ] Manually exercise the flow in `mix phx.server`: set a cutoff on a test company, confirm an invoice dated before it is refused with the flash, confirm a description-only edit on that same invoice still saves, then clear the cutoff and confirm both save.
- [ ] Check the company-form control in both light and dark themes.
