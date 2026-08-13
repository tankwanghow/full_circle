# Accounting Period Lock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give administrators a cutoff date per company that blocks writing or rebuilding general-ledger rows dated on or before it, across the eight core accounting documents plus Journal.

**Architecture:** The cutoff lives in `company.settings["period"]["closed_through"]`, set only through an admin-gated, logged function on `FullCircle.Sys`. `period_closed_through/1` always re-reads that map from the database — the session `current_company` is stale. Enforcement is a single `Ecto.Multi.run` step inserted immediately before the operations that touch the GL. Public `create_*` / `update_*` map the Multi failure to `{:error, :period_closed}`. There is no document-level delete to guard.

**Tech Stack:** Elixir 1.19.5, Phoenix 1.8.3, Phoenix LiveView 1.1.x, Ecto/Postgres, ExUnit.

Spec: `docs/superpowers/specs/2026-08-09-accounting-period-lock-design.md` (revised 2026-08-13)

## Global Constraints

- Never run bare `mix format` — it rewrites roughly 14 already-unformatted files on master. Format only the files you touched: `mix format path/to/file.ex`.
- Commit directly to `master`. No feature branches.
- LiveView flash kind must be `:warn`. `:warning` renders nothing, silently.
- All new user-facing strings go through `gettext/1`.
- Schemas use `use FullCircle.Schema` (binary_id primary keys), not `use Ecto.Schema`.
- The existing `transactions.closed` flag means "seeded opening balance". Do not repurpose it, and do not write to it.
- Bind insertion points by **function name**, not the line numbers in older drafts — they have drifted.
- Public APIs return `{:error, :period_closed}`, never `{:error, :assert_period_open, :period_closed, _}`.
- Do not add `delete_receipt` / `delete_payment`. Receipt and Payment are not deletable documents.
- Run tests with `mix test`.

---

## File Structure

**Created:**
- `priv/repo/migrations/<timestamp>_add_update_closed_transaction_trigger.exs` — replace the trigger function (`RETURN NEW` on UPDATE) and add the missing `BEFORE UPDATE` trigger.
- `test/full_circle/period_lock_test.exs` — cutoff storage, the guard, per-document create/update.
- `test/full_circle_web/live/period_lock_live_test.exs` — company-form control and a blocked save's flash.

**Modified:**
- `lib/full_circle/sys.ex` — `period_closed_through/1`, `close_period_through/3`.
- `lib/full_circle/accounting.ex` — `assert_period_open/2`, `multi_assert_period_open/3`, `map_period_closed/1`.
- `lib/full_circle/billing.ex` — guard + map on Invoice and PurInvoice create/update.
- `lib/full_circle/debcre.ex` — guard + map on CreditNote and DebitNote create/update.
- `lib/full_circle/bill_pay.ex` — guard + map on Payment create/update. No delete wrapper.
- `lib/full_circle/receive_fund.ex` — guard + map on Receipt create/update. No delete wrapper.
- `lib/full_circle/cheque.ex` — guard + map on Deposit and ReturnCheque create/update.
- `lib/full_circle/journal_entry.ex` — guard + map on Journal create/update.
- `lib/full_circle_web/live/{invoice,pur_invoice,receipt,payment,credit_note,debit_note,journal}_live/form.ex`
- `lib/full_circle_web/live/cheque_live/{deposit_form,return_cheque_form}.ex`
- `lib/full_circle_web/live/company_live/form.ex` — sibling admin cutoff form after `#company` closes.

---

## Task 1: Cutoff storage and the administrator action

**Files:**
- Modify: `lib/full_circle/sys.ex` (after `update_company_settings/3`)
- Test: `test/full_circle/period_lock_test.exs` (create)

**Interfaces:**
- Consumes: `Sys.get_company_settings/2`, `Sys.log_changeset/5`, `Sys.user_role_in_company/2`, `FullCircle.Repo`, `FullCircle.Sys.Company`.
- Produces:
  - `Sys.period_closed_through(company) :: Date.t() | nil`
  - `Sys.close_period_through(company, Date.t() | nil, user) :: {:ok, Company.t()} | {:error, :future_date} | :not_authorise`

- [ ] **Step 1: Write the failing tests**

Create `test/full_circle/period_lock_test.exs`:

