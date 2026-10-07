# Receipt Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On New Payment and New Purchase Invoice, a clerk adds a photo or PDF of a bill or receipt (📱 phone QR or 📎 desktop). An AI reads it and fills the form's empty fields. The clerk corrects and saves, and the file is attached to the saved document as a 🧾 Receipt note.

**Architecture:** The pipeline is pure and has three stages:
1. `Receipts.Extract`: file → `%Extracted{}`, through the AI.
2. `Receipts.Prefill`: `%Extracted{}` → form attrs and warnings. It reuses the contact and goods rules in a new shared `DocPrefill` module.
3. `FullCircleWeb.ReceiptCapture`: the LiveView glue and a function component, shared by both forms.

Files go through the existing note tray and phone page. The form runs extraction with `start_async`. Save appends a `Notes.create_note` step to the document's create `Multi`, so the document and its receipt commit together.

**Tech Stack:** Elixir 1.19 / Phoenix 1.8 / LiveView 1.2, Ecto Multi, `:httpc` through `BankReconciliation.LlmClient` (Claude native API / Gemini OpenAI-compatible), ExUnit + Phoenix.LiveViewTest.

**Spec:** `docs/superpowers/specs/2026-10-07-receipt-capture-design.md`

## Global Constraints

- Use `use FullCircle.Schema` for any schema. There are no new tables and no migrations in this plan.
- Flash kind for warnings is `:warn`. `:warning` renders nothing.
- Never run bare `mix format`. Format only the files you touched: `mix format path/a.ex path/b.exs`.
- Commit on `master`. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests make **no live AI calls**. Stub through `Application.put_env(:full_circle, :llm_http, fn url, headers, body, timeout -> … end)` and use `async: false` in every test module that sets it.
- UI must look right in light **and** dark themes. Every colour class has a `dark:` pair.
- Seeded-line traps, verbatim from `.claude/skills/e-invoice-bill-prefill.md`:
  - `unit_multiplier` must stay **0**.
  - Quantity goes into `package_qty` **and** `quantity`.
  - Tax % ÷ 100 = `tax_rate` fraction.
- Receipt AI settings key: `"llm_receipt"`. Shared key: `"llm"`. Field names: `llm-provider`, `llm-endpoint`, `llm-model`, `llm-api-key`.
- Extraction timeout: **90 s**. Receipt `max_tokens`: **4096**. Image size limit sent to the AI: **5 MB**.
- Note on the saved document: title `"🧾 Receipt"`, visibility Everyone (nil), `subject_type` `"Payment"` / `"PurInvoice"`.
- PurInvoice supplier bill no → **`e_inv_internal_id`**. `pur_invoice_no` is our gapless PINV number. Never seed it.
- Not recognised → only `descriptions` = summary (≤ 200 chars) is seeded, plus a warning.
- Merging fills **only blank fields**. A zero amount counts as blank.

## Review Focus

1. **A large desktop photo (> 5 MB, e.g. a 12 MP JPEG sent via 📎 from a PC folder):** the clerk gets "Photo too large to read (max 5 MB)", not an API 400. Test in Task 4.
2. **A negative total (a refund slip or credit receipt):** warn "Total is negative — this looks like a refund or credit note", rather than silently seeding a negative `funds_amount`. Test in Task 4.
3. **The clerk picked the supplier before the AI finished:** the clerk's contact and its id are kept, and the receipt's contact is not merged half-way (name from one, id from the other). Test in Task 6.
4. **↻ Read again after the clerk keyed lines:** keyed lines survive, and only blank header fields fill. Test in Task 6 (pure) and Task 7 (LiveView).
5. **The clerk changes the supplier after a receipt was read:** the duplicate warning is re-checked against the new contact, so a stale "possible duplicate" does not linger and a new one appears. Test in Task 7.

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `lib/full_circle/sys.ex` | modify | `llm_defaults/0`, `llm_settings/2` |
| `lib/full_circle_web/live/bank_reconciliation_live/index.ex` | modify | use `Sys.llm_settings/1` |
| `lib/full_circle_web/live/query_live/form.ex` | modify | use `Sys.llm_settings/1` |
| `lib/full_circle_web/live/company_live/form.ex` | modify | "AI for receipts / bills" block, save `"llm_receipt"` |
| `lib/full_circle/doc_prefill.ex` | create | shared contact/goods/line seeding (moved from `EInvMetas.Prefill`) |
| `lib/full_circle/e_inv_metas/prefill.ex` | modify | call `DocPrefill` |
| `lib/full_circle/bank_reconciliation/llm_client.ex` | modify | `call_with_image/6`, opts on `call_with_pdf`, swappable HTTP |
| `lib/full_circle/receipts/extracted.ex` | create | `%Extracted{}` struct |
| `lib/full_circle/receipts/extract.ex` | create | prompt, AI call, JSON decode, parse/validate |
| `lib/full_circle/receipts/prefill.ex` | create | `%Extracted{}` → attrs + warnings |
| `lib/full_circle/bill_pay.ex` | modify | `create_payment/4` with `extend_multi` |
| `lib/full_circle_web/receipt_capture.ex` | create | socket helpers, `merge_params/3`, `attach_multi/3`, `receipt_capture/1` component |
| `lib/full_circle_web/live/payment_live/form.ex` | modify | wire ReceiptCapture |
| `lib/full_circle_web/live/pur_invoice_live/form.ex` | modify | wire ReceiptCapture |
| `.claude/skills/receipt-capture.md` | create | contract skill |
| `.claude/skills/e-invoice-bill-prefill.md`, `CLAUDE.md` | modify | point at DocPrefill, list the new skill |

Tests: `test/full_circle/llm_settings_test.exs`, `test/full_circle/doc_prefill_test.exs`, `test/full_circle/bank_reconciliation/llm_client_test.exs`, `test/full_circle/receipts/extract_test.exs`, `test/full_circle/receipts/prefill_test.exs`, `test/full_circle_web/receipt_capture_test.exs`, `test/full_circle_web/live/payment_receipt_capture_live_test.exs`, `test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs`, plus one test added to `test/full_circle_web/live/company_live_test.exs` and one to `test/full_circle/bill_pay_test.exs`.

---

### Task 1: Per-feature AI settings (`Sys.llm_settings/2`) + Company form block

**Files:**
- Modify: `lib/full_circle/sys.ex` (near `get_company_settings/2`, ~line 267)
- Modify: `lib/full_circle_web/live/bank_reconciliation_live/index.ex:1253-1263`
- Modify: `lib/full_circle_web/live/query_live/form.ex:~285-295` (`load_llm_settings/1`)
- Modify: `lib/full_circle_web/live/company_live/form.ex` (LLM block ~110-175, `mount_edit` ~298-315, `"save"` ~348)
- Test: `test/full_circle/llm_settings_test.exs` (create), `test/full_circle_web/live/company_live_test.exs` (add one test in `describe "Edit"`)

**Interfaces:**
- Produces:
  - `Sys.llm_defaults() :: %{String.t() => String.t()}`
  - `Sys.llm_settings(company) :: map` (profile `:default`)
  - `Sys.llm_settings(company, :default | :receipt) :: map`
  - All four keys are always present.

- [ ] **Step 1: Write the failing unit test**

Create `test/full_circle/llm_settings_test.exs`:

```elixir
defmodule FullCircle.LlmSettingsTest do
  use FullCircle.DataCase, async: true

  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures

  alias FullCircle.Sys

  setup do
    %{company: company_fixture(user_fixture(), %{})}
  end

  defp put(company, key, map) do
    {:ok, company} = Sys.update_company_settings(company, key, map)
    company
  end

  test "default profile is the shared llm setting over blanks", %{company: c} do
    assert Sys.llm_settings(c) == %{
             "llm-provider" => "none",
             "llm-endpoint" => "",
             "llm-model" => "",
             "llm-api-key" => ""
           }

    c = put(c, "llm", %{"llm-provider" => "claude", "llm-api-key" => "k1"})
    assert Sys.llm_settings(c)["llm-provider"] == "claude"
    assert Sys.llm_settings(c)["llm-api-key"] == "k1"
    assert Sys.llm_settings(c)["llm-model"] == ""
  end

  test "receipt profile: non-blank receipt fields win, blank ones fall back", %{company: c} do
    c =
      c
      |> put("llm", %{
        "llm-provider" => "claude",
        "llm-endpoint" => "",
        "llm-model" => "claude-sonnet-4-6",
        "llm-api-key" => "k1"
      })
      |> put("llm_receipt", %{
        "llm-provider" => "",
        "llm-endpoint" => "",
        "llm-model" => "claude-haiku-4-5-20251001",
        "llm-api-key" => ""
      })

    receipt = Sys.llm_settings(c, :receipt)
    assert receipt["llm-model"] == "claude-haiku-4-5-20251001"
    assert receipt["llm-provider"] == "claude"
    assert receipt["llm-api-key"] == "k1"
    assert Sys.llm_settings(c, :default)["llm-model"] == "claude-sonnet-4-6"
  end

  test "receipt profile with no receipt settings equals the default", %{company: c} do
    c = put(c, "llm", %{"llm-provider" => "gemini", "llm-api-key" => "g"})
    assert Sys.llm_settings(c, :receipt) == Sys.llm_settings(c)
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle/llm_settings_test.exs`
Expected: FAIL with `UndefinedFunctionError ... Sys.llm_settings/1`.

- [ ] **Step 3: Implement in `lib/full_circle/sys.ex`**

Add directly after `update_company_settings/3`:

```elixir
  @llm_defaults %{
    "llm-provider" => "none",
    "llm-endpoint" => "",
    "llm-model" => "",
    "llm-api-key" => ""
  }

  def llm_defaults, do: @llm_defaults

  @doc """
  AI provider settings for a feature. `:default` is the shared `"llm"` key
  (Bank Recon, Query). `:receipt` lays every non-blank `"llm_receipt"` field
  over it, so receipts can use another model, or another provider, while
  reusing whatever was left blank.
  """
  def llm_settings(company, profile \\ :default)

  def llm_settings(company, :default),
    do: Map.merge(@llm_defaults, get_company_settings(company, "llm"))

  def llm_settings(company, :receipt) do
    overrides =
      company
      |> get_company_settings("llm_receipt")
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    Map.merge(llm_settings(company, :default), overrides)
  end
```

- [ ] **Step 4: Run the unit test and confirm it passes**

Run: `mix test test/full_circle/llm_settings_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Replace the three copies**

In `lib/full_circle_web/live/bank_reconciliation_live/index.ex`, replace the body of `load_llm_settings/1`:

```elixir
  defp load_llm_settings(socket),
    do: FullCircle.Sys.llm_settings(socket.assigns.current_company)
```

In `lib/full_circle_web/live/query_live/form.ex`, replace the body of its `load_llm_settings/1` (the `defaults = %{…}` / `Map.merge` block) with the same one-liner.

In `lib/full_circle_web/live/company_live/form.ex` `mount_edit/2`, replace the `llm_defaults = …` and `llm_settings = …` lines with:

```elixir
    llm_settings = Sys.llm_settings(company)

    llm_receipt =
      Map.merge(Sys.llm_defaults(), Sys.get_company_settings(company, "llm_receipt"))
```

and add `|> assign(:llm_receipt, llm_receipt)` right after `|> assign(:llm_settings, llm_settings)`.

- [ ] **Step 6: Write the failing Company form test**

Add inside `describe "Edit"` in `test/full_circle_web/live/company_live_test.exs`:

```elixir
    test "saves receipt AI settings apart from the shared ones", %{
      conn: conn,
      comp: comp,
      comp1: comp1
    } do
      conn = conn |> put_session(:current_company_id, comp1.id)
      {:ok, lv, html} = live(conn, ~p"/edit_company/#{comp.id}")
      assert html =~ "AI for receipts / bills"

      attrs = valid_company_attributes(%{name: "kakak"})

      {:ok, _, _html} =
        lv
        |> announce_closing_month(attrs)
        |> form("#company",
          company: attrs,
          llm: %{"llm-provider" => "claude", "llm-model" => "claude-sonnet-4-6"},
          llm_receipt: %{"llm-provider" => "", "llm-model" => "claude-haiku-4-5-20251001"}
        )
        |> render_submit()
        |> follow_redirect(conn)

      fresh = FullCircle.Sys.get_company!(comp.id)
      assert FullCircle.Sys.llm_settings(fresh, :receipt)["llm-model"] == "claude-haiku-4-5-20251001"
      assert FullCircle.Sys.llm_settings(fresh, :receipt)["llm-provider"] == "claude"
      assert FullCircle.Sys.llm_settings(fresh)["llm-model"] == "claude-sonnet-4-6"
    end
```

Run: `mix test test/full_circle_web/live/company_live_test.exs`
Expected: the new test FAILS (no "AI for receipts / bills" text, and no `llm_receipt` inputs for `form/3`).

- [ ] **Step 7: Add the block and save**

In `company_live/form.ex`:
- Change the LLM block's help text to `gettext("Shared AI settings: bank statements and queries. These settings are shared across all users in this company.")`.
- Insert this before that block's closing `</div>` (after the shared grid's closing `</div>`):

```heex
        <p class="font-semibold mt-4 mb-1">{gettext("AI for receipts / bills")}</p>
        <p class="text-xs text-gray-500 dark:text-gray-400 mb-2">
          {gettext(
            "Reads photos of bills and receipts on New Payment / New Purchase Invoice. Leave a field blank to use the setting above."
          )}
        </p>
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <label class="block text-sm font-medium mb-1">{gettext("Provider")}</label>
            <select name="llm_receipt[llm-provider]" class="w-full rounded border-gray-300 text-sm">
              <option value="" selected={@llm_receipt["llm-provider"] in [nil, ""]}>
                {gettext("Same as above")}
              </option>
              <option value="none" selected={@llm_receipt["llm-provider"] == "none"}>
                {gettext("None")}
              </option>
              <option value="claude" selected={@llm_receipt["llm-provider"] == "claude"}>
                Claude
              </option>
              <option value="gemini" selected={@llm_receipt["llm-provider"] == "gemini"}>
                Gemini
              </option>
            </select>
          </div>
          <div class="col-span-9">
            <label class="block text-sm font-medium mb-1">{gettext("Endpoint")}</label>
            <input
              type="text"
              name="llm_receipt[llm-endpoint]"
              value={@llm_receipt["llm-endpoint"]}
              placeholder={@llm_settings["llm-endpoint"]}
              class="w-full rounded border-gray-300 text-sm"
            />
          </div>
          <div class="col-span-3">
            <label class="block text-sm font-medium mb-1">{gettext("Model")}</label>
            <input
              type="text"
              name="llm_receipt[llm-model]"
              value={@llm_receipt["llm-model"]}
              placeholder={@llm_settings["llm-model"]}
              class="w-full rounded border-gray-300 text-sm"
            />
          </div>
          <div class="col-span-9">
            <label class="block text-sm font-medium mb-1">{gettext("API Key")}</label>
            <input
              type="text"
              name="llm_receipt[llm-api-key]"
              value={@llm_receipt["llm-api-key"]}
              placeholder={if @llm_settings["llm-api-key"] != "", do: "•••• " <> gettext("same as above")}
              class="w-full rounded border-gray-300 text-sm"
            />
          </div>
        </div>
