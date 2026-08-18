# Xero → Full Circle Import (Golden Husbandry) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-time Mix task that snapshots a Xero organisation and replays it into a fresh Full Circle company as live documents (full authorised history), with conversion balances only and a fixed-asset register.

**Architecture:** Disk snapshot (JSON) is the source of truth after pull. A `Client` behaviour lets CI inject a fixture. `Mapper` turns Xero types into Full Circle attrs. `Apply` creates/resets the company and calls import wrappers next to existing `create_*` functions (same Multi/GL, Xero number instead of gapless mint). `Reconcile` compares Xero reports in the snapshot to Full Circle.

**Tech Stack:** Elixir 1.19, Ecto.Multi, `Req`, Jason, existing Billing / ReceiveFund / BillPay / DebCre / JournalEntry / Seeding.

**Spec:** `docs/superpowers/specs/2026-08-18-xero-import-golden-husbandry-design.md`

## Global Constraints

- Target production company name is exactly `Golden Husbandry Sdn. Bhd.`; tests **must** use a different name via `opts[:company_name]`.
- No LiveView, no dashboard entry, no `accounting.journals.read`, no PaySlips/Employees, no bank-rec ticks.
- Import wrappers live next to production create functions and **do not** call `Helpers.get_gapless_doc_id/5`.
- Credentials and the live snapshot stay gitignored. CI uses `test/support/fixtures/xero_import/`.
- HTTP client is `Req`. Period lock stays unset until the operator closes it after reconcile.
- Commit on `master` after each task. Do not paste Xero secrets into chat or the repo.

---

## File Structure

- **Create** `priv/xero_import/.gitignore` — ignore `.credentials`, `golden_husbandry/`, `*.log`.
- **Create** `priv/xero_import/overrides.json.example` — sample account/tax remaps.
- **Create** `lib/full_circle/xero_import.ex` — facade: `read_snapshot/1`, `dry_run/2`, `apply/2`, `reconcile/2`.
- **Create** `lib/full_circle/xero_import/client.ex` — `@callback` behaviour.
- **Create** `lib/full_circle/xero_import/snapshot.ex` — read/write snapshot directory; atomic replace on pull.
- **Create** `lib/full_circle/xero_import/mapper.ex` — pure maps (accounts, tax, contacts, goods, FA, docs).
- **Create** `lib/full_circle/xero_import/apply.ex` — company create/reset + phases.
- **Create** `lib/full_circle/xero_import/reconcile.ex` — TB / AR/AP / counts / FA NBV / bank.
- **Create** `lib/full_circle/xero_import/gapless.ex` — bump counters from imported numbers.
- **Create** `lib/full_circle/xero_import/http_client.ex` — Req + OAuth (Task 10 only).
- **Create** `lib/mix/tasks/full_circle.import_xero.ex` — `--auth --snapshot --dry-run --apply --reset --reconcile --user`.
- **Create** `test/support/fixtures/xero_import/snapshot/` — committed fixture JSON files.
- **Create** `test/full_circle/xero_import/mapper_test.exs`
- **Create** `test/full_circle/xero_import/apply_test.exs`
- **Create** `test/full_circle/xero_import/reconcile_test.exs`
- **Modify** `lib/full_circle/billing.ex` — `import_invoice/3`, `import_pur_invoice/3`.
- **Modify** `lib/full_circle/receive_fund.ex` — `import_receipt/3`.
- **Modify** `lib/full_circle/bill_pay.ex` — `import_payment/3`.
- **Modify** `lib/full_circle/debcre.ex` — `import_credit_note/3`, `import_debit_note/3`.
- **Modify** `lib/full_circle/journal_entry.ex` — `import_journal/3`.
- **Modify** existing create tests only if a shared helper is extracted; prefer new test files.

---

### Task 1: Snapshot on disk + fixture + facade read

**Files:**
- Create: `priv/xero_import/.gitignore`
- Create: `test/support/fixtures/xero_import/snapshot/organisation.json`
- Create: `test/support/fixtures/xero_import/snapshot/accounts.json`
- Create: `test/support/fixtures/xero_import/snapshot/tax_rates.json`
- Create: `test/support/fixtures/xero_import/snapshot/contacts.json`
- Create: `test/support/fixtures/xero_import/snapshot/items.json`
- Create: `test/support/fixtures/xero_import/snapshot/invoices.json`
- Create: `test/support/fixtures/xero_import/snapshot/credit_notes.json`
- Create: `test/support/fixtures/xero_import/snapshot/bank_transactions.json`
- Create: `test/support/fixtures/xero_import/snapshot/payments.json`
- Create: `test/support/fixtures/xero_import/snapshot/manual_journals.json`
- Create: `test/support/fixtures/xero_import/snapshot/bank_transfers.json`
- Create: `test/support/fixtures/xero_import/snapshot/fixed_assets.json`
- Create: `test/support/fixtures/xero_import/snapshot/conversion_balances.json`
- Create: `test/support/fixtures/xero_import/snapshot/reports.json`
- Create: `lib/full_circle/xero_import/snapshot.ex`
- Create: `lib/full_circle/xero_import.ex`
- Test: `test/full_circle/xero_import/snapshot_test.exs`

**Interfaces:**
- Consumes: nothing
- Produces: `FullCircle.XeroImport.Snapshot.read(dir) :: {:ok, map()} | {:error, term()}` where the map has atom keys `:organisation`, `:accounts`, `:tax_rates`, `:contacts`, `:items`, `:invoices`, `:credit_notes`, `:bank_transactions`, `:payments`, `:manual_journals`, `:bank_transfers`, `:fixed_assets`, `:conversion_balances`, `:reports`. `FullCircle.XeroImport.fixture_dir/0` returns the test fixture path. `FullCircle.XeroImport.read_snapshot/1` delegates to `Snapshot.read/1`.

- [ ] **Step 1: Write the failing test**

`test/full_circle/xero_import/snapshot_test.exs`:

```elixir
defmodule FullCircle.XeroImport.SnapshotTest do
  use ExUnit.Case, async: true

  alias FullCircle.XeroImport
  alias FullCircle.XeroImport.Snapshot

  test "read/1 loads the committed fixture snapshot" do
    assert {:ok, snap} = Snapshot.read(XeroImport.fixture_dir())
    assert snap.organisation["Name"] == "Fixture Org"
    assert length(snap.accounts) >= 4
    assert Enum.any?(snap.invoices, &(&1["InvoiceNumber"] == "INV-000123"))
    assert snap.reports["trial_balance"] != nil
  end

  test "read/1 errors when a required file is missing" do
    dir = System.tmp_dir!() |> Path.join("xero-empty-#{System.unique_integer()}")
    File.mkdir_p!(dir)
    assert {:error, {:missing_file, _}} = Snapshot.read(dir)
  end
end
```