```elixir
defmodule FullCircle.PeriodLockTest do
  use FullCircle.DataCase

  alias FullCircle.Sys
  alias FullCircle.Sys.Company

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  defp company_today(company) do
    case DateTime.now(company.timezone || "Etc/UTC") do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

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
      future = Date.add(company_today(company), 1)
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
      {:ok, _} = Sys.update_company_settings(company, "period", %{"closed_through" => "rubbish"})
      assert Sys.period_closed_through(company) == nil
    end

    test "reads the cutoff from the database, not the in-memory struct", %{
      company: company,
      admin: admin
    } do
      {:ok, _} = Sys.close_period_through(company, ~D[2025-12-31], admin)
      stale = %{company | settings: %{}}
      assert Sys.period_closed_through(stale) == ~D[2025-12-31]
    end
  end
end
```

`Sys.allow_user_to_access/4` — granting admin last. `company_fixture` sets `timezone: "Asia/Kuala_Lumpur"`; never use `Date.utc_today() + 1` for the future-date test.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL with `function FullCircle.Sys.period_closed_through/1 is undefined`.

- [ ] **Step 3: Implement**

Add to `lib/full_circle/sys.ex`, directly after `update_company_settings/3`:

```elixir
  @period_settings_key "period"
  @closed_through_key "closed_through"

  @doc """
  The date through which this company's accounting period is closed, or `nil`.

  Always re-reads `companies.settings` from the database. The session
  `current_company` is a snapshot and must not be trusted for the cutoff.
  Returns `nil` for an unset or unparseable value.
  """
  def period_closed_through(company) do
    company
    |> then(&Repo.get!(Company, &1.id))
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
        fresh = Repo.get!(Company, company.id)
        new_settings = Map.put(fresh.settings || %{}, @period_settings_key, values)

        # Multi.update is the clearer shape. Repo.update inside Multi.run would
        # also join this transaction — style, not a correctness fix.
        Ecto.Multi.new()
        |> Ecto.Multi.update(:company, Ecto.Changeset.change(fresh, %{settings: new_settings}))
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

`Company` is already aliased in `sys.ex`. `log_changeset/5` builds `entity` from the struct, so the log row is anchored to the company.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/sys.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/sys.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): admin-set accounting period cutoff on the company"
```

---

## Task 2: The guard function

**Files:**
- Modify: `lib/full_circle/accounting.ex` (immediately after `assert_doc_editable/4`)
- Test: `test/full_circle/period_lock_test.exs`

**Interfaces:**
- Consumes: `Sys.period_closed_through/1` from Task 1.
- Produces:
  - `Accounting.assert_period_open([Date.t() | nil], company) :: :ok | {:error, :period_closed}`
  - `Accounting.multi_assert_period_open(Ecto.Multi.t(), (map() -> [Date.t() | nil]), company) :: Ecto.Multi.t()`
  - `Accounting.map_period_closed(term()) :: term()`

- [ ] **Step 1: Write the failing tests**

Append inside the test module:

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

  describe "map_period_closed/1" do
    test "collapses the Multi 4-tuple" do
      assert {:error, :period_closed} =
               FullCircle.Accounting.map_period_closed(
                 {:error, :assert_period_open, :period_closed, %{}}
               )
    end

    test "passes other results through" do
      assert {:ok, :x} = FullCircle.Accounting.map_period_closed({:ok, :x})
      assert :not_authorise = FullCircle.Accounting.map_period_closed(:not_authorise)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL with `function FullCircle.Accounting.assert_period_open/2 is undefined`.

- [ ] **Step 3: Implement**

Add to `lib/full_circle/accounting.ex` immediately after `assert_doc_editable/4`:

```elixir
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

  def multi_assert_period_open(multi, dates_fun, company) do
    Ecto.Multi.run(multi, :assert_period_open, fn _repo, changes ->
      case assert_period_open(dates_fun.(changes), company) do
        :ok -> {:ok, :period_open}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def map_period_closed({:error, :assert_period_open, :period_closed, _}), do: {:error, :period_closed}
  def map_period_closed(other), do: other
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/accounting.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/accounting.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): assert_period_open guard and its Multi wrapper"
```

---

## Task 3: Wire Invoice and PurInvoice

