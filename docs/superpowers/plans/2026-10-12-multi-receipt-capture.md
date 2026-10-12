# Multi-receipt Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One photo or (multi-page) PDF holding many receipts fills one Payment with one line per receipt and no payee (a salesperson's fuel claim). One receipt behaves exactly as today.

**Architecture:** `Receipts.Extract` asks the AI for `{"documents": [...]}` and returns a list of `%Extracted{}`. `Receipts.Prefill.build/4` gains a list clause that dispatches: one recognised document → today's struct clause; PurInvoice → first document + warning; Payment with 2+ → new `build_many/3`. The seed map shape is unchanged, so the Payment/PurInvoice forms and `ReceiptCapture.merge_params/3` do not change; only `ReceiptCapture`'s read summary renders a list.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.2, Ecto/PostgreSQL, ExUnit with the `:llm_http` stub.

**Spec:** `docs/superpowers/specs/2026-10-11-multi-receipt-capture-design.md` (builds on `docs/superpowers/specs/2026-10-07-receipt-capture-design.md`; contract in `.claude/skills/receipt-capture.md`).

## Global Constraints

- Payment only gets multi-receipt seeding. PurInvoice uses the first recognised document and warns `"The file shows <n> bills — only the first was used. One Purchase Invoice per bill."`
- One recognised receipt → today's behaviour exactly (payee, item lines, SST/rounding lines, funds account, duplicate check, TIN learning).
- 2+ recognised receipts → **no payee keys in the seed at all** (`contact_name/contact_id/tax_id/reg_no` absent), `learn: nil`, `contact_ids: {nil, nil}`, `duplicate: nil`.
- Line text: `"<shop> #<doc_no> <DD/MM/YYYY>"`, parts not read left out, `"Receipt"` when nothing was read. Quantity 1, unit price = the receipt total (0 when no total), discount 0, no good, no tax code.
- At most **40** receipts per read (first 40 in read order, then sorted by date). Over 40 warns `"<n> receipts read; only the first 40 were used. Split the claim into two Payments."` *(The cap lives in `Prefill`, not `Extract` as the spec's "Code shape" says: the model has already produced the extra entries, and the cap is a seeding decision.)*
- LLM options for every receipt read: `max_tokens: 32_768`, `timeout: 180_000`.
- Every warning is advisory; nothing new blocks Save.
- Never run bare `mix format`. Format only the files you touched: `mix format <file> <file>`.
- Commit on `master` directly. End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Payment line amounts are `quantity × unit_price + discount` — **discount is stored ≤ 0** (`PaymentDetail.compute_fields/1`). The spec's "− discount" means the same thing in positive terms.
- Never compare `Date` structs with `<`/`>` or sort tuples containing them: use `Date.compare/2`, `Enum.max(dates, Date)`, or ISO strings.
- Test log noise "missing the :database key in options for FullCircle.QueryRepo" is harmless.

## Review Focus

1. **A receipt with no date among dated ones** — it must sort last, not crash, and not become the pay date. Test in Task 1.
2. **No shop names read at all** — descriptions `"3 receipts"` and warning `"3 receipts — pick the payee …"`, never `"from 0 shops"`. Test in Task 1.
3. **Receipt nos with regex/LIKE metacharacters** (`INV/26-001(A)`, `50%`) in the duplicate-claim query — must not raise, must match literally, and `#12` must not match `#123`. Test in Task 2.
4. **The same receipt twice in one file** (photographed twice, or on two scanned pages) — warn `"<receipt> appears more than once in this file."` Test in Task 2.
5. **Odd model replies** — `"documents": []`, entries that are not objects, or today's single-object shape — must give a usable result, never a crash. Test in Task 3.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `lib/full_circle/receipts/prefill.ex` | modify | list dispatch, `build_many/3`, per-receipt and batch warnings, `claimed_warning/2` |
| `lib/full_circle/receipts/extract.ex` | modify | `documents` prompt, `parse_documents/2`, list return, new LLM options |
| `lib/full_circle_web/receipt_capture.ex` | modify | read summary renders one line per recognised document |
| `test/full_circle/receipts/prefill_test.exs` | modify | multi-receipt seeding and warnings |
| `test/full_circle/receipts/extract_test.exs` | modify | list contract, options |
| `test/full_circle_web/live/payment_receipt_capture_live_test.exs` | modify | fuel-claim read on the form |
| `test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs` | modify | two bills → first used |
| `.claude/skills/receipt-capture.md` | modify | list contract, 2+ rules, limits |

---

### Task 1: `Prefill.build/4` takes a list; Payment with 2+ receipts

**Files:**
- Modify: `lib/full_circle/receipts/prefill.ex`
- Test: `test/full_circle/receipts/prefill_test.exs`

**Interfaces:**
- Consumes: `%FullCircle.Receipts.Extracted{}` (fields `recognized, summary, supplier_name, supplier_tin, supplier_brn, doc_no, date, total, payment_method, e_invoice_uuid, warnings, …`); `DocPrefill.seed_lines/1` (list of `%{descriptions, quantity, unit_price, discount, tax_rate, amount}` → string-keyed line maps); existing private `put_funds_account/5`, `period_warning/2`, `e_invoice_warning/2`.
- Produces: `Prefill.build(docs :: [%Extracted{}], com, user, detail_key) :: %{attrs: map, warnings: [String.t()], duplicate: nil | String.t(), learn: nil | tuple, contact_ids: {tin, brn}, total: Decimal.t() | nil}` — same map shape as the existing struct clause. The struct clause `build(%Extracted{}, …)` stays public and unchanged. Private `receipt_text/2` (doc, with_date?) is reused in Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `test/full_circle/receipts/prefill_test.exs`, before the final `end`:

```elixir
  describe "build/4 with a list" do
    defp fuel(shop, no, days_ago, total, method \\ "cash") do
      ex(%{
        supplier_name: shop,
        supplier_tin: nil,
        doc_no: no,
        date: Date.add(Date.utc_today(), -days_ago),
        total: Decimal.new(total),
        payment_method: method,
        lines: []
      })
    end

    defp dmy(days_ago), do: Calendar.strftime(Date.add(Date.utc_today(), -days_ago), "%d/%m/%Y")

    test "one recognised document seeds exactly like the struct clause", %{c: c, u: u} do
      assert Prefill.build([ex()], c, u, :payment_details) ==
               Prefill.build(ex(), c, u, :payment_details)
    end

    test "3 receipts, 3 shops: no payee, one dated line each, sum, latest date", %{c: c, u: u} do
      contact_fixture(c, u, %{"name" => "Petronas BM", "tax_id" => "C2345678901"})

      docs = [
        fuel("Shell Juru", "S-9", 2, "60.00"),
        fuel("Petronas BM", "P-101", 9, "80.00"),
        fuel("Caltex Alma", "C-7", 5, "45.50")
      ]

      seed = Prefill.build(docs, c, u, :payment_details)

      refute Map.has_key?(seed.attrs, :contact_id)
      refute Map.has_key?(seed.attrs, :contact_name)
      assert seed.learn == nil
      assert seed.contact_ids == {nil, nil}
      assert seed.duplicate == nil

      assert Enum.map(seed.attrs.payment_details, & &1["descriptions"]) == [
               "Petronas BM #P-101 #{dmy(9)}",
               "Caltex Alma #C-7 #{dmy(5)}",
               "Shell Juru #S-9 #{dmy(2)}"
             ]

      [first | _] = seed.attrs.payment_details
      assert Decimal.eq?(first["quantity"], 1)
      assert Decimal.eq?(first["unit_price"], Decimal.new("80.00"))
      assert first["good_name"] == ""

      assert Decimal.eq?(seed.attrs.funds_amount, Decimal.new("185.50"))
      assert Decimal.eq?(seed.total, Decimal.new("185.50"))
      assert seed.attrs.payment_date == Date.add(Date.utc_today(), -2)
      assert seed.attrs.descriptions == "3 receipts: Shell Juru, Petronas BM, Caltex Alma"

      assert "3 receipts from 3 shops — pick the payee (e.g. the salesperson)." in seed.warnings

      assert "Receipts are dated #{dmy(9)} to #{dmy(2)}; the pay date was set to #{dmy(2)}." in seed.warnings
    end

    test "receipts from one shop still leave the payee blank", %{c: c, u: u} do
      contact_fixture(c, u, %{"name" => "Petronas BM", "tax_id" => "C2345678901"})

      docs = [
        %{fuel("Petronas BM", "P-1", 3, "50.00") | supplier_tin: "C2345678901"},
        %{fuel("Petronas BM", "P-2", 1, "70.00") | supplier_tin: "C2345678901"}
      ]

      seed = Prefill.build(docs, c, u, :payment_details)
      refute Map.has_key?(seed.attrs, :contact_id)
      assert "2 receipts from 1 shop — pick the payee (e.g. the salesperson)." in seed.warnings
    end

    test "all cash → Cash In Hand; any other method → no funds account", %{c: c, u: u} do
      cash = account_fixture(%{name: "Cash In Hand", account_type: "Cash or Equivalent"}, c, u)

      seed =
        Prefill.build([fuel("A", "1", 1, "10"), fuel("B", "2", 1, "20")], c, u, :payment_details)

      assert seed.attrs.funds_account_id == cash.id

      seed =
        Prefill.build(
          [fuel("A", "1", 1, "10"), fuel("B", "2", 1, "20", "card")],
          c,
          u,
          :payment_details
        )

      refute Map.has_key?(seed.attrs, :funds_account_id)
    end

    test "unrecognised entries are dropped with a warning", %{c: c, u: u} do
      junk = %Extracted{recognized: false, summary: "A coffee cup", warnings: []}

      seed =
        Prefill.build(
          [fuel("A", "1", 1, "10"), junk, fuel("B", "2", 1, "20")],
          c,
          u,
          :payment_details
        )

      assert length(seed.attrs.payment_details) == 2
      assert "1 document in the file could not be read as a receipt." in seed.warnings

      one = Prefill.build([fuel("A", "1", 1, "10"), junk], c, u, :payment_details)
      assert one.attrs.descriptions == "A #1"
      assert "1 document in the file could not be read as a receipt." in one.warnings
    end

    test "nothing recognised → today's not-recognised seed", %{c: c, u: u} do
      junk = %Extracted{
        recognized: false,
        summary: "Photo of a cheque",
        warnings: ["Not recognised as a bill or receipt."]
      }

      seed = Prefill.build([junk], c, u, :payment_details)
      assert seed.attrs == %{descriptions: "Photo of a cheque"}
      assert seed.warnings == ["Not recognised as a bill or receipt."]
    end

    test "receipt with no total: 0 line and a warning naming it", %{c: c, u: u} do
      docs = [fuel("A", "1", 1, "10"), %{fuel("Shell Juru", "S-9", 1, "1") | total: nil}]
      seed = Prefill.build(docs, c, u, :payment_details)

      line = Enum.find(seed.attrs.payment_details, &(&1["descriptions"] =~ "Shell Juru"))
      assert Decimal.eq?(line["unit_price"], 0)
      assert Decimal.eq?(seed.attrs.funds_amount, Decimal.new("10"))
      assert "Shell Juru #S-9: no total read — its line is 0.00." in seed.warnings
    end

    test "per-receipt warnings carry the receipt's name", %{c: c, u: u} do
      bad = %{fuel("Shell Juru", "S-9", 1, "10") | warnings: ["Receipt lines don't add up: x"]}
      seed = Prefill.build([fuel("A", "1", 1, "10"), bad], c, u, :payment_details)
      assert "Shell Juru #S-9: Receipt lines don't add up: x" in seed.warnings
    end

    test "a receipt with no date sorts last and is not the pay date", %{c: c, u: u} do
      docs = [%{fuel("Nodate", "N-1", 0, "5") | date: nil}, fuel("A", "1", 4, "10")]
      seed = Prefill.build(docs, c, u, :payment_details)

      assert Enum.map(seed.attrs.payment_details, & &1["descriptions"]) ==
               ["A #1 #{dmy(4)}", "Nodate #N-1"]

      assert seed.attrs.payment_date == Date.add(Date.utc_today(), -4)
      refute Enum.any?(seed.warnings, &(&1 =~ "Receipts are dated"))
    end

    test "no shop names read: plain count, no 'from 0 shops'", %{c: c, u: u} do
      docs = for i <- 1..3, do: %{fuel("x", "#{i}", 1, "10") | supplier_name: nil}
      seed = Prefill.build(docs, c, u, :payment_details)

      assert seed.attrs.descriptions == "3 receipts"
      assert "3 receipts — pick the payee (e.g. the salesperson)." in seed.warnings
      assert hd(seed.attrs.payment_details)["descriptions"] == "#1 #{dmy(1)}"
    end

    test "41 receipts: the first 40 read are used, with a split warning", %{c: c, u: u} do
      docs = for i <- 1..41, do: fuel("Shop#{i}", "#{i}", 1, "1")
      seed = Prefill.build(docs, c, u, :payment_details)

      assert length(seed.attrs.payment_details) == 40
      refute Enum.any?(seed.attrs.payment_details, &(&1["descriptions"] =~ "Shop41 "))

      assert "41 receipts read; only the first 40 were used. Split the claim into two Payments." in seed.warnings
    end

    test "pur invoice with 2 bills: the first is used, with a warning", %{c: c, u: u} do
      seed =
        Prefill.build(
          [ex(), ex(%{doc_no: "B-2", supplier_name: "Other"})],
          c,
          u,
          :pur_invoice_details
        )

      assert seed.attrs.e_inv_internal_id == "A12345"

      assert "The file shows 2 bills — only the first was used. One Purchase Invoice per bill." in seed.warnings
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/receipts/prefill_test.exs`
Expected: the new `build/4 with a list` tests FAIL with `FunctionClauseError` (no `build/4` clause for a list); the existing tests still pass.

- [ ] **Step 3: Implement the list clause and `build_many/3`**

In `lib/full_circle/receipts/prefill.ex`:

Add the module attribute next to `@cash_account`:

```elixir
  @max_receipts 40
```

Insert this **above** the existing `def build(%Extracted{recognized: false} = ex, …)` clause:

```elixir
  @doc """
  A read's documents → one seed. Only recognised documents count. One seeds
  as before; a PurInvoice takes the first; a Payment with 2+ gets one line
  per receipt and no payee (`build_many/3`) — for a claim the payee is the
  claimant, not the shops.
  """
  def build(docs, com, user, detail_key) when is_list(docs) do
    {known, unknown} = Enum.split_with(docs, & &1.recognized)
    dropped = dropped_warning(known, unknown)

    case {known, detail_key} do
      {[], _} ->
        build(List.first(docs) || not_recognised(), com, user, detail_key)

      {[one], _} ->
        one |> build(com, user, detail_key) |> add_warnings(dropped)

      {[first | _], :pur_invoice_details} ->
        first
        |> build(com, user, detail_key)
        |> add_warnings([only_first_warning(length(known)) | dropped])

      {many, :payment_details} ->
        many |> build_many(com, user) |> add_warnings(dropped)
    end
  end
```

Add these private functions after the existing `build(%Extracted{} = ex, …)` clause:

```elixir
  defp not_recognised,
    do: %Extracted{recognized: false, warnings: [gettext("Not recognised as a bill or receipt.")]}

  defp add_warnings(seed, []), do: seed
  defp add_warnings(seed, extra), do: %{seed | warnings: seed.warnings ++ extra}

  defp dropped_warning([], _unknown), do: []
  defp dropped_warning(_known, []), do: []

  defp dropped_warning(_known, unknown),
    do: [
      ngettext(
        "%{count} document in the file could not be read as a receipt.",
        "%{count} documents in the file could not be read as receipts.",
        length(unknown)
      )
    ]

  defp only_first_warning(n),
    do:
      gettext(
        "The file shows %{n} bills — only the first was used. One Purchase Invoice per bill.",
        n: n
      )

  # 2+ receipts on a Payment (a claim): one line per receipt, payee left for
  # the clerk. The first @max_receipts in read order are used, then sorted by date.
  defp build_many(docs, com, user) do
    {used, over} = Enum.split(docs, @max_receipts)
    # Shop names in read order (descriptions); lines in date order.
    shops = used |> Enum.map(& &1.supplier_name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    used = sort_by_date(used)
    dates = used |> Enum.map(& &1.date) |> Enum.reject(&is_nil/1)
    pay_date = if dates == [], do: nil, else: Enum.max(dates, Date)
    total = Enum.reduce(used, Decimal.new(0), &Decimal.add(&1.total || 0, &2))
    method = if Enum.all?(used, &(&1.payment_method == "cash")), do: "cash"

    attrs =
      %{
        payment_details: used |> Enum.map(&receipt_line/1) |> DocPrefill.seed_lines(),
        payment_date: pay_date,
        funds_amount: total,
        descriptions: many_descriptions(length(used), shops)
      }
      |> put_funds_account(%{payment_method: method}, :payment_details, com, user)

    warnings =
      [payee_warning(length(used), length(shops))] ++
        span_warning(dates, pay_date) ++
        over_warning(length(used) + length(over)) ++
        Enum.flat_map(used, &receipt_warnings(&1, com))

    %{
      attrs: attrs,
      warnings: warnings,
      duplicate: nil,
      learn: nil,
      contact_ids: {nil, nil},
      total: total
    }
  end

  # ISO strings sort by date (Date structs compare structurally); undated last,
  # read order breaks ties.
  defp sort_by_date(docs) do
    docs
    |> Enum.with_index()
    |> Enum.sort_by(fn {d, i} -> {if(d.date, do: Date.to_iso8601(d.date), else: "9999"), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp receipt_line(doc) do
    amount = doc.total || Decimal.new(0)

    %{
      descriptions: receipt_text(doc, true),
      quantity: Decimal.new(1),
      unit_price: amount,
      discount: Decimal.new(0),
      tax_rate: nil,
      amount: amount
    }
  end

  # "<shop> #<doc_no> <DD/MM/YYYY>", parts not read left out.
  defp receipt_text(doc, with_date?) do
    [
      doc.supplier_name,
      doc.doc_no && "#" <> doc.doc_no,
      with_date? && doc.date && Calendar.strftime(doc.date, "%d/%m/%Y")
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> case do
      [] -> gettext("Receipt")
      parts -> Enum.join(parts, " ")
    end
  end

  defp many_descriptions(n, []), do: gettext("%{n} receipts", n: n)

  defp many_descriptions(n, shops),
    do:
      String.slice(
        gettext("%{n} receipts: %{shops}", n: n, shops: Enum.join(shops, ", ")),
        0,
        @descriptions_max
      )

  defp payee_warning(n, 0),
    do: gettext("%{n} receipts — pick the payee (e.g. the salesperson).", n: n)

  defp payee_warning(n, shops),
    do:
      ngettext(
        "%{n} receipts from %{count} shop — pick the payee (e.g. the salesperson).",
        "%{n} receipts from %{count} shops — pick the payee (e.g. the salesperson).",
        shops,
        n: n
      )

  defp span_warning([], _pay_date), do: []

  defp span_warning(dates, pay_date) do
    first = Enum.min(dates, Date)

    if Date.compare(first, pay_date) == :eq,
      do: [],
      else: [
        gettext("Receipts are dated %{first} to %{last}; the pay date was set to %{last}.",
          first: Calendar.strftime(first, "%d/%m/%Y"),
          last: Calendar.strftime(pay_date, "%d/%m/%Y")
        )
      ]
  end

  defp over_warning(n) when n > @max_receipts,
    do: [
      gettext(
        "%{n} receipts read; only the first %{max} were used. Split the claim into two Payments.",
        n: n,
        max: @max_receipts
      )
    ]

  defp over_warning(_n), do: []

  defp receipt_warnings(doc, com) do
    label = receipt_text(doc, false)
    no_total = if is_nil(doc.total), do: gettext("no total read — its line is 0.00.")

    (doc.warnings ++
       [no_total, period_warning(doc.date, com), e_invoice_warning(doc.e_invoice_uuid, com)])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&"#{label}: #{&1}")
  end
```

Note on `put_funds_account/5`: its `:payment_details` clause reads `attrs[:contact_id]` (nil here, so the sole-account lookup is skipped) and `ex.payment_method` — passing `%{payment_method: method}` reuses it unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/receipts/prefill_test.exs`
Expected: all PASS, no compile warnings.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/receipts/prefill.ex test/full_circle/receipts/prefill_test.exs
git add lib/full_circle/receipts/prefill.ex test/full_circle/receipts/prefill_test.exs
git commit -m "feat(receipts): Prefill takes a list — many receipts make one Payment line each, no payee

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Duplicate-claim warnings (earlier Payments, and twice in one file)

**Files:**
- Modify: `lib/full_circle/receipts/prefill.ex`
- Test: `test/full_circle/receipts/prefill_test.exs`

**Interfaces:**
- Consumes: from Task 1 — `build_many/3`, `receipt_warnings/2`, `receipt_text/2`. Schemas `FullCircle.BillPay.Payment` (`company_id`, `payment_no`), `FullCircle.BillPay.PaymentDetail` (`payment_id`, `descriptions`, `quantity`, `unit_price`, `discount` ≤ 0).
- Produces: `Prefill.claimed_warning(doc :: %Extracted{}, com) :: String.t() | nil` (public, for tests and a future inbox).

- [ ] **Step 1: Write the failing tests**

Append inside the `describe "build/4 with a list"` block from Task 1:

```elixir
    defp claimed_payment!(c, u, line_text, amount) do
      contact = contact_fixture(c, u)
      good = good_fixture(c, u)
      pur_acct = Accounting.get_account_by_name("General Purchases", c, u)

      attrs =
        payment_attrs(contact, good, pur_acct, no_ptax(c), pay_funds_account_fixture(c, u),
          tax_rate: "0",
          quantity: "1",
          unit_price: amount,
          funds_amount: amount
        )
        |> put_in(["payment_details", "0", "descriptions"], line_text)

      {:ok, %{create_payment: pv}} = BillPay.create_payment(attrs, c, u)
      pv
    end

    test "a receipt already on an earlier Payment line warns with its payment no", %{
      c: c,
      u: u
    } do
      pv = claimed_payment!(c, u, "Shell #777 01/10/2026", "50.00")

      seed =
        Prefill.build(
          [fuel("Shell", "777", 1, "50.00"), fuel("A", "1", 1, "10")],
          c,
          u,
          :payment_details
        )

      assert "Shell #777 (RM 50.00) may already be claimed on #{pv.payment_no}." in seed.warnings
    end

    test "same receipt no, different amount: no claimed warning", %{c: c, u: u} do
      claimed_payment!(c, u, "Shell #777 01/10/2026", "50.00")
      refute Prefill.claimed_warning(fuel("Shell", "777", 1, "51.00"), c)
    end

    test "receipt nos match literally and whole", %{c: c, u: u} do
      claimed_payment!(c, u, "Shell #INV/26-001(A) 01/10/2026", "20.00")
      claimed_payment!(c, u, "Esso #123 01/10/2026", "30.00")

      assert Prefill.claimed_warning(fuel("Shell", "INV/26-001(A)", 1, "20.00"), c)
      refute Prefill.claimed_warning(fuel("Esso", "12", 1, "30.00"), c)
      refute Prefill.claimed_warning(fuel("Esso", "50%", 1, "30.00"), c)
      refute Prefill.claimed_warning(fuel("Esso", nil, 1, "30.00"), c)
    end

    test "the same receipt twice in one file warns once", %{c: c, u: u} do
      seed =
        Prefill.build(
          [fuel("Shell", "777", 1, "50.00"), fuel("Shell", "777", 1, "50.0")],
          c,
          u,
          :payment_details
        )

      assert Enum.count(seed.warnings, &(&1 == "Shell #777 appears more than once in this file.")) ==
               1
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/full_circle/receipts/prefill_test.exs`
Expected: the four new tests FAIL (`UndefinedFunctionError` for `claimed_warning/2`, missing warnings).

- [ ] **Step 3: Implement**

In `lib/full_circle/receipts/prefill.ex`, extend the aliases:

```elixir
  alias FullCircle.BillPay.{Payment, PaymentDetail}
```

(replacing `alias FullCircle.BillPay.Payment`).

In `build_many/3`, add the in-file repeats to the warnings:

```elixir
    warnings =
      [payee_warning(length(used), length(shops))] ++
        span_warning(dates, pay_date) ++
        over_warning(length(used) + length(over)) ++
        repeated_warnings(used) ++
        Enum.flat_map(used, &receipt_warnings(&1, com))
```

In `receipt_warnings/2`, append the claimed warning **after** the prefixing (its text already names the receipt):

```elixir
  defp receipt_warnings(doc, com) do
    label = receipt_text(doc, false)
    no_total = if is_nil(doc.total), do: gettext("no total read — its line is 0.00.")

    (doc.warnings ++
       [no_total, period_warning(doc.date, com), e_invoice_warning(doc.e_invoice_uuid, com)])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&"#{label}: #{&1}")
    |> Kernel.++(List.wrap(claimed_warning(doc, com)))
  end