Write fixture files (minimum viable). `organisation.json`:

```json
{
  "Name": "Fixture Org",
  "BaseCurrency": "MYR",
  "FinancialYearEndDay": 31,
  "FinancialYearEndMonth": 12,
  "Timezone": "ASIA/KUALA_LUMPUR"
}
```

`accounts.json` — list including at least:

- `{ "AccountID": "ac-sales", "Code": "200", "Name": "Sales", "Type": "REVENUE" }`
- `{ "AccountID": "ac-bank", "Code": "090", "Name": "Cheque Account", "Type": "BANK" }`
- `{ "AccountID": "ac-ar", "Code": "610", "Name": "Accounts Receivable", "Type": "CURRENT" }`
- `{ "AccountID": "ac-ap", "Code": "800", "Name": "Accounts Payable", "Type": "CURRLIAB" }`
- `{ "AccountID": "ac-gst", "Code": "820", "Name": "GST", "Type": "CURRLIAB" }`
- `{ "AccountID": "ac-fa", "Code": "710", "Name": "Motor Vehicles", "Type": "FIXED" }`
- `{ "AccountID": "ac-accum", "Code": "711", "Name": "Less Accumulated Depreciation on Motor Vehicles", "Type": "FIXED" }`
- `{ "AccountID": "ac-depre", "Code": "477", "Name": "Depreciation", "Type": "DEPRECIATN" }`
- `{ "AccountID": "ac-disp", "Code": "270", "Name": "Gain on Disposal", "Type": "OTHERINCOME" }`

`tax_rates.json`:

```json
[
  {
    "Name": "SST 6%",
    "TaxType": "OUTPUT",
    "EffectiveRate": 6.0,
    "CanApplyToRevenue": true,
    "CanApplyToExpenses": true,
    "Status": "ACTIVE"
  },
  {
    "Name": "Tax Exempt",
    "TaxType": "NONE",
    "EffectiveRate": 0.0,
    "CanApplyToRevenue": true,
    "CanApplyToExpenses": true,
    "Status": "ACTIVE"
  }
]
```

`contacts.json`: two contacts `Alice Customer` (IsCustomer true) and `Bob Supplier` (IsSupplier true). Give them `ContactID` values `ct-alice` and `ct-bob`. Empty Addresses ok.

`items.json`: one item `{ "ItemID": "it-egg", "Code": "EGG", "Name": "Egg", "SalesDetails": { "UnitPrice": 1.0, "AccountCode": "200", "TaxType": "OUTPUT" }, "PurchaseDetails": { "UnitPrice": 0.8, "AccountCode": "200", "TaxType": "NONE" } }`.

`invoices.json`:

1. ACCREC `INV-000123`, AUTHORISED, Contact Alice, Date `2024-02-01`, Due `2024-03-01`, LineAmountTypes Exclusive, one line Sales/EGG qty 10 unit 5 tax OUTPUT, `InvoiceID` `inv-123`, CurrencyCode MYR, Total 53.00 (if 6% — use Tax Exempt NONE so totals stay 50.00 to keep fixture math easy). Use **Tax Exempt / NONE** on fixture invoices so totals are 50.00.
2. ACCREC `SI-88` AUTHORISED same shape, `InvoiceID` `inv-si88`, Total 20.00 — used to prove gapless ignore.
3. ACCPAY `BILL-10` AUTHORISED Contact Bob, `InvoiceID` `bill-10`, Total 30.00.
4. ACCREC draft `INV-DRAFT` Status DRAFT — must be skipped later.
5. One conversion-style ACCREC `CONV-AR-1` with `InvoiceID` `inv-conv`, Total 100.00 (used when stripping conversion AR).

`payments.json`: one payment `{ "PaymentID": "pay-1", "Invoice": { "InvoiceID": "inv-123" }, "Amount": 50.0, "Date": "2024-02-15", "Account": { "AccountID": "ac-bank" }, "Status": "AUTHORISED" }`.

`manual_journals.json`: one posted journal dated `2024-01-15`, two lines Cheque Account +50 / Sales −50, `Narration`: "Opening adj", `ManualJournalID` `mj-1`.

`credit_notes.json`, `bank_transactions.json`, and `bank_transfers.json`: empty lists `[]` for now.

`fixed_assets.json`:

```json
[
  {
    "AssetId": "fa-van",
    "AssetName": "Van 1",
    "AssetNumber": "FA-001",
    "PurchaseDate": "2023-01-01",
    "PurchasePrice": 100000.0,
    "ResidualValue": 10000.0,
    "DepreciationStartDate": "2023-01-01",
    "BookValue": 80000.0,
    "AccountingBookValue": 80000.0,
    "DepreciationMethod": "StraightLine",
    "AveragingMethod": "ActualDays",
    "DepreciationRate": 20.0,
    "AssetTypeId": "fat-vehicle",
    "AssetType": {
      "AssetTypeName": "Vehicles",
      "FixedAssetAccountId": "ac-fa",
      "AccumulatedDepreciationAccountId": "ac-accum",
      "DepreciationExpenseAccountId": "ac-depre"
    },
    "DepreciationHistory": [
      { "DepreciationDate": "2023-12-31", "DepreciationAmount": 20000.0, "CostLimit": 100000.0 }
    ]
  }
]
```

`conversion_balances.json`:

```json
{
  "Date": "2024-01-01",
  "Lines": [
    { "AccountID": "ac-bank", "Balance": 1000.0 },
    { "AccountID": "ac-ar", "Balance": 100.0 },
    { "AccountID": "ac-fa", "Balance": 100000.0 },
    { "AccountID": "ac-accum", "Balance": -20000.0 },
    { "AccountID": "ac-sales", "Balance": 0.0 }
  ]
}
```

AR 100.00 matches `CONV-AR-1` so later apply can strip it.

`reports.json`:

```json
{
  "trial_balance": [
    { "account_name": "Cheque Account", "balance": 1050.0 },
    { "account_name": "Account Receivables", "balance": 120.0 },
    { "account_name": "Motor Vehicles", "balance": 100000.0 },
    { "account_name": "Less Accumulated Depreciation on Motor Vehicles", "balance": -20000.0 }
  ],
  "aged_receivables": [{ "contact_name": "Alice Customer", "balance": 20.0 }],
  "aged_payables": [{ "contact_name": "Bob Supplier", "balance": 30.0 }],
  "invoice_totals": { "count": 3, "amount": 170.0 },
  "bill_totals": { "count": 1, "amount": 30.0 },
  "fa_nbv": [{ "name": "Van 1", "nbv": 80000.0 }],
  "bank": [{ "account_name": "Cheque Account", "balance": 1050.0 }]
}
```

(These report figures are **placeholders for reconcile tests**; Task 9 will adjust them to whatever apply actually posts. Keep the keys stable.)

`priv/xero_import/.gitignore`:

```
.credentials
golden_husbandry/
*.log
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix test test/full_circle/xero_import/snapshot_test.exs`
Expected: compilation error — `FullCircle.XeroImport` missing.

- [ ] **Step 3: Implement Snapshot.read/1 and the facade**

```elixir
defmodule FullCircle.XeroImport do
  @fixture Path.expand("../../../test/support/fixtures/xero_import/snapshot", __DIR__)

  def fixture_dir, do: @fixture
  def read_snapshot(dir), do: FullCircle.XeroImport.Snapshot.read(dir)
end

defmodule FullCircle.XeroImport.Snapshot do
  @files ~w(
    organisation accounts tax_rates contacts items invoices credit_notes
    bank_transactions payments manual_journals bank_transfers
    fixed_assets conversion_balances reports
  )a

  def read(dir) do
    Enum.reduce_while(@files, {:ok, %{}}, fn key, {:ok, acc} ->
      path = Path.join(dir, "#{key}.json")

      cond do
        not File.exists?(path) ->
          {:halt, {:error, {:missing_file, path}}}

        true ->
          with {:ok, bin} <- File.read(path),
               {:ok, json} <- Jason.decode(bin) do
            {:cont, {:ok, Map.put(acc, key, json)}}
          else
            err -> {:halt, {:error, err}}
          end
      end
    end)
  end
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/xero_import/snapshot_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add priv/xero_import/.gitignore test/support/fixtures/xero_import lib/full_circle/xero_import.ex lib/full_circle/xero_import/snapshot.ex test/full_circle/xero_import/snapshot_test.exs
git commit -m "feat(xero-import): snapshot reader and fixture JSON"
```

---

### Task 2: Mapper

**Files:**
- Create: `lib/full_circle/xero_import/mapper.ex`
- Test: `test/full_circle/xero_import/mapper_test.exs`

**Interfaces:**
- Consumes: snapshot maps from Task 1
- Produces:
  - `Mapper.account_type(xero_type, overrides) :: {:ok, String.t()} | {:error, {:unmapped_account_type, String.t()}}`
  - `Mapper.tax_codes(xero_rate) :: [%{code: String.t(), tax_type: String.t(), rate: Decimal.t(), descriptions: String.t()}]`
  - `Mapper.contact(xero_contact) :: map()` string-key attrs (`name`, `country`, `category`, …)
  - `Mapper.good(xero_item, accounts_by_code, tax_by_type) :: map()`
  - `Mapper.fixed_asset(xero_asset) :: {:ok, map()} | {:error, {:diminishing_value, String.t()}}`
  - `Mapper.importable_invoice?(xero_inv) :: boolean()`
  - `Mapper.base_currency_ok?(doc, base) :: boolean()`