**Files:**
- Modify: `lib/full_circle/billing.ex` — `update_doc_multi/9` rebuild branch, `create_invoice_multi/4`, `create_pur_invoice_multi/4`, and each public `create_*` / `update_*` (`|> Repo.transaction() |> Accounting.map_period_closed()`).
- Test: `test/full_circle/period_lock_test.exs`

`billing.ex` already aliases `FullCircle.Accounting`. Guard the `else` branch of `doc_transactions_unchanged?` only.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "Invoice under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               create_invoice_dated(company, admin, Date.utc_today())
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, %{create_invoice: _}} =
               create_invoice_dated(company, admin, Date.utc_today())
    end

    test "editing a GL field on a closed-period invoice is rejected",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)

      assert {:error, :period_closed} =
               FullCircle.Billing.update_invoice(invoice, gl_changing_attrs(invoice), company, admin)
    end

    test "a description-only edit on a closed-period invoice still succeeds",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)

      assert {:ok, %{update_invoice: updated}} =
               FullCircle.Billing.update_invoice(
                 invoice,
                 description_only_attrs(invoice, "edited after closing"),
                 company,
                 admin
               )

      assert updated.descriptions == "edited after closing"
    end

    test "moving an open invoice into a closed period is rejected",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)

      assert {:error, :period_closed} =
               FullCircle.Billing.update_invoice(
                 invoice,
                 date_change_attrs(invoice, Date.add(Date.utc_today(), -60)),
                 company,
                 admin
               )
    end
  end

  describe "PurInvoice under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               create_pur_invoice_dated(company, admin, Date.utc_today())
    end
  end
```

Private helpers at the bottom of the module. `lock_version` is required:

```elixir
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
      "lock_version" => invoice.lock_version,
      "invoice_details" => details
    }
  end

  defp description_only_attrs(invoice, text) do
    invoice |> invoice_to_attrs() |> Map.put("descriptions", text)
  end

  defp gl_changing_attrs(invoice) do
    attrs = invoice_to_attrs(invoice)
    details = Map.update!(attrs["invoice_details"], "0", &Map.put(&1, "unit_price", "99.00"))
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

  defp create_pur_invoice_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoPTax"
      )

    attrs =
      FullCircle.BillingFixtures.pur_invoice_attrs(contact, good, acct, tc, tax_rate: "0")
      |> Map.put("pur_invoice_date", Date.to_string(date))

    FullCircle.Billing.create_pur_invoice(attrs, company, user)
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — create/edit return `{:ok, _}` where `{:error, :period_closed}` is asserted. The description-only test should already pass.

- [ ] **Step 3: Implement**

In `update_doc_multi/9`, replace the `else` branch so the guard sits before `Multi.delete_all`:

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

In `create_invoice_multi/4`, before `create_doc_transactions`:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^invoice_name => doc} -> [doc.invoice_date] end,
      com
    )
```

Same in `create_pur_invoice_multi/4` with `doc.pur_invoice_date`.

On every public `create_invoice`, `update_invoice`, `create_pur_invoice`, `update_pur_invoice`, change `|> Repo.transaction()` to `|> Repo.transaction() |> Accounting.map_period_closed()`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/billing_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/billing.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/billing.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Invoice and PurInvoice"
```

---

## Task 4: Wire CreditNote and DebitNote

**Files:**
- Modify: `lib/full_circle/debcre.ex` — `update_note_multi/8` rebuild branch, both create multis, all four public functions via `map_period_closed/1`. Add `alias FullCircle.Accounting` if missing.
- Test: `test/full_circle/period_lock_test.exs`

Notes use `:note_date` directly; `@credit_note_txn_opts` has no `doc_date_key`.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "CreditNote under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.DebCre.create_credit_note(
                 credit_note_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "a description-only edit on a closed-period credit note still succeeds",
         %{company: company, admin: admin} do
      {:ok, %{create_credit_note: cn}} =
        FullCircle.DebCre.create_credit_note(
          credit_note_attrs_dated(company, admin, Date.utc_today()),
          company,
          admin
        )

      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)
      cn = FullCircle.DebCre.get_credit_note!(cn.id, company, admin)

      attrs = credit_note_to_attrs(cn) |> Map.put("descriptions", "edited after closing")

      assert {:ok, %{update_credit_note: updated}} =
               FullCircle.DebCre.update_credit_note(cn, attrs, company, admin)

      assert updated.descriptions == "edited after closing"
    end
  end

  describe "DebitNote under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.DebCre.create_debit_note(
                 debit_note_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end