```

In `handle_event("save", …)`, after the `"llm"` update:

```elixir
    if llm_receipt_params = params["llm_receipt"] do
      Sys.update_company_settings(socket.assigns.company, "llm_receipt", llm_receipt_params)
    end
```

- [ ] **Step 8: Run the tests and confirm they pass**

Run: `mix test test/full_circle/llm_settings_test.exs test/full_circle_web/live/company_live_test.exs test/full_circle_web/live/query_live_test.exs test/full_circle_web/live/bank_reconciliation_live_test.exs`
Expected: 0 failures.

- [ ] **Step 9: Commit**

```bash
mix format lib/full_circle/sys.ex lib/full_circle_web/live/bank_reconciliation_live/index.ex lib/full_circle_web/live/query_live/form.ex lib/full_circle_web/live/company_live/form.ex test/full_circle/llm_settings_test.exs test/full_circle_web/live/company_live_test.exs
git add -A lib/full_circle/sys.ex lib/full_circle_web/live/bank_reconciliation_live/index.ex lib/full_circle_web/live/query_live/form.ex lib/full_circle_web/live/company_live/form.ex test/full_circle/llm_settings_test.exs test/full_circle_web/live/company_live_test.exs
git commit -m "feat(sys): per-feature AI settings; receipts can use their own model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `FullCircle.DocPrefill`: shared seeding moved out of `EInvMetas.Prefill`

There are no unit tests for `EInvMetas.Prefill` today, because `build/4` calls LHDN. So this task first pins the moved behaviour with characterization tests against `DocPrefill`, then switches `EInvMetas.Prefill` over to it.

**Files:**
- Create: `lib/full_circle/doc_prefill.ex`
- Modify: `lib/full_circle/e_inv_metas/prefill.ex`
- Test: `test/full_circle/doc_prefill_test.exs`

**Interfaces:**
- Produces:
  - `DocPrefill.seed_lines([%{descriptions, quantity, unit_price, discount, tax_rate}]) :: [map]`
    - `tax_rate` is a **percent** (number, Decimal or nil). Output maps are string-keyed.
    - `"tax_rate"` is the fraction, `"unit_multiplier" => 0`, `"package_qty" => 0`, `"_persistent_id" => idx`.
  - `DocPrefill.put_contact(attrs, tin, brn, name, com, role, opts \\ []) :: {attrs, String.t() | nil}`
    - `role`: `:supplier | :customer`.
    - `opts[:source]` labels the document in the name-only warning (default `"e-Invoice"`).
    - Puts atom keys `:contact_name, :contact_id, :tax_id, :reg_no`.
  - `DocPrefill.put_goods(attrs, detail_key, com, user, side :: :purchase | :sales) :: attrs`
  - `DocPrefill.to_decimal(any) :: Decimal.t() | nil`

- [ ] **Step 1: Write the failing characterization test**

Create `test/full_circle/doc_prefill_test.exs`:

```elixir
defmodule FullCircle.DocPrefillTest do
  use FullCircle.DataCase, async: true

  import FullCircle.BillingFixtures
  import Ecto.Query

  alias FullCircle.{Accounting, Billing, DocPrefill, Repo}
  alias FullCircle.Accounting.TaxCode

  setup do
    %{admin: admin, company: company} = billing_setup()
    %{admin: admin, company: company}
  end

  defp bought(contact, good, company, admin) do
    pur_acct = Accounting.get_account_by_name("General Purchases", company, admin)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    {:ok, _} =
      Billing.create_pur_invoice(
        pur_invoice_attrs(contact, good, pur_acct, no_ptax, tax_rate: "0"),
        company,
        admin
      )
  end

  describe "seed_lines/1" do
    test "percent becomes a fraction; multiplier and package qty stay 0" do
      [line] =
        DocPrefill.seed_lines([
          %{descriptions: "PVC PIPE", quantity: 4.0, unit_price: 12.5, discount: 0.0, tax_rate: 6.0}
        ])

      assert line["descriptions"] == "PVC PIPE"
      assert line["quantity"] == 4.0
      assert line["tax_rate"] == 0.06
      assert line["unit_multiplier"] == 0
      assert line["package_qty"] == 0
      assert line["_persistent_id"] == 0
      assert line["good_name"] == ""
    end

    test "Decimal percent becomes a Decimal fraction; nil tax is 0" do
      [a, b] =
        DocPrefill.seed_lines([
          %{descriptions: "A", quantity: Decimal.new(1), unit_price: Decimal.new("8"), discount: Decimal.new(0), tax_rate: Decimal.new("8")},
          %{descriptions: "B", quantity: Decimal.new(1), unit_price: Decimal.new("2"), discount: Decimal.new(0), tax_rate: nil}
        ])

      assert Decimal.eq?(a["tax_rate"], Decimal.new("0.08"))
      assert b["tax_rate"] == 0
      assert b["_persistent_id"] == 1
    end
  end

  describe "put_contact/7" do
    test "TIN match: contact set, no warning", %{company: c, admin: u} do
      contact = contact_fixture(c, u, %{"name" => "Kedai Ali Hardware", "tax_id" => "C2345678901"})

      {attrs, warning} = DocPrefill.put_contact(%{}, "C2345678901", nil, "whatever", c, :supplier)

      assert attrs.contact_id == contact.id
      assert attrs.contact_name == contact.name
      assert warning == nil
    end

    test "name-only match warns and names the source", %{company: c, admin: u} do
      contact_fixture(c, u, %{"name" => "Kedai Ali Hardware", "tax_id" => "C1", "reg_no" => "R1"})

      {attrs, warning} =
        DocPrefill.put_contact(%{}, nil, nil, "KEDAI ALI HARDWARE", c, :supplier, source: "Receipt")

      assert attrs.contact_id
      assert warning =~ "matched by name only"
      assert warning =~ "Receipt"
    end

    test "no match: contact blank with the read name, warns", %{company: c} do
      {attrs, warning} = DocPrefill.put_contact(%{}, "C999", nil, "Nobody Sdn Bhd", c, :supplier)

      assert attrs.contact_id == nil
      assert attrs.contact_name == "Nobody Sdn Bhd"
      assert warning =~ "not found"
    end
  end

  describe "put_goods/5" do
    test "sole good: good and packaging seeded, multiplier 0, package_qty = qty",
         %{company: c, admin: u} do
      contact = contact_fixture(c, u)
      good = good_fixture(c, u)
      bought(contact, good, c, u)

      attrs =
        %{contact_id: contact.id, payment_details: DocPrefill.seed_lines([%{descriptions: "x", quantity: 3, unit_price: 1, discount: 0, tax_rate: nil}])}
        |> DocPrefill.put_goods(:payment_details, c, u, :purchase)

      [line] = attrs.payment_details
      assert line["good_name"] == good.name
      assert line["package_name"] == "default_pkg"
      assert line["unit_multiplier"] == 0
      assert line["package_qty"] == 3
    end

    test "two goods: only a good named in the description, without packaging",
         %{company: c, admin: u} do
      contact = contact_fixture(c, u)
      g1 = good_fixture(c, u, %{"name" => "Layer Feed"})
      g2 = good_fixture(c, u, %{"name" => "Wheat Pollard"})
      bought(contact, g1, c, u)
      bought(contact, g2, c, u)

      attrs =
        %{
          contact_id: contact.id,
          pur_invoice_details:
            DocPrefill.seed_lines([
              %{descriptions: "WHEAT POLLARD 55KG", quantity: 2, unit_price: 1, discount: 0, tax_rate: nil},
              %{descriptions: "GLUE", quantity: 1, unit_price: 1, discount: 0, tax_rate: nil}
            ])
        }
        |> DocPrefill.put_goods(:pur_invoice_details, c, u, :purchase)

      [pollard, glue] = attrs.pur_invoice_details
      assert pollard["good_name"] == g2.name
      assert pollard["package_name"] == ""
      assert glue["good_name"] == ""
    end

    test "no contact: unchanged", %{company: c, admin: u} do
      attrs = %{contact_id: nil, payment_details: []}
      assert DocPrefill.put_goods(attrs, :payment_details, c, u, :purchase) == attrs
    end
  end

  test "to_decimal/1 parses strings, numbers and junk" do
    assert Decimal.eq?(DocPrefill.to_decimal("12.50"), Decimal.new("12.50"))
    assert Decimal.eq?(DocPrefill.to_decimal(3), Decimal.new(3))
    assert DocPrefill.to_decimal("abc") == nil
    assert DocPrefill.to_decimal(nil) == nil
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle/doc_prefill_test.exs`
Expected: FAIL. `FullCircle.DocPrefill` is undefined.

- [ ] **Step 3: Create `lib/full_circle/doc_prefill.ex`**

Move the code **unchanged** except for these four points:
- (a) The functions become public.
- (b) `seed_lines/1` uses `percent_to_fraction/1`, so it also accepts Decimals. Floats behave exactly as before.
- (c) `put_contact` takes `opts` with `:source`.
- (d) The name-only warning text uses `%{source}` instead of the literal "e-Invoice".

```elixir
defmodule FullCircle.DocPrefill do
  @moduledoc """
  Seeding a new purchase or sales document from data read off another
  document: an LHDN e-invoice (`EInvMetas.Prefill`) or a photographed
  receipt (`Receipts.Prefill`). Contact by identifiers first, goods only when
  safe, and the seeded-line traps in one place — see
  `.claude/skills/e-invoice-bill-prefill.md`.
  """

  alias FullCircle.{Accounting, Billing, Product}
  use Gettext, backend: FullCircleWeb.Gettext

  # --- Lines ---

  @doc """
  Detail params from read lines. `tax_rate` on input is a percent; on output
  a fraction. `unit_multiplier` stays 0 and `package_qty` 0 until a good with
  packaging is applied — copying the good's multiplier zeroes the quantity.
  """
  def seed_lines(lines) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      %{
        "_persistent_id" => idx,
        "descriptions" => line.descriptions,
        "quantity" => line.quantity,
        "unit_price" => line.unit_price,
        "discount" => line.discount,
        "tax_rate" => percent_to_fraction(line.tax_rate),
        "good_name" => "",
        "account_name" => "",
        "tax_code_name" => "",
        "package_name" => "",
        "package_qty" => 0,
        "unit_multiplier" => 0,
        "unit" => ""
      }
    end)
  end

  defp percent_to_fraction(nil), do: 0
  defp percent_to_fraction(%Decimal{} = d), do: Decimal.div(d, 100)
  defp percent_to_fraction(n) when is_number(n), do: n / 100

  # --- Contact ---

  def put_contact(attrs, tin, brn, name, com, role, opts \\ []) do
    source = Keyword.get(opts, :source, gettext("e-Invoice"))

    case Accounting.resolve_e_invoice_contact(tin, brn, name, com) do
      nil ->
        label = if role == :customer, do: gettext("Customer"), else: gettext("Supplier")

        {Map.merge(attrs, %{contact_name: name || "", contact_id: nil, tax_id: nil, reg_no: nil}),
         gettext("%{role} \"%{name}\" not found. Please select the contact.",
           role: label,
           name: name || ""
         )}

      {contact, source_field} ->
        {Map.merge(attrs, %{
           contact_name: contact.name,
           contact_id: contact.id,
           tax_id: contact.tax_id,
           reg_no: contact.reg_no
         }), contact_warning(source_field, contact, name, role, source)}
    end
  end

  defp contact_warning(:name, contact, read_name, role, source) do
    role_label = if role == :customer, do: gettext("Customer"), else: gettext("Supplier")

    gettext(
      "%{role} matched by name only: %{source} \"%{read_name}\" to \"%{contact}\". No TIN or Reg No match, please verify.",
      role: role_label,
      source: source,
      read_name: read_name || "",
      contact: contact.name
    )
  end

  defp contact_warning(_identifier_match, _contact, _read_name, _role, _source), do: nil

  # --- Goods ---

  def put_goods(%{contact_id: contact_id} = attrs, detail_key, com, user, side)
      when not is_nil(contact_id) do
    # body moved verbatim from EInvMetas.Prefill.put_goods/5
  end

  def put_goods(attrs, _detail_key, _com, _user, _side), do: attrs

  # seed_good/6, good_named_in/2, apply_good/5, merge_good/4 (both clauses):
  # moved verbatim from EInvMetas.Prefill as private functions.

  # --- Numbers ---

  def to_decimal(nil), do: nil
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(n) when is_integer(n), do: Decimal.new(n)
  def to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  def to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  def to_decimal(_), do: nil
end
```

The two comments above mark a **verbatim move**, not a placeholder. Copy the bodies of `put_goods/5` (first clause), `seed_good/6` (both clauses), `good_named_in/2` (both clauses), `apply_good/5` and `merge_good/4` (both clauses) from `lib/full_circle/e_inv_metas/prefill.ex` lines 200-303 into this module, unchanged.

- [ ] **Step 4: Switch `EInvMetas.Prefill` to it**

In `lib/full_circle/e_inv_metas/prefill.ex`:
- Delete `seed_lines/1`, `put_contact/6`, both `contact_warning/4` clauses, `put_goods/5` (both clauses), `seed_good/6`, `good_named_in/2`, `apply_good/5`, `merge_good/4` and the `to_decimal/1` clauses.
- Add `alias FullCircle.DocPrefill`.
- Replace the calls:
  - `seed_lines(` → `DocPrefill.seed_lines(`
  - `|> put_contact(` → `|> DocPrefill.put_contact(`
  - `put_goods(attrs,` → `DocPrefill.put_goods(attrs,`
  - in `payable/2`: `&to_decimal/1` → `&DocPrefill.to_decimal/1`