Hard-coded account type table **must** match the spec. Overrides is a map `%{"account_types" => %{"WEIRD" => "Expenses"}, "control_accounts" => %{"Accounts Receivable" => "Account Receivables"}}`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule FullCircle.XeroImport.MapperTest do
  use ExUnit.Case, async: true
  alias FullCircle.XeroImport.Mapper

  test "maps every specified Xero account type" do
    assert Mapper.account_type("BANK", %{}) == {:ok, "Bank"}
    assert Mapper.account_type("REVENUE", %{}) == {:ok, "Revenue"}
    assert Mapper.account_type("SALES", %{}) == {:ok, "Revenue"}
    assert Mapper.account_type("DEPRECIATN", %{}) == {:ok, "Depreciation"}
  end

  test "unknown type without override fails" do
    assert {:error, {:unmapped_account_type, "WEIRD"}} = Mapper.account_type("WEIRD", %{})
  end

  test "override wins" do
    assert Mapper.account_type("WEIRD", %{"account_types" => %{"WEIRD" => "Expenses"}}) ==
             {:ok, "Expenses"}
  end

  test "6% dual-apply tax becomes two codes at 0.06" do
    codes =
      Mapper.tax_codes(%{
        "Name" => "SST 6%",
        "EffectiveRate" => 6.0,
        "CanApplyToRevenue" => true,
        "CanApplyToExpenses" => true
      })

    assert Enum.map(codes, & &1.tax_type) |> Enum.sort() == ["Purchase", "Sales"]
    assert Enum.all?(codes, &Decimal.eq?(&1.rate, Decimal.new("0.06")))
    assert Enum.any?(codes, &String.ends_with?(&1.code, "-S"))
    assert Enum.any?(codes, &String.ends_with?(&1.code, "-P"))
  end

  test "blank contact country becomes Malaysia" do
    c = Mapper.contact(%{"Name" => "Alice", "IsCustomer" => true, "Addresses" => []})
    assert c["country"] == "Malaysia"
    assert c["category"] == "Customer"
  end

  test "diminishing-value asset fails" do
    assert {:error, {:diminishing_value, _}} =
             Mapper.fixed_asset(%{"AssetName" => "Van", "DepreciationMethod" => "DiminishingValue"})
  end

  test "straight-line asset rate is a fraction" do
    {:ok, fa} =
      Mapper.fixed_asset(%{
        "AssetName" => "Van 1",
        "PurchaseDate" => "2023-01-01",
        "PurchasePrice" => 100000.0,
        "ResidualValue" => 10000.0,
        "DepreciationStartDate" => "2023-01-01",
        "DepreciationMethod" => "StraightLine",
        "DepreciationRate" => 20.0,
        "AveragingMethod" => "Monthly"
      })

    assert fa["depre_method"] == "Straight-Line"
    assert Decimal.eq?(fa["depre_rate"], Decimal.new("0.2"))
    assert fa["depre_interval"] == "Monthly"
  end

  test "skips draft and void invoices" do
    refute Mapper.importable_invoice?(%{"Status" => "DRAFT", "Type" => "ACCREC"})
    refute Mapper.importable_invoice?(%{"Status" => "VOIDED", "Type" => "ACCREC"})
    assert Mapper.importable_invoice?(%{"Status" => "AUTHORISED", "Type" => "ACCREC"})
    assert Mapper.importable_invoice?(%{"Status" => "PAID", "Type" => "ACCREC"})
  end

  test "rejects non-base currency" do
    refute Mapper.base_currency_ok?(%{"CurrencyCode" => "USD"}, "MYR")
    assert Mapper.base_currency_ok?(%{"CurrencyCode" => "MYR"}, "MYR")
  end
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix test test/full_circle/xero_import/mapper_test.exs`
Expected: FAIL — `Mapper` missing.

- [ ] **Step 3: Implement Mapper**

Put the spec table in a module attribute:

```elixir
@account_types %{
  "BANK" => "Bank",
  "CURRENT" => "Current Asset",
  "FIXED" => "Fixed Asset",
  "INVENTORY" => "Inventory",
  "PREPAYMENT" => "Prepayment",
  "NONCURRENT" => "Non-current Asset",
  "CURRLIAB" => "Current Liability",
  "LIABILITY" => "Liability",
  "TERMLIAB" => "Non-current Liability",
  "EQUITY" => "Equity",
  "REVENUE" => "Revenue",
  "SALES" => "Revenue",
  "OTHERINCOME" => "Other Income",
  "DIRECTCOSTS" => "Direct Costs",
  "EXPENSE" => "Expenses",
  "OVERHEADS" => "Overhead",
  "DEPRECIATN" => "Depreciation"
}
```

Tax code: start from a slug of `Name` (alphanumeric, max 12 chars so `-S`/`-P` fit in 15). Rate = `EffectiveRate / 100`. Zero-rate dual-apply still produces `-S`/`-P` (defaults `NoSTax`/`NoPTax` are reused later in Apply, not here).

Contact category: `"Customer"` if `IsCustomer`, `"Supplier"` if `IsSupplier`, `"Customer, Supplier"` if both, `nil` if neither.

Fixed asset: `StraightLine` / `NoDepreciation` / `FullDepreciationAtPurchase` (map last two to `No Depreciation`, rate `0`). `ActualDays` or anything monthly-ish → `Monthly`; yearly averaging → `Yearly`. Default interval `Yearly` if missing. Disposal account name left for Apply to fill from type or override (`disp_fund_ac_name`).

`importable_invoice?/1` (and the same status check for credit notes): Status in `~w(AUTHORISED PAID)`. Invoices file: Type `ACCREC` → Invoice, `ACCPAY` → PurInvoice. Credit notes file (empty in fixture): Type `ACCREC` → CreditNote, `ACCPAY` → DebitNote.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/xero_import/mapper_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/xero_import/mapper.ex test/full_circle/xero_import/mapper_test.exs lib/full_circle/xero_import/snapshot.ex test/support/fixtures/xero_import
git commit -m "feat(xero-import): map Xero types to Full Circle attrs"
```

---

### Task 3: import_invoice and import_pur_invoice

**Files:**
- Modify: `lib/full_circle/billing.ex` (add `import_invoice/3`, `import_pur_invoice/3`, and `import_*_multi` that copy `create_*_multi` without `get_gapless_doc_id`)
- Test: `test/full_circle/xero_import/import_invoice_test.exs`

**Interfaces:**
- Consumes: existing `make_changeset/5`, `create_doc_transactions/5`
- Produces: `Billing.import_invoice(attrs, com, user) :: {:ok, map()} | {:error, ...} | :not_authorise` where attrs **must** include `"invoice_no"`. Same return shape as `create_invoice` (`%{create_invoice: invoice}`). `import_pur_invoice/3` uses `"pur_invoice_no"` and Multi name `:create_pur_invoice`.

- [ ] **Step 1: Write the failing test**

Reuse `billing_setup()` / `invoice_attrs/4` from `FullCircle.BillingFixtures`.

```elixir
defmodule FullCircle.XeroImport.ImportInvoiceTest do
  use FullCircle.DataCase
  alias FullCircle.{Billing, Accounting, Repo}
  alias FullCircle.Accounting.{Transaction, TaxCode}
  import FullCircle.BillingFixtures

  setup do
    billing_setup()
  end

  test "keeps the supplied number and posts GL", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    sales = Accounting.get_account_by_name("General Sales", company, admin)
    no_stax = Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    attrs = invoice_attrs(contact, good, sales, no_stax) |> Map.put("invoice_no", "INV-000123")

    assert {:ok, %{create_invoice: inv}} = Billing.import_invoice(attrs, company, admin)
    assert inv.invoice_no == "INV-000123"

    txns = Repo.all(from t in Transaction, where: t.doc_type == "Invoice" and t.doc_no == "INV-000123")
    assert txns != []
  end

  test "does not increment the Invoice gapless counter", %{admin: admin, company: company} do
    contact = contact_fixture(company, admin)
    good = good_fixture(company, admin)
    sales = Accounting.get_account_by_name("General Sales", company, admin)
    no_stax = Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoSTax")

    before =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == "Invoice",
          select: g.current
      )

    attrs = invoice_attrs(contact, good, sales, no_stax) |> Map.put("invoice_no", "INV-000123")
    assert {:ok, _} = Billing.import_invoice(attrs, company, admin)

    after_c =
      Repo.one!(
        from g in FullCircle.Sys.GaplessDocId,
          where: g.company_id == ^company.id and g.doc_type == "Invoice",
          select: g.current
      )

    assert after_c == before
  end
end
```

Add a matching `import_pur_invoice` test with `"pur_invoice_no" => "BILL-10"` in the same file.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix test test/full_circle/xero_import/import_invoice_test.exs`
Expected: FAIL — `import_invoice/3` undefined.

- [ ] **Step 3: Implement import wrappers**

Copy `create_invoice_multi/4` to `import_invoice_multi/4`. Delete the `get_gapless_doc_id` step. Insert with:

```elixir
doc = Map.fetch!(attrs, "invoice_no")