```

Helpers — read `get_credit_note!/3` and the CreditNote schema for the descriptions field and detail assoc names before filling `credit_note_to_attrs/1`. Include `lock_version` and each detail `id`. If CreditNote has no `descriptions` header field, change the description-only test to a non-GL field that exists (or skip that assertion and only assert `{:ok, _}`).

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

  defp debit_note_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    acct = FullCircle.Accounting.get_account_by_name("General Purchases", company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoPTax"
      )

    FullCircle.DebCreFixtures.debit_note_attrs(contact, acct, tc, tax_rate: "0")
    |> Map.put("note_date", Date.to_string(date))
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the create tests return `{:ok, _}`.

- [ ] **Step 3: Implement**

In `update_note_multi/8` `else` branch, insert the guard before `Multi.delete_all`, dates `[note.note_date, Map.get(changes, step_name, note).note_date]`.

In both create multis, insert the guard before `create_note_transactions` with `[doc.note_date]`.

Pipe all four public functions through `Accounting.map_period_closed/1`.

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

## Task 5: Wire Payment (create and update only)

**Files:**
- Modify: `lib/full_circle/bill_pay.ex` — `create_payment_multi/4`, `update_payment_multi/5`, public `create_payment/3` and `update_payment/4`.
- Test: `test/full_circle/period_lock_test.exs`

Do **not** add `delete_payment/3`. Do **not** touch `payment_live/form.ex` delete handler.

Payment has no fingerprint fast path.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "Payment under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.BillPay.create_payment(
                 payment_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, %{create_payment: _}} =
               FullCircle.BillPay.create_payment(
                 payment_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end
```

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
Expected: FAIL — create returns `{:ok, _}`.

- [ ] **Step 3: Implement**

In `create_payment_multi/4`, before `create_payment_transactions`:

```elixir
    |> Accounting.multi_assert_period_open(
      fn %{^payment_name => doc} -> [doc.payment_date] end,
      com
    )
```

In `update_payment_multi/5`, between `Multi.update` and `Multi.delete_all`, dates `[payment.payment_date, Map.get(changes, payment_name, payment).payment_date]`.

Pipe `create_payment/3` and `update_payment/4` through `Accounting.map_period_closed/1`. Add `alias FullCircle.Accounting` if missing.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/bill_pay_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/bill_pay.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/bill_pay.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Payment"
```

---

## Task 6: Wire Receipt (create and update only)

**Files:**
- Modify: `lib/full_circle/receive_fund.ex` — create multi, `update_doc_multi/8`, public `create_receipt/3` and `update_receipt/4`.
- Test: `test/full_circle/period_lock_test.exs`

Do **not** add `delete_receipt/3`. Do **not** touch `receipt_live/form.ex` delete handler.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "Receipt under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.ReceiveFund.create_receipt(
                 receipt_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "a description-only edit on a closed-period receipt is rejected",
         %{company: company, admin: admin} do
      receipt = FullCircle.ReceiveFundFixtures.receipt_fixture(company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      receipt = FullCircle.ReceiveFund.get_receipt!(receipt.id, company, admin)
      attrs = receipt_to_attrs(receipt) |> Map.put("descriptions", "edited after closing")

      assert {:error, :period_closed} =
               FullCircle.ReceiveFund.update_receipt(receipt, attrs, company, admin)
    end

    test "a new receipt can still match a closed-period invoice",
         %{company: company, admin: admin} do
      invoice = FullCircle.BillingFixtures.invoice_fixture(company, admin)
      invoice = FullCircle.Billing.get_invoice!(invoice.id, company, admin)
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      attrs =
        receipt_attrs_matching(company, admin, invoice, Date.add(Date.utc_today(), 1))

      assert {:ok, %{create_receipt: _}} =
               FullCircle.ReceiveFund.create_receipt(attrs, company, admin)
    end
  end
```

Helpers — `receipt_to_attrs/1` must rebuild details, funds, cheques and matchers from the loaded receipt (mirror `test/full_circle/receive_fund_test.exs` update attrs, plus `lock_version`). A descriptions-only map fails the changeset first.