- Remove the now-unused aliases `Accounting, Billing, Product` from its `alias` line, keeping `EInvMetas`.
- Keep `variance/2`.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix test test/full_circle/doc_prefill_test.exs test/full_circle_web/live/e_inv_list_live_test.exs test/full_circle/e_inv_metas test/full_circle/accounting_test.exs && mix compile --warnings-as-errors`
Expected: 0 failures and no warnings (an unused-alias warning means Step 4 is incomplete).

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/doc_prefill.ex lib/full_circle/e_inv_metas/prefill.ex test/full_circle/doc_prefill_test.exs
git add lib/full_circle/doc_prefill.ex lib/full_circle/e_inv_metas/prefill.ex test/full_circle/doc_prefill_test.exs
git commit -m "refactor(prefill): shared DocPrefill for contact, goods and seeded lines

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `LlmClient`: images, per-call options, swappable HTTP

**Files:**
- Modify: `lib/full_circle/bank_reconciliation/llm_client.ex`
- Test: `test/full_circle/bank_reconciliation/llm_client_test.exs` (create)

**Interfaces:**
- Produces:
  - `LlmClient.call_with_image(settings, system, user, base64, media_type, opts \\ []) :: {:ok, text, usage} | {:error, String.t()}`
  - `LlmClient.call_with_pdf(settings, system, user, base64, opts \\ [])` (the existing 4-arity call is unchanged)
  - `opts`: `:timeout` (ms, default 600_000), `:max_tokens` (default 65_536)
  - Test hook: `Application.get_env(:full_circle, :llm_http)`, a 4-arity fn `(url, headers, body_json, timeout) -> {:ok, decoded_map} | {:error, String.t()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.BankReconciliation.LlmClientTest do
  use ExUnit.Case, async: false

  alias FullCircle.BankReconciliation.LlmClient

  setup do
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn url, headers, body, timeout ->
      send(test_pid, {:llm_request, url, headers, Jason.decode!(body), timeout})

      if String.contains?(url, "anthropic") do
        {:ok, %{"content" => [%{"text" => "ok"}], "usage" => %{"input_tokens" => 10, "output_tokens" => 2}}}
      else
        {:ok,
         %{
           "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}],
           "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2}
         }}
      end
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
  end

  @claude %{"llm-provider" => "claude", "llm-api-key" => "k", "llm-endpoint" => "", "llm-model" => ""}
  @gemini %{"llm-provider" => "gemini", "llm-api-key" => "g", "llm-endpoint" => "", "llm-model" => ""}

  test "claude image: image block with media type, options applied" do
    assert {:ok, "ok", usage} =
             LlmClient.call_with_image(@claude, "sys", "read", "QUJD", "image/jpeg",
               timeout: 90_000,
               max_tokens: 4096
             )

    assert_received {:llm_request, _url, _h, body, 90_000}
    [%{"content" => [block, text]}] = body["messages"]
    assert block == %{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/jpeg", "data" => "QUJD"}}
    assert text == %{"type" => "text", "text" => "read"}
    assert body["max_tokens"] == 4096
    assert usage.total_tokens == 12
  end

  test "gemini image: data URI image_url" do
    assert {:ok, "ok", _} = LlmClient.call_with_image(@gemini, "sys", "read", "QUJD", "image/png")
    assert_received {:llm_request, _url, _h, body, 600_000}
    [_sys, %{"content" => [block, _]}] = body["messages"]
    assert block == %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,QUJD"}}
  end

  test "pdf keeps the document block and the old defaults" do
    assert {:ok, "ok", _} = LlmClient.call_with_pdf(@claude, "sys", "read", "UERG")
    assert_received {:llm_request, _url, _h, body, 600_000}
    [%{"content" => [block, _]}] = body["messages"]
    assert block["type"] == "document"
    assert block["source"]["media_type"] == "application/pdf"
    assert body["max_tokens"] == 65_536
  end

  test "no provider: error, no request" do
    assert {:error, _} = LlmClient.call_with_image(%{"llm-provider" => "none"}, "s", "u", "x", "image/jpeg")
    refute_received {:llm_request, _, _, _, _}
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle/bank_reconciliation/llm_client_test.exs`
Expected: FAIL. `call_with_image/6` is undefined.

- [ ] **Step 3: Implement**

In `llm_client.ex`:

(1) Add `@default_timeout 600_000` and `@default_max_tokens 65_536` near the top.

(2) Replace `call_with_pdf/4` with:

```elixir
  def call_with_pdf(settings, system_prompt, user_prompt, pdf_base64, opts \\ []),
    do:
      call_with_file(
        settings,
        system_prompt,
        user_prompt,
        {:pdf, "application/pdf", pdf_base64},
        opts
      )

  def call_with_image(settings, system_prompt, user_prompt, base64, media_type, opts \\ []),
    do: call_with_file(settings, system_prompt, user_prompt, {:image, media_type, base64}, opts)

  defp call_with_file(settings, system_prompt, user_prompt, file, opts) do
    provider = settings["llm-provider"] || "none"

    case @providers[provider] do
      nil ->
        {:error, "LLM provider not configured."}

      config ->
        endpoint = non_blank(settings["llm-endpoint"], config.url)
        model = non_blank(settings["llm-model"], config.model)
        api_key = settings["llm-api-key"] || ""

        request_with_file(config.format, endpoint, model, api_key, system_prompt, user_prompt, file, opts)
    end
  end
```

(3) Rename both `request_with_pdf/7` clauses to `request_with_file/8` with the extra args `file, opts` in place of `pdf_base64`:
- In the content list, replace the hard-coded document / `image_url` map with `file_block(:claude, file)` and `file_block(:openai, file)`.
- `max_tokens: 65536` → `max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)`.
- `http_post(url, headers, body)` → `http_post(url, headers, body, Keyword.get(opts, :timeout, @default_timeout))`.

Add:

```elixir
  defp file_block(:claude, {:pdf, _media_type, data}),
    do: %{type: "document", source: %{type: "base64", media_type: "application/pdf", data: data}}

  defp file_block(:claude, {:image, media_type, data}),
    do: %{type: "image", source: %{type: "base64", media_type: media_type, data: data}}

  defp file_block(:openai, {_kind, media_type, data}),
    do: %{type: "image_url", image_url: %{url: "data:#{media_type};base64,#{data}"}}
```

(4) In both `request/6` clauses, change `http_post(url, headers, body)` to `http_post(url, headers, body, @default_timeout)`.

(5) Replace `http_post/3` with:

```elixir
  # Tests swap the transport: config :full_circle, :llm_http, fn url, headers, body, timeout -> …
  defp http_post(url, headers, body, timeout) do
    case Application.get_env(:full_circle, :llm_http) do
      nil -> httpc_post(url, headers, body, timeout)
      post -> post.(url, headers, body, timeout)
    end
  end

  defp httpc_post(url, headers, body, timeout) do
    h = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    case :httpc.request(
           :post,
           {to_charlist(url), h, ~c"application/json", body},
           [{:timeout, timeout}],
           []
         ) do
      {:ok, {{_, 200, _}, _, resp}} ->
        {:ok, Jason.decode!(to_string(resp))}

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, "API error #{status}: #{to_string(resp) |> String.slice(0, 300)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/bank_reconciliation/ && mix compile --warnings-as-errors`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_reconciliation/llm_client.ex test/full_circle/bank_reconciliation/llm_client_test.exs
git add lib/full_circle/bank_reconciliation/llm_client.ex test/full_circle/bank_reconciliation/llm_client_test.exs
git commit -m "feat(llm): image input, per-call timeout and max_tokens, stubbable HTTP

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `Receipts.Extract`: file → `%Extracted{}`

**Files:**
- Create: `lib/full_circle/receipts/extracted.ex`, `lib/full_circle/receipts/extract.ex`
- Test: `test/full_circle/receipts/extract_test.exs`

**Interfaces:**
- Consumes: `LlmClient.call_with_image/6`, `LlmClient.call_with_pdf/5` (Task 3)
- Produces:
  - `%FullCircle.Receipts.Extracted{recognized: boolean, summary: String.t() | nil, supplier_name, supplier_tin, supplier_brn, supplier_sst_no, doc_no, date: Date | nil, due_date: Date | nil, lines: [%{descriptions, quantity, unit_price, discount, tax_rate (percent Decimal | nil), amount}], subtotal, tax_total, rounding, total (Decimal | nil), payment_method: String.t() | nil, e_invoice_uuid, warnings: [String.t()]}`
  - `Extract.run(path, content_type, llm_settings, opts \\ []) :: {:ok, %Extracted{}, usage} | {:error, String.t()}`
    - opts: `:today` (Date), `:timeout` (default 90_000)
  - `Extract.parse(map, today) :: %Extracted{}` (pure)
  - `Extract.decode_json(text) :: {:ok, map} | :error` (pure)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.Receipts.ExtractTest do
  use ExUnit.Case, async: false

  alias FullCircle.Receipts.{Extract, Extracted}

  @today ~D[2026-10-07]
  @settings %{"llm-provider" => "claude", "llm-api-key" => "k", "llm-endpoint" => "", "llm-model" => ""}

  @good %{
    "recognized" => true,
    "summary" => "Hardware receipt from Kedai Ali, RM 58.32",
    "supplier" => %{"name" => "Kedai Ali Hardware", "tin" => "C2345678901", "brn" => "201901012345", "sst_no" => nil},
    "doc_no" => "A12345",
    "date" => "2026-10-03",
    "due_date" => nil,
    "lines" => [
      %{"description" => "PVC PIPE 2\"", "quantity" => 4, "unit_price" => 12.5, "discount" => 0, "tax_rate_percent" => nil, "amount" => 50.0},
      %{"description" => "GLUE 500ML", "quantity" => 1, "unit_price" => "RM 4.00", "discount" => nil, "tax_rate_percent" => nil, "amount" => "4.00"}
    ],
    "subtotal" => 54.0,
    "tax_total" => 4.32,
    "rounding" => 0,
    "total" => "RM 58.32",
    "payment_method" => "cash",
    "e_invoice_uuid" => nil
  }

  defp stub(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn _url, _h, body, timeout ->
      send(test_pid, {:llm_called, Jason.decode!(body), timeout})
      text = Agent.get_and_update(agent, fn [r | rest] -> {r, rest} end)
      {:ok, %{"content" => [%{"text" => text}], "usage" => %{"input_tokens" => 100, "output_tokens" => 50}}}
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
  end

  defp tmp(ext, bytes) do
    path = Path.join(System.tmp_dir!(), "rcpt#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, bytes)
    path
  end

  describe "parse/2" do
    test "reads header, lines, totals; strips RM and commas" do
      ex = Extract.parse(@good, @today)

      assert %Extracted{recognized: true, supplier_name: "Kedai Ali Hardware", supplier_tin: "C2345678901"} = ex
      assert ex.doc_no == "A12345"
      assert ex.date == ~D[2026-10-03]
      assert ex.payment_method == "cash"
      assert Decimal.eq?(ex.total, Decimal.new("58.32"))
      assert Decimal.eq?(ex.tax_total, Decimal.new("4.32"))
      assert [pipe, glue] = ex.lines
      assert pipe.descriptions == "PVC PIPE 2\""
      assert Decimal.eq?(pipe.quantity, 4)
      assert Decimal.eq?(glue.unit_price, Decimal.new("4.00"))
      assert Decimal.eq?(glue.discount, 0)
      assert ex.warnings == []
    end

    test "DD/MM/YYYY date and 1,234.50 amounts" do
      ex = Extract.parse(%{@good | "date" => "03/10/2026", "total" => "1,234.50", "lines" => []}, @today)
      assert ex.date == ~D[2026-10-03]
      assert Decimal.eq?(ex.total, Decimal.new("1234.50"))
    end

    test "lines that do not add up to the total warn" do
      ex = Extract.parse(%{@good | "total" => 70}, @today)
      assert Enum.any?(ex.warnings, &(&1 =~ "don't add up"))
    end

    test "tax-inclusive line amounts do not warn" do
      ex = Extract.parse(%{@good | "total" => 54, "rounding" => 0}, @today)
      refute Enum.any?(ex.warnings, &(&1 =~ "don't add up"))
    end

    test "future and very old dates warn" do
      assert Enum.any?(Extract.parse(%{@good | "date" => "2026-12-01"}, @today).warnings, &(&1 =~ "future"))
      assert Enum.any?(Extract.parse(%{@good | "date" => "2025-01-01"}, @today).warnings, &(&1 =~ "year old"))
    end

    test "an unreadable value becomes nil with a warning" do
      ex = Extract.parse(%{@good | "date" => "sometime"}, @today)
      assert ex.date == nil
      assert Enum.any?(ex.warnings, &(&1 =~ "date"))
    end

    test "total but no lines: one line for the net of tax and rounding" do
      ex = Extract.parse(%{@good | "lines" => [], "rounding" => -0.02, "total" => 58.30}, @today)
      [line] = ex.lines
      assert line.descriptions == "Kedai Ali Hardware"
      assert Decimal.eq?(line.unit_price, Decimal.new("54.00"))
    end

    test "negative total warns as a refund or credit note" do
      ex = Extract.parse(%{@good | "lines" => [], "tax_total" => 0, "total" => -20}, @today)
      assert Enum.any?(ex.warnings, &(&1 =~ "refund"))
    end

    test "recognized false keeps only the summary" do
      ex = Extract.parse(%{"recognized" => false, "summary" => "Photo of a cheque from Maybank"}, @today)
      assert %Extracted{recognized: false, summary: "Photo of a cheque from Maybank", lines: [], total: nil} = ex
      assert Enum.any?(ex.warnings, &(&1 =~ "Not recognised"))
    end

    test "no total and no lines counts as not recognised" do
      ex = Extract.parse(%{"recognized" => true, "summary" => "Blurry shot", "lines" => [], "total" => nil}, @today)
      refute ex.recognized
      assert ex.summary == "Blurry shot"
    end

    test "summary is cut at 200 characters" do
      ex = Extract.parse(%{"recognized" => false, "summary" => String.duplicate("x", 300)}, @today)
      assert String.length(ex.summary) == 200
    end
  end

  describe "decode_json/1" do
    test "plain, fenced and chatty replies" do
      assert {:ok, %{"a" => 1}} = Extract.decode_json(~s({"a": 1}))
      assert {:ok, %{"a" => 1}} = Extract.decode_json("```json\n{\"a\": 1}\n```")
      assert {:ok, %{"a" => 1}} = Extract.decode_json("Here it is: {\"a\": 1} hope it helps")
      assert :error = Extract.decode_json("sorry, I cannot")
    end
  end

  describe "run/4" do
    test "image: one call with the 90 s timeout and 4096 tokens" do
      stub([Jason.encode!(@good)])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>)

      assert {:ok, %Extracted{recognized: true}, usage} = Extract.run(path, "image/jpeg", @settings, today: @today)
      assert usage.total_tokens == 150
      assert_received {:llm_called, body, 90_000}
      assert body["max_tokens"] == 4096
      [%{"content" => [%{"type" => "image"}, _]}] = body["messages"]
    end

    test "pdf goes as a document" do
      stub([Jason.encode!(@good)])
      path = tmp(".pdf", "%PDF-1.4 x")
      assert {:ok, _, _} = Extract.run(path, "application/pdf", @settings, today: @today)
      assert_received {:llm_called, body, _}
      [%{"content" => [%{"type" => "document"}, _]}] = body["messages"]
    end

    test "bad JSON retries once asking for JSON only" do
      stub(["I think this is a receipt", Jason.encode!(@good)])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF>>)
      assert {:ok, %Extracted{recognized: true}, _} = Extract.run(path, "image/jpeg", @settings, today: @today)
      assert_received {:llm_called, _, _}
      assert_received {:llm_called, second, _}
      [%{"content" => [_, %{"text" => text}]}] = second["messages"]
      assert text =~ "JSON object only"
    end

    test "bad JSON twice is an error" do
      stub(["nope", "still nope"])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF>>)
      assert {:error, msg} = Extract.run(path, "image/jpeg", @settings, today: @today)
      assert msg =~ "could not be read"
    end

    test "photo over 5 MB is refused before any call" do
      stub([])
      path = tmp(".jpg", :binary.copy(<<0>>, 5 * 1024 * 1024 + 1))
      assert {:error, msg} = Extract.run(path, "image/jpeg", @settings, today: @today)
      assert msg =~ "too large"
      refute_received {:llm_called, _, _}
    end

    test "unsupported type is refused" do
      stub([])
      assert {:error, msg} = Extract.run(tmp(".mp4", "x"), "video/mp4", @settings, today: @today)
      assert msg =~ "photos and PDFs"
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle/receipts/extract_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 3: Create `lib/full_circle/receipts/extracted.ex`**