```

Add the two functions:

```elixir
  @doc """
  An earlier Payment line that already claims this receipt — its text holds
  "#<doc_no>" as a whole word and its amount is within 0.01 — or nil.
  Relies on the line text `build_many/3` writes; advisory only.
  """
  def claimed_warning(%Extracted{doc_no: no, total: %Decimal{} = total} = doc, com)
      when is_binary(no) do
    # A bound regex parameter: metacharacters in the receipt no are escaped,
    # and "#12" must not match "#123".
    pattern = "#" <> Regex.escape(no) <> "(\\s|$)"

    from(d in PaymentDetail,
      join: p in Payment,
      on: p.id == d.payment_id,
      where: p.company_id == ^com.id,
      where: fragment("? ~* ?", d.descriptions, ^pattern),
      where:
        fragment("abs(round(? * ? + ?, 2) - ?) < 0.01", d.quantity, d.unit_price, d.discount, ^total),
      order_by: p.payment_no,
      select: p.payment_no,
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      payment_no ->
        gettext("%{receipt} (RM %{amount}) may already be claimed on %{doc}.",
          receipt: receipt_text(doc, false),
          amount: Decimal.round(total, 2),
          doc: payment_no
        )
    end
  end

  def claimed_warning(_doc, _com), do: nil

  # The same receipt photographed twice, or on two scanned pages.
  defp repeated_warnings(docs) do
    docs
    |> Enum.filter(&(&1.doc_no && &1.total))
    |> Enum.group_by(&{&1.supplier_name, &1.doc_no, Decimal.to_string(Decimal.round(&1.total, 2))})
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {_key, [doc | _]} ->
      gettext("%{receipt} appears more than once in this file.", receipt: receipt_text(doc, false))
    end)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/full_circle/receipts/prefill_test.exs`
Expected: all PASS.

- [ ] **Step 5: Format and commit**

```bash
mix format lib/full_circle/receipts/prefill.ex test/full_circle/receipts/prefill_test.exs
git add lib/full_circle/receipts/prefill.ex test/full_circle/receipts/prefill_test.exs
git commit -m "feat(receipts): warn when a claimed receipt is already on a Payment, or twice in one file

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `Extract` returns a list; the capture strip shows every receipt