`receipt_attrs_matching/4` finds the invoice's contact-bearing transaction and attaches a matcher. `receive_fund_test.exs` does **not** contain this shape — write it:

```elixir
  defp receipt_attrs_dated(company, user, date) do
    contact = FullCircle.BillingFixtures.contact_fixture(company, user)
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)
    funds_acct = FullCircle.ReceiveFundFixtures.funds_account_fixture(company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    FullCircle.ReceiveFundFixtures.receipt_attrs_with_funds(
      contact,
      good,
      sales_acct,
      tc,
      funds_acct,
      tax_rate: "0"
    )
    |> Map.put("receipt_date", Date.to_string(date))
  end

  defp receipt_attrs_matching(company, user, invoice, date) do
    good = FullCircle.BillingFixtures.good_fixture(company, user)
    sales_acct = FullCircle.Accounting.get_account_by_name("General Sales", company, user)
    funds_acct = FullCircle.ReceiveFundFixtures.funds_account_fixture(company, user)

    tc =
      Repo.one!(
        from t in FullCircle.Accounting.TaxCode,
          where: t.company_id == ^company.id and t.code == "NoSTax"
      )

    ar_txn =
      Repo.one!(
        from t in FullCircle.Accounting.Transaction,
          where: t.doc_type == "Invoice",
          where: t.doc_id == ^invoice.id,
          where: not is_nil(t.contact_id),
          limit: 1
      )

    FullCircle.ReceiveFundFixtures.receipt_attrs_with_funds(
      %{name: invoice.contact_name, id: invoice.contact_id},
      good,
      sales_acct,
      tc,
      funds_acct,
      tax_rate: "0",
      quantity: "0",
      unit_price: "0",
      funds_amount: "50.00"
    )
    |> Map.put("receipt_date", Date.to_string(date))
    |> Map.put("contact_id", invoice.contact_id)
    |> Map.put("contact_name", invoice.contact_name)
    |> Map.put("transaction_matchers", %{
      "0" => %{
        "transaction_id" => ar_txn.id,
        "match_amount" => "50.00",
        "doc_date" => Date.to_string(date),
        "doc_type" => "Receipt",
        "t_doc_no" => invoice.invoice_no,
        "t_doc_type" => "Invoice",
        "t_doc_date" => Date.to_string(invoice.invoice_date),
        "t_doc_id" => invoice.id,
        "amount" => to_string(ar_txn.amount),
        "all_matched_amount" => "0",
        "_persistent_id" => "0"
      }
    })
  end
```

If `receipt_attrs_with_funds` rejects a map-as-contact, build the contact from `invoice.contact_id` via `Repo.get!`. If create fails validation, read `ReceiveFund.Receipt` changeset and the matcher `validate_required` list and adjust — do not drop the test.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — create returns `{:ok, _}`.

- [ ] **Step 3: Implement**