```elixir
defmodule FullCircle.Receipts.Extracted do
  @moduledoc """
  What the AI read off a bill or receipt, already parsed and checked by
  `Receipts.Extract`. Amounts are Decimals, dates Dates, a line's `tax_rate`
  is a percent. `recognized: false` means only `summary` is meaningful.
  """
  defstruct recognized: true,
            summary: nil,
            supplier_name: nil,
            supplier_tin: nil,
            supplier_brn: nil,
            supplier_sst_no: nil,
            doc_no: nil,
            date: nil,
            due_date: nil,
            lines: [],
            subtotal: nil,
            tax_total: nil,
            rounding: nil,
            total: nil,
            payment_method: nil,
            e_invoice_uuid: nil,
            warnings: []
end
```

- [ ] **Step 4: Create `lib/full_circle/receipts/extract.ex`**

```elixir
defmodule FullCircle.Receipts.Extract do
  @moduledoc """
  A photographed bill or receipt (JPEG/PNG/WebP/PDF) → `%Extracted{}`, via the
  company's receipt AI (`Sys.llm_settings(company, :receipt)`). Knows nothing
  about forms, so a future captured-receipts inbox can call it as is. The
  model's answer is never trusted: every value is parsed here, and what does
  not parse becomes nil with a warning. Contract: `.claude/skills/receipt-capture.md`.
  """
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.BankReconciliation.LlmClient
  alias FullCircle.Receipts.Extracted

  @max_image_bytes 5 * 1024 * 1024
  @summary_max 200
  @image_types ~w(image/jpeg image/png image/webp)

  @system_prompt """
  You read photos and PDFs of Malaysian supplier bills, invoices, cash bills and
  shop receipts. Reply with ONE JSON object and nothing else:

  {"recognized": true|false,
   "summary": "one plain sentence of what the picture shows",
   "supplier": {"name": str|null, "tin": str|null, "brn": str|null, "sst_no": str|null},
   "doc_no": str|null, "date": "YYYY-MM-DD"|null, "due_date": "YYYY-MM-DD"|null,
   "lines": [{"description": str, "quantity": num|null, "unit_price": num|null,
              "discount": num|null, "tax_rate_percent": num|null, "amount": num|null}],
   "subtotal": num|null, "tax_total": num|null, "rounding": num|null, "total": num|null,
   "payment_method": "cash"|"card"|"transfer"|"cheque"|null,
   "e_invoice_uuid": str|null}

  Rules:
  - Use null for anything not printed or not legible. Never guess.
  - recognized is false when the picture is not a bill, invoice, cash bill or
    receipt (a delivery order, cheque, letter, product photo, unreadable shot).
    Then leave every other field null and lines empty.
  - summary is always set, max 200 characters, e.g. "Petrol receipt from
    Petronas Bukit Mertajam, RM 80.00" or "Blurry photo of a handwritten note".
  - Dates as YYYY-MM-DD. Printed numeric dates are Malaysian DD/MM/YYYY.
  - Amounts are plain numbers: no currency, no thousands separators.
  - One line per item row, handwritten cash-bill rows included. amount is the
    line total as printed.
  - tax_rate_percent is the line's tax percentage (6 for 6%), null if not shown
    per line. tax_total is the total SST/service tax printed.
  - rounding is the rounding adjustment (e.g. -0.02), never a line.
  - total is the final amount payable.
  - supplier is the business that issued the document, not the buyer.
    tin = Tax Identification No (e.g. C20880050010), brn = business
    registration no (e.g. 201901012345 or 123456-K), sst_no = SST registration.
  - e_invoice_uuid is the LHDN e-invoice UUID / validation id if printed.
  """

  @user_prompt "Read this document."
  @json_only "Reply with the JSON object only."

  def run(path, content_type, settings, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    llm_opts = [timeout: Keyword.get(opts, :timeout, 90_000), max_tokens: 4096]

    with {:ok, kind} <- kind(content_type),
         {:ok, bin} <- read(path, kind) do
      data = Base.encode64(bin)
      ask = fn prompt -> ask(kind, settings, prompt, data, content_type, llm_opts) end

      with {:ok, text, usage} <- ask.(@user_prompt) do
        case decode_json(text) do
          {:ok, map} -> {:ok, parse(map, today), usage}
          :error -> retry(ask, today)
        end
      end
    end
  end

  defp retry(ask, today) do
    with {:ok, text, usage} <- ask.(@user_prompt <> " " <> @json_only) do
      case decode_json(text) do
        {:ok, map} -> {:ok, parse(map, today), usage}
        :error -> {:error, gettext("The AI's answer could not be read. Try ↻ Read again.")}
      end
    end
  end

  defp kind("application/pdf"), do: {:ok, :pdf}
  defp kind(ct) when ct in @image_types, do: {:ok, :image}
  defp kind(_), do: {:error, gettext("Only photos and PDFs can be read.")}

  defp read(path, kind) do
    case File.read(path) do
      {:ok, bin} when kind == :image and byte_size(bin) > @max_image_bytes ->
        {:error, gettext("Photo too large to read (max 5 MB).")}

      {:ok, bin} ->
        {:ok, bin}

      {:error, _} ->
        {:error, gettext("Receipt file is missing.")}
    end
  end

  defp ask(:pdf, settings, prompt, data, _ct, opts),
    do: LlmClient.call_with_pdf(settings, @system_prompt, prompt, data, opts)

  defp ask(:image, settings, prompt, data, ct, opts),
    do: LlmClient.call_with_image(settings, @system_prompt, prompt, data, ct, opts)

  @doc "The first `{…}` object in a model reply (fences and chatter tolerated)."
  def decode_json(text) when is_binary(text) do
    with [json] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  def decode_json(_), do: :error

  @doc "A decoded model reply → `%Extracted{}`, with warnings for what does not hold."
  def parse(map, today) when is_map(map) do
    summary = map |> Map.get("summary") |> text() |> cut(@summary_max)
    supplier = if is_map(map["supplier"]), do: map["supplier"], else: %{}

    {fields, warnings} =
      [
        {:date, map, "date", &date/1},
        {:due_date, map, "due_date", &date/1},
        {:subtotal, map, "subtotal", &dec/1},
        {:tax_total, map, "tax_total", &dec/1},
        {:rounding, map, "rounding", &dec/1},
        {:total, map, "total", &dec/1}
      ]
      |> Enum.map_reduce([], fn {key, src, name, parser}, acc ->
        {value, warning} = field(src, name, parser)
        {{key, value}, if(warning, do: [warning | acc], else: acc)}
      end)

    f = Map.new(fields)
    lines = map |> Map.get("lines") |> List.wrap() |> Enum.flat_map(&line/1)

    if map["recognized"] == false or (is_nil(f.total) and lines == []) do
      %Extracted{
        recognized: false,
        summary: summary,
        warnings: [gettext("Not recognised as a bill or receipt.")]
      }
    else
      supplier_name = text(supplier["name"])
      lines = if lines == [] and f.total, do: [total_line(supplier_name, f)], else: lines

      %Extracted{
        recognized: true,
        summary: summary,
        supplier_name: supplier_name,
        supplier_tin: text(supplier["tin"]),
        supplier_brn: text(supplier["brn"]),
        supplier_sst_no: text(supplier["sst_no"]),
        doc_no: text(map["doc_no"]),
        date: f.date,
        due_date: f.due_date,
        lines: lines,
        subtotal: f.subtotal,
        tax_total: f.tax_total,
        rounding: f.rounding,
        total: f.total,
        payment_method: payment_method(map["payment_method"]),
        e_invoice_uuid: text(map["e_invoice_uuid"]),
        warnings:
          Enum.reverse(warnings) ++
            Enum.reject(
              [sum_warning(lines, f), date_warning(f.date, today), negative_warning(f.total)],
              &is_nil/1
            )
      }
    end
  end

  defp field(src, name, parser) do
    raw = Map.get(src, name)

    case {raw, parser.(raw)} do
      {nil, _} -> {nil, nil}
      {"", _} -> {nil, nil}
      {_, nil} -> {nil, gettext("Could not read %{field}: %{value}", field: name, value: inspect(raw))}
      {_, value} -> {value, nil}
    end
  end

  defp line(%{} = l) do
    descr = text(l["description"])
    qty = dec(l["quantity"]) || Decimal.new(1)
    discount = dec(l["discount"]) || Decimal.new(0)
    amount = dec(l["amount"])

    price =
      dec(l["unit_price"]) ||
        if(amount && not Decimal.eq?(qty, 0), do: Decimal.div(Decimal.add(amount, discount), qty))

    amount = amount || (price && Decimal.sub(Decimal.mult(qty, price), discount))

    if is_nil(descr) and is_nil(amount) do
      []
    else
      [
        %{
          descriptions: descr || "",
          quantity: qty,
          unit_price: price || Decimal.new(0),
          discount: discount,
          tax_rate: dec(l["tax_rate_percent"]),
          amount: amount || Decimal.new(0)
        }
      ]
    end
  end

  defp line(_), do: []

  defp total_line(supplier_name, f) do
    net = f.total |> Decimal.sub(f.tax_total || 0) |> Decimal.sub(f.rounding || 0)

    %{
      descriptions: supplier_name || gettext("Receipt"),
      quantity: Decimal.new(1),
      unit_price: net,
      discount: Decimal.new(0),
      tax_rate: nil,
      amount: net
    }
  end

  # Lines may be printed before tax (SST added below) or tax-inclusive; either
  # adding up to the total is fine.
  defp sum_warning(_lines, %{total: nil}), do: nil

  defp sum_warning(lines, f) do
    sum = Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))
    rounding = f.rounding || Decimal.new(0)
    without_tax = Decimal.add(sum, rounding)
    with_tax = Decimal.add(without_tax, f.tax_total || 0)

    if close?(with_tax, f.total) or close?(without_tax, f.total) do
      nil
    else
      gettext("Receipt lines don't add up: lines %{lines} + tax %{tax} + rounding %{r} ≠ total %{total}.",
        lines: sum,
        tax: f.tax_total || 0,
        r: rounding,
        total: f.total
      )
    end
  end

  defp close?(a, b), do: Decimal.lt?(Decimal.abs(Decimal.sub(a, b)), Decimal.new("0.01"))

  defp date_warning(nil, _today), do: nil

  defp date_warning(date, today) do
    cond do
      Date.compare(date, today) == :gt ->
        gettext("Receipt date %{d} is in the future.", d: date)

      Date.diff(today, date) > 365 ->
        gettext("Receipt date %{d} is more than a year old.", d: date)

      true ->
        nil
    end
  end

  defp negative_warning(nil), do: nil

  defp negative_warning(total) do
    if Decimal.negative?(total),
      do: gettext("Total is negative — this looks like a refund or credit note."),
      else: nil
  end

  # --- value parsers: nil when not readable ---

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)

  defp dec(s) when is_binary(s) do
    case s |> String.replace(~r/[^0-9.\-]/, "") |> Decimal.parse() do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp dec(_), do: nil

  defp date(s) when is_binary(s) do
    s = String.trim(s)

    case Date.from_iso8601(s) do
      {:ok, d} ->
        d

      _ ->
        with [_, dd, mm, yyyy] <- Regex.run(~r/^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{4})$/, s),
             {:ok, d} <- Date.new(String.to_integer(yyyy), String.to_integer(mm), String.to_integer(dd)) do
          d
        else
          _ -> nil
        end
    end
  end

  defp date(_), do: nil

  defp payment_method(m) when m in ~w(cash card transfer cheque), do: m
  defp payment_method(_), do: nil

  defp text(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp text(_), do: nil

  defp cut(nil, _max), do: nil
  defp cut(s, max), do: String.slice(s, 0, max)
end
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix test test/full_circle/receipts/extract_test.exs`
Expected: 0 failures. If "tax-inclusive line amounts do not warn" fails, check that `sum_warning` accepts `without_tax`. Do not loosen the other assertions.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/receipts/extracted.ex lib/full_circle/receipts/extract.ex test/full_circle/receipts/extract_test.exs
git add lib/full_circle/receipts test/full_circle/receipts/extract_test.exs
git commit -m "feat(receipts): AI extraction of bills and receipts with checked output

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `Receipts.Prefill`: `%Extracted{}` → form attrs and warnings

**Files:**
- Create: `lib/full_circle/receipts/prefill.ex`
- Test: `test/full_circle/receipts/prefill_test.exs`