Multi.insert(invoice_name, fn _ ->
  make_changeset(
    Invoice,
    %Invoice{},
    Map.merge(attrs, %{"invoice_no" => doc, "e_inv_internal_id" => attrs["e_inv_internal_id"] || doc}),
    com,
    user
  )
end)
```

Keep the log, `multi_assert_period_open`, and `create_doc_transactions` exactly as create. Same pattern for pur invoice (`"pur_invoice_no"`, `:create_pur_invoice`).

`import_invoice/3` is `can?(:create_invoice)` + `import_invoice_multi` + `map_period_closed`. Do **not** change `create_invoice/3`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/xero_import/import_invoice_test.exs test/full_circle/billing_test.exs`
Expected: PASS (existing create still mints `INV-######`)

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/billing.ex test/full_circle/xero_import/import_invoice_test.exs
git commit -m "feat(billing): import invoice and pur invoice with supplied numbers"
```

---

### Task 4: import_receipt and import_payment (with matchers)

**Files:**
- Modify: `lib/full_circle/receive_fund.ex` — `import_receipt/3`
- Modify: `lib/full_circle/bill_pay.ex` — `import_payment/3`
- Test: `test/full_circle/xero_import/import_receipt_payment_test.exs`

**Interfaces:**
- Consumes: Task 3 imported invoices/bills so matchers have a `transaction_id`
- Produces: `ReceiveFund.import_receipt/3`, `BillPay.import_payment/3`. Attrs include `"receipt_no"` / `"payment_no"` and optional `"transaction_matchers"` in the same shape `create_receipt` already casts (`transaction_id`, `match_amount`, `doc_type`, `doc_date`).

Look at `Receipt` / `Payment` `cast_assoc(:transaction_matchers)` and at `Accounting.query_transactions_for_matching/5` for the control-account transaction on the imported invoice. The matcher `transaction_id` is that AR (invoice) or AP (bill) header transaction.

- [ ] **Step 1: Write the failing test**

```elixir
# After Billing.import_invoice(... "INV-000123" ...)
ar_txn =
  Repo.one!(
    from t in Transaction,
      join: a in FullCircle.Accounting.Account,
      on: a.id == t.account_id,
      where: t.doc_no == "INV-000123" and t.doc_type == "Invoice" and a.name == "Account Receivables"
  )

receipt_attrs = %{
  "receipt_no" => "RC-XERO-1",
  "receipt_date" => Date.to_iso8601(Date.utc_today()),
  "contact_id" => contact.id,
  "contact_name" => contact.name,
  "funds_account_id" => funds.id,
  "funds_account_name" => funds.name,
  "funds_amount" => "50.00",
  "receipt_details" => %{},
  "transaction_matchers" => %{
    "0" => %{
      "transaction_id" => ar_txn.id,
      "match_amount" => "-50.00",
      "doc_type" => "Receipt",
      "doc_date" => Date.to_iso8601(Date.utc_today()),
      "_persistent_id" => "1"
    }
  }
}

assert {:ok, %{create_receipt: rc}} = ReceiveFund.import_receipt(receipt_attrs, company, admin)
assert rc.receipt_no == "RC-XERO-1"
```

Use `funds_account_fixture/2`. Receipt `match_amount` **must be the negated AR balance** — same as `receipt_live/form.ex` (`Decimal.negate(match_tran.balance)`). For a 50.00 invoice AR header, that is `"-50.00"`. Payment vs AP uses the same negate-balance rule.

Also assert Invoice gapless / Receipt gapless `current` unchanged.

Add a payment test against an imported bill similarly.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix test test/full_circle/xero_import/import_receipt_payment_test.exs`
Expected: FAIL — `import_receipt/3` undefined.

- [ ] **Step 3: Implement**

Same as Task 3: clone `create_receipt_multi` / `create_payment_multi`, drop `get_gapless_doc_id`, take number from attrs. Keep `create_receipt_transactions` so matchers post.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/xero_import/import_receipt_payment_test.exs test/full_circle/receive_fund_test.exs test/full_circle/bill_pay_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/receive_fund.ex lib/full_circle/bill_pay.ex test/full_circle/xero_import/import_receipt_payment_test.exs
git commit -m "feat(funds): import receipt and payment with Xero numbers and matchers"
```

---

### Task 5: import credit note, debit note, journal

**Files:**
- Modify: `lib/full_circle/debcre.ex` — `import_credit_note/3`, `import_debit_note/3`
- Modify: `lib/full_circle/journal_entry.ex` — `import_journal/3`
- Test: `test/full_circle/xero_import/import_notes_journal_test.exs`

**Interfaces:**
- Produces: same Multi names as create (`:create_credit_note`, `:create_debit_note`, `:create_journal`). Credit/debit note number field is `"note_no"` (`FullCircle.DebCre.CreditNote`). Journal number field is `"journal_no"`.

- [ ] **Step 1: Write failing tests**

Take a working `create_credit_note` attrs map from `test/full_circle/debcre_test.exs`, put `"note_no" => "CN-9"`, call `DebCre.import_credit_note/3`, assert `note.note_no == "CN-9"` and DebitNote/CreditNote `gapless_doc_ids.current` unchanged. Same for debit note `"DN-9"`. For journal, use `journal_attrs_dated/3` from `test/full_circle/period_lock_test.exs` (or the journal fixture in that file), set `"journal_no" => "JS-XERO-1"`, assert balance 0 and Journal gapless unchanged.

- [ ] **Step 2: Run — expect undefined functions**

Run: `mix test test/full_circle/xero_import/import_notes_journal_test.exs`

- [ ] **Step 3: Implement** by cloning create multis minus gapless.

- [ ] **Step 4: Run import tests + existing debcre and journal tests.**

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/debcre.ex lib/full_circle/journal_entry.ex test/full_circle/xero_import/import_notes_journal_test.exs
git commit -m "feat(docs): import credit note, debit note, and journal with supplied numbers"
```

---

### Task 6: Apply company, masters, fixed assets

**Files:**
- Create: `lib/full_circle/xero_import/apply.ex` (company + masters + FA phases only)
- Create: `priv/xero_import/overrides.json.example`
- Test: `test/full_circle/xero_import/apply_test.exs`

**Interfaces:**
- Consumes: `XeroImport.read_snapshot/1`, `Mapper.*`, `Sys.create_company/2`, `Sys.delete_company/2`, `Seeding` for FA depreciations
- Produces:
  - `Apply.run(snapshot, user, opts) :: {:ok, %{company: Company.t(), id_map: map()}} | {:error, term()}`
  - `opts` keys: `:company_name` (default `"Golden Husbandry Sdn. Bhd."`), `:reset` (boolean), `:stop_after` (`:masters` for this task’s tests)
  - `id_map` string keys `"account:" <> xero_id`, `"contact:" <> xero_id`, `"good:" <> xero_id`, `"asset:" <> xero_id` → Full Circle UUIDs