Guard `update_doc_multi/8` between `Multi.update` and `Multi.delete_all` (`[doc.receipt_date, new.receipt_date]`). Guard the create multi before `create_receipt_transactions`. Pipe public create/update through `map_period_closed/1`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/period_lock_test.exs test/full_circle/receive_fund_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/receive_fund.ex test/full_circle/period_lock_test.exs
git add lib/full_circle/receive_fund.ex test/full_circle/period_lock_test.exs
git commit -m "feat(period-lock): enforce the cutoff on Receipt"
```

---

## Task 7: Wire Deposit and ReturnCheque

**Files:**
- Modify: `lib/full_circle/cheque.ex` — all four create/update multis and public functions.
- Test: `test/full_circle/period_lock_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "Deposit under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.Cheque.create_deposit(
                 deposit_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, %{create_deposit: _}} =
               FullCircle.Cheque.create_deposit(
                 deposit_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end

  describe "ReturnCheque under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.Cheque.create_return_cheque(
                 return_cheque_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end
```

`deposit_attrs_dated/3` is the map inside `ChequeFixtures.deposit_fixture/3` with the date parameterised. `return_cheque_attrs_dated/3` copies `ChequeFixtures.return_cheque_fixture/2`: create a receipt-with-cheque **before** closing the period (or dated after the cutoff if you close first — the receipt itself must not be blocked), then build the return attrs with the given `return_date`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — create returns `{:ok, _}`.

- [ ] **Step 3: Implement**

Guard each create multi before its `create_*_transactions` (`deposit_date` / `return_date`). Guard each update multi between log insert and `Multi.delete_all`. Pipe the four public functions through `map_period_closed/1`. Add `alias FullCircle.Accounting` if missing.

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
- Modify: `lib/full_circle/journal_entry.ex` — `create_journal_multi/4`, `update_journal_multi/5`, public create/update.
- Test: `test/full_circle/period_lock_test.exs`

Journal transactions are a `has_many` with `on_replace: :delete`, written by `cast_assoc`. There is no separate `delete_all`. Place the guard **after** `Multi.insert` / `Multi.update` so a failing step rolls the header back.

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "Journal under a closed period" do
    setup do
      %{admin: admin, company: company} = FullCircle.BillingFixtures.billing_setup()
      %{admin: admin, company: company}
    end

    test "creating into a closed period is rejected", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.utc_today(), admin)

      assert {:error, :period_closed} =
               FullCircle.JournalEntry.create_journal(
                 journal_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end

    test "creating after the cutoff succeeds", %{company: company, admin: admin} do
      {:ok, _} = Sys.close_period_through(company, Date.add(Date.utc_today(), -30), admin)

      assert {:ok, %{create_journal: _}} =
               FullCircle.JournalEntry.create_journal(
                 journal_attrs_dated(company, admin, Date.utc_today()),
                 company,
                 admin
               )
    end
  end
```

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

Read `Transaction.journal_entry_changeset/2` if this map is rejected and adjust keys.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — create returns `{:ok, _}`.

- [ ] **Step 3: Implement**

Append the guard after the log insert on create (`[doc.journal_date]`). On update, insert it between `Multi.update` and `Sys.insert_log_for`, dates `[journal.journal_date, new.journal_date]`. Pipe public create/update through `map_period_closed/1`.

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
- Modify the save `case` in:
  - `lib/full_circle_web/live/invoice_live/form.ex`
  - `lib/full_circle_web/live/pur_invoice_live/form.ex`
  - `lib/full_circle_web/live/receipt_live/form.ex`
  - `lib/full_circle_web/live/payment_live/form.ex`
  - `lib/full_circle_web/live/credit_note_live/form.ex`
  - `lib/full_circle_web/live/debit_note_live/form.ex`
  - `lib/full_circle_web/live/journal_live/form.ex`
  - `lib/full_circle_web/live/cheque_live/deposit_form.ex`
  - `lib/full_circle_web/live/cheque_live/return_cheque_form.ex`
- Test: `test/full_circle_web/live/period_lock_live_test.exs` (create)

Contexts now return `{:error, :period_closed}`. A 2-tuple does not collide with `{:error, failed_operation, changeset, _}`. Add the clause on **new and edit** save paths of each form. Journal / Deposit / ReturnCheque have no `{:error, :closed}` today — add this clause anyway.

Place `{:error, :period_closed}` **above any looser `{:error, _}` (or `{:error, _, _, _}`) clause in the same `case`**. A generic match listed first would swallow it. On the invoice save path today the looser `{:error, _}` clauses live in other handlers, not that `case`, so this is unlikely to bite — still put the new clause first.

Do **not** change any `handle_event("delete")`.

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/live/period_lock_live_test.exs`. Follow login/navigation in `test/full_circle_web/live/stale_save_live_test.exs`. Invoice form id is `object-form`.

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

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs`
Expected: FAIL — no flash matching "Accounting period is closed".

- [ ] **Step 3: Implement**

In every save `case` listed above (both `:new` and `:edit` where they are separate functions). Insert this clause **before** any `{:error, _}` or `{:error, _, _, _}` catch-all in that same `case`:

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

Flash kind must be `:warn`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle_web/live/invoice_live/form.ex lib/full_circle_web/live/pur_invoice_live/form.ex lib/full_circle_web/live/receipt_live/form.ex lib/full_circle_web/live/payment_live/form.ex lib/full_circle_web/live/credit_note_live/form.ex lib/full_circle_web/live/debit_note_live/form.ex lib/full_circle_web/live/journal_live/form.ex lib/full_circle_web/live/cheque_live/deposit_form.ex lib/full_circle_web/live/cheque_live/return_cheque_form.ex test/full_circle_web/live/period_lock_live_test.exs
git add lib/full_circle_web/live/ test/full_circle_web/live/period_lock_live_test.exs
git commit -m "feat(period-lock): flash the cutoff date when a save is blocked"
```

---

## Task 10: The administrator control on the company form

**Files:**
- Modify: `lib/full_circle_web/live/company_live/form.ex`
- Test: `test/full_circle_web/live/period_lock_live_test.exs`

The edit route is `/edit_company/:id`. `mount_edit` already assigns `:company` from `Sys.get_company!/1` and `:current_role`. LLM settings use `@current_role == "admin"` — reuse that, do not invent `@is_admin`.

The period form is a **sibling after** `</.form>` of `#company`. Do not nest it.

- [ ] **Step 1: Write the failing tests**

```elixir
  test "an admin sees the period cutoff control", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    conn = log_in_user(conn, admin)

    {:ok, _view, html} = live(conn, ~p"/edit_company/#{company.id}")

    assert html =~ "Close Accounting Period"
  end

  test "a clerk does not see the period cutoff control", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    clerk = FullCircle.UserAccountsFixtures.user_fixture()
    {:ok, _} = Sys.allow_user_to_access(company, clerk, "clerk", admin)

    conn = log_in_user(conn, clerk)

    {:ok, _view, html} = live(conn, ~p"/edit_company/#{company.id}")

    refute html =~ "Close Accounting Period"
  end

  test "an admin can set the cutoff from the form", %{conn: conn} do
    %{admin: admin, company: company} = billing_setup()
    conn = log_in_user(conn, admin)

    {:ok, view, _html} = live(conn, ~p"/edit_company/#{company.id}")

    view
    |> form("#period-lock-form", period: %{closed_through: "2025-12-31"})
    |> render_submit()

    company = FullCircle.Sys.get_company!(company.id)
    assert Sys.period_closed_through(company) == ~D[2025-12-31]
  end
```

`allow_user_to_access/4` — granting admin last.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle_web/live/period_lock_live_test.exs`
Expected: FAIL — no "Close Accounting Period" text.

- [ ] **Step 3: Implement**

In `mount_edit/2`, after the existing assigns:

```elixir
|> assign(:closed_through, Sys.period_closed_through(company))
```

After the company `</.form>` (the one that ends just before `end` of `render/1`), add:

```heex
    <div
      :if={@live_action == :edit and @current_role == "admin"}
      class="max-w-2xl mx-auto mt-6 rounded border border-amber-400 p-4"
    >
      <div class="font-medium text-lg">{gettext("Close Accounting Period")}</div>
      <p class="text-sm mb-2">
        {gettext(
          "Blocks creating or amending any document dated on or before this date. This is separate from the financial-year closing month and day above. Clear the field to reopen."
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

```elixir
  def handle_event("save_period_lock", %{"period" => %{"closed_through" => str}}, socket) do
    date =
      case Date.from_iso8601(str) do
        {:ok, d} -> d
        {:error, _} -> nil
      end

    case Sys.close_period_through(socket.assigns.company, date, socket.assigns.current_user) do
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

The 2023 function `RETURN OLD` on success. That is correct for DELETE and **wrong for UPDATE** (PostgreSQL writes the old row; bank-rec `match_group_id` / Journal `cast_assoc` would silently no-op). Replace the function and add the trigger.

- [ ] **Step 1: Write the failing test**

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

    test "an open transaction updates and the new value is stored", %{
      company: company,
      admin: admin
    } do
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

      assert Repo.get!(FullCircle.Accounting.Transaction, txn.id).particulars == "fine"
    end
  end
```

The first `update_all` that sets `closed: true` must run **before** the trigger bites — `OLD.closed` is still false, so it passes either way. The open-transaction test **must** reload the column. `{1, _}` alone would pass under the old `RETURN OLD` function.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/period_lock_test.exs`
Expected: FAIL — the closed update succeeds where `Postgrex.Error` is asserted.

- [ ] **Step 3: Implement**

```bash
mix ecto.gen.migration add_update_closed_transaction_trigger
```

```elixir
defmodule FullCircle.Repo.Migrations.AddUpdateClosedTransactionTrigger do
  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_closed_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        IF (OLD.closed = true) AND EXISTS(SELECT 1 FROM companies WHERE id=OLD.company_id) THEN
          RAISE EXCEPTION 'Cannot update or delete a CLOSED transaction!'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          RETURN NEW;
        ELSE
          RETURN OLD;
        END IF;
      END;
      $trigger$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER update_closed_transaction_trigger
      BEFORE UPDATE ON transactions FOR EACH ROW
      EXECUTE PROCEDURE cannot_update_or_delete_closed_transaction();
    """
  end

  def down do
    execute "DROP TRIGGER update_closed_transaction_trigger ON transactions;"

    execute """
    CREATE OR REPLACE FUNCTION cannot_update_or_delete_closed_transaction()
      RETURNS trigger AS $trigger$
      BEGIN
        IF (OLD.closed = true) AND EXISTS(SELECT 1 FROM companies WHERE id=OLD.company_id) THEN
          RAISE EXCEPTION 'Cannot update or delete a CLOSED transaction!'
            USING ERRCODE = 'integrity_constraint_violation';
        ELSE
          RETURN OLD;
        END IF;
      END;
      $trigger$ LANGUAGE plpgsql;
    """
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix ecto.migrate && mix test test/full_circle/period_lock_test.exs`
Expected: PASS.

Then the whole suite — this trigger is global:

Run: `mix test`
Expected: PASS. If a seeding or bank-rec test now fails because it updates a `closed = true` row, report it rather than weakening the trigger.

- [ ] **Step 5: Format and commit**

```bash
mix format test/full_circle/period_lock_test.exs
git add priv/repo/migrations/ test/full_circle/period_lock_test.exs
git commit -m "fix(accounting): BEFORE UPDATE trigger for closed transactions returns NEW"
```

---

## Task 12: Document the contract as a skill

**Files:**
- Create: `.claude/skills/accounting-period-lock.md`
- Modify: `CLAUDE.md` (the project-skills list under "Domain Contexts")

Per the project's Skill Authoring Convention, **ask the user to confirm before finalising**.

- [ ] **Step 1: Draft the skill**

Frontmatter `description` must name the triggers: editing a document context's save path, adding a new GL-posting document type, or debugging a `:period_closed` error.

Contents:

- Cutoff lives in `companies.settings["period"]["closed_through"]`. `Sys.period_closed_through/1` **always re-reads the DB**. Do not read `company.settings` off the session struct.
- `Sys.close_period_through/3` is the only writer. Admin only. Logged as `close_period`.
- Rule: a save is blocked when it would write or rebuild GL rows dated on or before the cutoff.
- Guard sits in the multi, not in `make_changeset/5`. Public APIs return `{:error, :period_closed}` via `Accounting.map_period_closed/1`.
- Fast-path asymmetry: Invoice, PurInvoice, CreditNote, DebitNote keep non-GL editability; Payment, Receipt, Deposit, ReturnCheque, Journal do not.
- There is no document-level delete. Receipt/Payment `handle_event("delete")` is dead leftover — do not wrap it, do not build on it.
- Any new GL-posting document type must add the guard before its transaction build / `delete_all`, or it silently bypasses the lock.
- `transactions.closed` means "seeded opening balance". The UPDATE trigger must `RETURN NEW` for open rows.
- Payroll, trading, and fixed-asset depreciation are not covered yet.

- [ ] **Step 2: Add the pointer to CLAUDE.md**

Append `accounting-period-lock.md` to the project-skills list.

- [ ] **Step 3: Ask the user to confirm, then commit**

```bash
git add .claude/skills/accounting-period-lock.md CLAUDE.md
git commit -m "docs: accounting period lock skill"
```

---

## Final verification

- [ ] Run the full suite: `mix test`. Expected: PASS.
- [ ] Confirm `git status` is clean and no unrelated file was reformatted.
- [ ] Manually exercise in `mix phx.server`: set a cutoff on a test company (`/edit_company/:id`), confirm an invoice dated on or before it is refused with the flash naming the date, confirm a description-only edit on that invoice still saves, confirm a new receipt dated after the cutoff can still match that invoice, then clear the cutoff and confirm both save.
- [ ] Confirm there is still no Delete control on Receipt or Payment.