**Interfaces:**
- Consumes: `DocPrefill.seed_lines/1`, `put_contact/7`, `put_goods/5` (Task 2); `%Extracted{}` (Task 4)
- Produces:
  - `Receipts.Prefill.build(%Extracted{}, com, user, :payment_details | :pur_invoice_details) :: %{attrs: map (atom keys; details string-keyed), warnings: [String.t()], contact_ids: {tin, brn}, total: Decimal | nil}`
  - `Receipts.Prefill.duplicate_warning(attrs_or_params, :payment_details | :pur_invoice_details, com) :: String.t() | nil`
    - Accepts atom- or string-keyed maps. Reads `contact_id` plus `e_inv_internal_id` (PurInvoice) or `payment_date` + `funds_amount` (Payment).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.Receipts.PrefillTest do
  use FullCircle.DataCase, async: true

  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.AccountingFixtures
  import Ecto.Query

  alias FullCircle.{Accounting, Billing, BillPay, Repo, Sys}
  alias FullCircle.Accounting.TaxCode
  alias FullCircle.Receipts.{Extracted, Prefill}

  setup do
    %{admin: u, company: c} = billing_setup()
    %{u: u, c: c}
  end

  defp ex(attrs \\ %{}) do
    struct!(
      %Extracted{
        supplier_name: "Kedai Ali Hardware",
        supplier_tin: "C2345678901",
        doc_no: "A12345",
        date: Date.utc_today(),
        payment_method: "cash",
        total: Decimal.new("54.00"),
        tax_total: nil,
        rounding: nil,
        lines: [
          %{descriptions: "PVC PIPE", quantity: Decimal.new(4), unit_price: Decimal.new("12.50"), discount: Decimal.new(0), tax_rate: nil, amount: Decimal.new("50.00")},
          %{descriptions: "GLUE", quantity: Decimal.new(1), unit_price: Decimal.new("4.00"), discount: Decimal.new(0), tax_rate: Decimal.new("8"), amount: Decimal.new("4.00")}
        ]
      },
      attrs
    )
  end

  defp no_ptax(c), do: Repo.one!(from tc in TaxCode, where: tc.company_id == ^c.id and tc.code == "NoPTax")

  test "payment header: date, funds amount, shop + doc no in descriptions", %{c: c, u: u} do
    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.payment_date == Date.utc_today()
    assert Decimal.eq?(seed.attrs.funds_amount, Decimal.new("54.00"))
    assert seed.attrs.descriptions == "Kedai Ali Hardware #A12345"
    assert length(seed.attrs.payment_details) == 2
    assert seed.contact_ids == {"C2345678901", nil}
  end

  test "pur invoice header: supplier bill no into e_inv_internal_id, never pur_invoice_no", %{c: c, u: u} do
    seed = Prefill.build(ex(), c, u, :pur_invoice_details)
    assert seed.attrs.e_inv_internal_id == "A12345"
    refute Map.has_key?(seed.attrs, :pur_invoice_no)
    assert seed.attrs.pur_invoice_date == Date.utc_today()
    assert seed.attrs.due_date == Date.utc_today()
  end

  test "lines: percent tax becomes a fraction, multiplier 0", %{c: c, u: u} do
    [_pipe, glue] = Prefill.build(ex(), c, u, :payment_details).attrs.payment_details
    assert Decimal.eq?(glue["tax_rate"], Decimal.new("0.08"))
    assert glue["unit_multiplier"] == 0
  end

  test "contact by TIN, no contact warning", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"name" => "Kedai Ali Hdw", "tax_id" => "C2345678901"})
    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.contact_id == contact.id
    refute Enum.any?(seed.warnings, &(&1 =~ "Supplier"))
  end

  test "unknown supplier: blank contact with a warning", %{c: c, u: u} do
    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.contact_id == nil
    assert Enum.any?(seed.warnings, &(&1 =~ "not found"))
  end

  test "SST printed only as a total becomes its own line; rounding too", %{c: c, u: u} do
    lines = [hd(ex().lines)]

    seed =
      Prefill.build(ex(%{lines: lines, tax_total: Decimal.new("4.00"), rounding: Decimal.new("-0.02"), total: Decimal.new("53.98")}), c, u, :payment_details)

    descrs = Enum.map(seed.attrs.payment_details, & &1["descriptions"])
    assert descrs == ["PVC PIPE", "SST", "Rounding adj."]
    [_, sst, rnd] = seed.attrs.payment_details
    assert Decimal.eq?(sst["unit_price"], Decimal.new("4.00"))
    assert sst["good_name"] == ""
    assert Decimal.eq?(rnd["unit_price"], Decimal.new("-0.02"))
  end

  test "no SST line when a line already carries a tax rate", %{c: c, u: u} do
    seed = Prefill.build(ex(%{tax_total: Decimal.new("0.32")}), c, u, :payment_details)
    refute Enum.any?(seed.attrs.payment_details, &(&1["descriptions"] == "SST"))
  end

  test "funds account: sole account first, then Cash In Hand for cash, else none", %{c: c, u: u} do
    cash = account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)

    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.funds_account_id == cash.id

    seed = Prefill.build(ex(%{payment_method: "card"}), c, u, :payment_details)
    refute Map.get(seed.attrs, :funds_account_id)

    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    bank = pay_funds_account_fixture(c, u)
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)
    {:ok, _} = BillPay.create_payment(payment_attrs(contact, good, pur_acct, no_ptax(c), bank, tax_rate: "0"), c, u)

    seed = Prefill.build(ex(), c, u, :payment_details)
    assert seed.attrs.funds_account_id == bank.id
  end

  test "possible duplicate pur invoice: same contact and supplier bill no", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)
    attrs = pur_invoice_attrs(contact, good, pur_acct, no_ptax(c), tax_rate: "0") |> Map.put("e_inv_internal_id", "A12345")
    {:ok, %{create_pur_invoice: pinv}} = Billing.create_pur_invoice(attrs, c, u)

    seed = Prefill.build(ex(), c, u, :pur_invoice_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "Possible duplicate" and &1 =~ pinv.pur_invoice_no))
  end

  test "possible duplicate payment: same contact, date and amount", %{c: c, u: u} do
    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    bank = pay_funds_account_fixture(c, u)
    good = good_fixture(c, u)
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

    {:ok, %{create_payment: pv}} =
      BillPay.create_payment(
        payment_attrs(contact, good, pur_acct, no_ptax(c), bank, tax_rate: "0", quantity: "1", unit_price: "54.00", funds_amount: "54.00"),
        c,
        u
      )

    seed = Prefill.build(ex(), c, u, :payment_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "Possible duplicate" and &1 =~ pv.payment_no))

    assert Prefill.duplicate_warning(%{"contact_id" => contact.id, "payment_date" => Date.to_iso8601(Date.utc_today()), "funds_amount" => "54.00"}, :payment_details, c)
    refute Prefill.duplicate_warning(%{"contact_id" => nil, "payment_date" => "", "funds_amount" => ""}, :payment_details, c)
  end

  test "date in a closed period warns", %{c: c, u: u} do
    yesterday = Date.add(Date.utc_today(), -1)
    {:ok, _} = Sys.close_period_through(c, yesterday, u)
    seed = Prefill.build(ex(%{date: Date.add(yesterday, -3)}), c, u, :payment_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "closed accounting period"))
  end

  test "printed e-invoice uuid that we have synced warns", %{c: c, u: u} do
    Repo.insert_all("e_invoices", [%{id: Ecto.UUID.bingenerate(), uuid: "ABC123UUID", company_id: Ecto.UUID.dump!(c.id), inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}])
    seed = Prefill.build(ex(%{e_invoice_uuid: "ABC123UUID"}), c, u, :pur_invoice_details)
    assert Enum.any?(seed.warnings, &(&1 =~ "has an e-invoice"))
  end

  test "not recognised: only descriptions from the summary", %{c: c, u: u} do
    seed = Prefill.build(%Extracted{recognized: false, summary: "Photo of a cheque", warnings: ["Not recognised as a bill or receipt."]}, c, u, :payment_details)
    assert seed.attrs == %{descriptions: "Photo of a cheque"}
    assert seed.warnings == ["Not recognised as a bill or receipt."]
    assert seed.total == nil
  end