Control-account merge: if Xero name is `Accounts Receivable` (or override), **do not insert**; put that Xero id in `id_map` pointing at existing `Account Receivables`. Same for `Accounts Payable` → `Account Payables`. GST/tax liability → `Sales Tax Payable` when override or name match says so.

- [ ] **Step 1: Write failing tests**

```elixir
setup do
  user = FullCircle.UserAccountsFixtures.user_fixture()
  {:ok, snap} = FullCircle.XeroImport.read_snapshot(FullCircle.XeroImport.fixture_dir())
  name = "Xero Fixture #{System.unique_integer([:positive])}"
  %{user: user, snap: snap, name: name}
end

test "creates accounts without duplicating AR/AP", %{user: user, snap: snap, name: name} do
  assert {:ok, %{company: com, id_map: map}} =
           Apply.run(snap, user, company_name: name, stop_after: :masters)

  names = Repo.all(from a in FullCircle.Accounting.Account, where: a.company_id == ^com.id, select: a.name)
  assert "Account Receivables" in names
  refute "Accounts Receivable" in names
  assert "Sales" in names
  assert "Cheque Account" in names
  assert map["account:ac-ar"] == Accounting.get_account_by_name("Account Receivables", com, user).id
end

test "aborts without reset if company already has invoices", %{user: user, snap: snap, name: name} do
  {:ok, %{company: com}} = Apply.run(snap, user, company_name: name, stop_after: :masters)
  # insert a dummy invoice via import so the company is "dirty"
  # ... or insert a Transaction row
  assert {:error, :company_not_empty} = Apply.run(snap, user, company_name: name, stop_after: :masters)
end

test "reset deletes and recreates", %{user: user, snap: snap, name: name} do
  {:ok, %{company: com1}} = Apply.run(snap, user, company_name: name, stop_after: :masters)
  assert {:ok, %{company: com2}} = Apply.run(snap, user, company_name: name, reset: true, stop_after: :masters)
  assert com1.id != com2.id
end

test "straight-line asset is seeded and depre rows do not post GL", %{user: user, snap: snap, name: name} do
  {:ok, %{company: com}} = Apply.run(snap, user, company_name: name, stop_after: :masters)
  fa = Repo.one!(from f in FullCircle.Accounting.FixedAsset, where: f.company_id == ^com.id)
  assert fa.name == "Van 1"
  assert Decimal.eq?(fa.depre_rate, Decimal.new("0.2"))
  depre = Repo.all(from d in FullCircle.Accounting.FixedAssetDepreciation, where: d.fixed_asset_id == ^fa.id)
  assert depre != []
  assert Enum.all?(depre, & &1.is_seed)
  refute Repo.exists?(
    from t in Transaction,
      where: t.company_id == ^com.id and t.doc_type == "fixed_asset_depreciations"
  )
end
```

Add a diminishing-value test by `put_in` on `snap.fixed_assets` before `Apply.run` — expect `{:error, {:diminishing_value, _}}`.

Company attrs: `name`, `country: "Malaysia"`, `timezone: "Asia/Kuala_Lumpur"` (or org timezone mapped), `closing_month` / `closing_day` from `FinancialYearEndMonth` / `FinancialYearEndDay`.

- [ ] **Step 2: Run — expect Apply missing**

Run: `mix test test/full_circle/xero_import/apply_test.exs`

- [ ] **Step 3: Implement Apply through `:masters`**

Order: create company (or reset via `Sys.delete_company` then create) → accounts (skip/merge defaults) → tax codes via `StdInterface`/`Seeding.fill_changeset("TaxCodes", ...)` → contacts → goods → FA + `Seeding.fill_changeset("FixedAssetDepreciations", ...)` / `Seeding.seed("FixedAssetDepreciations", ...)`.

Empty-check: `Repo.exists?(from t in Transaction, where: t.company_id == ^id)` or any Invoice. If exists and not `reset`, `{:error, :company_not_empty}`.

Load overrides from `opts[:overrides]` map (tests pass `%{}`); Mix task later reads `priv/xero_import/overrides.json` if present.

Wire `XeroImport.apply/2` as `Apply.run/3`.

- [ ] **Step 4: Run apply_test.exs — PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/xero_import/apply.ex lib/full_circle/xero_import.ex priv/xero_import/overrides.json.example test/full_circle/xero_import/apply_test.exs
git commit -m "feat(xero-import): apply company, masters, and fixed assets"
```

---

### Task 7: Apply conversion balances, live documents, allocations, gapless

**Files:**
- Modify: `lib/full_circle/xero_import/apply.ex`
- Create: `lib/full_circle/xero_import/gapless.ex`
- Test: extend `test/full_circle/xero_import/apply_test.exs`

**Interfaces:**
- Consumes: import_* from Tasks 3–5, `Seeding.seed("Balances", ...)`
- Produces: full `Apply.run/3` without `:stop_after` (or `stop_after: :all`). Writes `id_map` including `"invoice:" <> xero_id`. `Gapless.bump(company, imported_numbers_by_type)` where type is `"Invoice"` etc. and numbers are the imported strings.

Conversion: seed `Balances` at `conversion_balances["Date"]`. Amount sign: Xero Balance as given (positive debit). Map AccountID via `id_map`. **Subtract** totals of imported conversion invoices that hit AR/AP (fixture: `CONV-AR-1` 100.00) from the AR/AP conversion line so AR seed becomes 0 when that invoice is also imported.

Detect conversion invoices: `InvoiceNumber` starts with `CONV-` **or** Date == conversion Date. Document this in a comment on `Apply.conversion_invoice?/2`.

Skip draft/void via `Mapper.importable_invoice?/1`. Abort `{:error, {:missing_allocation_target, payment_id, invoice_id}}` if a payment’s InvoiceID is not in `id_map`.

Abort `{:error, {:foreign_currency, invoice_number}}` if `not Mapper.base_currency_ok?(inv, base)`.

Order: invoices/bills → credit/debit notes (empty in fixture) → receipts/payments with matchers → manual journals → bank spend/receive/transfers (empty).

Receipt from a Xero payment on ACCREC: funds account = payment AccountID mapped; `funds_amount` = payment Amount; matcher against the invoice’s AR transaction; `match_amount` sign as established in Task 4.

- [ ] **Step 1: Write failing tests**

```elixir
test "imports INV-000123 and does not mint INV-000001", %{user: user, snap: snap, name: name} do
  assert {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)
  inv = Repo.one!(from i in FullCircle.Billing.Invoice, where: i.company_id == ^com.id and i.invoice_no == "INV-000123")
  refute Repo.exists?(from i in FullCircle.Billing.Invoice, where: i.company_id == ^com.id and i.invoice_no == "INV-DRAFT")