**Files:**
- Modify: `lib/full_circle/receipts/extract.ex`
- Modify: `lib/full_circle_web/receipt_capture.ex:152-192` (read/finished) and `:299-309` (read summary)
- Test: `test/full_circle/receipts/extract_test.exs`
- Test: `test/full_circle_web/live/payment_receipt_capture_live_test.exs`
- Test: `test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs`

**Interfaces:**
- Consumes: Task 1's `Prefill.build(docs :: list, com, user, detail_key)`.
- Produces: `Extract.run(path, content_type, settings, opts) :: {:ok, [%Extracted{}], usage} | {:error, String.t()}` (list is never empty); `Extract.parse_documents(map, today) :: [%Extracted{}]`. `ReceiptCapture` keeps `receipt.extracted` but it is now a list.

- [ ] **Step 1: Write the failing Extract tests**

In `test/full_circle/receipts/extract_test.exs`, add a `describe` block after `describe "decode_json/1"`:

```elixir
  describe "parse_documents/2" do
    test "one entry per document" do
      second = Map.merge(@good, %{"doc_no" => "B-2", "supplier" => %{"name" => "Shell"}})
      docs = Extract.parse_documents(%{"documents" => [@good, second]}, @today)

      assert [%Extracted{doc_no: "A12345"}, %Extracted{doc_no: "B-2", supplier_name: "Shell"}] =
               docs
    end

    test "today's single-object reply is one document" do
      assert [%Extracted{recognized: true, doc_no: "A12345"}] =
               Extract.parse_documents(@good, @today)
    end

    test "an empty list is one unrecognised document" do
      assert [%Extracted{recognized: false, summary: "Blank page"}] =
               Extract.parse_documents(%{"documents" => [], "summary" => "Blank page"}, @today)
    end

    test "entries that are not objects are skipped" do
      assert [%Extracted{doc_no: "A12345"}] =
               Extract.parse_documents(%{"documents" => ["junk", 3, nil, @good]}, @today)

      assert [%Extracted{recognized: false}] =
               Extract.parse_documents(%{"documents" => ["junk"]}, @today)
    end
  end
```