end
```

Before running, open `priv/repo/migrations/*create_e_invoices*` (`ls priv/repo/migrations | grep -i e_inv`) and check the `e_invoices` NOT NULL columns. If the `insert_all` above misses a required column, add it to that map. Keep the test's intent unchanged: a row with this `uuid` for this company.

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle/receipts/prefill_test.exs`
Expected: FAIL (`Receipts.Prefill` is undefined).

- [ ] **Step 3: Create `lib/full_circle/receipts/prefill.ex`**

```elixir
defmodule FullCircle.Receipts.Prefill do
  @moduledoc """
  `%Extracted{}` → attrs for a new Payment or PurInvoice, plus advisory
  warnings. Contact and goods follow `DocPrefill` (identifiers first, goods
  only when safe). Nothing here blocks a save. Contract:
  `.claude/skills/receipt-capture.md`.
  """
  import Ecto.Query, warn: false
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.{Accounting, BillPay, DocPrefill, Repo, Sys}
  alias FullCircle.Billing.PurInvoice
  alias FullCircle.BillPay.Payment
  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Receipts.Extracted

  @descriptions_max 200
  @cash_account "Cash In Hand"

  def build(%Extracted{recognized: false} = ex, _com, _user, _detail_key) do
    %{
      attrs: %{descriptions: String.slice(ex.summary || "", 0, @descriptions_max)},
      warnings: ex.warnings,
      contact_ids: {nil, nil},
      total: nil
    }
  end

  def build(%Extracted{} = ex, com, user, detail_key) do
    {attrs, contact_warning} =
      %{detail_key => DocPrefill.seed_lines(ex.lines ++ extra_lines(ex))}
      |> Map.merge(header(ex, detail_key))
      |> DocPrefill.put_contact(ex.supplier_tin, ex.supplier_brn, ex.supplier_name, com, :supplier,
        source: gettext("Receipt")
      )

    attrs =
      attrs
      |> DocPrefill.put_goods(detail_key, com, user, :purchase)
      |> put_funds_account(ex, detail_key, com, user)

    warnings =
      (ex.warnings ++
         [
           contact_warning,
           duplicate_warning(attrs, detail_key, com),
           period_warning(ex.date, com),
           e_invoice_warning(ex.e_invoice_uuid, com)
         ])
      |> Enum.reject(&is_nil/1)

    %{
      attrs: attrs,
      warnings: warnings,
      contact_ids: {ex.supplier_tin, ex.supplier_brn},
      total: ex.total
    }
  end

  defp header(ex, :payment_details) do
    %{payment_date: ex.date, funds_amount: ex.total, descriptions: payment_descriptions(ex)}
  end

  defp header(ex, :pur_invoice_details) do
    # e_inv_internal_id is the supplier's own bill number; pur_invoice_no is
    # our gapless PINV number and is never seeded.
    %{pur_invoice_date: ex.date, due_date: ex.due_date || ex.date, e_inv_internal_id: ex.doc_no}
  end

  defp payment_descriptions(ex) do
    [ex.supplier_name, ex.doc_no && "#" <> ex.doc_no]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      s -> String.slice(s, 0, @descriptions_max)
    end
  end

  # This company books SST as its own line; a rounding adjustment needs its
  # own account. Both leave the good blank for the clerk.
  defp extra_lines(ex) do
    sst =
      if positive?(ex.tax_total) and Enum.all?(ex.lines, &(is_nil(&1.tax_rate) or Decimal.eq?(&1.tax_rate, 0))),
        do: [extra_line(gettext("SST"), ex.tax_total)],
        else: []

    rounding =
      if ex.rounding && not Decimal.eq?(ex.rounding, 0),
        do: [extra_line(gettext("Rounding adj."), ex.rounding)],
        else: []

    sst ++ rounding
  end

  defp extra_line(descr, amount),
    do: %{descriptions: descr, quantity: Decimal.new(1), unit_price: amount, discount: Decimal.new(0), tax_rate: nil, amount: amount}

  defp positive?(%Decimal{} = d), do: Decimal.gt?(d, 0)
  defp positive?(_), do: false

  # Sole funds account (98.7% right on history), else Cash In Hand for a cash
  # receipt, else blank.
  defp put_funds_account(attrs, ex, :payment_details, com, user) do
    name =
      (attrs[:contact_id] && BillPay.sole_funds_account_name(attrs.contact_id, com)) ||
        if(ex.payment_method == "cash", do: @cash_account)

    case name && Accounting.get_account_by_name(name, com, user) do
      nil -> attrs
      account -> Map.merge(attrs, %{funds_account_name: account.name, funds_account_id: account.id})
    end
  end

  defp put_funds_account(attrs, _ex, _detail_key, _com, _user), do: attrs

  @doc "A possible-duplicate warning for these (seed attrs or form params), or nil."
  def duplicate_warning(attrs, :pur_invoice_details, com) do
    with contact_id when contact_id not in [nil, ""] <- get(attrs, :contact_id),
         doc_no when doc_no not in [nil, ""] <- get(attrs, :e_inv_internal_id),
         no when not is_nil(no) <-
           Repo.one(
             from p in PurInvoice,
               where: p.company_id == ^com.id and p.contact_id == ^contact_id and p.e_inv_internal_id == ^doc_no,
               select: p.pur_invoice_no,
               limit: 1
           ) do
      gettext("Possible duplicate: %{doc} has the same supplier and bill no.", doc: no)
    else
      _ -> nil
    end
  end

  def duplicate_warning(attrs, :payment_details, com) do
    with contact_id when contact_id not in [nil, ""] <- get(attrs, :contact_id),
         %Date{} = date <- to_date(get(attrs, :payment_date)),
         %Decimal{} = amount <- DocPrefill.to_decimal(get(attrs, :funds_amount)),
         no when not is_nil(no) <-
           Repo.one(
             from p in Payment,
               where:
                 p.company_id == ^com.id and p.contact_id == ^contact_id and
                   p.payment_date == ^date and p.funds_amount == ^amount,
               select: p.payment_no,
               limit: 1
           ) do
      gettext("Possible duplicate: %{doc} has the same supplier, date and amount.", doc: no)
    else
      _ -> nil
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp to_date(%Date{} = d), do: d

  defp to_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp to_date(_), do: nil

  defp period_warning(nil, _com), do: nil

  defp period_warning(date, com) do
    case Sys.period_closed_through(com) do
      %Date{} = closed ->
        if Date.compare(date, closed) != :gt,
          do: gettext("Date %{d} is in a closed accounting period (closed through %{c}).", d: date, c: closed),
          else: nil

      _ ->
        nil
    end
  end

  defp e_invoice_warning(nil, _com), do: nil

  defp e_invoice_warning(uuid, com) do
    if Repo.exists?(from e in EInvoice, where: e.company_id == ^com.id and e.uuid == ^uuid),
      do: gettext("This bill has an e-invoice (%{uuid}). Create it from the E-Invoice list instead.", uuid: uuid),
      else: nil
  end
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle/receipts/`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/receipts/prefill.ex test/full_circle/receipts/prefill_test.exs
git add lib/full_circle/receipts/prefill.ex test/full_circle/receipts/prefill_test.exs
git commit -m "feat(receipts): map a read receipt onto Payment/PurInvoice with warnings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `create_payment` extend hook + `ReceiptCapture` core (merge and attach)

**Files:**
- Modify: `lib/full_circle/bill_pay.ex` (`create_payment/3` ~line 319)
- Create: `lib/full_circle_web/receipt_capture.ex` (core functions in this task; the component and socket glue come in Task 7)
- Test: `test/full_circle/bill_pay_test.exs` (add one test), `test/full_circle_web/receipt_capture_test.exs` (create)

**Interfaces:**
- Produces:
  - `BillPay.create_payment(attrs, com, user, extend_multi \\ &Function.identity/1)`
  - `FullCircleWeb.ReceiptCapture.merge_params(current_params :: map, seed_attrs :: map, detail_key :: atom) :: map` (string-keyed result)
  - `FullCircleWeb.ReceiptCapture.attach_multi(tray_id, doc_type :: "Payment" | "PurInvoice", doc_key :: :create_payment | :create_pur_invoice, com, user) :: (Ecto.Multi.t() -> Ecto.Multi.t())`
  - `FullCircleWeb.ReceiptCapture.attach_blocked?(tray_id, com, user) :: boolean` (the tray has files but the user lacks `:create_note`)

- [ ] **Step 1: Write the failing tests**

Add to `test/full_circle/bill_pay_test.exs`, inside its top-level module. Reuse that file's existing setup; if it has none that fits, put this in its own `describe` with the setup shown:

```elixir
  describe "create_payment/4 extend_multi" do
    setup do
      %{admin: u, company: c} = FullCircle.BillingFixtures.billing_setup()
      %{u: u, c: c}
    end

    test "runs the extension inside the same transaction", %{u: u, c: c} do
      import FullCircle.BillingFixtures
      import FullCircle.BillPayFixtures

      contact = contact_fixture(c, u)
      good = good_fixture(c, u)
      pur_acct = FullCircle.Accounting.get_account_by_name("General Purchases", c, u)
      tc = FullCircle.Repo.one!(Ecto.Query.from(t in FullCircle.Accounting.TaxCode, where: t.company_id == ^c.id and t.code == "NoPTax"))
      attrs = payment_attrs(contact, good, pur_acct, tc, pay_funds_account_fixture(c, u), tax_rate: "0")

      ext = fn multi -> Ecto.Multi.run(multi, :boom, fn _repo, %{create_payment: p} -> {:error, p.payment_no} end) end

      assert {:error, :boom, _no, _} = FullCircle.BillPay.create_payment(attrs, c, u, ext)
      assert FullCircle.Repo.aggregate(FullCircle.BillPay.Payment, :count) == 0
    end
  end
```

Create `test/full_circle_web/receipt_capture_test.exs`:

```elixir
defmodule FullCircleWeb.ReceiptCaptureTest do
  use FullCircle.DataCase, async: true

  import FullCircle.BillingFixtures
  import FullCircle.BillPayFixtures
  import FullCircle.NotesFixtures
  import Ecto.Query

  alias FullCircle.{Accounting, BillPay, Repo}
  alias FullCircle.Notes.{Attachments, Note, Trays}
  alias FullCircleWeb.ReceiptCapture

  describe "merge_params/3" do
    @seed %{
      contact_name: "Kedai Ali",
      contact_id: "c-1",
      tax_id: "C1",
      reg_no: nil,
      payment_date: ~D[2026-10-03],
      funds_amount: Decimal.new("54.00"),
      descriptions: "Kedai Ali #A1",
      payment_details: [%{"descriptions" => "PVC", "quantity" => 4, "_persistent_id" => 0}]
    }

    test "fills blanks, keyed values win, zero counts as blank" do
      current = %{"payment_no" => "...new...", "descriptions" => "my words", "funds_amount" => "0", "payment_date" => ""}
      merged = ReceiptCapture.merge_params(current, @seed, :payment_details)

      assert merged["descriptions"] == "my words"
      assert merged["payment_no"] == "...new..."
      assert merged["payment_date"] == ~D[2026-10-03]
      assert Decimal.eq?(merged["funds_amount"], Decimal.new("54.00"))
      assert merged["payment_details"] == %{"0" => %{"descriptions" => "PVC", "quantity" => 4, "_persistent_id" => 0}}
    end

    test "a contact the clerk picked is kept whole — never half-merged" do
      current = %{"contact_name" => "Mine Sdn Bhd", "contact_id" => "", "tax_id" => ""}
      merged = ReceiptCapture.merge_params(current, @seed, :payment_details)
      assert merged["contact_name"] == "Mine Sdn Bhd"
      assert merged["contact_id"] == ""
      assert merged["tax_id"] == ""
    end

    test "keyed lines are kept; blank lines are replaced" do
      keyed = %{"payment_details" => %{"0" => %{"good_name" => "Glue", "quantity" => "1", "unit_price" => "4"}}}
      assert ReceiptCapture.merge_params(keyed, @seed, :payment_details)["payment_details"] == keyed["payment_details"]

      blank = %{"payment_details" => %{"0" => %{"good_name" => "", "quantity" => "0", "unit_price" => "0"}}}
      assert %{"0" => %{"descriptions" => "PVC"}} = ReceiptCapture.merge_params(blank, @seed, :payment_details)["payment_details"]
    end
  end

  describe "attach_multi/5" do
    setup do
      %{admin: u, company: c} = billing_setup()
      contact = contact_fixture(c, u)
      good = good_fixture(c, u)
      pur_acct = Accounting.get_account_by_name("General Purchases", c, u)
      tc = Repo.one!(from t in FullCircle.Accounting.TaxCode, where: t.company_id == ^c.id and t.code == "NoPTax")
      attrs = payment_attrs(contact, good, pur_acct, tc, pay_funds_account_fixture(c, u), tax_rate: "0")
      %{u: u, c: c, attrs: attrs}
    end

    test "a tray with files becomes a 🧾 Receipt note on the new payment", %{u: u, c: c, attrs: attrs} do
      tray = tray_fixture(c, u)
      {:ok, _} = Attachments.attach_to_tray(tray.id, %{path: real_jpeg_file(:rgb), file_name: "r.jpg"}, c, u)

      {:ok, %{create_payment: pv}} =
        BillPay.create_payment(attrs, c, u, ReceiptCapture.attach_multi(tray.id, "Payment", :create_payment, c, u))

      note = Repo.one!(from n in Note, where: n.subject_type == "Payment" and n.subject_id == ^pv.id, preload: :attachments)
      assert note.title == "🧾 Receipt"
      assert note.visibility == nil
      assert [%{file_name: "r.jpg"}] = note.attachments
      refute Trays.has_files?(tray.id, c, u)
    end

    test "an empty tray adds nothing", %{u: u, c: c, attrs: attrs} do
      {:ok, _} = BillPay.create_payment(attrs, c, u, ReceiptCapture.attach_multi(Ecto.UUID.generate(), "Payment", :create_payment, c, u))
      assert Repo.aggregate(Note, :count) == 0
    end

    test "a user without :create_note: payment saves, receipt not attached", %{u: u, c: c, attrs: attrs} do
      guest = user_with_role(c, u, "guest")
      tray = tray_fixture(c, guest)
      {:ok, _} = Attachments.attach_to_tray(tray.id, %{path: real_jpeg_file(:rgb), file_name: "r.jpg"}, c, guest)
      assert ReceiptCapture.attach_blocked?(tray.id, c, guest)
      assert ReceiptCapture.attach_multi(tray.id, "Payment", :create_payment, c, guest).(Ecto.Multi.new()) == Ecto.Multi.new()
    end
  end
end
```

(Guests cannot open trays if `Trays.open` checks roles. If `tray_fixture(c, guest)` fails, use the `"auditor"` role, which reads notes but cannot create them; see `Authorization.can?(:create_note)`. Then check `attach_blocked?` is true for that user.)

- [ ] **Step 2: Run them and confirm they fail**

Run: `mix test test/full_circle/bill_pay_test.exs test/full_circle_web/receipt_capture_test.exs`
Expected: FAIL (`create_payment/4` and `ReceiptCapture` are undefined).

- [ ] **Step 3: Add the hook to `create_payment`**

In `lib/full_circle/bill_pay.ex`:

```elixir
  @doc """
  `extend_multi` lets a caller append steps that need the created Payment —
  e.g. attaching a captured receipt as a note (`FullCircleWeb.ReceiptCapture`).
  """
  def create_payment(attrs, com, user, extend_multi \\ &Function.identity/1) do
    case can?(user, :create_payment, com) do
      true ->
        Multi.new()
        |> create_payment_multi(attrs, com, user)
        |> extend_multi.()
        |> Repo.transaction()
        |> Accounting.map_period_closed()

      false ->
        :not_authorise
    end
  end
```

- [ ] **Step 4: Create `lib/full_circle_web/receipt_capture.ex` (core part)**

```elixir
defmodule FullCircleWeb.ReceiptCapture do
  @moduledoc """
  Receipt capture on New Payment / New Purchase Invoice. The form owns a note
  tray filled from the phone (📱) or desktop (📎); the first file is read by
  `Receipts.Extract` and seeds the form's *empty* fields through
  `Receipts.Prefill`; Save attaches the tray as a 🧾 Receipt note on the new
  document inside the same transaction. Contract:
  `.claude/skills/receipt-capture.md`.
  """
  use FullCircleWeb, :html

  alias Ecto.Multi
  alias FullCircle.Notes
  alias FullCircle.Notes.Trays

  # Fields filled together or not at all: half a contact (a name the clerk
  # typed with the receipt's id) would save the wrong party.
  @groups [
    ~w(contact_name contact_id tax_id reg_no),
    ~w(funds_account_name funds_account_id)
  ]

  @doc """
  `seed_attrs` laid under `current` form params: a field is filled only when
  blank there (nil, "", or a zero amount), a group only when its first field
  is blank, and lines only when no current line has a good, quantity or price.
  """
  def merge_params(current, seed_attrs, detail_key) do
    seed = Map.new(seed_attrs, fn {k, v} -> {to_string(k), v} end)
    lines_key = to_string(detail_key)
    grouped = List.flatten(@groups)

    merged =
      Enum.reduce(@groups, current, fn [lead | _] = group, acc ->
        if blank?(acc[lead]) and Map.has_key?(seed, lead),
          do: Map.merge(acc, Map.take(seed, group)),
          else: acc
      end)

    merged =
      seed
      |> Map.drop([lines_key | grouped])
      |> Enum.reduce(merged, fn {k, v}, acc ->
        if blank?(acc[k]), do: Map.put(acc, k, v), else: acc
      end)

    if lines_blank?(current[lines_key]) and is_list(seed[lines_key]) do
      lines =
        seed[lines_key]
        |> Enum.with_index()
        |> Map.new(fn {line, i} -> {to_string(i), line} end)

      Map.put(merged, lines_key, lines)
    else
      merged
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(%Decimal{} = d), do: Decimal.eq?(d, 0)

  defp blank?(s) when is_binary(s) do
    case Decimal.parse(String.trim(s)) do
      {d, ""} -> Decimal.eq?(d, 0)
      _ -> false
    end
  end

  defp blank?(_), do: false

  defp lines_blank?(nil), do: true
  defp lines_blank?(lines) when is_map(lines), do: lines_blank?(Map.values(lines))

  defp lines_blank?(lines) when is_list(lines) do
    Enum.all?(lines, fn line ->
      blank?(line["good_name"]) and blank?(line["quantity"]) and blank?(line["unit_price"])
    end)
  end

  @doc "Appends the 🧾 Receipt note step when the tray has files and the user may write notes."
  def attach_multi(tray_id, doc_type, doc_key, com, user) do
    if Trays.has_files?(tray_id, com, user) and can_note?(com, user) do
      fn multi ->
        Multi.run(multi, :receipt_note, fn _repo, changes ->
          doc = Map.fetch!(changes, doc_key)

          %{
            "subject_type" => doc_type,
            "subject_id" => doc.id,
            "title" => "🧾 " <> gettext("Receipt"),
            "tray_id" => tray_id
          }
          |> Notes.create_note(com, user)
          |> case do
            {:ok, note} -> {:ok, note}
            :not_authorise -> {:error, :not_authorise}
            {:error, reason} -> {:error, reason}
          end
        end)
      end
    else
      &Function.identity/1
    end
  end

  @doc "True when the tray holds files that this user cannot attach as a note."
  def attach_blocked?(tray_id, com, user),
    do: Trays.has_files?(tray_id, com, user) and not can_note?(com, user)

  defp can_note?(com, user), do: FullCircle.Authorization.can?(user, :create_note, com)
end
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix test test/full_circle/bill_pay_test.exs test/full_circle_web/receipt_capture_test.exs`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle/bill_pay.ex lib/full_circle_web/receipt_capture.ex test/full_circle/bill_pay_test.exs test/full_circle_web/receipt_capture_test.exs
git add lib/full_circle/bill_pay.ex lib/full_circle_web/receipt_capture.ex test/full_circle/bill_pay_test.exs test/full_circle_web/receipt_capture_test.exs
git commit -m "feat(receipts): blank-only form merge and receipt note on save

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Payment form: capture, read, fill, save with receipt

**Files:**
- Modify: `lib/full_circle_web/receipt_capture.ex` (socket glue + component)
- Modify: `lib/full_circle_web/live/payment_live/form.ex`
- Test: `test/full_circle_web/live/payment_receipt_capture_live_test.exs` (create)

**Interfaces:**
- Consumes: Tasks 1–6 (`Sys.llm_settings/2`, `Extract.run/4`, `Prefill.build/4`, `Prefill.duplicate_warning/3`, `merge_params/3`, `attach_multi/5`, `attach_blocked?/3`, `BillPay.create_payment/4`)
- Produces, in `FullCircleWeb.ReceiptCapture`:
  - `init(socket) :: socket`. Assigns `receipt_tray_id, receipt_files, receipt_state (:idle | :reading | :done | :error | :off), receipt, receipt_usage, receipt_error, receipt_settings, receipt_contact_ids`.
  - `files_changed(socket, detail_key) :: socket`
  - `read(socket, attachment_id | nil, detail_key) :: socket` (nil = first file)
  - `finished(socket, async_result) :: {socket, seed | nil}`
  - `recheck_duplicate(socket, params, detail_key) :: socket`
  - `discard_file(socket, att_id, detail_key) :: socket`
  - Component `receipt_capture/1`. Attrs: `id`, `tray_id`, `files`, `state`, `receipt`, `usage`, `error`, `keyed_total` (Decimal), `label` (phone page label), `current_company`, `current_user`.

- [ ] **Step 1: Write the failing LiveView test**

```elixir
defmodule FullCircleWeb.PaymentReceiptCaptureLiveTest do
  use FullCircleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.AccountingFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.{Accounting, Billing, Repo, Sys}
  alias FullCircle.Notes.{Attachments, Note, Trays}

  @reply %{
    "recognized" => true,
    "summary" => "Hardware receipt",
    "supplier" => %{"name" => "Kedai Ali Hardware", "tin" => "C2345678901"},
    "doc_no" => "A12345",
    "date" => Date.to_iso8601(Date.utc_today()),
    "lines" => [%{"description" => "PVC PIPE", "quantity" => 4, "unit_price" => 12.5, "amount" => 50}],
    "tax_total" => nil,
    "rounding" => nil,
    "total" => 50,
    "payment_method" => "cash"
  }

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    {:ok, company} = Sys.update_company_settings(company, "llm_receipt", %{"llm-provider" => "claude", "llm-api-key" => "k"})
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp stub(reply) do
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn _u, _h, _b, _t ->
      send(test_pid, :llm_called)
      {:ok, %{"content" => [%{"text" => Jason.encode!(reply)}], "usage" => %{"input_tokens" => 1, "output_tokens" => 1}}}
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
  end

  defp tray_id(lv) do
    [_, id] = Regex.run(~r/id="receipt-box"[^>]*data-tray-id="([^"]+)"/, render(lv))
    id
  end

  defp drop_photo(lv, company, user) do
    id = tray_id(lv)
    {:ok, _} = Trays.open(id, company, user)
    {:ok, _} = Attachments.attach_to_tray(id, %{path: real_jpeg_file(:rgb), file_name: "r.jpg"}, company, user)
    render(lv)
    render_async(lv)
  end

  defp value(lv, id), do: lv |> element("##{id}") |> render() |> then(&Regex.run(~r/value="([^"]*)"/, &1)) |> List.last()

  test "a photo is read and fills the empty fields", %{conn: conn, user: u, company: c} do
    stub(@reply)
    contact = contact_fixture(c, u, %{"name" => "Kedai Ali Hdw", "tax_id" => "C2345678901"})
    cash = account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")

    html = drop_photo(lv, c, u)

    assert html =~ "Kedai Ali Hardware"
    assert value(lv, "payment_contact_id") == contact.id
    assert value(lv, "payment_funds_account_id") == cash.id
    assert value(lv, "payment_funds_amount") =~ "50"
    assert value(lv, "payment_descriptions") == "Kedai Ali Hardware #A12345"
    assert html =~ "PVC PIPE"
  end

  test "typed values survive; a second file does not re-read", %{conn: conn, user: u, company: c} do
    stub(@reply)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    lv |> form("#object-form", payment: %{"descriptions" => "petty cash Oct"}) |> render_change()

    drop_photo(lv, c, u)
    assert value(lv, "payment_descriptions") == "petty cash Oct"
    assert_received :llm_called

    {:ok, _} = Attachments.attach_to_tray(tray_id(lv), %{path: real_jpeg_file(:gray), file_name: "b.jpg"}, c, u)
    render(lv)
    render_async(lv)
    refute_received :llm_called
  end

  test "↻ Read again keeps keyed lines", %{conn: conn, user: u, company: c} do
    stub(@reply)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    drop_photo(lv, c, u)
    lv |> form("#object-form", payment: %{"payment_details" => %{"0" => %{"descriptions" => "EDITED", "quantity" => "4", "unit_price" => "12.5"}}}) |> render_change()

    lv |> element("#receipt-read-again") |> render_click()
    html = render_async(lv)
    assert html =~ "EDITED"
  end

  test "not recognised: summary into descriptions", %{conn: conn, user: u, company: c} do
    stub(%{"recognized" => false, "summary" => "Photo of a cheque"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    html = drop_photo(lv, c, u)
    assert value(lv, "payment_descriptions") == "Photo of a cheque"
    assert html =~ "Not recognised"
  end

  test "AI off: the file still attaches, strip says so", %{conn: conn, user: u, company: c} do
    {:ok, _} = Sys.update_company_settings(c, "llm_receipt", %{"llm-provider" => "none"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    html = drop_photo(lv, c, u)
    assert html =~ "AI reading off"
    assert html =~ "r.jpg"
  end

  test "save attaches the receipt as a note on the payment", %{conn: conn, user: u, company: c} do
    stub(@reply)
    contact = contact_fixture(c, u, %{"tax_id" => "C2345678901"})
    account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)
    good = good_fixture(c, u, %{"name" => "PVC Pipe"})
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)
    tc = Repo.one!(from t in FullCircle.Accounting.TaxCode, where: t.company_id == ^c.id and t.code == "NoPTax")
    {:ok, _} = Billing.create_pur_invoice(pur_invoice_attrs(contact, good, pur_acct, tc, tax_rate: "0"), c, u)

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    drop_photo(lv, c, u)

    {:ok, _, _} = lv |> form("#object-form") |> render_submit() |> follow_redirect(conn)

    note = Repo.one!(from n in Note, where: n.subject_type == "Payment", preload: :attachments)
    assert note.title == "🧾 Receipt"
    assert [_] = note.attachments
  end

  test "a closed-period save keeps the tray for a re-save", %{conn: conn, user: u, company: c} do
    stub(%{@reply | "date" => Date.to_iso8601(Date.add(Date.utc_today(), -10))})
    {:ok, _} = Sys.close_period_through(c, Date.add(Date.utc_today(), -1), u)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    html = drop_photo(lv, c, u)
    assert html =~ "closed accounting period"

    lv |> form("#object-form") |> render_submit()
    assert Trays.has_files?(tray_id(lv), c, u)
    assert Repo.aggregate(Note, :count) == 0
  end

  test "changing the supplier re-checks duplicates", %{conn: conn, user: u, company: c} do
    stub(@reply)
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")
    drop_photo(lv, c, u)
    other = contact_fixture(c, u)
    html = lv |> form("#object-form", payment: %{"contact_name" => other.name, "contact_id" => other.id}) |> render_change()
    refute html =~ "Possible duplicate"
  end
end
```

The last test pins only the "no stale warning" half. The "new duplicate appears" half is covered by `duplicate_warning/3` in Task 5.

If the save test fails because the seeded Payment needs fields the receipt cannot give (check the flash), read `BillPay.make_changeset` for the required fields and add them to the receipt stub or to the `form/3` params **in the test**. Do not loosen the production merge.

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle_web/live/payment_receipt_capture_live_test.exs`
Expected: FAIL (no `#receipt-box`).

- [ ] **Step 3: Add the socket glue to `lib/full_circle_web/receipt_capture.ex`**

Add these aliases at the top: `alias FullCircle.{Receipts, Sys}`, `alias FullCircle.Notes.Attachments`, `alias FullCircle.BankReconciliation.LlmClient`, `import Phoenix.LiveView, only: [start_async: 3]`. Then:

```elixir
  def init(socket) do
    tray_id = Ecto.UUID.generate()
    if Phoenix.LiveView.connected?(socket), do: FullCircleWeb.NoteFiles.listen_self({:tray, tray_id})

    assign(socket,
      receipt_tray_id: tray_id,
      receipt_files: [],
      receipt_state: :idle,
      receipt: nil,
      receipt_usage: nil,
      receipt_error: nil,
      receipt_contact_ids: nil,
      receipt_settings: Sys.llm_settings(socket.assigns.current_company, :receipt)
    )
  end

  @doc "A file landed or left: reload the tray; the first file is read once."
  def files_changed(socket, detail_key) do
    %{receipt_tray_id: id, current_company: com, current_user: user} = socket.assigns
    socket = assign(socket, receipt_files: Trays.list(id, com, user))

    case {socket.assigns.receipt_state, socket.assigns.receipt_files} do
      {:idle, [_ | _]} -> read(socket, nil, detail_key)
      _ -> socket
    end
  end

  def discard_file(socket, att_id, detail_key) do
    %{receipt_tray_id: id, current_company: com, current_user: user} = socket.assigns
    Trays.discard_file(att_id, id, com, user)
    files_changed(socket, detail_key)
  end

  @doc "Read one tray file (nil: the first) in the background."
  def read(socket, att_id, detail_key) do
    %{receipt_files: files, receipt_settings: settings, current_company: com, current_user: user} =
      socket.assigns

    att = Enum.find(files, &(&1.id == att_id)) || List.first(files)

    cond do
      is_nil(att) ->
        socket

      settings["llm-provider"] in [nil, "", "none"] ->
        assign(socket, receipt_state: :off)

      true ->
        path = Attachments.abs_path(att)
        content_type = att.content_type

        socket
        |> assign(receipt_state: :reading, receipt_error: nil)
        |> start_async(:receipt, fn ->
          with {:ok, extracted, usage} <- Receipts.Extract.run(path, content_type, settings) do
            {:ok, Receipts.Prefill.build(extracted, com, user, detail_key), extracted, usage}
          end
        end)
    end
  end

  @doc "The read came back: `{socket, seed}` to merge, or `{socket, nil}`."
  def finished(socket, {:ok, {:ok, seed, extracted, usage}}) do
    {assign(socket,
       receipt_state: :done,
       receipt: %{extracted: extracted, warnings: seed.warnings, total: seed.total, duplicate: nil},
       receipt_usage: LlmClient.format_usage(usage),
       receipt_contact_ids: seed.contact_ids
     ), seed}
  end

  def finished(socket, {:ok, {:error, reason}}),
    do: {assign(socket, receipt_state: :error, receipt_error: to_string(reason)), nil}

  def finished(socket, {:exit, reason}),
    do: {assign(socket, receipt_state: :error, receipt_error: inspect(reason)), nil}

  @doc """
  The clerk changed the form: re-check the duplicate warning against the
  current contact. The original warnings from the read stay; the duplicate
  line is replaced.
  """
  def recheck_duplicate(%{assigns: %{receipt: %{} = receipt}} = socket, params, detail_key) do
    com = socket.assigns.current_company
    warnings = Enum.reject(receipt.warnings, &String.starts_with?(&1, gettext("Possible duplicate")))
    dup = Receipts.Prefill.duplicate_warning(params, detail_key, com)
    assign(socket, receipt: %{receipt | warnings: warnings, duplicate: dup})
  end

  def recheck_duplicate(socket, _params, _detail_key), do: socket
```

- [ ] **Step 4: Add the `receipt_capture/1` component** (same module)

```elixir
  attr :id, :string, required: true
  attr :tray_id, :string, required: true
  attr :files, :list, required: true
  attr :state, :atom, required: true
  attr :receipt, :map, default: nil
  attr :usage, :string, default: nil
  attr :error, :string, default: nil
  attr :keyed_total, :any, default: nil
  attr :label, :string, required: true
  attr :current_company, :map, required: true
  attr :current_user, :map, required: true

  def receipt_capture(assigns) do
    assigns =
      assign(assigns, photo: Attachments.photo_settings(assigns.current_company))

    ~H"""
    <div
      id={"#{@id}-box"}
      data-tray-id={@tray_id}
      phx-hook="NoteDrop"
      data-url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
      data-max-bytes={Attachments.max_bytes()}
      data-max-edge={@photo.max_edge}
      data-quality={@photo.quality}
      class="@container mb-2 rounded-lg border border-sky-400 bg-sky-50 p-2 text-sm text-gray-900 dark:border-sky-700 dark:bg-sky-950 dark:text-gray-100"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-semibold">🧾 {gettext("Receipt")}</span>
        <FullCircleWeb.NoteComponents.attach_button
          id={"#{@id}-attach"}
          url={~p"/companies/#{@current_company.id}/note_trays/#{@tray_id}/files"}
          company={@current_company}
        />
        <.live_component
          module={FullCircleWeb.NoteLive.PhoneQrComponent}
          id={"#{@id}-phone"}
          target={{:tray, @tray_id}}
          label={@label}
          current_company={@current_company}
          current_user={@current_user}
        />
        <span id={"#{@id}-status"} class="text-gray-700 dark:text-gray-300">
          <%= case @state do %>
            <% :idle -> %>
              {gettext("Snap or drop a bill / receipt — the AI fills the empty fields.")}
            <% :reading -> %>
              ⏳ {gettext("Reading receipt…")}
            <% :done -> %>
              ✓ {gettext("Read.")} <span class="text-xs text-gray-500 dark:text-gray-400">{@usage}</span>
            <% :error -> %>
              <span class="text-rose-700 dark:text-rose-300">
                {gettext("Couldn't read receipt:")} {@error}
              </span>
            <% :off -> %>
              {gettext("AI reading off — set it under Company → AI for receipts / bills.")}
          <% end %>
        </span>
        <button
          :if={@state in [:done, :error] and @files != []}
          type="button"
          id={"#{@id}-read-again"}
          phx-click="receipt_read_again"
          class="whitespace-nowrap rounded-full border border-gray-300 px-3 py-0.5 hover:bg-gray-100 dark:border-gray-600 dark:hover:bg-gray-800"
        >
          ↻ {gettext("Read again")}
        </button>
      </div>
      <FullCircleWeb.NoteComponents.file_grid
        id={"#{@id}-files"}
        attachments={@files}
        removable
        remove_event="receipt_discard_file"
        confirm={nil}
      />
      <div :if={@receipt} id={"#{@id}-read"} class="mt-2 grid gap-1">
        <% ex = @receipt.extracted %>
        <p :if={ex.recognized}>
          <span class="font-medium">{ex.supplier_name || gettext("(no supplier name)")}</span>
          <span :if={ex.supplier_tin}> · TIN {ex.supplier_tin}</span>
          <span :if={ex.supplier_brn}> · BRN {ex.supplier_brn}</span>
          <span :if={ex.doc_no}> · #{ex.doc_no}</span>
          <span :if={ex.date}> · {ex.date}</span>
          <span :if={ex.total}> · {gettext("Total")} {ex.total}</span>
        </p>
        <p :if={!ex.recognized} class="italic">{ex.summary}</p>
        <p :if={@receipt.total && @keyed_total} id={"#{@id}-totals"}>
          <% diff = FullCircle.EInvMetas.Prefill.variance(@keyed_total, @receipt.total) %>
          <span class={if diff, do: "text-rose-700 dark:text-rose-300", else: "text-emerald-700 dark:text-emerald-300"}>
            {gettext("Keyed RM %{k} · Receipt RM %{r}", k: Decimal.round(@keyed_total, 2), r: @receipt.total)}
            {if diff, do: gettext("(differs by %{d})", d: Decimal.round(diff, 2)), else: "✓"}
          </span>
        </p>
        <ul class="list-disc pl-5 text-amber-800 dark:text-amber-300">
          <li :for={w <- @receipt.warnings ++ List.wrap(@receipt.duplicate)}>{w}</li>
        </ul>
      </div>
    </div>
    """
  end
```

If `FullCircleWeb.NoteComponents.file_grid/1` / `attach_button/1` are not imported via `use FullCircleWeb, :html`, the fully-qualified calls above work as written.

- [ ] **Step 5: Wire the Payment form** (`lib/full_circle_web/live/payment_live/form.ex`)

(a) At the end of the `mount/3` pipeline add:

```elixir
     |> then(&if(&1.assigns.live_action == :new, do: FullCircleWeb.ReceiptCapture.init(&1), else: &1))
```

(b) Add these handlers next to the other `handle_event`s:

```elixir
  @impl true
  def handle_info({:note_files, {:tray, _}}, socket),
    do: {:noreply, FullCircleWeb.ReceiptCapture.files_changed(socket, :payment_details)}

  @impl true
  def handle_async(:receipt, result, socket) do
    case FullCircleWeb.ReceiptCapture.finished(socket, result) do
      {socket, nil} ->
        {:noreply, socket}

      {socket, seed} ->
        params =
          FullCircleWeb.ReceiptCapture.merge_params(socket.assigns.form.params, seed.attrs, :payment_details)

        {:noreply, socket} = validate(params, assign(socket, e_inv_supplier_ids: seed.contact_ids))
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("attachment_uploaded", _, socket),
    do: {:noreply, FullCircleWeb.ReceiptCapture.files_changed(socket, :payment_details)}

  @impl true
  def handle_event("receipt_read_again", _, socket),
    do: {:noreply, FullCircleWeb.ReceiptCapture.read(socket, nil, :payment_details)}

  @impl true
  def handle_event("receipt_discard_file", %{"id" => id}, socket),
    do: {:noreply, FullCircleWeb.ReceiptCapture.discard_file(socket, id, :payment_details)}
```

Setting `e_inv_supplier_ids` reuses the existing `maybe_learn_supplier_ids/2` after save, so the read TIN/BRN is stamped onto the chosen contact.

(c) In `handle_event("validate", …)`, re-check duplicates on new documents:

```elixir
  def handle_event("validate", %{"payment" => params}, socket) do
    socket = FullCircleWeb.ReceiptCapture.recheck_duplicate(socket, params, :payment_details)
    validate(params, socket)
  end
```

(`recheck_duplicate/3` is a no-op until a receipt has been read, so edit mode is unaffected.)

(d) In `save(socket, :new, params)` change the create call to:

```elixir
    case BillPay.create_payment(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user,
           receipt_multi(socket)
         ) do
```

and add the helpers:

```elixir
  defp receipt_multi(socket) do
    case socket.assigns[:receipt_tray_id] do
      nil ->
        &Function.identity/1

      tray_id ->
        FullCircleWeb.ReceiptCapture.attach_multi(
          tray_id,
          "Payment",
          :create_payment,
          socket.assigns.current_company,
          socket.assigns.current_user
        )
    end
  end

  defp maybe_warn_receipt_not_attached(socket) do
    %{current_company: com, current_user: user} = socket.assigns

    if socket.assigns[:receipt_tray_id] &&
         FullCircleWeb.ReceiptCapture.attach_blocked?(socket.assigns.receipt_tray_id, com, user),
       do: put_flash(socket, :warn, gettext("Saved, but the receipt was not attached: you cannot write notes.")),
       else: socket
  end
```

In the `{:ok, %{create_payment: obj}}` branch, add `|> maybe_warn_receipt_not_attached()` after `|> maybe_learn_supplier_ids(obj)`.

(e) Render: directly after `<.error_box changeset={@form.source} />` in `render/1`:

```heex
        <FullCircleWeb.ReceiptCapture.receipt_capture
          :if={@live_action == :new}
          id="receipt"
          tray_id={@receipt_tray_id}
          files={@receipt_files}
          state={@receipt_state}
          receipt={@receipt}
          usage={@receipt_usage}
          error={@receipt_error}
          keyed_total={Ecto.Changeset.fetch_field!(@form.source, :payment_detail_amount)}
          label={gettext("a new payment")}
          current_company={@current_company}
          current_user={@current_user}
        />
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `mix test test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/recon_doc_prefill_live_test.exs test/full_circle_web/live/stale_save_live_test.exs`
Expected: 0 failures.

- [ ] **Step 7: Run the full suite**

Run: `mix test`
Expected: green (the 2026-10-07 baseline is 2305 tests plus the ones added here). QueryRepo and punch-ingest log noise is harmless.

- [ ] **Step 8: Commit, then hand over for a manual check**

```bash
mix format lib/full_circle_web/receipt_capture.ex lib/full_circle_web/live/payment_live/form.ex test/full_circle_web/live/payment_receipt_capture_live_test.exs
git add lib/full_circle_web/receipt_capture.ex lib/full_circle_web/live/payment_live/form.ex test/full_circle_web/live/payment_receipt_capture_live_test.exs
git commit -m "feat(payment): capture a receipt photo, AI-fill the new payment, keep it as a note

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Manual check (the user, on a real phone):**
1. Set Company → AI for receipts / bills.
2. Start the server with `PHX_HOST=<LAN IP> iex -S mix phx.server`.
3. Open New Payment → 📱 → photograph 3–5 real petty-cash receipts, one payment each.
4. Report contact / total / lines hit rates before starting Task 8.

---

### Task 8: PurInvoice form: the same capture

**Files:**
- Modify: `lib/full_circle_web/live/pur_invoice_live/form.ex`
- Test: `test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs` (create)

**Interfaces:**
- Consumes: everything from Task 7 with `:pur_invoice_details`, `"PurInvoice"`, `:create_pur_invoice`.

- [ ] **Step 1: Write the failing LiveView test**

```elixir
defmodule FullCircleWeb.PurInvoiceReceiptCaptureLiveTest do
  use FullCircleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import FullCircle.UserAccountsFixtures
  import FullCircle.SysFixtures
  import FullCircle.BillingFixtures
  import FullCircle.NotesFixtures

  alias FullCircle.{Accounting, Billing, Repo, Sys}
  alias FullCircle.Notes.{Attachments, Note, Trays}

  @reply %{
    "recognized" => true,
    "summary" => "Supplier bill",
    "supplier" => %{"name" => "Ansonfarm Engineering", "tin" => "C5550001112"},
    "doc_no" => "INV-778",
    "date" => Date.to_iso8601(Date.utc_today()),
    "lines" => [%{"description" => "MOTOR 2HP", "quantity" => 1, "unit_price" => 850, "amount" => 850}],
    "total" => 850
  }

  setup %{conn: conn} do
    user = user_fixture()
    company = company_fixture(user, %{})
    {:ok, company} = Sys.update_company_settings(company, "llm_receipt", %{"llm-provider" => "claude", "llm-api-key" => "k"})
    test_pid = self()

    Application.put_env(:full_circle, :llm_http, fn _u, _h, _b, _t ->
      send(test_pid, :llm_called)
      {:ok, %{"content" => [%{"text" => Jason.encode!(@reply)}], "usage" => %{"input_tokens" => 1, "output_tokens" => 1}}}
    end)

    on_exit(fn -> Application.delete_env(:full_circle, :llm_http) end)
    %{conn: log_in_user(conn, user), user: user, company: company}
  end

  defp drop_photo(lv, c, u) do
    [_, id] = Regex.run(~r/id="receipt-box"[^>]*data-tray-id="([^"]+)"/, render(lv))
    {:ok, _} = Trays.open(id, c, u)
    {:ok, _} = Attachments.attach_to_tray(id, %{path: real_jpeg_file(:rgb), file_name: "bill.jpg"}, c, u)
    render(lv)
    render_async(lv)
  end

  defp value(lv, id), do: lv |> element("##{id}") |> render() |> then(&Regex.run(~r/value="([^"]*)"/, &1)) |> List.last()

  test "bill no goes to the supplier ref field, lines fill the blank line", %{conn: conn, user: u, company: c} do
    contact = contact_fixture(c, u, %{"tax_id" => "C5550001112"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/PurInvoice/new")
    html = drop_photo(lv, c, u)

    assert value(lv, "pur_invoice_contact_id") == contact.id
    assert value(lv, "pur_invoice_e_inv_internal_id") == "INV-778"
    assert value(lv, "pur_invoice_pur_invoice_no") == "...new..."
    assert html =~ "MOTOR 2HP"
  end

  test "save attaches the bill as a note on the purchase invoice", %{conn: conn, user: u, company: c} do
    contact = contact_fixture(c, u, %{"tax_id" => "C5550001112"})
    good = good_fixture(c, u, %{"name" => "Motor"})
    pur_acct = Accounting.get_account_by_name("General Purchases", c, u)
    tc = Repo.one!(from t in FullCircle.Accounting.TaxCode, where: t.company_id == ^c.id and t.code == "NoPTax")
    {:ok, _} = Billing.create_pur_invoice(pur_invoice_attrs(contact, good, pur_acct, tc, tax_rate: "0"), c, u)

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/PurInvoice/new")
    drop_photo(lv, c, u)
    {:ok, _, _} = lv |> form("#object-form") |> render_submit() |> follow_redirect(conn)

    note = Repo.one!(from n in Note, where: n.subject_type == "PurInvoice", preload: :attachments)
    assert note.title == "🧾 Receipt"
    assert [%{file_name: "bill.jpg"}] = note.attachments
  end
end
```

Check the PurInvoice form id and route first: `grep -n 'id="object-form"\|PurInvoice/new' lib/full_circle_web/live/pur_invoice_live/form.ex lib/full_circle_web/router.ex`. Use whatever is there.

- [ ] **Step 2: Run it and confirm it fails**

Run: `mix test test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs`
Expected: FAIL (no `#receipt-box`).

- [ ] **Step 3: Wire the form**

In `lib/full_circle_web/live/pur_invoice_live/form.ex`:

(a) At the end of the `mount/3` pipeline:

```elixir
     |> then(&if(&1.assigns.live_action == :new, do: FullCircleWeb.ReceiptCapture.init(&1), else: &1))
```

(b) Add `handle_info({:note_files, {:tray, _}}, …)`, `handle_async(:receipt, …)` and the three `handle_event`s (`attachment_uploaded`, `receipt_read_again`, `receipt_discard_file`). They are exactly the Task 7 code with `:payment_details` → `:pur_invoice_details`.
- Put the `handle_info` clause **above** the existing `handle_info({:trading_attach_selection, …})` clause. Elixir matches clauses in order, and the two patterns are different, so the order only matters for grouping.

(c) Change `handle_event("validate", %{"pur_invoice" => params}, socket)` to call `FullCircleWeb.ReceiptCapture.recheck_duplicate(socket, params, :pur_invoice_details)` before `validate(params, socket)`.

(d) In `save(socket, :new, params)`, the `true ->` branch of the `cond` currently passes `attach_links_fun(socket, params, company, user)`. Compose it with the receipt step:

```elixir
        true ->
          links = attach_links_fun(socket, params, company, user)
          receipt = receipt_multi(socket)

          Billing.create_pur_invoice(params, company, user, fn multi -> multi |> links.() |> receipt.() end)
```

Add `receipt_multi/1` and `maybe_warn_receipt_not_attached/1` exactly as in Task 7, with `"PurInvoice"` and `:create_pur_invoice`.
- Add `|> maybe_warn_receipt_not_attached()` after `|> maybe_learn_supplier_ids(obj)` in the success branch.
- The two trading `cond` branches (`load_ids` / `transport_ids`) do **not** get the receipt step. Those bills come from the settlement board, not a photo.

(e) Render: after `<.error_box changeset={@form.source} />`:

```heex
        <FullCircleWeb.ReceiptCapture.receipt_capture
          :if={@live_action == :new}
          id="receipt"
          tray_id={@receipt_tray_id}
          files={@receipt_files}
          state={@receipt_state}
          receipt={@receipt}
          usage={@receipt_usage}
          error={@receipt_error}
          keyed_total={Ecto.Changeset.fetch_field!(@form.source, :pur_invoice_amount)}
          label={gettext("a new purchase invoice")}
          current_company={@current_company}
          current_user={@current_user}
        />
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix test test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs test/full_circle_web/live/trading_settlement_live_test.exs test/full_circle_web/live/trading_desk_live_test.exs && mix test`
Expected: 0 failures.

- [ ] **Step 5: Commit, then hand over for a manual check**

```bash
mix format lib/full_circle_web/live/pur_invoice_live/form.ex test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs
git add lib/full_circle_web/live/pur_invoice_live/form.ex test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs
git commit -m "feat(pur_invoice): capture a bill photo, AI-fill the new purchase invoice

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Manual check (the user):** photograph 3–5 paper supplier bills into New Purchase Invoice, including a multi-page bill via phone **Scan**. Then report the hit rates.

---

### Task 9: Skill and docs

**Files:**
- Create: `.claude/skills/receipt-capture.md`
- Modify: `.claude/skills/e-invoice-bill-prefill.md`, `CLAUDE.md`

- [ ] **Step 1: Write `.claude/skills/receipt-capture.md`**

```markdown
---
name: receipt-capture
description: Use when working on photo/PDF receipt capture on New Payment or New Purchase Invoice — Receipts.Extract (AI prompt, JSON contract, checks), Receipts.Prefill (field mapping, funds account, SST/rounding lines, warnings), FullCircleWeb.ReceiptCapture (tray, blank-only merge, receipt note on save), or the "llm_receipt" AI settings.
---

# Receipt capture (PurInvoice / Payment from a photo)

Spec: `docs/superpowers/specs/2026-10-07-receipt-capture-design.md`.
For bills that have an LHDN e-invoice, use `e-invoice-bill-prefill.md` instead.
OCR only serves the paper-only tail.

## Pipeline
`Receipts.Extract.run/4` (file → `%Extracted{}`) → `Receipts.Prefill.build/4`
(→ attrs + warnings) → `ReceiptCapture.merge_params/3` (blank-only) → the form's `validate/2`.
Extract and Prefill know nothing about LiveView. A future inbox calls them as they are.

## Contracts that bite
- **Settings:** use `Sys.llm_settings(company, :receipt)`. Never read `"llm"` directly.
  Blank `"llm_receipt"` fields fall back to `"llm"`.
- **Supplier bill no → `e_inv_internal_id`.** `pur_invoice_no` is our gapless PINV
  number and is never seeded. Payment puts "<shop> #<doc_no>" in `descriptions`.
- **Not recognised** (`recognized: false`, or no total and no lines): only
  `descriptions` = summary (≤ 200 chars) is seeded, plus a warning.
- **The model is never trusted:** every value is parsed in `Extract.parse/2`. A
  value that doesn't parse becomes nil + a warning. Lines that don't add up warn.
  Tax-inclusive or tax-exclusive line amounts both pass.
- **Seeded-line traps** live in `DocPrefill.seed_lines/1` (`unit_multiplier` 0;
  qty into `quantity`, then `package_qty` once a good is applied; percent → fraction).
- **Extra lines:** SST given only as a total, and a non-zero rounding, each become
  their own line with the good blank.
- **Funds account:** the sole account → "Cash In Hand" (exact name) for a cash
  receipt → blank.
- **Merge fills only blanks.** Zero counts as blank. The contact
  (`contact_name/id/tax_id/reg_no`) and funds-account fields move as **groups**.
  Lines are replaced only when no line has a good, qty or price.
- **One read per tray:** the first file triggers it (state `:idle` → `:reading`).
  Later files only attach. ↻ Read again re-reads on purpose.
- **Save:** `attach_multi/5` appends `Notes.create_note` (title "🧾 Receipt",
  Everyone, subject = the new doc) to the create Multi. The doc and its note
  commit together. A failed save leaves the tray for a re-save. With no
  `:create_note` permission the step is skipped and a `:warn` flash says so.
- **Limits:** images over 5 MB are refused before the call; 90 s timeout;
  `max_tokens` 4096.
- **Tests:** stub `Application.put_env(:full_circle, :llm_http, fn url, headers,
  body, timeout -> …)` with `async: false`. LiveView tests: `Trays.open` +
  `Attachments.attach_to_tray`, then `render(lv)` and `render_async(lv)`.
```

- [ ] **Step 2: Update the existing docs**

- In `.claude/skills/e-invoice-bill-prefill.md`, add under the "Seeding" intro:

  > The contact, goods and seeded-line helpers now live in `FullCircle.DocPrefill` (shared with receipt capture); `EInvMetas.Prefill` calls them.

- Also change the trap section's "`Prefill` fills the good" wording to "`DocPrefill.put_goods/5` fills the good".
- In `CLAUDE.md`, add `receipt-capture.md` to the project skills list (after `e-invoice-bill-prefill.md`).

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/receipt-capture.md .claude/skills/e-invoice-bill-prefill.md CLAUDE.md
git commit -m "docs(skills): receipt capture contract; DocPrefill pointer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Notes for the executor

- **Panel placement.** The spec says the Receipt panel sits "beside the form". This plan puts it as a strip **above** the form inside the card, because both forms are already `min-w-[64rem]` and a side column would force horizontal scroll. If the user wants it beside the form after the manual check, that's a layout-only follow-up.
- **No Cancel discard.** These forms have no Cancel button that owns the tray. Abandoned trays are removed by `TrayPruner` after 24 h, which the spec allows.
- **The duplicate warning** names the existing document number. It is not a link, because the forms render warnings as plain text.