end

test "receipt matchers settle INV-000123", %{user: user, snap: snap, name: name} do
  {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)
  # outstanding on INV-000123 is 0
  ar =
    Repo.one!(
      from t in Transaction,
        join: a in FullCircle.Accounting.Account, on: a.id == t.account_id,
        where: t.company_id == ^com.id and t.doc_no == "INV-000123" and a.name == "Account Receivables"
    )
  matched = Repo.aggregate(from m in FullCircle.Accounting.TransactionMatcher, where: m.transaction_id == ^ar.id, select: sum(m.match_amount))
  assert Decimal.eq?(Decimal.add(ar.amount, matched || 0), 0)
end

test "payment whose invoice is missing aborts", %{user: user, snap: snap, name: name} do
  snap = put_in(snap.payments, [%{"PaymentID" => "pay-bad", "Invoice" => %{"InvoiceID" => "nope"}, "Amount" => 1.0, "Date" => "2024-02-01", "Account" => %{"AccountID" => "ac-bank"}, "Status" => "AUTHORISED"}])
  assert {:error, {:missing_allocation_target, "pay-bad", "nope"}} = Apply.run(snap, user, company_name: name)
end

test "gapless sits at 123 after INV-000123; SI-88 does not move it", %{user: user, snap: snap, name: name} do
  {:ok, %{company: com}} = Apply.run(snap, user, company_name: name)
  current = Repo.one!(from g in FullCircle.Sys.GaplessDocId, where: g.company_id == ^com.id and g.doc_type == "Invoice", select: g.current)
  assert current == 123
end

test "conversion AR is reduced by imported conversion invoice", %{user: user, snap: snap, name: name} do
  {:ok, %{company: com, id_map: map}} = Apply.run(snap, user, company_name: name)
  ar_id = map["account:ac-ar"]
  seed =
    Repo.all(
      from t in Transaction,
        where: t.company_id == ^com.id and t.account_id == ^ar_id and t.old_data == true
    )
  # CONV-AR-1 100 stripped from conversion 100 → no leftover seed (or 0 rows / 0 amount)
  assert Enum.reduce(seed, Decimal.new(0), &Decimal.add(&2, &1.amount)) |> Decimal.eq?(0)
end
```

- [ ] **Step 2: Run apply_test — new tests FAIL**

- [ ] **Step 3: Implement remaining Apply phases + Gapless.bump/2**

```elixir
# Gapless.bump
# prefixes: Invoice INV, PurInvoice PINV, Receipt RC, Payment PV,
# CreditNote CN, DebitNote DN, Journal JS
def bump(company, %{Invoice => ["INV-000123", "SI-88"]}) do
  # parse ^PREFIX-(\d+)$, max n, update gapless_doc_ids.current
end
```

Call `Gapless.bump` at end of successful apply.

- [ ] **Step 4: Run `mix test test/full_circle/xero_import/` — PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/xero_import/apply.ex lib/full_circle/xero_import/gapless.ex test/full_circle/xero_import/apply_test.exs
git commit -m "feat(xero-import): conversion balances, live documents, matchers, gapless"
```

---

### Task 8: Dry-run + Mix task (offline)

**Files:**
- Modify: `lib/full_circle/xero_import.ex` — `dry_run/2`
- Create: `lib/mix/tasks/full_circle.import_xero.ex`
- Test: `test/full_circle/xero_import/dry_run_test.exs`

**Interfaces:**
- Produces: `XeroImport.dry_run(snapshot, opts) :: {:ok, %{counts: map(), errors: [term()]}} | {:error, term()}`. Builds every changeset / runs Mapper / allocation checks **without** inserting. `counts` keys: `:accounts`, `:contacts`, `:invoices`, `:bills`, `:receipts`, `:payments`, `:journals`, `:assets`, `:skipped`. Exit problems go in `errors` (diminishing value, missing allocation, unmapped type, foreign currency).

Mix task:

```
mix full_circle.import_xero --dry-run --snapshot-dir PATH --user EMAIL
mix full_circle.import_xero --apply --snapshot-dir PATH --user EMAIL [--reset]
```

Default `--snapshot-dir` is `priv/xero_import/golden_husbandry`. `--user` or env `FC_IMPORT_USER`. Logs to `priv/xero_import/golden_husbandry/last_run.log` when that dir is writable; tests should pass `--log` false / use tmp.

`--auth` and `--snapshot` (pull) are stubs in this task that print “not implemented” and exit 1. Implemented in Task 10.

- [ ] **Step 1: Failing test**

```elixir
test "dry-run reports INV-000123 and skips draft", %{snap: snap} do
  assert {:ok, %{counts: c, errors: []}} = XeroImport.dry_run(snap, %{})
  assert c.invoices == 3  # INV-000123, SI-88, CONV-AR-1
  assert c.skipped >= 1
end

test "dry-run captures missing allocation without writing", %{snap: snap} = ctx do
  snap = put_in(snap.payments, [/* bad payment */])
  assert {:ok, %{errors: errors}} = XeroImport.dry_run(snap, %{})
  assert Enum.any?(errors, &match?({:missing_allocation_target, _, _}, &1))
  refute Repo.exists?(from c in FullCircle.Sys.Company, where: c.name == ^ctx.name)
end
```

- [ ] **Step 2: Run — dry_run missing**

- [ ] **Step 3: Implement dry_run (share validation with Apply via `Apply.plan/2` that returns `{ops, errors}` without writing). Wire Mix task with `Mix.Task`, `app.start`, OptionParser `strict: [auth: :boolean, snapshot: :boolean, dry_run: :boolean, apply: :boolean, reset: :boolean, reconcile: :boolean, user: :string, snapshot_dir: :string]`.**

`--apply` without `--reset` on a dirty Golden Husbandry company must print the `:company_not_empty` error and exit 1.