In `describe "run/4"`, replace the test `"image: one call with the 90 s timeout and 16k tokens"` with:

```elixir
    test "image: one call with the 180 s timeout and 32k tokens, a list back" do
      stub([Jason.encode!(%{"documents" => [@good, @good]})])
      path = tmp(".jpg", <<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>)

      assert {:ok, [%Extracted{recognized: true}, %Extracted{}], usage} =
               Extract.run(path, "image/jpeg", @settings, today: @today)

      assert usage.total_tokens == 150
      assert_received {:llm_called, body, 180_000}
      assert body["max_tokens"] == 32_768
      [%{"content" => [%{"type" => "image"}, _]}] = body["messages"]
      assert body["system"] =~ "documents"
    end
```

Change the assertion in `"bad JSON retries once asking for JSON only"` from
`assert {:ok, %Extracted{recognized: true}, _} =` to
`assert {:ok, [%Extracted{recognized: true}], _} =`.

(The Claude request body carries the system prompt as a top-level `"system"` string — `LlmClient`, the `system: system_prompt` field.)

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/full_circle/receipts/extract_test.exs`
Expected: FAIL — `parse_documents/2` undefined; `run/4` returns a struct, 90 000 timeout.

- [ ] **Step 3: Implement the Extract changes**

In `lib/full_circle/receipts/extract.ex`, replace `@system_prompt` with:

```elixir
  @system_prompt """
  You read photos and PDFs of Malaysian supplier bills, invoices, cash bills and
  shop receipts. One file may hold several of them. Reply with ONE JSON object
  and nothing else:

  {"documents": [
    {"recognized": true|false,
     "summary": "one plain sentence of what this document is",
     "supplier": {"name": str|null, "tin": str|null, "brn": str|null, "sst_no": str|null},
     "doc_no": str|null, "date": "YYYY-MM-DD"|null, "due_date": "YYYY-MM-DD"|null,
     "lines": [{"description": str, "quantity": num|null, "unit_price": num|null,
                "discount": num|null, "tax_rate_percent": num|null, "amount": num|null}],
     "subtotal": num|null, "tax_total": num|null, "rounding": num|null, "total": num|null,
     "payment_method": "cash"|"card"|"transfer"|"cheque"|null,
     "e_invoice_uuid": str|null}
  ]}

  Rules:
  - One entry per separate bill or receipt, in reading order: page by page,
    top to bottom, left to right.
  - One bill can run across pages: lines carried over, "Page 1 of 3", the total
    on a later page. That is ONE entry, not one per page.
  - A page can hold several receipts. Each is its own entry.
  - Use null for anything not printed or not legible. Never guess.
  - recognized is false for something that is not a bill, invoice, cash bill or
    receipt (a delivery order, cheque, letter, product photo, unreadable shot).
    Then leave its other fields null and lines empty. A file with no bill or
    receipt at all is a single entry with recognized false.
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
```

Change `@user_prompt` to `"Read every bill or receipt in this file."`.

In `run/4`, change the options and the parse call:

```elixir
    llm_opts = [timeout: Keyword.get(opts, :timeout, 180_000), max_tokens: 32_768]
```

```elixir
      with {:ok, text, usage} <- ask.(@user_prompt) do
        case decode_json(text) do
          {:ok, map} -> {:ok, parse_documents(map, today), usage}
          :error -> retry(ask, today)
        end
      end
```

and in `retry/2`: `{:ok, map} -> {:ok, parse_documents(map, today), usage}`.

Add, above `@doc "A decoded model reply → …"` (`parse/2`):

```elixir
  @doc """
  A decoded reply → one `%Extracted{}` per document, never an empty list.
  Today's single-object shape counts as one document; entries that are not
  objects are skipped; nothing left is one unrecognised document.
  """
  def parse_documents(%{"documents" => docs} = map, today) when is_list(docs) do
    case for(%{} = doc <- docs, do: parse(doc, today)) do
      [] -> [parse(%{"recognized" => false, "summary" => map["summary"]}, today)]
      parsed -> parsed
    end
  end

  def parse_documents(map, today) when is_map(map), do: [parse(map, today)]
```

Update the `@moduledoc` first sentence to: `A photographed bill or receipt (JPEG/PNG/WebP/PDF) → a list of \`%Extracted{}\`, one per document in the file, via …`.

- [ ] **Step 4: Run the Extract tests**

Run: `mix test test/full_circle/receipts/extract_test.exs`
Expected: all PASS.

- [ ] **Step 5: Write the failing LiveView tests**

In `test/full_circle_web/live/payment_receipt_capture_live_test.exs`, add before the final `end`:

```elixir
  defp fuel(shop, no, days_ago, total) do
    %{
      "recognized" => true,
      "summary" => "Fuel receipt",
      "supplier" => %{"name" => shop},
      "doc_no" => no,
      "date" => Date.to_iso8601(Date.add(Date.utc_today(), -days_ago)),
      "lines" => [%{"description" => "RON95", "quantity" => 1, "amount" => total}],
      "total" => total,
      "payment_method" => "cash"
    }
  end

  test "a fuel claim: payee picked first is kept, one line per receipt", %{
    conn: conn,
    user: u,
    company: c
  } do
    stub(%{
      "documents" => [
        fuel("Shell Juru", "S-9", 2, 60),
        fuel("Petronas BM", "P-101", 9, 80),
        fuel("Caltex Alma", "C-7", 5, 45.5)
      ]
    })

    salesperson = contact_fixture(c, u, %{"name" => "Ah Kow (sales)"})
    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/Payment/new")

    render_change(lv, "validate", %{
      "payment" => %{"contact_name" => salesperson.name, "contact_id" => salesperson.id}
    })

    html = drop_photo(lv, c, u)
    d9 = Calendar.strftime(Date.add(Date.utc_today(), -9), "%d/%m/%Y")

    assert value(lv, "payment_contact_id") == salesperson.id
    assert value(lv, "payment_funds_amount") =~ "185.5"
    assert html =~ "Petronas BM #P-101 #{d9}"
    assert html =~ "Caltex Alma"
    assert html =~ "Shell Juru"
    assert html =~ "3 receipts from 3 shops"
    refute html =~ "RON95"
  end
```

In `test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs`, add before the final `end`:

```elixir
  test "two bills in one file: the first fills the form, with a warning", %{
    conn: conn,
    user: u,
    company: c
  } do
    second = Map.merge(@reply, %{"doc_no" => "INV-999", "supplier" => %{"name" => "Other Co"}})

    Application.put_env(:full_circle, :llm_http, fn _u, _h, _b, _t ->
      {:ok,
       %{
         "content" => [%{"text" => Jason.encode!(%{"documents" => [@reply, second]})}],
         "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
       }}
    end)

    {:ok, lv, _} = live(conn, ~p"/companies/#{c.id}/PurInvoice/new")
    html = drop_photo(lv, c, u)

    assert value(lv, "pur_invoice_e_inv_internal_id") == "INV-778"
    assert html =~ "The file shows 2 bills"
    assert html =~ "MOTOR 2HP"
  end
```

- [ ] **Step 6: Run them to verify they fail**

Run: `mix test test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs`
Expected: the two new tests FAIL, and the existing ones crash in the read summary (`ex.recognized` on a list → `KeyError`/`BadMapError`), because `Extract.run` now returns a list.

- [ ] **Step 7: Render a list in the capture strip**

In `lib/full_circle_web/receipt_capture.ex`, `read/3` and `finished/2` need no code change (they pass `extracted` through; `Prefill.build/4` takes the list). Update the `read/3` doc comment and the `@moduledoc` phrase "the first file is read by `Receipts.Extract`" to "the first file is read by `Receipts.Extract` (one or many receipts)".

Replace the summary block (the `<% ex = @receipt.extracted %>` line through the `<p :if={!ex.recognized} …>` line) with:

```heex
        <% docs = Enum.filter(@receipt.extracted, & &1.recognized) %>
        <p :for={ex <- docs}>
          <span class="font-medium">{ex.supplier_name || gettext("(no supplier name)")}</span>
          <span :if={ex.supplier_tin}> · TIN {ex.supplier_tin}</span>
          <span :if={ex.supplier_brn}> · BRN {ex.supplier_brn}</span>
          <span :if={ex.doc_no}> · #{ex.doc_no}</span>
          <span :if={ex.date}> · {ex.date}</span>
          <span :if={ex.total}> · {gettext("Total")} {ex.total}</span>
        </p>
        <p :if={docs == [] and @receipt.extracted != []} class="italic">
          {hd(@receipt.extracted).summary}
        </p>
```

- [ ] **Step 8: Run all receipt tests**

Run: `mix test test/full_circle/receipts test/full_circle_web/receipt_capture_test.exs test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs`
Expected: all PASS, no compile warnings.

- [ ] **Step 9: Format and commit**

```bash
mix format lib/full_circle/receipts/extract.ex lib/full_circle_web/receipt_capture.ex test/full_circle/receipts/extract_test.exs test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs
git add lib/full_circle/receipts/extract.ex lib/full_circle_web/receipt_capture.ex test/full_circle/receipts/extract_test.exs test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/pur_invoice_receipt_capture_live_test.exs
git commit -m "feat(receipts): read every receipt in a photo or multi-page PDF; 32k tokens, 180 s

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Skill contract and full suite

**Files:**
- Modify: `.claude/skills/receipt-capture.md`

**Interfaces:**
- Consumes: everything above.
- Produces: an up-to-date contract for future sessions.

- [ ] **Step 1: Update the skill**

In `.claude/skills/receipt-capture.md`:

Change the frontmatter `description` to:

```
description: Use when working on photo/PDF receipt capture on New Payment or New Purchase Invoice — Receipts.Extract (AI prompt, {"documents": […]} list contract, checks), Receipts.Prefill (field mapping, multi-receipt claims, funds account, SST/rounding lines, warnings), FullCircleWeb.ReceiptCapture (tray, blank-only merge, receipt note on save), or the "llm_receipt" AI settings.
```

Under `## Pipeline`, replace the first sentence's `(file → \`%Extracted{}\`)` with `(file → \`[%Extracted{}]\`, never empty)` and add after the pipeline paragraph:

```markdown
Multi-receipt spec: `docs/superpowers/specs/2026-10-11-multi-receipt-capture-design.md`.
```

Add these bullets to `## Contracts that bite`, after "Not recognised":

```markdown
- **List contract:** the AI replies `{"documents": [...]}`, one entry per bill or
  receipt (a bill across pages is one entry). `Extract.parse_documents/2` also
  takes the old single-object shape and never returns `[]`.
  `Prefill.build/4` takes the list: only recognised entries count (the rest
  are dropped with a warning). One → the struct clause, unchanged. PurInvoice →
  the first, plus "only the first was used". Payment with 2+ → `build_many/3`.
- **2+ receipts on a Payment (a claim):** no payee keys in the seed at all (the
  claimant isn't a shop; the merge keeps one picked first), `learn`/`duplicate`
  nil. One line per receipt, `"<shop> #<doc_no> <DD/MM/YYYY>"`, qty 1,
  price = total (0 + warning when none), date-sorted (undated last). Amount =
  sum, pay date = latest, Cash In Hand only if all cash. Per-receipt warnings
  are prefixed with `"<shop> #<doc_no>: "`. Cap 40 (in `Prefill`, read order).
- **Duplicate claims:** `claimed_warning/2` matches an earlier Payment line whose
  text holds `#<doc_no>` as a whole word (bound regex param, escaped) and whose
  `qty × price + discount` is within 0.01 (discount is stored ≤ 0). It depends
  on the line text above. Repeats inside one file warn too.
```

In the **Limits** bullet, change `90 s timeout; \`max_tokens\` 16_384` to `180 s timeout; \`max_tokens\` 32_768 (40 receipts with lines)`.

- [ ] **Step 2: Run the full suite**

Run: `mix test`
Expected: 0 failures (about 2400 tests). QueryRepo / punch-ingest log noise is harmless.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/receipt-capture.md
git commit -m "docs(skills): receipt capture — list contract, multi-receipt claims, new limits

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