- [ ] **Step 4: `mix test test/full_circle/xero_import/dry_run_test.exs` PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/xero_import.ex lib/full_circle/xero_import/apply.ex lib/mix/tasks/full_circle.import_xero.ex test/full_circle/xero_import/dry_run_test.exs
git commit -m "feat(xero-import): dry-run and Mix task CLI"
```

---

### Task 9: Reconcile

**Files:**
- Create: `lib/full_circle/xero_import/reconcile.ex`
- Modify: Mix task `--reconcile`
- Test: `test/full_circle/xero_import/reconcile_test.exs`

**Interfaces:**
- Produces: `Reconcile.run(snapshot, company, user) :: {:ok, %{checks: [map()]}} | {:error, %{checks: [map()]}}`. Each check is `%{name: atom(), ok?: boolean(), diffs: [map()]}`. Tolerance `Decimal.new("0.01")`. Compare snapshot `reports` keys from Task 1 to live Full Circle:

  - TB: `Reporting` / sum of `transactions.amount` per account name (mapped). Use the same sign convention as `reports.trial_balance`.
  - Aged AR/AP: outstanding per contact (invoice/bill header txn + matchers), names as Full Circle contact names.
  - Invoice/bill count+totals: authorised imported docs only.
  - FA NBV: `pur_price - sum(seeded depre) - disposals`.
  - Bank: account_type `Bank` balances.

After a successful fixture `Apply.run`, **recompute** expected `reports.json` from what Apply actually posted (update the fixture in this task if the placeholder numbers were wrong). One test mutates a Full Circle account balance (insert a 0.01 journal) and expects `{:error, _}`.

- [ ] **Step 1: Failing tests** — matching apply → `{:ok, _}`; off-by-0.01 → `{:error, %{checks: checks}}` with a TB diff printing both sides (`xero` / `full_circle` / `delta`).

- [ ] **Step 2: Run — Reconcile missing**

- [ ] **Step 3: Implement Reconcile + Mix `--reconcile`** (read-only; needs `--user` and existing company name, default Golden Husbandry).

- [ ] **Step 4: `mix test test/full_circle/xero_import/` PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/xero_import/reconcile.ex lib/full_circle/xero_import.ex lib/mix/tasks/full_circle.import_xero.ex test/full_circle/xero_import/reconcile_test.exs test/support/fixtures/xero_import
git commit -m "feat(xero-import): reconcile snapshot reports to Full Circle"
```

---

### Task 10: Xero HTTP client, --snapshot, --auth

**Files:**
- Create: `lib/full_circle/xero_import/client.ex` (behaviour)
- Create: `lib/full_circle/xero_import/http_client.ex`
- Create: `lib/full_circle/xero_import/credentials.ex`
- Modify: `lib/full_circle/xero_import/snapshot.ex` — `pull/2`
- Modify: Mix task
- Test: `test/full_circle/xero_import/http_client_test.exs` (no network)

**Interfaces:**
- `Client` callbacks: `get_organisation/1`, `list_accounts/1`, … one per snapshot file. Return `{:ok, decoded} | {:error, term()}`.
- `HttpClient` implements them with `Req.get` to `https://api.xero.com/api.xro/2.0/...` and Assets `https://api.xero.com/assets.xro/1.0/Assets`. Header `Xero-Tenant-Id`, `Authorization: Bearer`. Paginate with `page` until empty (Accounting API). Retry 429 with `Retry-After` or 2/4/8s, max 5. 401 after one token refresh → error.
- `Credentials.load(path)` reads `XERO_CLIENT_ID=` dotenv-style file. `token/1` — if `XERO_REFRESH_TOKEN` present, refresh via `POST https://identity.xero.com/connect/token`; else client_credentials grant (`grant_type=client_credentials`, scopes from spec).
- `Snapshot.pull(client, dest_dir)` writes to `dest_dir <> ".tmp"` then `File.rename` over dest only on full success. Never replace dest on failure.
- `--auth`: bind `127.0.0.1:4099`, print the Xero authorize URL (`https://login.xero.com/identity/connect/authorize` with client_id, redirect_uri `http://127.0.0.1:4099/callback`, scopes from spec, `response_type=code`). Exchange code, append tokens to `.credentials`. No unit test for the browser; test the token POST parser with a Bypass or a fake `Req` adapter.

Do **not** request `accounting.journals.read`. Endpoints: Organisation, Accounts, TaxRates, Contacts, Items, Invoices (paginate), CreditNotes, Payments, BankTransactions, BankTransfers, ManualJournals, Setup (conversion), Reports (TrialBalance, AgedReceivablesByContact, AgedPayablesByContact), Assets.

- [ ] **Step 1: Tests for pagination assembly, 429 retry, failed pull leaving old dir, credentials parse, client_credentials body.** Use `Req.Test` (Req 0.6) or a tiny mock module that implements `Client`.

- [ ] **Step 2: Run — modules missing**

- [ ] **Step 3: Implement.** Default credentials path `priv/xero_import/.credentials`.

- [ ] **Step 4: Unit tests PASS. Manually: operator creates the Xero app (not in CI).**

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/xero_import lib/mix/tasks/full_circle.import_xero.ex test/full_circle/xero_import/http_client_test.exs
git commit -m "feat(xero-import): Xero HTTP client, snapshot pull, and OAuth auth"
```

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| Mix task flags | 8, 10 |
| Snapshot on disk, atomic replace | 1, 10 |
| Client behaviour / fixture CI | 1, 10 |
| Mapper tables, tax, contacts, goods, FA abort | 2 |
| Default AR/AP/tax reuse | 6 |
| Import wrappers, keep Xero numbers | 3–5 |
| Conversion balances + strip conversion invoices | 7 |
| Full history live docs + matchers + abort missing target | 7 |
| Draft/void skip | 2, 7 |
| Foreign currency abort | 2, 7 |
| Gapless bump rules | 7 |
| Company empty / `--reset` | 6 |
| Dry-run | 8 |
| Reconcile checks ±0.01 | 9 |
| Custom Connection + web auth, no journals.read | 10 |
| No PaySlips / no bank-rec ticks | all (not implemented) |
| Salary as journals/bank spend | 7 (manual journals + payments) |

## Operator after code lands

1. Create Xero app; put Client ID/Secret in `priv/xero_import/.credentials`.
2. `mix full_circle.import_xero --auth` if web app.
3. `mix full_circle.import_xero --snapshot`
4. `mix full_circle.import_xero --dry-run --user YOU@email`
5. `mix full_circle.import_xero --apply --user YOU@email`
6. `mix full_circle.import_xero --reconcile --user YOU@email`
7. Close the period; revoke the Xero app.
