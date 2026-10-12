# Bank Bulk Payment Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn ticked supplier Payments into an RHB Reflex Bulk Pay CSV or a PB enterprise ECP Payment TXT file that the bank's maker uploads and the bank's approver approves.

**Architecture:** The shared `FullCircle.FileSpec` engine gains optional generic features (allowed sources, computed columns, child rows, CSV quoting, per-field character allow-lists, filename templates, `max_rows`), plus five PayScript text/maths builtins. A new `FullCircle.BankPayment` context owns versioned bank file formats, paying-account profiles, batches and batch lines. Supplier bank details live on `contacts` behind an admin/manager-only changeset. LiveViews follow the statutory file-format pages.

**Tech Stack:** Elixir 1.19.5 / OTP 28, Phoenix 1.8, Phoenix LiveView 1.2, Ecto + PostgreSQL, Tailwind 4.

**Spec:** `docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md`

## Spec clarifications made while planning (implement these, not the spec wording)

1. **Row date variable is `doc_date`**, not `payment_date`. `FileSpec.prepare_rows/2` merges the header context *over* each row, so a row key named `payment_date` would be overwritten by the batch's header `payment_date`. Rows carry `doc_date` (the Payment's own date); the header carries `payment_date` (the batch's chosen bank payment date).
2. **`record_id` comes from a Postgres sequence** (`bank_payment_record_seq`, `nextval`), not the gapless doc counter. It is never reused, which is all the banks require, and needs no per-company seed row.
3. **`computed` columns may only use row and header variables**, not each other. JSON objects decode to unordered maps, so "earlier ones" has no stable meaning.
4. **A bank spec declares the profile params it needs** in a top-level `"params": ["corporate_id", ...]` list. Format validation adds those names to the known variables; batch pre-flight and the profile form check the profile has them. `FileSpec` ignores the key.
5. **Header variable `batch_no`** = `YYYYMMDD` of today + 3-digit seq (e.g. `20261012001`, 11 chars). It fills RHB's 20-char "file batch number" in header and footer.
6. **Batch lines snapshot** `payment_no`, `doc_date`, `contact_name`, `descriptions` too, and the **batch stores its header context**, so "Download again" rebuilds a byte-identical file even if the contact, Payment or profile changed since.
7. **Payments have no delete path in `BillPay`**, so there is nothing to lock for delete. The Payment form shows a banner naming the batch; enforcement of the locked fields is in `BillPay.update_payment/4`.

## Global Constraints

- Use `use FullCircle.Schema` (binary_id keys) for every new schema; migrations get `binary_id` primary keys automatically.
- **Never run bare `mix format`** — it rewrites ~14 unrelated files. Run `mix format <the files you touched>` only.
- Commit directly on `master` (solo workflow). Commit message trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- LiveView warning flashes use kind **`:warn`** — `put_flash(:warning, …)` renders nothing.
- Every new UI colour must work in light **and** dark themes (pair `bg-*-100` with `dark:bg-*-900/30` or similar).
- Existing statutory specs must render byte-for-byte the same: `test/full_circle/file_spec_test.exs`, `test/full_circle/file_spec_parity_test.exs`, `test/full_circle/statutory_config_test.exs` and `test/full_circle/statutory_config/` must stay green after every FileSpec task.
- Roles: bank details view/edit `admin manager`; bank config (profiles, formats) `admin`; batch create/void/download `admin manager`; saved SQL queries create/update/delete/execute `admin manager`.
- Payment date for a batch: today … today + 59 days.
- RHB hash total: `floor((Σ last6(account_no) × last6(int(amount))) × 24 + 2994) / 285)`; PB hash total: total amount in cents + Σ first 4 digits of every beneficiary account number.
- Tests: `mix test <path>` (auto-creates/migrates the test DB). Credo is not installed — skip it.

## Review Focus

1. **Supplier name containing a comma or double quote in the RHB CSV** — must be wrapped in quotes with inner quotes doubled, not split into extra columns. Pinned in Task 3 (`quote`) and Task 10 (golden line with `Tan, Lee & Sons`).
2. **Supplier's bank details edited after a batch was exported** — "Download again" must still produce the original file from the line snapshot. Pinned in Task 11.
3. **A voided batch's filename** — the next batch on the same day must take the next sequence number, because banks refuse a filename already uploaded. Pinned in Task 11.
4. **Account number typed with spaces or dashes** (`1122-3344 5566`) — stored as digits only and length-checked against the bank. Pinned in Task 5.
5. **Editing a batched Payment's description** (not a locked field) — must still save; changing its amount must be refused naming the batch. Pinned in Task 12.

## File Structure

Create:
- `priv/repo/migrations/20261012100000_create_bank_payments.exs` — contact columns, 4 tables, sequence.
- `lib/full_circle/bank_payment.ex` — context: formats, profiles, eligibility, batches, rendering, payment lock.
- `lib/full_circle/bank_payment/banks.ex` — Malaysian bank list (name, BIC, valid account lengths).
- `lib/full_circle/bank_payment/file_format.ex` — `bank_file_formats` schema.
- `lib/full_circle/bank_payment/profile.ex` — `bank_payment_profiles` schema + params text helpers.
- `lib/full_circle/bank_payment/batch.ex` — `bank_payment_batches` schema.
- `lib/full_circle/bank_payment/batch_line.ex` — `bank_payment_batch_lines` schema.
- `lib/full_circle/bank_payment/rows.ex` — Payment → line snapshot → FileSpec row.
- `priv/bank_file_templates/rhb_bulk_pay.json`, `priv/bank_file_templates/pbb_ecp_payment.json`.
- `lib/full_circle_web/live/contact_live/bank_component.ex` — bank details block.
- `lib/full_circle_web/live/bank_file_format_live/index.ex`, `.../form.ex`.
- `lib/full_circle_web/live/bank_payment_profile_live/index.ex`, `.../form.ex`.
- `lib/full_circle_web/live/bank_batch_live/index.ex`.
- `lib/full_circle_web/controllers/bank_batch_controller.ex`.
- `test/support/fixtures/bank_payment_fixtures.ex`.
- Tests: `test/full_circle/file_spec_bank_test.exs`, `test/full_circle/bank_payment_test.exs`, `test/full_circle/bank_payment_golden_test.exs`, `test/full_circle/contact_bank_test.exs`, `test/full_circle/user_queries_auth_test.exs`, `test/full_circle_web/live/contact_bank_live_test.exs`, `test/full_circle_web/live/bank_setup_live_test.exs`, `test/full_circle_web/live/bank_batch_live_test.exs`.
- `.claude/skills/bank-bulk-payment.md` (drafted in Task 15, user confirms).

Modify:
- `lib/full_circle/pay_script/validator.ex`, `lib/full_circle/pay_script/evaluator.ex` — builtins.
- `lib/full_circle/file_spec.ex` — engine features.
- `lib/full_circle/accounting/contact.ex`, `lib/full_circle/accounting.ex` — bank fields + save.
- `lib/full_circle/authorization.ex` — new actions, query roles.
- `lib/full_circle/bill_pay.ex` — payment lock.
- `lib/full_circle_web/live/contact_live/form.ex`, `lib/full_circle_web/live/payment_live/form.ex`, `lib/full_circle_web/live/payment_live/index_component.ex`, `lib/full_circle_web/live/query_live/index.ex`, `lib/full_circle_web/live/query_live/form.ex`, `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, `lib/full_circle_web/router.ex`, `assets/js/app.js`.
- `CLAUDE.md` — skill list (Task 15).

---

### Task 1: PayScript builtins `left`, `right`, `mid`, `num`, `mod`

**Files:**
- Modify: `lib/full_circle/pay_script/validator.ex:6-20` (the `@builtins` map)
- Modify: `lib/full_circle/pay_script/evaluator.ex` (add clauses before `defp eval_call("lookup", …)`, add `eval_text/3` helper next to `eval_str/3`)
- Test: `test/full_circle/pay_script_text_builtins_test.exs`

**Interfaces:**
- Produces: PayScript expressions `left(text, n)`, `right(text, n)`, `mid(text, start, n)` (1-based), `num(text)` (number from the digits; `""` → 0; a number passes through), `mod(a, b)` (floored modulo; `mod(x, 0)` is an error). `left`/`right`/`mid` accept a number as text (`1000.0` → `"1000"`).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.PayScriptTextBuiltinsTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript

  defp ev(src, ctx \\ %{}), do: PayScript.eval_expression(src, ctx, nil)

  test "left/right/mid slice text" do
    ctx = %{"acct" => "112233374890"}
    assert {:ok, "1122"} = ev(~s|left(acct, 4)|, ctx)
    assert {:ok, "374890"} = ev(~s|right(acct, 6)|, ctx)
    assert {:ok, "2233"} = ev(~s|mid(acct, 3, 4)|, ctx)
    assert {:ok, "12"} = ev(~s|right("12", 6)|)
    assert {:ok, ""} = ev(~s|mid("abc", 9, 4)|)
  end

  test "left/right accept a whole number as text" do
    assert {:ok, "1000"} = ev(~s|left(amount, 6)|, %{"amount" => 1000.0})
  end

  test "num reads digits; blank is zero; numbers pass through" do
    assert {:ok, 374_890.0} = ev(~s|num("374890")|)
    assert {:ok, +0.0} = ev(~s|num("")|)
    assert {:ok, 12.5} = ev(~s|num(x)|, %{"x" => 12.5})
  end

  test "mod is floored modulo" do
    assert {:ok, 1000.0} = ev(~s|mod(1000, 1000000)|)
    assert {:ok, 234_567.0} = ev(~s|mod(1234567, 1000000)|)
    assert {:error, %{message: "mod by zero"}} = ev(~s|mod(5, 0)|)
  end

  test "validator knows the new builtins and their arity" do
    assert :ok = PayScript.validate("result = left(\"ab\", 1)")
    assert {:error, [err]} = PayScript.validate("result = mid(\"ab\", 1)")
    assert Exception.message(err) =~ "mid() takes 3 argument(s), got 2"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/pay_script_text_builtins_test.exs`
Expected: FAIL — `unknown function left/2` errors and validator "unknown function 'left'".

- [ ] **Step 3: Implement**

In `lib/full_circle/pay_script/validator.ex`, extend `@builtins`:

```elixir
  @builtins %{
    "min" => 2,
    "max" => 2,
    "ceil" => 1,
    "floor" => 1,
    "abs" => 1,
    "round" => 2,
    "upper" => 1,
    "lower" => 1,
    "trim" => 1,
    "replace" => 3,
    "left" => 2,
    "right" => 2,
    "mid" => 3,
    "num" => 1,
    "mod" => 2,
    "lookup" => 3,
    "ytd_sum" => 1,
    "calc" => 1
  }
```

In `lib/full_circle/pay_script/evaluator.ex`, insert directly **above** `defp eval_call("lookup", [t, v, c], vars, env) do`:

```elixir
  defp eval_call("left", [s, n], vars, env) do
    with {:ok, str} <- eval_text(s, vars, env),
         {:ok, k} <- eval_num(n, vars, env),
         do: {:ok, String.slice(str, 0, max(trunc(k), 0))}
  end

  defp eval_call("right", [s, n], vars, env) do
    with {:ok, str} <- eval_text(s, vars, env),
         {:ok, k} <- eval_num(n, vars, env) do
      k = max(trunc(k), 0)
      {:ok, String.slice(str, max(String.length(str) - k, 0), k)}
    end
  end

  defp eval_call("mid", [s, start, n], vars, env) do
    with {:ok, str} <- eval_text(s, vars, env),
         {:ok, st} <- eval_num(start, vars, env),
         {:ok, k} <- eval_num(n, vars, env),
         do: {:ok, String.slice(str, max(trunc(st) - 1, 0), max(trunc(k), 0))}
  end

  defp eval_call("num", [s], vars, env) do
    with {:ok, v} <- eval(s, vars, env) do
      cond do
        is_number(v) ->
          {:ok, v * 1.0}

        is_binary(v) ->
          case v |> String.replace(~r/[^0-9.\-]/, "") |> Float.parse() do
            {f, _} -> {:ok, f}
            :error -> {:ok, 0.0}
          end

        true ->
          {:error, %Error{message: "num expects text or a number, got #{value_label(v)}"}}
      end
    end
  end

  defp eval_call("mod", [a, b], vars, env) do
    with {:ok, x} <- eval_num(a, vars, env),
         {:ok, y} <- eval_num(b, vars, env) do
      if y == 0,
        do: {:error, %Error{message: "mod by zero"}},
        else: {:ok, x - y * Float.floor(x / y)}
    end
  end
```

Add next to `defp eval_str/3`:

```elixir
  # Text for the slicing builtins: a whole number reads as its digits, so
  # left(amount, 6) works on 1000.0 as "1000".
  defp eval_text(e, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      cond do
        is_binary(v) -> {:ok, v}
        is_number(v) and v == trunc(v) -> {:ok, Integer.to_string(trunc(v))}
        is_number(v) -> {:ok, Float.to_string(v * 1.0)}
        true -> {:error, %Error{message: "expected text, got #{value_label(v)}"}}
      end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/pay_script_text_builtins_test.exs test/full_circle/pay_script_test.exs test/full_circle/pay_script`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/pay_script/validator.ex lib/full_circle/pay_script/evaluator.ex test/full_circle/pay_script_text_builtins_test.exs
git add lib/full_circle/pay_script/validator.ex lib/full_circle/pay_script/evaluator.ex test/full_circle/pay_script_text_builtins_test.exs
git commit -m "feat(payscript): left/right/mid/num/mod builtins

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: FileSpec — allowed detail sources and `computed` columns

**Files:**
- Modify: `lib/full_circle/file_spec.ex` (`validate/2`, `render/4`, `validate_sections/3`, `validate_section/5`, new `validate_computed/3`, `apply_computed/2`, `computed_names/1`)
- Test: `test/full_circle/file_spec_bank_test.exs` (new; Tasks 3–4 add to it)

**Interfaces:**
- Produces: `FileSpec.validate(spec, variables, sources)` and `FileSpec.render(spec, rows, header_ctx, variables, sources)`. The 2-arity `validate/2` and 3/4-arity `render` keep `["statutory_rows"]`. Top-level spec key `"computed"`: `%{name => expression}`, evaluated per detail row (row + header variables) before filter/sort/aggregates; usable in fields, filters and `sum("name")`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.FileSpecBankTest do
  use ExUnit.Case, async: true

  alias FullCircle.FileSpec

  defp delimited(sections, extra \\ %{}) do
    Map.merge(%{"renderer" => "text", "delimiter" => ",", "sections" => sections}, extra)
  end

  describe "allowed sources" do
    test "validate/3 accepts a caller-allowed source" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}]}])
      assert :ok = FileSpec.validate(spec, ["name"], ["payments"])
    end

    test "validate/2 still only allows statutory_rows" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}]}])
      assert {:error, [msg]} = FileSpec.validate(spec, ["name"])
      assert msg =~ "statutory_rows"
    end
  end

  describe "computed" do
    test "computed columns render per row and sum in the footer" do
      spec =
        delimited(
          [
            %{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}, %{"expr" => "double", "format" => "decimal:0"}]},
            %{"kind" => "footer", "fields" => [%{"expr" => ~s|sum("double")|, "format" => "decimal:0"}]}
          ],
          %{"computed" => %{"double" => "amount * 2"}, "line_ending" => "\n"}
        )

      rows = [%{"name" => "a", "amount" => 1.5}, %{"name" => "b", "amount" => 2}]

      assert {:ok, "a,3\nb,4\n7\n"} = FileSpec.render(spec, rows, %{}, ["name", "amount"], ["payments"])
    end

    test "computed expressions are validated" do
      spec =
        delimited(
          [%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "x"}]}],
          %{"computed" => %{"x" => "nope + 1"}}
        )

      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "computed x: unknown identifier 'nope'"
    end

    test "computed must be a map" do
      spec = delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"computed" => ["x"]})
      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "computed must be a map"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/file_spec_bank_test.exs`
Expected: FAIL — `FileSpec.validate/3 is undefined`.

- [ ] **Step 3: Implement**

In `lib/full_circle/file_spec.ex`:

Add below `@section_kinds`:

```elixir
  @default_sources ["statutory_rows"]
```

Replace `validate/2` with:

```elixir
  @doc """
  Validates a spec map. `variables` is the list of allowed PayScript identifiers
  (detail-row keys plus header context keys). `sources` lists the detail
  `source` values the caller supplies rows for.
  """
  def validate(spec, variables) when is_map(spec) and is_list(variables),
    do: validate(spec, variables, @default_sources)

  def validate(spec, variables, sources)
      when is_map(spec) and is_list(variables) and is_list(sources) do
    row_variables = Enum.uniq(variables ++ computed_names(spec))

    errors =
      []
      |> validate_top_level(spec)
      |> validate_computed(spec, variables)
      |> validate_sections(spec, row_variables, sources)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end
```

Replace the `render` head and `with` with:

```elixir
  def render(spec, rows, header_ctx, variables \\ [], sources \\ @default_sources)
      when is_map(spec) and is_list(rows) and is_map(header_ctx) and is_list(variables) and
             is_list(sources) do
    with :ok <-
           validate(spec, Enum.uniq(variables ++ detail_variables(rows, header_ctx)), sources),
         {:ok, prepared} <- prepare_rows(rows, header_ctx),
         {:ok, prepared} <- apply_computed(spec, prepared),
         {:ok, lines} <- render_sections(spec, prepared, header_ctx) do
      ending = line_ending(spec)
      text = Enum.join(lines, ending) <> ending
      {:ok, text}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
    end
  end
```

Change `validate_sections/3` to `validate_sections/4`, threading `sources`:

```elixir
  defp validate_sections(errors, spec, variables, sources) do
    case Map.get(spec, "sections") do
      sections when is_list(sections) and sections != [] ->
        delimiter = Map.get(spec, "delimiter")

        sections
        |> Enum.with_index(1)
        |> Enum.reduce(errors, fn {section, idx}, acc ->
          validate_section(acc, section, idx, delimiter, variables, sources)
        end)

      _ ->
        ["sections must be a non-empty list" | errors]
    end
  end
```

Change `validate_section/5` to `validate_section/6`; replace its `statutory_rows` clause with:

```elixir
      section["kind"] == "detail" and section["source"] not in sources ->
        [
          "#{prefix}: detail section requires source " <>
            Enum.map_join(sources, " or ", &inspect/1)
          | errors
        ]
```

Add:

```elixir
  defp computed_names(spec) do
    case Map.get(spec, "computed") do
      m when is_map(m) -> Map.keys(m)
      _ -> []
    end
  end

  defp validate_computed(errors, spec, variables) do
    case Map.get(spec, "computed") do
      nil ->
        errors

      m when is_map(m) ->
        Enum.reduce(m, errors, fn
          {name, expr}, acc when is_binary(expr) ->
            case validate_expression(expr, variables, false) do
              :ok -> acc
              {:error, msgs} -> Enum.map(msgs, &"computed #{name}: #{&1}") ++ acc
            end

          {name, _}, acc ->
            ["computed #{name}: expression must be a string" | acc]
        end)

      _ ->
        ["computed must be a map of name => expression" | errors]
    end
  end

  defp apply_computed(spec, rows) do
    case Map.get(spec, "computed") do
      m when is_map(m) and map_size(m) > 0 ->
        try do
          {:ok, Enum.map(rows, &compute_row(&1, m))}
        catch
          {:computed_error, msg} -> {:error, msg}
        end

      _ ->
        {:ok, rows}
    end
  end

  defp compute_row(row, computed) do
    Enum.reduce(computed, row, fn {name, expr}, acc ->
      case PayScript.eval_expression(expr, row, nil) do
        {:ok, v} -> Map.put(acc, name, v)
        {:error, %Error{} = e} -> throw({:computed_error, "computed #{name}: #{Exception.message(e)}"})
      end
    end)
  end
```

- [ ] **Step 4: Run tests to verify they pass, including the statutory guard**

Run: `mix test test/full_circle/file_spec_bank_test.exs test/full_circle/file_spec_test.exs test/full_circle/file_spec_parity_test.exs test/full_circle/statutory_config_test.exs test/full_circle/statutory_config`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git add lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git commit -m "feat(filespec): caller-allowed detail sources and computed columns

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: FileSpec — child rows, CSV quoting, per-field `allow`

**Files:**
- Modify: `lib/full_circle/file_spec.ex` (`validate_top_level/2`, `validate_section/6`, `validate_field/5`, `render_sections/3`, `render_section/6`, `render_line/4`, `render_field/3`)
- Test: `test/full_circle/file_spec_bank_test.exs`

**Interfaces:**
- Produces spec keys: detail-section `"children": [%{"source" => list_key, "fields" => [...]}]` (child line per item, rendered right after its parent; child variables = parent row + item keys prefixed `"<source>_"`; children not counted in `count()`/`sum()`); top-level `"quote": "csv"` (delimited only); field `"allow": "<character-class body>"` (strips everything outside before padding).

- [ ] **Step 1: Write the failing tests** — append inside `FullCircle.FileSpecBankTest`:

```elixir
  describe "children" do
    test "child lines follow their parent and see parent + prefixed item keys" do
      spec =
        delimited(
          [
            %{
              "kind" => "detail",
              "source" => "payments",
              "fields" => [%{"expr" => ~s|"10"|}, %{"expr" => "no"}],
              "children" => [
                %{"source" => "advice", "fields" => [%{"expr" => ~s|"30"|}, %{"expr" => "no"}, %{"expr" => "advice_doc_no"}, %{"expr" => "advice_amount", "format" => "decimal:2"}]}
              ]
            },
            %{"kind" => "footer", "fields" => [%{"expr" => "count()", "format" => "decimal:0"}]}
          ],
          %{"line_ending" => "\n"}
        )

      rows = [
        %{"no" => "P1", "advice" => [%{"doc_no" => "I1", "amount" => Decimal.new("5")}, %{"doc_no" => "I2", "amount" => Decimal.new("6.5")}]},
        %{"no" => "P2", "advice" => []}
      ]

      vars = ["no", "advice", "advice_doc_no", "advice_amount"]

      assert {:ok, "10,P1\n30,P1,I1,5.00\n30,P1,I2,6.50\n10,P2\n2\n"} =
               FileSpec.render(spec, rows, %{}, vars, ["payments"])
    end

    test "a child needs a source and fields" do
      spec =
        delimited([
          %{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "no"}], "children" => [%{"fields" => [%{"expr" => "no"}]}]}
        ])

      assert {:error, [msg]} = FileSpec.validate(spec, ["no"], ["payments"])
      assert msg =~ "child 1: source is required"
    end
  end

  describe "quote csv" do
    test "wraps values holding the delimiter or quotes, doubling inner quotes" do
      spec =
        delimited(
          [%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}, %{"expr" => "note"}]}],
          %{"quote" => "csv", "line_ending" => "\n"}
        )

      rows = [%{"name" => "Tan, Lee & Sons", "note" => ~s|say "hi"|}, %{"name" => "Plain", "note" => "x"}]

      assert {:ok, ~s|"Tan, Lee & Sons","say ""hi"""\nPlain,x\n|} =
               FileSpec.render(spec, rows, %{}, ["name", "note"], ["payments"])
    end

    test "quote needs a delimiter" do
      spec = %{"renderer" => "text", "quote" => "csv", "sections" => [%{"kind" => "header", "fields" => [%{"expr" => "1", "width" => 1}]}]}
      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "quote requires a delimiter"
    end
  end

  describe "allow" do
    test "strips characters outside the class before padding" do
      spec = %{
        "renderer" => "text",
        "line_ending" => "\n",
        "sections" => [%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name", "width" => 12, "allow" => "A-Za-z0-9 "}]}]
      }

      assert {:ok, "Tan  Sons M \n"} =
               FileSpec.render(spec, [%{"name" => "Tan & Sons (M)"}], %{}, ["name"], ["payments"])
    end

    test "an invalid class is rejected" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name", "allow" => "z-a"}]}])
      assert {:error, [msg]} = FileSpec.validate(spec, ["name"], ["payments"])
      assert msg =~ "allow is not a valid character class"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/file_spec_bank_test.exs`
Expected: FAIL — children/quote/allow ignored or not validated.

- [ ] **Step 3: Implement**

`validate_top_level/2` gains two steps:

```elixir
  defp validate_top_level(errors, spec) do
    errors
    |> validate_renderer(spec)
    |> validate_line_ending(spec)
    |> validate_delimiter(spec)
    |> validate_extension(spec)
    |> validate_quote(spec)
  end

  defp validate_quote(errors, spec) do
    case Map.get(spec, "quote") do
      nil ->
        errors

      "csv" ->
        if Map.get(spec, "delimiter"), do: errors, else: ["quote requires a delimiter" | errors]

      other ->
        ["quote must be \"csv\", got #{inspect(other)}" | errors]
    end
  end
```

In `validate_section/6`'s `true ->` branch, append the children check:

```elixir
      true ->
        allow_aggregates = section["kind"] in ["header", "footer"]

        errors
        |> validate_filter(section, prefix, variables, allow_aggregates)
        |> validate_sort(section, prefix)
        |> validate_fields(section, prefix, delimiter, variables, allow_aggregates)
        |> validate_children(section, prefix, delimiter, variables)
```

Add:

```elixir
  defp validate_children(errors, %{"kind" => "detail"} = section, prefix, delimiter, variables) do
    case Map.get(section, "children") do
      nil ->
        errors

      children when is_list(children) ->
        children
        |> Enum.with_index(1)
        |> Enum.reduce(errors, fn {child, idx}, acc ->
          cprefix = "#{prefix}, child #{idx}"

          cond do
            not is_map(child) -> ["#{cprefix}: must be a map" | acc]
            not is_binary(child["source"]) -> ["#{cprefix}: source is required" | acc]
            true -> validate_fields(acc, child, cprefix, delimiter, variables, false)
          end
        end)

      _ ->
        ["#{prefix}: children must be a list" | errors]
    end
  end

  defp validate_children(errors, _section, _prefix, _delimiter, _variables), do: errors
```

In `validate_field/5`, add `|> validate_field_allow(field, prefix)` after `|> validate_field_pad(field, prefix)`, and add:

```elixir
  defp validate_field_allow(errors, field, prefix) do
    case Map.get(field, "allow") do
      nil ->
        errors

      allow when is_binary(allow) and allow != "" ->
        case Regex.compile("[^" <> allow <> "]", "u") do
          {:ok, _} -> errors
          {:error, _} -> ["#{prefix}: allow is not a valid character class" | errors]
        end

      other ->
        ["#{prefix}: allow must be a non-empty string, got #{inspect(other)}" | errors]
    end
  end
```

Rendering: replace `render_sections/3`, both `render_section/6` clauses, and `render_line/4` with a `fmt` map version, and add `render_children/3`, `quote_value/3`, `apply_allow/2`:

```elixir
  defp render_sections(spec, rows, header_ctx) do
    fmt = %{delimiter: Map.get(spec, "delimiter"), quote: Map.get(spec, "quote")}
    ctx = stringify_map(header_ctx)

    try do
      detail_section = Enum.find(spec["sections"], &(&1["kind"] == "detail"))

      filtered_detail =
        if detail_section do
          rows
          |> apply_filter(Map.get(detail_section, "filter"))
          |> apply_sort(Map.get(detail_section, "sort"))
        else
          []
        end

      aggregates = compute_aggregates(filtered_detail)

      lines =
        Enum.flat_map(spec["sections"], fn section ->
          render_section(section, rows, ctx, fmt, aggregates)
        end)

      {:ok, lines}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp render_section(%{"kind" => "detail"} = section, rows, _ctx, fmt, _aggregates) do
    rows
    |> apply_filter(Map.get(section, "filter"))
    |> apply_sort(Map.get(section, "sort"))
    |> Enum.flat_map(fn row ->
      [render_line(section["fields"], row, fmt, @no_aggregates) | render_children(section, row, fmt)]
    end)
  end

  defp render_section(section, _rows, ctx, fmt, aggregates) do
    [render_line(section["fields"], ctx, fmt, aggregates)]
  end

  defp render_children(section, row, fmt) do
    Enum.flat_map(Map.get(section, "children", []), fn child ->
      source = child["source"]

      row
      |> Map.get(source, [])
      |> List.wrap()
      |> Enum.map(fn item ->
        item_vars = Map.new(item, fn {k, v} -> {"#{source}_#{k}", normalize_value(v)} end)
        render_line(child["fields"], Map.merge(row, item_vars), fmt, @no_aggregates)
      end)
    end)
  end

  defp render_line(fields, ctx, fmt, aggregates) do
    rendered = Enum.map(fields, &render_field(&1, ctx, aggregates))

    case fmt.delimiter do
      nil -> Enum.join(rendered, "")
      d -> rendered |> Enum.map(&quote_value(&1, d, fmt.quote)) |> Enum.join(d)
    end
  end

  defp quote_value(value, delimiter, "csv") do
    if String.contains?(value, [delimiter, "\"", "\r", "\n"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end

  defp quote_value(value, _delimiter, _quote), do: value
```

Add near the top of the module (with the other attributes):

```elixir
  @no_aggregates %{count: 0, sums: %{}}
```

In `render_field/3`, change the success branch to:

```elixir
      value
      |> format_value(Map.get(field, "format", "text"))
      |> apply_allow(Map.get(field, "allow"))
      |> pad_value(field)
```

and add:

```elixir
  defp apply_allow(text, nil), do: text
  defp apply_allow(text, allow), do: String.replace(text, Regex.compile!("[^" <> allow <> "]", "u"), "")
```

- [ ] **Step 4: Run tests to verify they pass, including the statutory guard**

Run: `mix test test/full_circle/file_spec_bank_test.exs test/full_circle/file_spec_test.exs test/full_circle/file_spec_parity_test.exs test/full_circle/statutory_config_test.exs test/full_circle/statutory_config`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git add lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git commit -m "feat(filespec): child rows, CSV quoting and per-field allow lists

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: FileSpec — `filename` template and `max_rows`

**Files:**
- Modify: `lib/full_circle/file_spec.ex` (`validate/3`, `validate_top_level/2`; new `filename/3`, `max_rows/1`, `validate_filename/3`, `validate_max_rows/2`)
- Test: `test/full_circle/file_spec_bank_test.exs`

**Interfaces:**
- Produces: `FileSpec.filename(spec, ctx :: map, seq :: pos_integer | nil) :: String.t() | nil` — `nil` when the spec has no `"filename"`; `seq: nil` renders the sequence part as `""` (the "stem" used to number files). Tokens: `{name}`, `{name:%d%m%Y}` (strftime, Date values), `{seq:N}` (zero-padded to N). Non `[A-Za-z0-9._-]` characters in inserted values are dropped. `FileSpec.max_rows(spec) :: pos_integer | nil`.

- [ ] **Step 1: Write the failing tests** — append inside `FullCircle.FileSpecBankTest`:

```elixir
  describe "filename" do
    @tpl "PAYMENT_{corporate_id}_{today:%d%m%Y}_{seq:3}.CSV"

    test "renders values, dates and a padded sequence" do
      spec = %{"filename" => @tpl}
      ctx = %{"corporate_id" => "123456", "today" => ~D[2026-10-12]}
      assert FileSpec.filename(spec, ctx, 7) == "PAYMENT_123456_12102026_007.CSV"
      assert FileSpec.filename(spec, ctx, nil) == "PAYMENT_123456_12102026_.CSV"
    end

    test "drops unsafe characters from inserted values" do
      assert FileSpec.filename(%{"filename" => "{acct}PM.txt"}, %{"acct" => "3123-456 789"}, 1) == "3123456789PM.txt"
    end

    test "nil without a template" do
      assert FileSpec.filename(%{}, %{}, 1) == nil
    end

    test "unknown names are rejected" do
      spec = delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"filename" => "{nope}_{seq:2}.txt"})
      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "filename: unknown name 'nope'"
    end
  end

  describe "max_rows" do
    test "reads a positive integer" do
      assert FileSpec.max_rows(%{"max_rows" => 100}) == 100
      assert FileSpec.max_rows(%{}) == nil
    end

    test "rejects anything else" do
      spec = delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"max_rows" => 0})
      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "max_rows must be a positive integer"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/file_spec_bank_test.exs`
Expected: FAIL — `FileSpec.filename/3 is undefined`.

- [ ] **Step 3: Implement**

Add attribute:

```elixir
  @filename_token ~r/\{([A-Za-z_][A-Za-z0-9_]*)(?::([^}]*))?\}/
```

In `validate/3`, add `|> validate_filename(spec, variables)` after `validate_computed`. In `validate_top_level/2`, add `|> validate_max_rows(spec)` after `validate_quote`. Add:

```elixir
  @doc """
  Renders the spec's `filename` template, or nil when it has none. `seq: nil`
  leaves the sequence part out, giving the stem shared by files that differ
  only by sequence number.
  """
  def filename(spec, ctx, seq) when is_map(spec) and is_map(ctx) do
    case Map.get(spec, "filename") do
      nil ->
        nil

      tpl ->
        ctx = stringify_map(ctx)
        Regex.replace(@filename_token, tpl, fn _, name, opt -> filename_part(name, opt, ctx, seq) end)
    end
  end

  @doc "Most detail rows per file, or nil for no limit."
  def max_rows(spec) when is_map(spec), do: Map.get(spec, "max_rows")

  defp filename_part("seq", _opt, _ctx, nil), do: ""

  defp filename_part("seq", opt, _ctx, seq) do
    width =
      case Integer.parse(opt) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    seq |> Integer.to_string() |> String.pad_leading(width, "0")
  end

  defp filename_part(name, opt, ctx, _seq) do
    case Map.get(ctx, name) do
      %Date{} = d when opt != "" -> Calendar.strftime(d, opt)
      v -> v |> to_string() |> String.replace(~r/[^A-Za-z0-9._-]/, "")
    end
  end

  defp validate_filename(errors, spec, variables) do
    case Map.get(spec, "filename") do
      nil ->
        errors

      tpl when is_binary(tpl) and tpl != "" ->
        @filename_token
        |> Regex.scan(tpl, capture: :all_but_first)
        |> Enum.reduce(errors, fn [name | _], acc ->
          if name == "seq" or name in variables,
            do: acc,
            else: ["filename: unknown name '#{name}'" | acc]
        end)

      other ->
        ["filename must be a non-empty string, got #{inspect(other)}" | errors]
    end
  end

  defp validate_max_rows(errors, spec) do
    case Map.get(spec, "max_rows") do
      nil -> errors
      n when is_integer(n) and n > 0 -> errors
      other -> ["max_rows must be a positive integer, got #{inspect(other)}" | errors]
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass, including the statutory guard**

Run: `mix test test/full_circle/file_spec_bank_test.exs test/full_circle/file_spec_test.exs test/full_circle/file_spec_parity_test.exs test/full_circle/statutory_config_test.exs test/full_circle/statutory_config`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git add lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git commit -m "feat(filespec): filename templates and max_rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Supplier bank details on contacts (data, validation, permission, log)

**Files:**
- Create: `priv/repo/migrations/20261012100000_create_bank_payments.exs` (whole migration for the feature — contact columns now, tables used from Task 8)
- Create: `lib/full_circle/bank_payment/banks.ex`
- Modify: `lib/full_circle/accounting/contact.ex` (fields + `bank_changeset/2`)
- Modify: `lib/full_circle/accounting.ex` (`save_contact_bank/4`)
- Modify: `lib/full_circle/authorization.ex` (`:manage_contact_bank` and the other bank actions)
- Test: `test/full_circle/contact_bank_test.exs`

**Interfaces:**
- Produces: `FullCircle.BankPayment.Banks.all/0 :: [%{name, bic, lengths}]`, `get(bic) :: map | nil`, `name(bic) :: String.t() | nil`, `options/0 :: [{label, bic}]`.
- Produces: `Contact.bank_changeset(contact, attrs)`; `Accounting.save_contact_bank(contact, attrs, company, user) :: {:ok, Contact} | {:error, Changeset} | :not_authorise`; log entity `"contact_bank"`, action `"update_contact_bank"`.
- Produces: `can?(user, :manage_contact_bank | :manage_bank_payment_config | :create_bank_payment_batch | :void_bank_payment_batch, company)`.

- [ ] **Step 1: Write the migration** (whole feature; later tasks rely on these tables)

```elixir
defmodule FullCircle.Repo.Migrations.CreateBankPayments do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      add :bank_code, :string
      add :bank_account_no, :string
      add :bank_account_name, :string
      add :bank_details_changed_at, :utc_datetime
    end

    create table(:bank_file_formats) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :effective_from, :date, null: false
      add :spec, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_file_formats, [:company_id, :code, :effective_from],
             name: :bank_file_formats_unique_code_effective
           )

    create table(:bank_payment_profiles) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :format_code, :string, null: false
      add :our_account_no, :string, null: false
      add :start_date, :date, null: false
      add :params, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_payment_profiles, [:company_id, :account_id])

    create table(:bank_payment_batches) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :profile_id, references(:bank_payment_profiles, on_delete: :delete_all), null: false
      add :format_id, references(:bank_file_formats, on_delete: :delete_all), null: false
      add :payment_date, :date, null: false
      add :filename_stem, :string, null: false
      add :filename, :string, null: false
      add :seq, :integer, null: false
      add :header, :map, null: false
      add :count, :integer, null: false
      add :total, :decimal, null: false
      add :status, :string, null: false, default: "exported"
      add :void_reason, :string
      add :voided_by_id, references(:users, on_delete: :nilify_all)
      add :voided_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_payment_batches, [:company_id, :filename])
    create index(:bank_payment_batches, [:company_id, :filename_stem])

    # Banks require a record id that is never reused; a sequence never hands
    # the same number out twice, even across voided batches.
    execute "CREATE SEQUENCE bank_payment_record_seq", "DROP SEQUENCE bank_payment_record_seq"

    create table(:bank_payment_batch_lines) do
      add :batch_id, references(:bank_payment_batches, on_delete: :delete_all), null: false
      add :payment_id, references(:payments, on_delete: :delete_all), null: false
      add :record_no, :bigint, null: false
      add :live, :boolean, null: false, default: true
      add :payment_no, :string, null: false
      add :doc_date, :date, null: false
      add :amount, :decimal, null: false
      add :bank_code, :string, null: false
      add :bank_account_no, :string, null: false
      add :bank_account_name, :string, null: false
      add :contact_name, :string, null: false
      add :email, :string
      add :reg_no, :string
      add :descriptions, :string
      add :advice, {:array, :map}, null: false, default: []
    end

    # A Payment is in at most one non-voided batch, so it is never paid twice by file.
    create unique_index(:bank_payment_batch_lines, [:payment_id],
             where: "live",
             name: :bank_payment_batch_lines_one_live_per_payment
           )

    create unique_index(:bank_payment_batch_lines, [:record_no])
    create index(:bank_payment_batch_lines, [:batch_id])
  end
end
```

Run: `mix ecto.migrate`
Expected: migration runs cleanly.

- [ ] **Step 2: Write the failing test**

```elixir
defmodule FullCircle.ContactBankTest do
  use FullCircle.DataCase

  alias FullCircle.{Accounting, Repo, StdInterface}
  alias FullCircle.Accounting.Contact
  alias FullCircle.BankPayment.Banks
  alias FullCircle.Sys.Log

  import FullCircle.BillingFixtures
  import Ecto.Query

  setup do
    billing_setup()
  end

  describe "authorization" do
    test_authorise_to(:manage_contact_bank, ["admin", "manager"])
    test_authorise_to(:manage_bank_payment_config, ["admin"])
    test_authorise_to(:create_bank_payment_batch, ["admin", "manager"])
    test_authorise_to(:void_bank_payment_batch, ["admin", "manager"])
  end

  describe "Banks" do
    test "has Maybank with 12 digits and Public Bank's own BICs" do
      assert %{name: "Malayan Banking Berhad (Maybank)", lengths: [12]} = Banks.get("MBBEMYKL")
      assert Banks.get("PBBEMYKL")
      assert Banks.get("PIBEMYK1")
      assert Banks.get("NOPE") == nil
      assert {"RHB Bank Berhad", "RHBBMYKL"} in Banks.options()
    end
  end

  describe "save_contact_bank/4" do
    test "strips non-digits, stamps the change time and logs under contact_bank", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)

      assert {:ok, c} =
               Accounting.save_contact_bank(
                 c,
                 %{"bank_code" => "MBBEMYKL", "bank_account_no" => "1122-3344 5566", "bank_account_name" => " Tan Sdn Bhd "},
                 company,
                 admin
               )

      assert c.bank_account_no == "112233445566"
      assert c.bank_account_name == "Tan Sdn Bhd"
      assert c.bank_details_changed_at

      assert [%Log{action: "update_contact_bank"}] =
               Repo.all(from l in Log, where: l.entity == "contact_bank" and l.entity_id == ^c.id)

      assert Repo.all(from l in Log, where: l.entity == "contacts" and l.entity_id == ^c.id and l.action == "update_contact_bank") == []
    end

    test "all three fields together or none", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)
      assert {:error, cs} = Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL"}, company, admin)
      assert "required when bank details are filled" in errors_on(cs).bank_account_no
      assert {:ok, _} = Accounting.save_contact_bank(c, %{"bank_code" => "", "bank_account_no" => "", "bank_account_name" => ""}, company, admin)
    end

    test "account length must suit the bank", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)

      assert {:error, cs} =
               Accounting.save_contact_bank(c, %{"bank_code" => "RHBBMYKL", "bank_account_no" => "12345", "bank_account_name" => "X"}, company, admin)

      assert [msg] = errors_on(cs).bank_account_no
      assert msg =~ "must be 14 digits for RHB Bank Berhad"
    end

    test "clerks may not", %{company: company, admin: admin} do
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)
      c = contact_fixture(company, admin)
      assert :not_authorise = Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL"}, company, clerk)
    end
  end

  test "the ordinary contact changeset never writes bank fields", %{company: company, admin: admin} do
    c = contact_fixture(company, admin)

    {:ok, c} =
      StdInterface.update(Contact, "contact", c, %{"name" => c.name, "bank_account_no" => "999999999999", "bank_code" => "MBBEMYKL"}, company, admin)

    assert c.bank_account_no == nil
    assert c.bank_code == nil
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/full_circle/contact_bank_test.exs`
Expected: FAIL — `FullCircle.BankPayment.Banks` undefined.

- [ ] **Step 4: Implement**

`lib/full_circle/bank_payment/banks.ex`:

```elixir
defmodule FullCircle.BankPayment.Banks do
  @moduledoc """
  Malaysian banks for supplier bank details: name, BIC and valid savings/current
  account number lengths, from PB enterprise's "Interbank GIRO (IBG)
  Participating Financial Institutions" list, plus Public Bank and Public
  Islamic Bank, which that list leaves out because it is Public Bank's own.
  """

  @banks [
    {"Affin Bank Berhad", "PHBMMYKL", [12]},
    {"Affin Islamic Bank Berhad", "AIBBMYKL", [12]},
    {"Agrobank (Bank Pertanian Malaysia Berhad)", "AGOBMYKL", [16]},
    {"Al Rajhi Banking & Investment Corporation (Malaysia) Berhad", "RJHIMYKL", [15]},
    {"Alliance Bank Malaysia Berhad", "MFBBMYKL", [15]},
    {"Alliance Islamic Bank Berhad", "ALSRMYKL", [15]},
    {"AmBank (M) Berhad", "ARBKMYKL", [13]},
    {"AmBank Islamic Berhad", "AISLMYKL", [13]},
    {"Bangkok Bank Berhad", "BKKBMYKL", [13]},
    {"Bank Islam Malaysia Berhad", "BIMBMYKL", [14]},
    {"Bank Kerjasama Rakyat Malaysia Berhad", "BKRMMYKL", [12]},
    {"Bank Muamalat Malaysia Berhad", "BMMBMYKL", [14]},
    {"Bank of America Malaysia Berhad", "BOFAMY2X", Enum.to_list(5..17)},
    {"Bank of China (Malaysia) Berhad", "BKCHMYKL", [13, 15]},
    {"Bank Simpanan Nasional", "BSNAMYK1", [16]},
    {"BNP Paribas Malaysia Berhad", "BNPAMYKL", Enum.to_list(6..16)},
    {"China Construction Bank (Malaysia) Berhad", "PCBCMYKL", [12]},
    {"CIMB Bank Berhad", "CIBBMYKL", [10, 14]},
    {"CIMB Islamic Bank Berhad", "CTBBMYKL", [10, 14]},
    {"Citibank Berhad", "CITIMYKL", Enum.to_list(9..16)},
    {"Deutsche Bank (Malaysia) Berhad", "DEUTMYKL", Enum.to_list(10..17)},
    {"Hong Leong Bank Berhad", "HLBBMYKL", [11, 13]},
    {"Hong Leong Islamic Bank Berhad", "HLIBMYKL", [11, 13]},
    {"HSBC Amanah Malaysia Berhad", "HMABMYKL", [12, 13, 14, 15, 17]},
    {"HSBC Bank Malaysia Berhad", "HBMBMYKL", [12, 13, 14, 15, 17]},
    {"Industrial and Commercial Bank of China (Malaysia) Berhad", "ICBKMYKL", [19]},
    {"J.P. Morgan Chase Bank Berhad", "CHASMYKX", Enum.to_list(10..17)},
    {"Kuwait Finance House (Malaysia) Berhad", "KFHOMYKL", [12]},
    {"Malayan Banking Berhad (Maybank)", "MBBEMYKL", [12]},
    {"Maybank Islamic Berhad", "MBISMYKL", [12]},
    {"MBSB Bank Berhad", "AFBQMYKL", [16]},
    {"Mizuho Bank (Malaysia) Berhad", "MHCBMYKA", [10]},
    {"MUFG Bank (Malaysia) Berhad", "BOTKMYKX", [6]},
    {"OCBC Al-Amin Bank Berhad", "OABBMYKL", Enum.to_list(9..17)},
    {"OCBC Bank (Malaysia) Berhad", "OCBCMYKL", Enum.to_list(9..17)},
    {"Public Bank Berhad", "PBBEMYKL", [10]},
    {"Public Islamic Bank Berhad", "PIBEMYK1", [10]},
    {"RHB Bank Berhad", "RHBBMYKL", [14]},
    {"RHB Islamic Bank Berhad", "RHBAMYKL", [14]},
    {"Standard Chartered Bank Malaysia Berhad", "SCBLMYKX", Enum.to_list(5..17)},
    {"Standard Chartered Saadiq Berhad", "SCSRMYKK", Enum.to_list(5..17)},
    {"Sumitomo Mitsui Banking Corporation Malaysia Berhad", "SMBCMYKL", [8]},
    {"United Overseas Bank (Malaysia) Berhad", "UOVBMYKL", [7, 9, 10, 11, 12, 13, 14, 17]}
  ]

  def all, do: Enum.map(@banks, fn {name, bic, lengths} -> %{name: name, bic: bic, lengths: lengths} end)

  def get(nil), do: nil
  def get(bic), do: Enum.find(all(), &(&1.bic == bic))

  def name(bic) do
    case get(bic) do
      nil -> nil
      bank -> bank.name
    end
  end

  def options, do: Enum.map(all(), &{&1.name, &1.bic})
end
```

`lib/full_circle/accounting/contact.ex` — add to the schema after `field :misc_code, :string`:

```elixir
    # Supplier bank details for bank payment files. Written only through
    # bank_changeset/2 (admin/manager); changeset/2 never casts them.
    field :bank_code, :string
    field :bank_account_no, :string
    field :bank_account_name, :string
    field :bank_details_changed_at, :utc_datetime
```

and add after `changeset/2`:

```elixir
  @bank_fields [:bank_code, :bank_account_no, :bank_account_name]

  def bank_changeset(contact, attrs) do
    contact
    |> cast(attrs, @bank_fields)
    |> update_change(:bank_account_no, &(&1 && String.replace(&1, ~r/\D/, "")))
    |> update_change(:bank_account_name, &(&1 && String.trim(&1)))
    |> validate_bank_details()
    |> stamp_bank_change()
  end

  defp validate_bank_details(cs) do
    values = Enum.map(@bank_fields, &get_field(cs, &1))

    cond do
      Enum.all?(values, &(&1 in [nil, ""])) ->
        cs

      Enum.any?(values, &(&1 in [nil, ""])) ->
        Enum.reduce(@bank_fields, cs, fn f, acc ->
          if get_field(acc, f) in [nil, ""],
            do: add_error(acc, f, gettext("required when bank details are filled")),
            else: acc
        end)

      true ->
        validate_account_length(cs)
    end
  end

  defp validate_account_length(cs) do
    case FullCircle.BankPayment.Banks.get(get_field(cs, :bank_code)) do
      nil ->
        add_error(cs, :bank_code, gettext("not in list"))

      bank ->
        if String.length(get_field(cs, :bank_account_no)) in bank.lengths,
          do: cs,
          else:
            add_error(
              cs,
              :bank_account_no,
              gettext("must be %{lengths} digits for %{bank}",
                lengths: Enum.join(bank.lengths, "/"),
                bank: bank.name
              )
            )
    end
  end

  defp stamp_bank_change(cs) do
    if Enum.any?(@bank_fields, &Map.has_key?(cs.changes, &1)),
      do: put_change(cs, :bank_details_changed_at, DateTime.utc_now() |> DateTime.truncate(:second)),
      else: cs
  end
```

`lib/full_circle/accounting.ex` — add near the other contact functions (e.g. after `get_contact_by_name/3`):

```elixir
  @doc """
  Saves a contact's bank details. Admin/manager only. Logged under entity
  "contact_bank" so the contact's ordinary log, which any contact editor sees,
  never shows account numbers.
  """
  def save_contact_bank(%Contact{} = contact, attrs, com, user) do
    if can?(user, :manage_contact_bank, com) do
      Multi.new()
      |> Multi.update(:update_contact_bank, Contact.bank_changeset(contact, attrs))
      |> Multi.insert(:log, fn %{update_contact_bank: c} ->
        Sys.Log.changeset(%Sys.Log{}, %{
          entity: "contact_bank",
          entity_id: c.id,
          action: "update_contact_bank",
          delta: Sys.attr_to_string(attrs),
          user_id: user.id,
          company_id: com.id
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{update_contact_bank: c}} -> {:ok, c}
        {:error, :update_contact_bank, cs, _} -> {:error, cs}
      end
    else
      :not_authorise
    end
  end
```

If `Contact` is not already aliased in `accounting.ex`, add it to the `alias FullCircle.Accounting.{...}` list.

`lib/full_circle/authorization.ex` — add below the `:manage_statutory_config` clause:

```elixir
  def can?(user, :manage_contact_bank, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :manage_bank_payment_config, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :create_bank_payment_batch, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :void_bank_payment_batch, company),
    do: allow_roles(~w(admin manager), company, user)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/full_circle/contact_bank_test.exs test/full_circle_web/live/contact_live_test.exs test/full_circle/accounting_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
mix format priv/repo/migrations/20261012100000_create_bank_payments.exs lib/full_circle/bank_payment/banks.ex lib/full_circle/accounting/contact.ex lib/full_circle/accounting.ex lib/full_circle/authorization.ex test/full_circle/contact_bank_test.exs
git add priv/repo/migrations/20261012100000_create_bank_payments.exs lib/full_circle/bank_payment/banks.ex lib/full_circle/accounting/contact.ex lib/full_circle/accounting.ex lib/full_circle/authorization.ex test/full_circle/contact_bank_test.exs
git commit -m "feat(contacts): supplier bank details, admin/manager only, own audit log

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Contact form bank details block

**Files:**
- Create: `lib/full_circle_web/live/contact_live/bank_component.ex`
- Modify: `lib/full_circle_web/live/contact_live/form.ex` (assign `can_bank`, render the component after the contact `</.form>`)
- Test: `test/full_circle_web/live/contact_bank_live_test.exs`

**Interfaces:**
- Consumes: `Accounting.save_contact_bank/4`, `Contact.bank_changeset/2`, `Banks.options/0` (Task 5).
- Produces: live component `FullCircleWeb.ContactLive.BankComponent` (assigns `contact`, `current_company`, `current_user`), form id `contact-bank-form`, param key `contact_bank`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.ContactBankLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    contact = contact_fixture(com, admin)
    %{admin: admin, com: com, contact: contact}
  end

  defp conn_as(com, admin, role) do
    user = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, user, role, admin)
    log_in_user(build_conn(), user)
  end

  test "a manager sees and saves bank details", %{admin: admin, com: com, contact: contact} do
    conn = conn_as(com, admin, "manager")
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")
    assert html =~ "Bank details"

    lv
    |> form("#contact-bank-form", %{
      "contact_bank" => %{"bank_code" => "MBBEMYKL", "bank_account_no" => "112233445566", "bank_account_name" => "Tan"}
    })
    |> render_submit()

    assert render(lv) =~ "Saved"
    assert FullCircle.Repo.get!(FullCircle.Accounting.Contact, contact.id).bank_account_no == "112233445566"
  end

  test "a clerk never sees the bank block", %{admin: admin, com: com, contact: contact} do
    conn = conn_as(com, admin, "clerk")
    {:ok, _lv, html} = live(conn, ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")
    refute html =~ "Bank details"
    refute html =~ "contact-bank-form"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/live/contact_bank_live_test.exs`
Expected: FAIL — "Bank details" not in html.

- [ ] **Step 3: Implement**

`lib/full_circle_web/live/contact_live/bank_component.ex`:

```elixir
defmodule FullCircleWeb.ContactLive.BankComponent do
  @moduledoc "Supplier bank details on the contact form. Rendered only for :manage_contact_bank."
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting
  alias FullCircle.Accounting.Contact
  alias FullCircle.BankPayment.Banks

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:saved, fn -> false end)
     |> assign(form: to_form(Contact.bank_changeset(assigns.contact, %{}), as: :contact_bank))}
  end

  @impl true
  def handle_event("validate", %{"contact_bank" => params}, socket) do
    cs = socket.assigns.contact |> Contact.bank_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs, as: :contact_bank), saved: false)}
  end

  @impl true
  def handle_event("save", %{"contact_bank" => params}, socket) do
    case Accounting.save_contact_bank(
           socket.assigns.contact,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> assign(contact: contact, saved: true)
         |> assign(form: to_form(Contact.bank_changeset(contact, %{}), as: :contact_bank))}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :validate), as: :contact_bank), saved: false)}

      :not_authorise ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="mt-2 border rounded-lg border-emerald-500 bg-emerald-50 dark:bg-emerald-900/30 p-2"
    >
      <p class="font-semibold">{gettext("Bank details")}</p>
      <.form
        for={@form}
        id="contact-bank-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-5">
            <.input
              field={@form[:bank_code]}
              type="select"
              label={gettext("Bank")}
              options={Banks.options()}
              prompt={gettext("-- none --")}
            />
          </div>
          <div class="col-span-3">
            <.input field={@form[:bank_account_no]} label={gettext("Account No")} inputmode="numeric" />
          </div>
          <div class="col-span-4">
            <.input
              field={@form[:bank_account_name]}
              label={gettext("Account Holder Name")}
              value={@form[:bank_account_name].value || @contact.name}
            />
          </div>
        </div>
        <div class="flex justify-center items-center gap-x-2 mt-1">
          <button type="submit" class="blue button" id="save-bank">
            {gettext("Save Bank Details")}
          </button>
          <span :if={@saved} class="text-emerald-700 dark:text-emerald-300">{gettext("Saved")}</span>
          <.live_component
            module={FullCircleWeb.LogLive.Component}
            current_company={@current_company}
            id={"log_bank_#{@contact.id}"}
            show_log={false}
            entity="contact_bank"
            entity_id={@contact.id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
```

`lib/full_circle_web/live/contact_live/form.ex`:

In `mount/3`, before `{:ok, socket}`:

```elixir
    socket =
      assign(
        socket,
        :can_bank,
        FullCircle.Authorization.can?(
          socket.assigns.current_user,
          :manage_contact_bank,
          socket.assigns.current_company
        )
      )
```

In `render/1`, directly after the contact form's closing `</.form>` (still inside the `w-6/12` container div):

```heex
      <.live_component
        :if={@live_action == :edit and @can_bank}
        module={FullCircleWeb.ContactLive.BankComponent}
        id="contact-bank"
        contact={@form.data}
        current_company={@current_company}
        current_user={@current_user}
      />
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/contact_bank_live_test.exs test/full_circle_web/live/contact_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle_web/live/contact_live/bank_component.ex lib/full_circle_web/live/contact_live/form.ex test/full_circle_web/live/contact_bank_live_test.exs
git add lib/full_circle_web/live/contact_live/bank_component.ex lib/full_circle_web/live/contact_live/form.ex test/full_circle_web/live/contact_bank_live_test.exs
git commit -m "feat(contacts): bank details block on the contact form for admin/manager

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Saved SQL queries become admin/manager only

**Files:**
- Modify: `lib/full_circle/authorization.ex:216-226` (four query clauses)
- Modify: `lib/full_circle_web/live/query_live/index.ex` (`mount/3` gate)
- Modify: `lib/full_circle_web/live/query_live/form.ex` (`mount/3` gate)
- Test: `test/full_circle/user_queries_auth_test.exs`, add one test to `test/full_circle_web/live/query_live_test.exs`

**Interfaces:**
- Produces: `can?(user, :create_query | :update_query | :delete_query | :execute_query, company)` true only for admin, manager. Query pages redirect others to the dashboard.

- [ ] **Step 1: Write the failing tests**

`test/full_circle/user_queries_auth_test.exs`:

```elixir
defmodule FullCircle.UserQueriesAuthTest do
  use FullCircle.DataCase

  import FullCircle.BillingFixtures

  setup do
    billing_setup()
  end

  # Saved queries can read any column, including supplier bank details.
  describe "query authorization" do
    test_authorise_to(:create_query, ["admin", "manager"])
    test_authorise_to(:update_query, ["admin", "manager"])
    test_authorise_to(:delete_query, ["admin", "manager"])
    test_authorise_to(:execute_query, ["admin", "manager"])
  end
end
```

Append to `test/full_circle_web/live/query_live_test.exs` (inside the module):

```elixir
  test "a clerk is sent away from the query pages", %{company: company, user: admin} do
    clerk = user_fixture()
    FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)
    conn = log_in_user(build_conn(), clerk)

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/companies/#{company.id}/queries")
    assert to =~ "/dashboard"
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{company.id}/queries/new")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs`
Expected: FAIL — supervisor/clerk (and auditor for execute) still allowed; clerk page renders.

- [ ] **Step 3: Implement**

`lib/full_circle/authorization.ex` — replace the four clauses:

```elixir
  def can?(user, :create_query, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :update_query, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :delete_query, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :execute_query, company),
    do: allow_roles(~w(admin manager), company, user)
```

`lib/full_circle_web/live/query_live/index.ex` — replace `mount/3`:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :execute_query,
         socket.assigns.current_company
       ) do
      {:ok, assign(socket, page_title: gettext("Queries Listing"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end
```

`handle_params/3` runs after a mount that called `push_navigate`; guard it so it does not query for the refused user — wrap its body:

```elixir
  @impl true
  def handle_params(params, _uri, socket) do
    if FullCircle.Authorization.can?(socket.assigns.current_user, :execute_query, socket.assigns.current_company) do
      params = params["search"]
      terms = params["terms"] || ""

      {:noreply,
       socket
       |> assign(search: %{terms: terms})
       |> filter_objects(terms, true, 1)}
    else
      {:noreply, socket}
    end
  end
```

`lib/full_circle_web/live/query_live/form.ex` — at the start of `mount/3`, before the existing body, add the same gate: if not `can?(…, :execute_query, …)` return `{:ok, socket |> put_flash(:error, gettext("You are not authorised to perform this action")) |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}`; otherwise run the existing body unchanged. Implement by renaming the existing `mount/3` to `defp mount_allowed(params, session, socket)` and adding:

```elixir
  @impl true
  def mount(params, session, socket) do
    if FullCircle.Authorization.can?(
         socket.assigns.current_user,
         :execute_query,
         socket.assigns.current_company
       ) do
      mount_allowed(params, session, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end
```

(Remove the `@impl true` from the renamed private function.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs test/full_circle/authorization_test.exs`
Expected: PASS. If `authorization_test.exs` asserts old query roles, update those expectations to `["admin", "manager"]` — that is the intended change.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/authorization.ex lib/full_circle_web/live/query_live/index.ex lib/full_circle_web/live/query_live/form.ex test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs
git add lib/full_circle/authorization.ex lib/full_circle_web/live/query_live/index.ex lib/full_circle_web/live/query_live/form.ex test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs
git commit -m "feat(queries): saved SQL queries are admin/manager only

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: BankPayment schemas

**Files:**
- Create: `lib/full_circle/bank_payment/file_format.ex`, `profile.ex`, `batch.ex`, `batch_line.ex`
- Test: `test/full_circle/bank_payment_schema_test.exs`

**Interfaces:**
- Produces schemas `FullCircle.BankPayment.FileFormat` (`bank_file_formats`), `Profile` (`bank_payment_profiles`, virtual `account_name`), `Batch` (`bank_payment_batches`), `BatchLine` (`bank_payment_batch_lines`). `Profile.parse_params(text) :: map`, `Profile.params_text(map) :: String.t()`. `BatchLine.changeset/2` carries the `bank_payment_batch_lines_one_live_per_payment` unique constraint on `:payment_id`. `Batch.void_changeset/2`. `FileFormat.changeset/2` validates the spec through `FullCircle.BankPayment.validate_spec/1` (defined in Task 9; until then this task's test only covers Profile and BatchLine).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.BankPaymentSchemaTest do
  use ExUnit.Case, async: true

  alias FullCircle.BankPayment.{BatchLine, Profile}

  test "params text round-trips, ignoring blanks and comments" do
    text = "corporate_id = 123456\n\n# note\ncorporate_name=FULL CIRCLE SDN BHD\n"
    params = Profile.parse_params(text)
    assert params == %{"corporate_id" => "123456", "corporate_name" => "FULL CIRCLE SDN BHD"}
    assert Profile.parse_params(Profile.params_text(params)) == params
  end

  test "batch line requires its snapshot fields" do
    cs = BatchLine.changeset(%BatchLine{}, %{})
    refute cs.valid?
    assert {_, _} = cs.errors[:payment_id]
    assert {_, _} = cs.errors[:bank_account_no]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_schema_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement**

`lib/full_circle/bank_payment/file_format.ex`:

```elixir
defmodule FullCircle.BankPayment.FileFormat do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  schema "bank_file_formats" do
    field :code, :string
    field :name, :string
    field :effective_from, :date
    field :spec, :map
    belongs_to :company, FullCircle.Sys.Company
    timestamps(type: :utc_datetime)
  end

  def changeset(ff, attrs) do
    ff
    |> cast(attrs, [:code, :name, :effective_from, :spec, :company_id])
    |> validate_required([:code, :name, :effective_from, :spec, :company_id])
    |> validate_format(:code, ~r/^[a-z0-9_]+$/,
      message: gettext("only lowercase letters, digits and underscore")
    )
    |> validate_spec()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :bank_file_formats_unique_code_effective,
      message: gettext("a version with this effective date already exists")
    )
  end

  defp validate_spec(cs) do
    case get_field(cs, :spec) do
      spec when is_map(spec) and map_size(spec) > 0 ->
        case FullCircle.BankPayment.validate_spec(spec) do
          :ok -> cs
          {:error, errors} -> Enum.reduce(errors, cs, &add_error(&2, :spec, &1))
        end

      _ ->
        cs
    end
  end
end
```

`lib/full_circle/bank_payment/profile.ex`:

```elixir
defmodule FullCircle.BankPayment.Profile do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  alias FullCircle.Accounting.Account

  schema "bank_payment_profiles" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :account, Account
    field :format_code, :string
    field :our_account_no, :string
    field :start_date, :date
    field :params, :map, default: %{}
    field :account_name, :string, virtual: true
    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:company_id, :account_id, :format_code, :our_account_no, :start_date, :params])
    |> validate_required([:company_id, :account_id, :format_code, :our_account_no, :start_date])
    |> update_change(:our_account_no, &(&1 && String.replace(&1, ~r/\D/, "")))
    |> validate_bank_account()
    |> unique_constraint(:account_id,
      name: :bank_payment_profiles_company_id_account_id_index,
      message: gettext("already has a bank payment profile")
    )
  end

  defp validate_bank_account(cs) do
    case {get_field(cs, :account_id), get_field(cs, :company_id)} do
      {nil, _} ->
        cs

      {id, cid} ->
        case FullCircle.Repo.get_by(Account, id: id, company_id: cid) do
          %Account{account_type: "Bank"} -> cs
          _ -> add_error(cs, :account_id, gettext("must be a Bank account of this company"))
        end
    end
  end

  @doc "`key=value` per line → map. Blank lines and `#` comments are ignored."
  def parse_params(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  def parse_params(_), do: %{}

  def params_text(nil), do: ""

  def params_text(params) when is_map(params) do
    params |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
  end
end
```

`lib/full_circle/bank_payment/batch.ex`:

```elixir
defmodule FullCircle.BankPayment.Batch do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "bank_payment_batches" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :profile, FullCircle.BankPayment.Profile
    belongs_to :format, FullCircle.BankPayment.FileFormat
    field :payment_date, :date
    field :filename_stem, :string
    field :filename, :string
    field :seq, :integer
    field :header, :map
    field :count, :integer
    field :total, :decimal
    field :status, :string, default: "exported"
    field :void_reason, :string
    belongs_to :voided_by, FullCircle.UserAccounts.User
    field :voided_at, :utc_datetime
    belongs_to :created_by, FullCircle.UserAccounts.User
    has_many :lines, FullCircle.BankPayment.BatchLine
    timestamps(type: :utc_datetime)
  end

  @fields [
    :company_id,
    :profile_id,
    :format_id,
    :payment_date,
    :filename_stem,
    :filename,
    :seq,
    :header,
    :count,
    :total,
    :created_by_id
  ]

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:filename, name: :bank_payment_batches_company_id_filename_index)
  end

  def void_changeset(batch, attrs) do
    batch
    |> cast(attrs, [:void_reason, :voided_by_id, :voided_at])
    |> validate_required([:void_reason, :voided_by_id, :voided_at])
    |> put_change(:status, "voided")
  end
end
```

`lib/full_circle/bank_payment/batch_line.ex`:

```elixir
defmodule FullCircle.BankPayment.BatchLine do
  use FullCircle.Schema
  import Ecto.Changeset

  # Snapshot of what went into the file, so "Download again" rebuilds it
  # byte for byte whatever changed on the Payment or contact since.
  schema "bank_payment_batch_lines" do
    belongs_to :batch, FullCircle.BankPayment.Batch
    belongs_to :payment, FullCircle.BillPay.Payment
    field :record_no, :integer
    field :live, :boolean, default: true
    field :payment_no, :string
    field :doc_date, :date
    field :amount, :decimal
    field :bank_code, :string
    field :bank_account_no, :string
    field :bank_account_name, :string
    field :contact_name, :string
    field :email, :string
    field :reg_no, :string
    field :descriptions, :string
    field :advice, {:array, :map}, default: []
  end

  @required [
    :batch_id,
    :payment_id,
    :record_no,
    :payment_no,
    :doc_date,
    :amount,
    :bank_code,
    :bank_account_no,
    :bank_account_name,
    :contact_name
  ]

  def changeset(line, attrs) do
    line
    |> cast(attrs, @required ++ [:email, :reg_no, :descriptions, :advice])
    |> validate_required(@required)
    |> unique_constraint(:payment_id, name: :bank_payment_batch_lines_one_live_per_payment)
  end
end
```

Also create a minimal `lib/full_circle/bank_payment.ex` so `FileFormat` compiles (Task 9 fills it in):

```elixir
defmodule FullCircle.BankPayment do
  @moduledoc """
  Bank bulk payment files: supplier Payments → a bank upload file (RHB Reflex
  Bulk Pay, PB enterprise ECP Payment). See
  docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md.
  """

  alias FullCircle.FileSpec

  @sources ["payments"]
  @row_vars ~w(record_id payment_no doc_date amount bank_code account_no account_name contact_name reg_no email descriptions advice advice_text)
  @child_vars ~w(advice_doc_no advice_doc_date advice_amount)
  @header_vars ~w(our_account_no payment_date today company_name seq batch_no)

  @doc "Profile params the spec declares under \"params\"."
  def spec_params(spec), do: spec |> Map.get("params", []) |> List.wrap() |> Enum.filter(&is_binary/1)

  def format_variables(spec), do: @row_vars ++ @child_vars ++ @header_vars ++ spec_params(spec)

  def validate_spec(spec), do: FileSpec.validate(spec, format_variables(spec), @sources)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/bank_payment_schema_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex lib/full_circle/bank_payment/file_format.ex lib/full_circle/bank_payment/profile.ex lib/full_circle/bank_payment/batch.ex lib/full_circle/bank_payment/batch_line.ex test/full_circle/bank_payment_schema_test.exs
git add lib/full_circle/bank_payment.ex lib/full_circle/bank_payment/ test/full_circle/bank_payment_schema_test.exs
git commit -m "feat(bank-payment): schemas for formats, profiles, batches, lines

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Formats, templates and profiles in the context

**Files:**
- Modify: `lib/full_circle/bank_payment.ex`
- Create: `priv/bank_file_templates/rhb_bulk_pay.json`, `priv/bank_file_templates/pbb_ecp_payment.json`
- Create: `test/support/fixtures/bank_payment_fixtures.ex`
- Test: `test/full_circle/bank_payment_test.exs` (new; Tasks 11–12 add to it)

**Interfaces:**
- Consumes: schemas (Task 8), `FileSpec` (Tasks 2–4).
- Produces:
  - `list_formats(company_id) :: [FileFormat]` (code asc, effective_from desc)
  - `format_codes(company_id) :: [String.t()]`
  - `effective_format(company_id, code, date) :: FileFormat | nil`
  - `format_version_exists?(company_id, code, date_string) :: boolean`
  - `save_format(attrs, company, user, opts \\ []) :: {:ok, FileFormat} | {:error, Changeset} | :not_authorise` (`replace: true` updates the same `(code, effective_from)` row)
  - `templates() :: [%{code, name}]`, `load_template(code) :: {:ok, %{"code","name","spec"}} | {:error, String.t()}`
  - `list_profiles(company) :: [Profile with account_name]`, `get_profile(id, company) :: Profile | nil`, `bank_accounts(company) :: [{name, id}]`
  - `save_profile(profile, attrs, company, user) :: {:ok, Profile} | {:error, Changeset} | :not_authorise`
  - `missing_params(profile) :: :no_format | [String.t()]`
  - Fixtures: `bank_gl_account_fixture/2`, `bank_contact_fixture/3`, `install_template!/3`, `profile_fixture/4`, `bank_payment_fixture/5`.

- [ ] **Step 1: Write the templates**

`priv/bank_file_templates/rhb_bulk_pay.json`:

```json
{
  "code": "rhb_bulk_pay",
  "name": "RHB Reflex Bulk Pay (CSV)",
  "spec": {
    "renderer": "text",
    "delimiter": ",",
    "quote": "csv",
    "line_ending": "\r\n",
    "extension": "CSV",
    "filename": "PAYMENT_{corporate_id}_{today:%d%m%Y}_{seq:3}.CSV",
    "params": ["corporate_id", "corporate_name"],
    "computed": {
      "hash_part": "num(right(account_no, 6)) * mod(floor(amount), 1000000)"
    },
    "sections": [
      {
        "kind": "header",
        "fields": [
          {"expr": "\"00\""},
          {"expr": "\"01\""},
          {"expr": "corporate_id"},
          {"expr": "\"\""},
          {"expr": "left(corporate_name, 40)", "allow": "A-Za-z0-9 .,/()&'@:-"},
          {"expr": "our_account_no", "format": "digits"},
          {"expr": "payment_date", "format": "date:{0D}{0M}{YYYY}"},
          {"expr": "batch_no"},
          {"expr": "\"\""},
          {"expr": "\"A\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""}
        ]
      },
      {
        "kind": "detail",
        "source": "payments",
        "fields": [
          {"expr": "\"10\""},
          {"expr": "\"10\""},
          {"expr": "record_id"},
          {"expr": "amount", "format": "decimal:2"},
          {"expr": "bank_code"},
          {"expr": "\"1\""},
          {"expr": "left(account_name, 96)", "allow": "A-Za-z0-9 .,/()&'@:-"},
          {"expr": "account_no", "format": "digits"},
          {"expr": "if(reg_no == \"\", \"\", \"05\")"},
          {"expr": "left(reg_no, 15)", "allow": "A-Za-z0-9"},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "left(payment_no, 20)", "allow": "A-Za-z0-9 .,/()&'@:-"},
          {"expr": "left(descriptions, 20)", "allow": "A-Za-z0-9 .,/()&'@:-"},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "email"},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""}
        ],
        "children": [
          {
            "source": "advice",
            "fields": [
              {"expr": "\"30\""},
              {"expr": "advice_doc_date", "format": "date:{0D}{0M}{YYYY}"},
              {"expr": "advice_amount", "format": "decimal:2"},
              {"expr": "left(advice_doc_no, 20)", "allow": "A-Za-z0-9 .,/()&'@:-"},
              {"expr": "left(advice_doc_no, 20)", "allow": "A-Za-z0-9 .,/()&'@:-"},
              {"expr": "\"\""},
              {"expr": "\"\""},
              {"expr": "\"\""},
              {"expr": "\"\""}
            ]
          }
        ]
      },
      {
        "kind": "footer",
        "fields": [
          {"expr": "\"99\""},
          {"expr": "batch_no"},
          {"expr": "count()", "format": "decimal:0"},
          {"expr": "sum(\"amount\")", "format": "decimal:2"},
          {"expr": "floor((sum(\"hash_part\") * 24 + 2994) / 285)", "format": "decimal:0"},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""}
        ]
      }
    ]
  }
}
```

`priv/bank_file_templates/pbb_ecp_payment.json`:

```json
{
  "code": "pbb_ecp_payment",
  "name": "PB enterprise ECP Payment (text)",
  "spec": {
    "renderer": "text",
    "line_ending": "\r\n",
    "extension": "txt",
    "filename": "{our_account_no}PM{payment_date:%d%m%y}{seq:2}.txt",
    "computed": {
      "acct4": "num(left(account_no, 4))"
    },
    "sections": [
      {
        "kind": "header",
        "fields": [
          {"expr": "\"H\"", "width": 1},
          {"expr": "our_account_no", "format": "digits", "width": 10},
          {"expr": "payment_date", "format": "date:{YYYY}{0M}{0D}", "width": 8}
        ]
      },
      {
        "kind": "detail",
        "source": "payments",
        "fields": [
          {"expr": "\"D\"", "width": 1},
          {"expr": "record_id", "width": 16},
          {"expr": "if(bank_code == \"PBBEMYKL\" or bank_code == \"PIBEMYK1\", \"PBB\", \"IBG\")", "width": 3},
          {"expr": "account_no", "format": "digits", "width": 20},
          {"expr": "bank_code", "width": 11},
          {"expr": "account_name", "width": 120, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "if(reg_no == \"\", \"\", \"BR\")", "width": 2},
          {"expr": "reg_no", "width": 29, "allow": "A-Za-z0-9-"},
          {"expr": "amount", "format": "cents", "width": 16, "align": "right", "pad": "0"},
          {"expr": "payment_no", "width": 20, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "descriptions", "width": 20, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "email", "width": 70},
          {"expr": "\"\"", "width": 70},
          {"expr": "\"\"", "width": 16},
          {"expr": "\"\"", "width": 16},
          {"expr": "\"\"", "width": 120},
          {"expr": "\"\"", "width": 2},
          {"expr": "\"\"", "width": 29},
          {"expr": "mid(advice_text, 1, 40)", "width": 40, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "mid(advice_text, 41, 40)", "width": 40, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "mid(advice_text, 81, 40)", "width": 40, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "mid(advice_text, 121, 40)", "width": 40, "allow": "A-Za-z0-9 .,/()&'@:;+-"},
          {"expr": "mid(advice_text, 161, 40)", "width": 40, "allow": "A-Za-z0-9 .,/()&'@:;+-"}
        ]
      },
      {
        "kind": "footer",
        "fields": [
          {"expr": "\"F\"", "width": 1},
          {"expr": "count()", "format": "decimal:0", "width": 10, "align": "right", "pad": "0"},
          {"expr": "sum(\"amount\")", "format": "cents", "width": 20, "align": "right", "pad": "0"},
          {"expr": "round(sum(\"amount\") * 100, 0) + sum(\"acct4\")", "format": "decimal:0", "width": 20, "align": "right", "pad": "0"}
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Write the fixtures**

`test/support/fixtures/bank_payment_fixtures.ex`:

```elixir
defmodule FullCircle.BankPaymentFixtures do
  alias FullCircle.{Accounting, BankPayment, BillPay, Repo, StdInterface}
  alias FullCircle.Accounting.{Account, TaxCode}

  import FullCircle.BillingFixtures
  import Ecto.Query

  def bank_gl_account_fixture(company, user) do
    {:ok, account} =
      StdInterface.create(
        Account,
        "account",
        %{
          "name" => "Bank #{System.unique_integer([:positive])}",
          "account_type" => "Bank",
          "descriptions" => "test bank"
        },
        company,
        user
      )

    account
  end

  def bank_contact_fixture(company, user, bank \\ %{}) do
    c = contact_fixture(company, user, %{"email" => "sup#{System.unique_integer([:positive])}@example.com"})

    attrs =
      Map.merge(
        %{"bank_code" => "MBBEMYKL", "bank_account_no" => "112233445566", "bank_account_name" => c.name},
        bank
      )

    {:ok, c} = Accounting.save_contact_bank(c, attrs, company, user)
    c
  end

  def install_template!(company, user, code) do
    {:ok, t} = BankPayment.load_template(code)

    {:ok, f} =
      BankPayment.save_format(
        %{"code" => t["code"], "name" => t["name"], "effective_from" => "2026-01-01", "spec" => t["spec"]},
        company,
        user
      )

    f
  end

  def profile_fixture(company, user, account, attrs \\ %{}) do
    defaults = %{
      "account_id" => account.id,
      "format_code" => "rhb_bulk_pay",
      "our_account_no" => "21234500012345",
      "start_date" => Date.to_iso8601(Date.add(Date.utc_today(), -30)),
      "params" => %{"corporate_id" => "123456", "corporate_name" => "TEST SDN BHD"}
    }

    {:ok, p} = BankPayment.save_profile(%BankPayment.Profile{}, Map.merge(defaults, attrs), company, user)
    p
  end

  def bank_payment_fixture(company, user, contact, funds_account, amount \\ "100.00") do
    good = good_fixture(company, user)
    pur = Accounting.get_account_by_name("General Purchases", company, user)

    no_ptax =
      Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    attrs =
      FullCircle.BillPayFixtures.payment_attrs(contact, good, pur, no_ptax, funds_account,
        funds_amount: amount,
        quantity: "1",
        unit_price: amount,
        tax_rate: "0"
      )

    {:ok, %{create_payment: p}} = BillPay.create_payment(attrs, company, user)
    p
  end
end
```

- [ ] **Step 3: Write the failing test**

`test/full_circle/bank_payment_test.exs`:

```elixir
defmodule FullCircle.BankPaymentTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Profile

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    billing_setup()
  end

  describe "templates" do
    test "both bundled templates load and validate" do
      assert [%{code: "pbb_ecp_payment"}, %{code: "rhb_bulk_pay"}] =
               Enum.sort_by(BankPayment.templates(), & &1.code)

      for code <- ["rhb_bulk_pay", "pbb_ecp_payment"] do
        assert {:ok, %{"spec" => spec}} = BankPayment.load_template(code)
        assert :ok = BankPayment.validate_spec(spec)
      end
    end

    test "unknown or unsafe template codes are refused" do
      assert {:error, _} = BankPayment.load_template("../../etc/passwd")
      assert {:error, _} = BankPayment.load_template("nope")
    end
  end

  describe "formats" do
    test "save, effective version by date, replace in place", %{company: company, admin: admin} do
      f = install_template!(company, admin, "rhb_bulk_pay")
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2026-10-12]).id == f.id
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2025-12-31]) == nil
      assert BankPayment.format_version_exists?(company.id, "rhb_bulk_pay", "2026-01-01")

      attrs = %{"code" => "rhb_bulk_pay", "name" => "Renamed", "effective_from" => "2026-01-01", "spec" => f.spec}
      assert {:error, _cs} = BankPayment.save_format(attrs, company, admin)
      assert {:ok, f2} = BankPayment.save_format(attrs, company, admin, replace: true)
      assert f2.id == f.id
      assert f2.name == "Renamed"
    end

    test "an invalid spec is refused", %{company: company, admin: admin} do
      attrs = %{"code" => "bad", "name" => "Bad", "effective_from" => "2026-01-01", "spec" => %{"renderer" => "text"}}
      assert {:error, cs} = BankPayment.save_format(attrs, company, admin)
      assert errors_on(cs).spec != []
    end
  end

  describe "profiles" do
    test "must point at a Bank-type account", %{company: company, admin: admin} do
      cash = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)

      assert {:error, cs} =
               BankPayment.save_profile(
                 %Profile{},
                 %{"account_id" => cash.id, "format_code" => "rhb_bulk_pay", "our_account_no" => "1", "start_date" => "2026-01-01"},
                 company,
                 admin
               )

      assert "must be a Bank account of this company" in errors_on(cs).account_id
    end

    test "missing_params compares the profile with the format's declared params", %{company: company, admin: admin} do
      bank = bank_gl_account_fixture(company, admin)
      p = profile_fixture(company, admin, bank, %{"params" => %{"corporate_id" => "123456"}})
      assert BankPayment.missing_params(p) == :no_format
      install_template!(company, admin, "rhb_bulk_pay")
      assert BankPayment.missing_params(p) == ["corporate_name"]
      assert [%Profile{account_name: name}] = BankPayment.list_profiles(company)
      assert name == bank.name
    end

    test "only admins may configure", %{company: company, admin: admin} do
      mgr = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, mgr, "manager", admin)
      assert :not_authorise = BankPayment.save_profile(%Profile{}, %{}, company, mgr)
      assert :not_authorise = BankPayment.save_format(%{}, company, mgr)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_test.exs`
Expected: FAIL — `BankPayment.templates/0` undefined.

- [ ] **Step 5: Implement** — replace `lib/full_circle/bank_payment.ex` with:

```elixir
defmodule FullCircle.BankPayment do
  @moduledoc """
  Bank bulk payment files: supplier Payments → a bank upload file (RHB Reflex
  Bulk Pay, PB enterprise ECP Payment). See
  docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md and
  .claude/skills/bank-bulk-payment.md.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{FileSpec, Repo, Sys}
  alias FullCircle.Accounting.Account
  alias FullCircle.BankPayment.{FileFormat, Profile}

  @sources ["payments"]
  @row_vars ~w(record_id payment_no doc_date amount bank_code account_no account_name contact_name reg_no email descriptions advice advice_text)
  @child_vars ~w(advice_doc_no advice_doc_date advice_amount)
  @header_vars ~w(our_account_no payment_date today company_name seq batch_no)

  # ── Spec variables ─────────────────────────────────

  @doc "Profile params the spec declares under \"params\"."
  def spec_params(spec), do: spec |> Map.get("params", []) |> List.wrap() |> Enum.filter(&is_binary/1)

  def format_variables(spec), do: @row_vars ++ @child_vars ++ @header_vars ++ spec_params(spec)

  def validate_spec(spec), do: FileSpec.validate(spec, format_variables(spec), @sources)

  # ── Formats ────────────────────────────────────────

  def list_formats(company_id) do
    from(f in FileFormat,
      where: f.company_id == ^company_id,
      order_by: [asc: f.code, desc: f.effective_from]
    )
    |> Repo.all()
  end

  def format_codes(company_id) do
    from(f in FileFormat, where: f.company_id == ^company_id, distinct: true, select: f.code)
    |> Repo.all()
  end

  @doc "The version in force on `date` (latest effective_from <= date)."
  def effective_format(company_id, code, date) do
    from(f in FileFormat,
      where: f.company_id == ^company_id and f.code == ^code and f.effective_from <= ^date,
      order_by: [desc: f.effective_from],
      limit: 1
    )
    |> Repo.one()
  end

  def format_version_exists?(company_id, code, date_string) do
    find_format(company_id, code, date_string) != nil
  end

  defp find_format(company_id, code, date_string) do
    with true <- is_binary(code),
         {:ok, date} <- Date.from_iso8601(to_string(date_string)) do
      Repo.get_by(FileFormat, company_id: company_id, code: code, effective_from: date)
    else
      _ -> nil
    end
  end

  @doc "Saves a format version; `replace: true` updates the same (code, effective_from) row."
  def save_format(attrs, company, user, opts \\ []) do
    if can?(user, :manage_bank_payment_config, company) do
      attrs = attrs |> stringify() |> Map.put("company_id", company.id)

      base =
        (opts[:replace] && find_format(company.id, attrs["code"], attrs["effective_from"])) ||
          %FileFormat{}

      Multi.new()
      |> Multi.insert_or_update(:save_bank_file_format, FileFormat.changeset(base, attrs))
      |> Sys.insert_log_for(:save_bank_file_format, Map.drop(attrs, ["spec"]), company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{save_bank_file_format: f}} -> {:ok, f}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      :not_authorise
    end
  end

  # ── Templates ──────────────────────────────────────

  defp template_dir, do: Application.app_dir(:full_circle, "priv/bank_file_templates")

  def templates do
    template_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      t = path |> File.read!() |> Jason.decode!()
      %{code: t["code"], name: t["name"]}
    end)
    |> Enum.sort_by(& &1.code)
  end

  def load_template(code) when is_binary(code) do
    path = Path.join(template_dir(), code <> ".json")

    if code =~ ~r/\A[a-z0-9_]+\z/ and File.exists?(path),
      do: {:ok, path |> File.read!() |> Jason.decode!()},
      else: {:error, "no bank file template '#{code}'"}
  end

  # ── Profiles ───────────────────────────────────────

  def list_profiles(company) do
    from(p in Profile,
      join: a in Account,
      on: a.id == p.account_id,
      where: p.company_id == ^company.id,
      order_by: a.name,
      select: %{p | account_name: a.name}
    )
    |> Repo.all()
  end

  def get_profile(id, company) do
    with {:ok, uuid} <- Ecto.UUID.cast(id || "") do
      from(p in Profile,
        join: a in Account,
        on: a.id == p.account_id,
        where: p.id == ^uuid and p.company_id == ^company.id,
        select: %{p | account_name: a.name}
      )
      |> Repo.one()
    else
      _ -> nil
    end
  end

  def bank_accounts(company) do
    from(a in Account,
      where: a.company_id == ^company.id and a.account_type == "Bank",
      order_by: a.name,
      select: {a.name, a.id}
    )
    |> Repo.all()
  end

  def save_profile(%Profile{} = profile, attrs, company, user) do
    if can?(user, :manage_bank_payment_config, company) do
      attrs = attrs |> stringify() |> Map.put("company_id", company.id)
      name = if profile.id, do: :update_bank_payment_profile, else: :create_bank_payment_profile

      Multi.new()
      |> Multi.insert_or_update(name, Profile.changeset(profile, attrs))
      |> Sys.insert_log_for(name, Map.drop(attrs, ["params"]), company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{^name => p}} -> {:ok, p}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      :not_authorise
    end
  end

  @doc "Params the profile's format declares but the profile lacks; :no_format when none is in force."
  def missing_params(%Profile{} = profile) do
    case effective_format(profile.company_id, profile.format_code, Date.utc_today()) do
      nil ->
        :no_format

      f ->
        have = for {k, v} <- profile.params || %{}, v not in [nil, ""], do: k
        spec_params(f.spec) -- have
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/full_circle/bank_payment_test.exs test/full_circle/bank_payment_schema_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
mix format lib/full_circle/bank_payment.ex test/support/fixtures/bank_payment_fixtures.ex test/full_circle/bank_payment_test.exs
git add lib/full_circle/bank_payment.ex priv/bank_file_templates/ test/support/fixtures/bank_payment_fixtures.ex test/full_circle/bank_payment_test.exs
git commit -m "feat(bank-payment): versioned formats, RHB and PB templates, paying-account profiles

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Row building, rendering and golden files

**Files:**
- Create: `lib/full_circle/bank_payment/rows.ex`
- Modify: `lib/full_circle/bank_payment.ex` (`render_file/3`)
- Test: `test/full_circle/bank_payment_golden_test.exs`

**Interfaces:**
- Produces: `Rows.line_attrs(payment) :: map` (payment preloaded with `:contact`, `:payment_details`, `transaction_matchers: :transaction`); `Rows.to_row(line :: BatchLine | map with :record_no) :: map` (string keys per the spec's row table, `doc_date` for the Payment date); `Rows.advice_text(advice) :: String.t()`; `BankPayment.render_file(spec, rows, header) :: {:ok, text} | {:error, msg}`.

- [ ] **Step 1: Write the failing golden test**

```elixir
defmodule FullCircle.BankPaymentGoldenTest do
  use ExUnit.Case, async: true

  alias FullCircle.{BankPayment, FileSpec}

  defp row(attrs) do
    Map.merge(
      %{
        "record_id" => "000000000001",
        "payment_no" => "PV-000001",
        "doc_date" => ~D[2026-10-10],
        "amount" => Decimal.new("1000.00"),
        "bank_code" => "MBBEMYKL",
        "account_no" => "112233374890",
        "account_name" => "Supplier",
        "contact_name" => "Supplier",
        "reg_no" => "",
        "email" => "",
        "descriptions" => "",
        "advice" => [],
        "advice_text" => ""
      },
      attrs
    )
  end

  defp lines(text), do: String.split(text, "\r\n", trim: true)

  describe "RHB Reflex Bulk Pay" do
    setup do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")

      header = %{
        "corporate_id" => "123456",
        "corporate_name" => "FULL CIRCLE SDN BHD",
        "our_account_no" => "21234500012345",
        "payment_date" => ~D[2026-10-15],
        "today" => ~D[2026-10-12],
        "company_name" => "Full Circle Sdn Bhd",
        "seq" => 1,
        "batch_no" => "20261012001"
      }

      %{spec: spec, header: header}
    end

    # RHB's published worked example: hash total 164632936.
    test "hash total matches RHB's worked example", %{spec: spec, header: header} do
      rows =
        ["112233374890", "112233464890", "112233464890", "112233464890", "112233185456"]
        |> Enum.with_index(1)
        |> Enum.map(fn {acct, i} ->
          row(%{"account_no" => acct, "record_id" => String.pad_leading("#{i}", 12, "0")})
        end)

      assert {:ok, text} = BankPayment.render_file(spec, rows, header)
      assert List.last(lines(text)) == "99,20261012001,5,5000.00,164632936,,,,,"
    end

    test "header, detail with quoted name, advice child, filename", %{spec: spec, header: header} do
      r =
        row(%{
          "account_name" => "Tan, Lee & Sons",
          "reg_no" => "REG001",
          "descriptions" => "Test payment",
          "email" => "ah@example.com",
          "advice" => [%{"doc_no" => "INV-1", "doc_date" => ~D[2026-10-01], "amount" => Decimal.new("1000.00")}]
        })

      assert {:ok, text} = BankPayment.render_file(spec, [r], header)
      [h, d, a, _f] = lines(text)

      assert h ==
               Enum.join(
                 ["00", "01", "123456", "", "FULL CIRCLE SDN BHD", "21234500012345", "15102026", "20261012001", "", "A"] ++
                   List.duplicate("", 9),
                 ","
               )

      assert d ==
               Enum.join(
                 ["10", "10", "000000000001", "1000.00", "MBBEMYKL", "1", ~s|"Tan, Lee & Sons"|, "112233374890", "05", "REG001", "", "", "", "PV-000001", "Test payment"] ++
                   List.duplicate("", 12) ++ ["ah@example.com"] ++ List.duplicate("", 5),
                 ","
               )

      assert a == "30,01102026,1000.00,INV-1,INV-1,,,,"
      assert FileSpec.filename(spec, header, 1) == "PAYMENT_123456_12102026_001.CSV"
    end
  end

  describe "PB enterprise ECP Payment" do
    setup do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("pbb_ecp_payment")

      header = %{
        "our_account_no" => "3999999999",
        "payment_date" => ~D[2026-10-15],
        "today" => ~D[2026-10-12],
        "company_name" => "Full Circle Sdn Bhd",
        "seq" => 1,
        "batch_no" => "20261012001"
      }

      %{spec: spec, header: header}
    end

    test "fixed widths, PBB vs IBG, cents, hash and e-mail advice lines", %{spec: spec, header: header} do
      pbb =
        row(%{
          "bank_code" => "PBBEMYKL",
          "account_no" => "3123456789",
          "amount" => Decimal.new("1200.50"),
          "advice_text" => "INV-9 01/10/2026 1200.50"
        })

      ibg = row(%{"record_id" => "000000000002", "amount" => Decimal.new("99.99")})

      assert {:ok, text} = BankPayment.render_file(spec, [pbb, ibg], header)
      [h, d1, d2, f] = lines(text)

      assert h == "H399999999920261015"
      assert String.length(d1) == 781
      assert String.length(d2) == 781
      assert String.slice(d1, 17, 3) == "PBB"
      assert String.slice(d2, 17, 3) == "IBG"
      assert String.slice(d1, 40, 11) == "PBBEMYKL   "
      assert String.slice(d1, 202, 16) == "0000000000120050"
      assert String.slice(d1, 581, 40) == String.pad_trailing("INV-9 01/10/2026 1200.50", 40)
      # total cents 130049 + first-4-digit sum (3123 + 1122) = 134294
      assert f == "F0000000002" <> "00000000000000130049" <> "00000000000000134294"
      assert FileSpec.filename(spec, header, 1) == "3999999999PM15102601.txt"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_golden_test.exs`
Expected: FAIL — `BankPayment.render_file/3` undefined.

- [ ] **Step 3: Implement**

`lib/full_circle/bank_payment/rows.ex`:

```elixir
defmodule FullCircle.BankPayment.Rows do
  @moduledoc """
  Payment → batch line snapshot → FileSpec row. The row's own date is
  `doc_date`; `payment_date` is the batch's header value (FileSpec merges the
  header over each row).
  """

  alias FullCircle.BillPay.Payment

  @doc "Snapshot attrs for a batch line. Preload :contact, :payment_details, transaction_matchers: :transaction."
  def line_attrs(%Payment{contact: c} = p) do
    %{
      payment_no: p.payment_no,
      doc_date: p.payment_date,
      amount: p.funds_amount,
      bank_code: c.bank_code,
      bank_account_no: c.bank_account_no,
      bank_account_name: c.bank_account_name,
      contact_name: c.name,
      email: c.email,
      reg_no: c.reg_no,
      descriptions: p.descriptions,
      advice: advice(p)
    }
  end

  defp advice(p) do
    matched =
      for m <- p.transaction_matchers, m.transaction do
        %{
          "doc_no" => m.transaction.doc_no || "",
          "doc_date" => Date.to_iso8601(m.transaction.doc_date),
          "amount" => m.match_amount |> Decimal.abs() |> Decimal.round(2) |> Decimal.to_string(:normal)
        }
      end

    lines =
      for d <- p.payment_details do
        %{
          "doc_no" => d.descriptions || "",
          "doc_date" => Date.to_iso8601(p.payment_date),
          "amount" => d |> detail_amount() |> Decimal.to_string(:normal)
        }
      end

    matched ++ lines
  end

  defp detail_amount(d) do
    base = d.quantity |> Decimal.mult(d.unit_price) |> Decimal.add(d.discount)
    tax = base |> Decimal.mult(d.tax_rate) |> Decimal.round(2)
    base |> Decimal.add(tax) |> Decimal.round(2)
  end

  @doc "FileSpec row from a batch line (struct or map with :record_no)."
  def to_row(line) do
    advice = Enum.map(line.advice || [], &load_advice/1)

    %{
      "record_id" => line.record_no |> Integer.to_string() |> String.pad_leading(12, "0"),
      "payment_no" => line.payment_no,
      "doc_date" => line.doc_date,
      "amount" => line.amount,
      "bank_code" => line.bank_code,
      "account_no" => line.bank_account_no,
      "account_name" => line.bank_account_name,
      "contact_name" => line.contact_name,
      "reg_no" => line.reg_no || "",
      "email" => line.email || "",
      "descriptions" => line.descriptions || "",
      "advice" => advice,
      "advice_text" => advice_text(advice)
    }
  end

  defp load_advice(a) do
    %{
      "doc_no" => a["doc_no"] || "",
      "doc_date" => Date.from_iso8601!(a["doc_date"]),
      "amount" => Decimal.new(a["amount"])
    }
  end

  @doc "`<doc_no> <DD/MM/YYYY> <amount>; …` — for banks with free-text advice lines."
  def advice_text(advice) do
    Enum.map_join(advice, "; ", fn a ->
      "#{a["doc_no"]} #{Calendar.strftime(a["doc_date"], "%d/%m/%Y")} " <>
        (a["amount"] |> Decimal.round(2) |> Decimal.to_string(:normal))
    end)
  end
end
```

In `lib/full_circle/bank_payment.ex`, add under "Spec variables":

```elixir
  @doc "Renders a bank spec against FileSpec rows and a header context."
  def render_file(spec, rows, header) do
    FileSpec.render(spec, rows, header, format_variables(spec), @sources)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/bank_payment_golden_test.exs`
Expected: PASS. If the RHB footer differs, re-check `computed.hash_part` and `mod`; if PB widths differ, re-count the field widths against the plan's 19/781/51 totals.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment/rows.ex lib/full_circle/bank_payment.ex test/full_circle/bank_payment_golden_test.exs
git add lib/full_circle/bank_payment/rows.ex lib/full_circle/bank_payment.ex test/full_circle/bank_payment_golden_test.exs
git commit -m "feat(bank-payment): payment rows and golden RHB/PB files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Eligibility, batch creation, void, re-download

**Files:**
- Modify: `lib/full_circle/bank_payment.ex`
- Test: `test/full_circle/bank_payment_test.exs`

**Interfaces:**
- Consumes: `Rows` (Task 10), formats/profiles (Task 9), `BatchLine.changeset/2` unique constraint (Task 8).
- Produces:
  - `eligible_payments(profile, company) :: [%{id, payment_no, payment_date, amount, contact_name, bank_code, bank_name, account_no, account_name, changed_at, has_bank, recent_change}]`
  - `create_batches(profile_id, payment_ids, payment_date :: Date, company, user) :: {:ok, [Batch]} | {:error, String.t() | [String.t()]} | :not_authorise`
  - `void_batch(batch_id, reason, company, user) :: {:ok, Batch} | {:error, term} | :not_authorise`
  - `list_batches(company) :: [Batch]` (newest first, max 50)
  - `batch_files(ids :: [String.t()], company, user) :: {:ok, [{filename, text}]} | {:error, String.t()} | :not_authorise`
  - `zip(files) :: {:ok, binary}`
  - `preview(spec, profile, company) :: {:ok, text} | {:error, String.t()}`
  - `live_batch_filename(payment_id) :: String.t() | nil`

- [ ] **Step 1: Write the failing tests** — append to `FullCircle.BankPaymentTest`:

```elixir
  defp setup_bank(company, admin, format \\ "rhb_bulk_pay") do
    install_template!(company, admin, format)
    bank = bank_gl_account_fixture(company, admin)
    profile = profile_fixture(company, admin, bank, %{"format_code" => format})
    %{bank: bank, profile: profile}
  end

  describe "eligible_payments/2" do
    test "lists the account's unbatched payments since start date, flags missing bank details", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      with_bank = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      no_bank = bank_payment_fixture(company, admin, contact_fixture(company, admin), bank)
      other = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)
      _elsewhere = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), other)

      rows = BankPayment.eligible_payments(profile, company)
      assert Enum.map(rows, & &1.id) |> Enum.sort() == Enum.sort([with_bank.id, no_bank.id])
      assert Enum.find(rows, &(&1.id == with_bank.id)).has_bank
      assert Enum.find(rows, &(&1.id == with_bank.id)).recent_change
      refute Enum.find(rows, &(&1.id == no_bank.id)).has_bank
    end
  end

  describe "create_batches/5" do
    test "creates a batch, freezes its payments out of the list, renders a file", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "250.00")

      assert {:ok, [batch]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)
      assert batch.count == 1
      assert Decimal.equal?(batch.total, Decimal.new("250.00"))
      assert batch.filename =~ ~r/^PAYMENT_123456_\d{8}_001\.CSV$/
      assert BankPayment.live_batch_filename(p.id) == batch.filename
      assert BankPayment.eligible_payments(profile, company) == []

      assert {:ok, [{name, text}]} = BankPayment.batch_files([batch.id], company, admin)
      assert name == batch.filename
      assert text =~ ",250.00,MBBEMYKL,"
    end

    test "pre-flight lists payments without bank details and saves nothing", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, contact_fixture(company, admin), bank)

      assert {:error, [msg]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)
      assert msg =~ p.payment_no
      assert msg =~ "no bank details"
      assert BankPayment.list_batches(company) == []
    end

    test "payment date must be today .. today+59", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      assert {:error, msg} = BankPayment.create_batches(profile.id, [p.id], Date.add(Date.utc_today(), 60), company, admin)
      assert msg =~ "payment date"
    end

    test "a payment cannot be batched twice", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      {:ok, _} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)
      assert {:error, [msg]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)
      assert msg =~ "already in a bank batch"
    end

    test "splits at max_rows with consecutive sequence numbers", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin, "pbb_ecp_payment")
      f = BankPayment.effective_format(company.id, "pbb_ecp_payment", Date.utc_today())
      {:ok, _} = BankPayment.save_format(%{"code" => f.code, "name" => f.name, "effective_from" => "2026-01-01", "spec" => Map.put(f.spec, "max_rows", 2)}, company, admin, replace: true)
      {:ok, _} = BankPayment.save_profile(profile, %{"our_account_no" => "3999999999"}, company, admin)

      ids =
        for _ <- 1..3 do
          bank_payment_fixture(company, admin, bank_contact_fixture(company, admin, %{"bank_code" => "PBBEMYKL", "bank_account_no" => "3123456789"}), bank).id
        end

      assert {:ok, [b1, b2]} = BankPayment.create_batches(profile.id, ids, Date.utc_today(), company, admin)
      assert {b1.count, b2.count} == {2, 1}
      assert {b1.seq, b2.seq} == {1, 2}
      assert b1.filename =~ ~r/^3999999999PM\d{6}01\.txt$/
    end

    test "managers may, clerks may not", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)
      assert :not_authorise = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, clerk)
    end
  end

  describe "void and re-download" do
    test "void frees payments; the next batch takes the next seq; record ids never repeat", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      {:ok, [b1]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)

      assert {:error, _} = BankPayment.void_batch(b1.id, "  ", company, admin)
      assert {:ok, %{status: "voided"}} = BankPayment.void_batch(b1.id, "bank rejected", company, admin)
      assert BankPayment.live_batch_filename(p.id) == nil

      {:ok, [b2]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)
      assert b2.seq == 2

      {:ok, [{_, t1}]} = BankPayment.batch_files([b1.id], company, admin)
      {:ok, [{_, t2}]} = BankPayment.batch_files([b2.id], company, admin)
      rec = fn t -> t |> String.split("\r\n") |> Enum.at(1) |> String.split(",") |> Enum.at(2) end
      refute rec.(t1) == rec.(t2)
    end

    test "re-download uses the snapshot after the contact's bank details change", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      c = bank_contact_fixture(company, admin)
      p = bank_payment_fixture(company, admin, c, bank)
      {:ok, [b]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)
      {:ok, [{_, before}]} = BankPayment.batch_files([b.id], company, admin)

      {:ok, _} = FullCircle.Accounting.save_contact_bank(c, %{"bank_code" => "RHBBMYKL", "bank_account_no" => "21234500099999", "bank_account_name" => "Changed"}, company, admin)

      assert {:ok, [{_, ^before}]} = BankPayment.batch_files([b.id], company, admin)
    end
  end

  test "preview renders an unsaved spec against eligible payments", %{company: company, admin: admin} do
    %{bank: bank, profile: profile} = setup_bank(company, admin)
    bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "12.34")
    {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")
    assert {:ok, text} = BankPayment.preview(spec, profile, company)
    assert text =~ ",12.34,"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/bank_payment_test.exs`
Expected: FAIL — `eligible_payments/2` undefined.

- [ ] **Step 3: Implement** — add to `lib/full_circle/bank_payment.ex`.

Extend the aliases:

```elixir
  alias FullCircle.BillPay.Payment
  alias FullCircle.BankPayment.{Banks, Batch, BatchLine, FileFormat, Profile, Rows}
```

Add attributes:

```elixir
  @max_days_ahead 59
  @recent_change_days 30
  @preload [:contact, :payment_details, transaction_matchers: :transaction]
```

Add the section:

```elixir
  # ── Eligibility ────────────────────────────────────

  defp base_query(%Profile{} = profile, company) do
    from(p in Payment,
      join: c in assoc(p, :contact),
      as: :contact,
      where:
        p.company_id == ^company.id and p.funds_account_id == ^profile.account_id and
          p.payment_date >= ^profile.start_date and p.funds_amount > 0
    )
  end

  defp live_payment_ids, do: from(l in BatchLine, where: l.live, select: l.payment_id)

  def eligible_payments(%Profile{} = profile, company) do
    since = DateTime.add(DateTime.utc_now(), -@recent_change_days * 86_400, :second)

    from([p, contact: c] in base_query(profile, company),
      where: p.id not in subquery(live_payment_ids()),
      order_by: [desc: p.payment_date, desc: p.payment_no],
      select: %{
        id: p.id,
        payment_no: p.payment_no,
        payment_date: p.payment_date,
        amount: p.funds_amount,
        contact_name: c.name,
        bank_code: c.bank_code,
        account_no: c.bank_account_no,
        account_name: c.bank_account_name,
        changed_at: c.bank_details_changed_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn r ->
      Map.merge(r, %{
        bank_name: Banks.name(r.bank_code),
        has_bank: not is_nil(r.bank_code) and not is_nil(r.account_no) and not is_nil(r.account_name),
        recent_change: not is_nil(r.changed_at) and DateTime.compare(r.changed_at, since) == :gt
      })
    end)
  end

  # ── Batches ────────────────────────────────────────

  def create_batches(profile_id, payment_ids, %Date{} = payment_date, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Profile{} = profile <-
           get_profile(profile_id, company) || {:error, "bank payment profile not found"},
         :ok <- check_payment_date(payment_date),
         %FileFormat{} = format <-
           effective_format(company.id, profile.format_code, Date.utc_today()) ||
             {:error, "no bank file format '#{profile.format_code}' in force today"},
         :ok <- check_params(format.spec, profile),
         {:ok, payments} <- load_selected(profile, payment_ids, company),
         :ok <- preflight(payments) do
      do_create(profile, format, payments, payment_date, company, user)
    end
  end

  defp check_payment_date(date) do
    today = Date.utc_today()
    last = Date.add(today, @max_days_ahead)

    if Date.compare(date, today) != :lt and Date.compare(date, last) != :gt,
      do: :ok,
      else: {:error, "payment date must be between #{today} and #{last}"}
  end

  defp check_params(spec, profile) do
    have = for {k, v} <- profile.params || %{}, v not in [nil, ""], do: k

    case spec_params(spec) -- have do
      [] -> :ok
      missing -> {:error, "the bank payment profile is missing: #{Enum.join(missing, ", ")}"}
    end
  end

  defp load_selected(profile, payment_ids, company) do
    ids = payment_ids |> List.wrap() |> Enum.uniq()

    payments =
      from(p in base_query(profile, company), where: p.id in ^ids, preload: ^@preload)
      |> Repo.all()

    cond do
      ids == [] -> {:error, "tick at least one payment"}
      length(payments) != length(ids) -> {:error, "some ticked payments are not eligible for this bank account"}
      true -> {:ok, Enum.sort_by(payments, &{&1.payment_date, &1.payment_no})}
    end
  end

  defp preflight(payments) do
    live = MapSet.new(Repo.all(from(l in BatchLine, where: l.live and l.payment_id in ^Enum.map(payments, & &1.id), select: l.payment_id)))

    errors =
      Enum.flat_map(payments, fn p ->
        c = p.contact
        bank = Banks.get(c.bank_code)

        cond do
          MapSet.member?(live, p.id) ->
            ["#{p.payment_no}: already in a bank batch"]

          is_nil(c.bank_code) or is_nil(c.bank_account_no) or is_nil(c.bank_account_name) ->
            ["#{p.payment_no}: #{c.name} has no bank details"]

          is_nil(bank) or String.length(c.bank_account_no) not in bank.lengths ->
            ["#{p.payment_no}: #{c.name}'s account number does not suit #{c.bank_code}"]

          true ->
            []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp do_create(profile, format, payments, payment_date, company, user) do
    base = header_ctx(profile, company, payment_date)
    stem = stem_for(format, base, payment_date)
    chunks = Enum.chunk_every(payments, FileSpec.max_rows(format.spec) || length(payments))

    Repo.transaction(fn ->
      # Serialises batch creation per profile so sequence numbers never collide.
      Repo.one!(from(p in Profile, where: p.id == ^profile.id, lock: "FOR UPDATE", select: p.id))
      first = next_seq(company.id, stem)

      chunks
      |> Enum.with_index(first)
      |> Enum.map(fn {chunk, seq} ->
        insert_batch!(profile, format, chunk, base, stem, seq, payment_date, company, user)
      end)
    end)
  end

  defp header_ctx(profile, company, payment_date) do
    Map.merge(profile.params || %{}, %{
      "our_account_no" => profile.our_account_no,
      "payment_date" => payment_date,
      "today" => Date.utc_today(),
      "company_name" => company.name
    })
  end

  defp stem_for(format, base, payment_date) do
    FileSpec.filename(format.spec, base, nil) ||
      "#{format.code}_#{Calendar.strftime(payment_date, "%Y%m%d")}_"
  end

  defp filename_for(format, base, payment_date, seq) do
    FileSpec.filename(format.spec, base, seq) ||
      "#{stem_for(format, base, payment_date)}#{seq}.#{FileSpec.extension(format.spec)}"
  end

  # Voided batches count: banks refuse a filename that was already uploaded.
  defp next_seq(company_id, stem) do
    (Repo.one(from(b in Batch, where: b.company_id == ^company_id and b.filename_stem == ^stem, select: max(b.seq))) || 0) + 1
  end

  defp batch_no(seq),
    do: Calendar.strftime(Date.utc_today(), "%Y%m%d") <> String.pad_leading("#{seq}", 3, "0")

  defp insert_batch!(profile, format, chunk, base, stem, seq, payment_date, company, user) do
    header = base |> Map.put("seq", seq) |> Map.put("batch_no", batch_no(seq))
    filename = filename_for(format, base, payment_date, seq)
    total = Enum.reduce(chunk, Decimal.new(0), &Decimal.add(&1.funds_amount, &2))

    batch =
      %Batch{}
      |> Batch.changeset(%{
        company_id: company.id,
        profile_id: profile.id,
        format_id: format.id,
        payment_date: payment_date,
        filename_stem: stem,
        filename: filename,
        seq: seq,
        header: dump_header(header),
        count: length(chunk),
        total: total,
        created_by_id: user.id
      })
      |> Repo.insert()
      |> case do
        {:ok, b} -> b
        {:error, _} -> Repo.rollback("file #{filename} already exists; try again")
      end

    lines =
      Enum.map(chunk, fn p ->
        attrs =
          p
          |> Rows.line_attrs()
          |> Map.merge(%{batch_id: batch.id, payment_id: p.id, record_no: next_record_no()})

        case %BatchLine{} |> BatchLine.changeset(attrs) |> Repo.insert() do
          {:ok, l} -> l
          {:error, _} -> Repo.rollback("#{p.payment_no} was just batched by someone else")
        end
      end)

    case render_file(format.spec, Enum.map(lines, &Rows.to_row/1), header) do
      {:ok, _} -> :ok
      {:error, msg} -> Repo.rollback(msg)
    end

    Repo.insert!(
      Sys.log_changeset(
        :create_bank_payment_batch,
        batch,
        %{"filename" => filename, "count" => "#{batch.count}", "total" => Decimal.to_string(total)},
        company,
        user
      )
    )

    batch
  end

  defp next_record_no do
    %{rows: [[n]]} = Repo.query!("SELECT nextval('bank_payment_record_seq')")
    n
  end

  defp dump_header(header) do
    Map.new(header, fn
      {k, %Date{} = d} -> {k, Date.to_iso8601(d)}
      kv -> kv
    end)
  end

  defp load_header(header) do
    Enum.reduce(["payment_date", "today"], header, fn k, acc ->
      Map.update(acc, k, nil, &Date.from_iso8601!/1)
    end)
  end

  def void_batch(batch_id, reason, company, user) do
    reason = String.trim(reason || "")

    with true <- can?(user, :void_bank_payment_batch, company) || :not_authorise,
         %Batch{status: "exported"} = batch <- get_batch(batch_id, company) || {:error, "batch not found"},
         true <- reason != "" || {:error, "a reason is required to void a batch"} do
      Multi.new()
      |> Multi.update(
        :void_bank_payment_batch,
        Batch.void_changeset(batch, %{
          void_reason: reason,
          voided_by_id: user.id,
          voided_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      )
      |> Multi.update_all(:free_lines, from(l in BatchLine, where: l.batch_id == ^batch.id), set: [live: false])
      |> Sys.insert_log_for(:void_bank_payment_batch, %{"reason" => reason, "filename" => batch.filename}, company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{void_bank_payment_batch: b}} -> {:ok, b}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      %Batch{} -> {:error, "batch is already voided"}
      other -> other
    end
  end

  defp get_batch(id, company) do
    with {:ok, uuid} <- Ecto.UUID.cast(id || "") do
      Repo.get_by(Batch, id: uuid, company_id: company.id)
    else
      _ -> nil
    end
  end

  def list_batches(company) do
    from(b in Batch,
      where: b.company_id == ^company.id,
      order_by: [desc: b.inserted_at, desc: b.seq],
      limit: 50
    )
    |> Repo.all()
  end

  @doc "Rebuilds each batch's file from its saved lines, header and format version."
  def batch_files(ids, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise do
      ids
      |> List.wrap()
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
        case batch_file(id, company) do
          {:ok, file} -> {:cont, {:ok, acc ++ [file]}}
          {:error, msg} -> {:halt, {:error, msg}}
        end
      end)
    end
  end

  defp batch_file(id, company) do
    case get_batch(id, company) do
      nil ->
        {:error, "batch not found"}

      batch ->
        batch = Repo.preload(batch, [:format, lines: from(l in BatchLine, order_by: l.record_no)])

        case render_file(batch.format.spec, Enum.map(batch.lines, &Rows.to_row/1), load_header(batch.header)) do
          {:ok, text} -> {:ok, {batch.filename, text}}
          {:error, msg} -> {:error, msg}
        end
    end
  end

  def zip(files) do
    entries = Enum.map(files, fn {name, text} -> {String.to_charlist(name), text} end)
    {:ok, {_name, bin}} = :zip.create(~c"bank_batches.zip", entries, [:memory])
    {:ok, bin}
  end

  @doc "Renders `spec` (saved or not) against up to 10 eligible payments with bank details."
  def preview(spec, %Profile{} = profile, company) do
    payments =
      from([p, contact: c] in base_query(profile, company),
        where: not is_nil(c.bank_code) and not is_nil(c.bank_account_no) and not is_nil(c.bank_account_name),
        order_by: [desc: p.payment_date],
        limit: 10,
        preload: ^@preload
      )
      |> Repo.all()

    rows =
      payments
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> p |> Rows.line_attrs() |> Map.put(:record_no, i) |> Rows.to_row() end)

    header =
      profile
      |> header_ctx(company, Date.utc_today())
      |> Map.merge(%{"seq" => 1, "batch_no" => batch_no(1)})

    render_file(spec, rows, header)
  end

  # ── Payment lock ───────────────────────────────────

  def live_batch_filename(payment_id) do
    from(l in BatchLine,
      join: b in Batch,
      on: b.id == l.batch_id,
      where: l.payment_id == ^payment_id and l.live,
      select: b.filename
    )
    |> Repo.one()
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/bank_payment_test.exs test/full_circle/bank_payment_golden_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex test/full_circle/bank_payment_test.exs
git add lib/full_circle/bank_payment.ex test/full_circle/bank_payment_test.exs
git commit -m "feat(bank-payment): eligible payments, batch creation, void and re-download

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Lock batched Payments

**Files:**
- Modify: `lib/full_circle/bank_payment.ex` (`assert_payment_unlocked/2`)
- Modify: `lib/full_circle/bill_pay.ex:399-416` (`update_payment/4` `with` chain)
- Modify: `lib/full_circle_web/live/payment_live/form.ex` (mount assigns, error clause, banner)
- Modify: `lib/full_circle_web/live/payment_live/index_component.ex` (tag)
- Test: `test/full_circle/bank_payment_test.exs`

**Interfaces:**
- Produces: `BankPayment.assert_payment_unlocked(payment, changeset) :: :ok | {:error, :bank_batched, filename}`. `BillPay.update_payment/4` may now return `{:error, :bank_batched, filename}`.

- [ ] **Step 1: Write the failing tests** — append to `FullCircle.BankPaymentTest`:

```elixir
  describe "payment lock" do
    test "locked fields are refused while batched; other edits pass", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      {:ok, [b]} = BankPayment.create_batches(profile.id, [p.id], Date.utc_today(), company, admin)

      assert :ok = BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, descriptions: "x"))

      assert {:error, :bank_batched, name} =
               BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, funds_amount: Decimal.new("1")))

      assert name == b.filename

      p = FullCircle.BillPay.get_payment!(p.id, company, admin)
      assert {:error, :bank_batched, ^name} = FullCircle.BillPay.update_payment(p, %{"funds_amount" => "1.00"}, company, admin)

      {:ok, _} = BankPayment.void_batch(b.id, "redo", company, admin)
      assert :ok = BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, funds_amount: Decimal.new("1")))
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/bank_payment_test.exs`
Expected: FAIL — `assert_payment_unlocked/2` undefined.

- [ ] **Step 3: Implement**

In `lib/full_circle/bank_payment.ex`, under "Payment lock":

```elixir
  @locked_fields [:funds_amount, :contact_id, :funds_account_id, :payment_date]

  @doc "Refuses changes to a batched Payment's amount, supplier, funds account or date."
  def assert_payment_unlocked(%Payment{id: id}, %Ecto.Changeset{} = cs) do
    case live_batch_filename(id) do
      nil ->
        :ok

      filename ->
        if Enum.any?(@locked_fields, &Map.has_key?(cs.changes, &1)),
          do: {:error, :bank_batched, filename},
          else: :ok
    end
  end
```

In `lib/full_circle/bill_pay.ex` `update_payment/4`, extend the `with`:

```elixir
    with true <- can?(user, :update_payment, com) || :not_authorise,
         :ok <-
           Accounting.assert_doc_editable(payment.id, "Payment", com.id, check_matchers: false),
         :ok <-
           FullCircle.BankPayment.assert_payment_unlocked(
             payment,
             make_changeset(Payment, payment, attrs, com, user)
           ) do
```

In `lib/full_circle_web/live/payment_live/form.ex`:

- In `mount/3`'s final pipeline (after `|> assign(matchers_got_error: false)`), add `|> assign_new(:bank_batch, fn -> nil end)`.
- In `mount_edit/2`, add `|> assign(:bank_batch, FullCircle.BankPayment.live_batch_filename(object.id))` before `|> assign(:form, to_form(cs))`.
- In the edit-save `case BillPay.update_payment(...)`, add before the `{:error, failed_operation, changeset, _}` clause:

```elixir
      {:error, :bank_batched, filename} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "In bank batch %{file}: void the batch first to change the amount, supplier, funds account or date.",
             file: filename
           )
         )}
```

- In `render/1`, directly after `<p class="w-full text-3xl text-center font-medium">{@page_title}</p>`:

```heex
        <div
          :if={@bank_batch}
          id="bank-batch-banner"
          class="text-center rounded border border-amber-500 bg-amber-100 dark:bg-amber-900/40 p-1 mb-1"
        >
          {gettext(
            "In bank batch %{file}: amount, supplier, funds account and date are locked.",
            file: @bank_batch
          )}
        </div>
```

In `lib/full_circle_web/live/payment_live/index_component.ex`:

- In `update/2`, add `|> assign_new(:bank_batch, fn %{obj: obj} -> FullCircle.BankPayment.live_batch_filename(obj.id) end)` after `|> assign(assigns)`.
- After `<.row_notes_badge count={@note_count} tasks={@task_count} id={@obj.id} />`:

```heex
            <span
              :if={@bank_batch}
              class="text-xs rounded px-1 bg-amber-200 text-amber-900 dark:bg-amber-800 dark:text-amber-100"
              title={@bank_batch}
            >
              {gettext("Bank")}
            </span>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/bank_payment_test.exs test/full_circle/bill_pay_test.exs test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/stale_save_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/form.ex lib/full_circle_web/live/payment_live/index_component.ex test/full_circle/bank_payment_test.exs
git add lib/full_circle/bank_payment.ex lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/form.ex lib/full_circle_web/live/payment_live/index_component.ex test/full_circle/bank_payment_test.exs
git commit -m "feat(bank-payment): lock a batched Payment's amount, supplier, account and date

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Settings pages — profiles and file formats

**Files:**
- Create: `lib/full_circle_web/live/bank_payment_profile_live/index.ex`, `.../form.ex`
- Create: `lib/full_circle_web/live/bank_file_format_live/index.ex`, `.../form.ex`
- Modify: `lib/full_circle_web/router.ex` (live routes, inside the `:require_authenticated_user_n_active_company` live_session next to the statutory routes)
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` (admin button)
- Test: `test/full_circle_web/live/bank_setup_live_test.exs`

**Interfaces:**
- Consumes: Task 9 and Task 11 context functions.
- Produces routes: `/companies/:company_id/bank_payment_profiles`, `/bank_payment_profiles/new`, `/bank_payment_profiles/:id/edit`, `/bank_file_formats`, `/bank_file_formats/new` (optional `?code=`). Form ids: `#profile-form` (params `profile`), `#format-form` (params `file_format`).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.BankSetupLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BankPaymentFixtures

  setup %{conn: conn} do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    %{conn: log_in_user(conn, admin), admin: admin, com: com}
  end

  test "load a template and save it as a format", %{conn: conn, com: com} do
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_file_formats/new")

    html = lv |> form("#format-form", %{"file_format" => %{"template" => "rhb_bulk_pay"}}) |> render_change()
    html = lv |> element("#load-template") |> render_click()
    assert html =~ "hash_part"

    lv |> form("#format-form") |> render_submit()
    {:ok, _, html} = live(conn, ~p"/companies/#{com.id}/bank_file_formats")
    assert html =~ "rhb_bulk_pay"
  end

  test "create a profile and warn about missing params", %{conn: conn, com: com, admin: admin} do
    install_template!(com, admin, "rhb_bulk_pay")
    bank = bank_gl_account_fixture(com, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_payment_profiles/new")

    lv
    |> form("#profile-form", %{
      "profile" => %{
        "account_id" => bank.id,
        "format_code" => "rhb_bulk_pay",
        "our_account_no" => "21234500012345",
        "start_date" => "2026-10-01",
        "params_text" => "corporate_id=123456"
      }
    })
    |> render_submit()

    {path, flash} = assert_redirect(lv)
    assert path =~ "/bank_payment_profiles"
    assert flash["warn"] =~ "corporate_name"
  end

  test "managers cannot open setup", %{com: com, admin: admin} do
    mgr = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, mgr, "manager", admin)
    conn = log_in_user(build_conn(), mgr)
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{com.id}/bank_file_formats")
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{com.id}/bank_payment_profiles")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/live/bank_setup_live_test.exs`
Expected: FAIL — no route.

- [ ] **Step 3: Add routes** in `lib/full_circle_web/router.ex` after `live("/statutory_bundle/import", StatutoryBundleLive.Import, :new)`:

```elixir
      live("/bank_payment_profiles", BankPaymentProfileLive.Index, :index)
      live("/bank_payment_profiles/new", BankPaymentProfileLive.Form, :new)
      live("/bank_payment_profiles/:id/edit", BankPaymentProfileLive.Form, :edit)

      live("/bank_file_formats", BankFileFormatLive.Index, :index)
      live("/bank_file_formats/new", BankFileFormatLive.Form, :new)

      live("/bank_batches", BankBatchLive.Index, :index)
```

(`/bank_batches` is implemented in Task 14; until then `mix compile` warns about the missing module — create Task 14's file before running the full suite, or add this one line in Task 14 instead.)

- [ ] **Step 4: Implement the profile pages**

`lib/full_circle_web/live/bank_payment_profile_live/index.ex`:

```elixir
defmodule FullCircleWeb.BankPaymentProfileLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    if FullCircle.Authorization.can?(socket.assigns.current_user, :manage_bank_payment_config, socket.assigns.current_company) do
      {:ok,
       socket
       |> assign(page_title: gettext("Bank Payment Profiles"))
       |> assign(profiles: BankPayment.list_profiles(socket.assigns.current_company))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-2 flex justify-center gap-2">
        <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles/new"} class="blue button" id="new_profile">
          {gettext("New Profile")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats"} class="blue button">
          {gettext("Bank File Formats")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_batches"} class="blue button">
          {gettext("Bank Batches")}
        </.link>
      </div>
      <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-2">
        <div class="col-span-4">{gettext("Bank Account")}</div>
        <div class="col-span-3">{gettext("Format")}</div>
        <div class="col-span-3">{gettext("Our Account No")}</div>
        <div class="col-span-2">{gettext("Start Date")}</div>
      </div>
      <div :for={p <- @profiles} id={"profile-#{p.id}"} class="grid grid-cols-12 p-2 border-b">
        <div class="col-span-4">
          <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles/#{p.id}/edit"} class="text-blue-600 hover:font-bold">
            {p.account_name}
          </.link>
        </div>
        <div class="col-span-3">{p.format_code}</div>
        <div class="col-span-3">{p.our_account_no}</div>
        <div class="col-span-2">{FullCircleWeb.Helpers.format_date(p.start_date)}</div>
      </div>
    </div>
    """
  end
end
```

`lib/full_circle_web/live/bank_payment_profile_live/form.ex`:

```elixir
defmodule FullCircleWeb.BankPaymentProfileLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Profile

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(socket.assigns.current_user, :manage_bank_payment_config, com) do
      profile =
        case params["id"] do
          nil -> %Profile{params: %{}}
          id -> BankPayment.get_profile(id, com) || raise(Ecto.NoResultsError, queryable: Profile)
        end

      {:ok,
       socket
       |> assign(page_title: if(profile.id, do: gettext("Edit Bank Payment Profile"), else: gettext("New Bank Payment Profile")))
       |> assign(profile: profile)
       |> assign(bank_accounts: BankPayment.bank_accounts(com))
       |> assign(format_codes: BankPayment.format_codes(com.id))
       |> assign(errors: [])
       |> assign(form: %{
         "account_id" => profile.account_id,
         "format_code" => profile.format_code || "",
         "our_account_no" => profile.our_account_no || "",
         "start_date" => (profile.start_date && Date.to_iso8601(profile.start_date)) || Date.to_iso8601(Date.utc_today()),
         "params_text" => Profile.params_text(profile.params)
       })}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"profile" => params}, socket) do
    {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params))}
  end

  @impl true
  def handle_event("save", %{"profile" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)

    attrs =
      form
      |> Map.put("params", Profile.parse_params(form["params_text"]))
      |> Map.delete("params_text")

    com = socket.assigns.current_company

    case BankPayment.save_profile(socket.assigns.profile, attrs, com, socket.assigns.current_user) do
      {:ok, profile} ->
        socket =
          case BankPayment.missing_params(profile) do
            [] -> put_flash(socket, :info, gettext("Bank payment profile saved."))
            :no_format -> put_flash(socket, :warn, gettext("Saved. No file format '%{code}' is in force yet.", code: profile.format_code))
            missing -> put_flash(socket, :warn, gettext("Saved, but the format needs: %{params}", params: Enum.join(missing, ", ")))
          end

        {:noreply, push_navigate(socket, to: ~p"/companies/#{com.id}/bank_payment_profiles")}

      {:error, cs} ->
        {:noreply, assign(socket, form: form, errors: changeset_errors(cs))}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={%{}} id="profile-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Bank Account (GL)")}</label>
            <select name="profile[account_id]" class="w-full border rounded px-2 py-1 dark:bg-gray-800">
              <option value="">{gettext("-- choose --")}</option>
              <option :for={{name, id} <- @bank_accounts} value={id} selected={id == @form["account_id"]}>{name}</option>
            </select>
          </div>
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Format Code")}</label>
            <input type="text" name="profile[format_code]" value={@form["format_code"]} list="format-codes" class="w-full border rounded px-2 py-1 dark:bg-gray-800" />
            <datalist id="format-codes">
              <option :for={c <- @format_codes} value={c} />
            </datalist>
          </div>
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Our Account No")}</label>
            <input type="text" name="profile[our_account_no]" value={@form["our_account_no"]} class="w-full border rounded px-2 py-1 dark:bg-gray-800" />
          </div>
          <div class="col-span-6">
            <label class="block text-sm font-medium">{gettext("Start Date")}</label>
            <input type="date" name="profile[start_date]" value={@form["start_date"]} class="w-full border rounded px-2 py-1 dark:bg-gray-800" />
          </div>
          <div class="col-span-12">
            <label class="block text-sm font-medium">{gettext("Bank params (one key=value per line)")}</label>
            <textarea name="profile[params_text]" rows="4" class="w-full font-mono text-sm border rounded px-2 py-1 dark:bg-gray-800">{@form["params_text"]}</textarea>
          </div>
        </div>
        <p :for={msg <- @errors} class="text-rose-600 text-sm">{msg}</p>
        <div class="flex justify-center mt-4 gap-2">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"} class="blue button">{gettext("Cancel")}</.link>
        </div>
      </.form>
    </div>
    """
  end
end
```

- [ ] **Step 5: Implement the format pages**

`lib/full_circle_web/live/bank_file_format_live/index.ex`:

```elixir
defmodule FullCircleWeb.BankFileFormatLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(socket.assigns.current_user, :manage_bank_payment_config, com) do
      {:ok,
       socket
       |> assign(page_title: gettext("Bank File Formats"))
       |> assign(formats: BankPayment.list_formats(com.id))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-6/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-2 flex justify-center gap-2">
        <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats/new"} class="blue button" id="new_format">
          {gettext("New Version")}
        </.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"} class="blue button">
          {gettext("Bank Payment Profiles")}
        </.link>
      </div>
      <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-2">
        <div class="col-span-4">{gettext("Code")}</div>
        <div class="col-span-5">{gettext("Name")}</div>
        <div class="col-span-3">{gettext("Effective From")}</div>
      </div>
      <div :for={f <- @formats} id={"format-#{f.id}"} class="grid grid-cols-12 p-2 border-b">
        <div class="col-span-4">
          <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats/new?#{[code: f.code]}"} class="text-blue-600 hover:font-bold">
            {f.code}
          </.link>
        </div>
        <div class="col-span-5">{f.name}</div>
        <div class="col-span-3">{FullCircleWeb.Helpers.format_date(f.effective_from)}</div>
      </div>
    </div>
    """
  end
end
```

`lib/full_circle_web/live/bank_file_format_live/form.ex`:

```elixir
defmodule FullCircleWeb.BankFileFormatLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(socket.assigns.current_user, :manage_bank_payment_config, com) do
      code = params["code"] || ""

      {name, spec_json} =
        case code != "" && Enum.find(BankPayment.list_formats(com.id), &(&1.code == code)) do
          %{} = newest -> {newest.name, Jason.encode!(newest.spec, pretty: true)}
          _ -> {"", "{}"}
        end

      profiles = BankPayment.list_profiles(com)

      {:ok,
       socket
       |> assign(page_title: gettext("New Bank File Format Version"))
       |> assign(templates: BankPayment.templates(), profiles: profiles)
       |> assign(form: %{
         "code" => code,
         "name" => name,
         "effective_from" => Date.to_iso8601(Date.utc_today()),
         "spec" => spec_json,
         "template" => "",
         "profile_id" => (List.first(profiles) || %{id: ""}).id
       })
       |> assign(preview_lines: nil, preview_error: nil, spec_errors: [], save_errors: [], confirm_replace: false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  @impl true
  def handle_event("validate", %{"file_format" => params}, socket) do
    {:noreply,
     socket
     |> assign(form: Map.merge(socket.assigns.form, params), confirm_replace: false)
     |> assign_spec_errors(params["spec"])}
  end

  @impl true
  def handle_event("load_template", _params, socket) do
    case BankPayment.load_template(socket.assigns.form["template"] || "") do
      {:ok, t} ->
        form =
          Map.merge(socket.assigns.form, %{
            "code" => t["code"],
            "name" => t["name"],
            "spec" => Jason.encode!(t["spec"], pretty: true)
          })

        {:noreply, socket |> assign(form: form) |> assign_spec_errors(form["spec"])}

      {:error, msg} ->
        {:noreply, assign(socket, save_errors: [msg])}
    end
  end

  @impl true
  def handle_event("preview", _params, socket) do
    form = socket.assigns.form
    com = socket.assigns.current_company

    with {:ok, spec} <- decode_and_validate(form["spec"]),
         %{} = profile <- BankPayment.get_profile(form["profile_id"], com) || {:error, gettext("choose a profile to preview with")},
         {:ok, text} <- BankPayment.preview(spec, profile, com) do
      lines = text |> String.split(~r/\r?\n/, trim: true) |> Enum.take(20)
      {:noreply, assign(socket, preview_lines: lines, preview_error: nil)}
    else
      {:error, msg} -> {:noreply, assign(socket, preview_lines: nil, preview_error: msg)}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    form = Map.merge(socket.assigns.form, Map.get(params, "file_format", %{}))
    socket = assign(socket, form: form)

    if BankPayment.format_version_exists?(socket.assigns.current_company.id, form["code"], form["effective_from"]),
      do: {:noreply, assign(socket, confirm_replace: true, save_errors: [])},
      else: do_save(socket, [])
  end

  @impl true
  def handle_event("replace", _params, socket), do: do_save(socket, replace: true)

  defp do_save(socket, opts) do
    form = socket.assigns.form
    com = socket.assigns.current_company

    with {:ok, spec} <- decode_and_validate(form["spec"]) do
      attrs = %{"code" => form["code"], "name" => form["name"], "effective_from" => form["effective_from"], "spec" => spec}

      case BankPayment.save_format(attrs, com, socket.assigns.current_user, opts) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, if(opts[:replace], do: gettext("File format version replaced."), else: gettext("File format saved.")))
           |> push_navigate(to: ~p"/companies/#{com.id}/bank_file_formats")}

        {:error, cs} ->
          {:noreply, assign(socket, confirm_replace: false, save_errors: changeset_errors(cs))}

        :not_authorise ->
          {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
      end
    else
      {:error, _} ->
        {:noreply, assign(socket, confirm_replace: false, save_errors: [gettext("fix spec errors before saving")])}
    end
  end

  defp decode_and_validate(json) when is_binary(json) do
    with {:ok, spec} <- Jason.decode(json),
         :ok <- BankPayment.validate_spec(spec) do
      {:ok, spec}
    else
      {:error, %Jason.DecodeError{}} -> {:error, gettext("invalid JSON")}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
      {:error, msg} -> {:error, msg}
    end
  end

  defp decode_and_validate(_), do: {:error, gettext("spec is required")}

  defp assign_spec_errors(socket, json) when is_binary(json) do
    errors =
      case Jason.decode(json) do
        {:ok, spec} ->
          case BankPayment.validate_spec(spec) do
            :ok -> []
            {:error, errs} -> errs
          end

        {:error, _} ->
          [gettext("invalid JSON")]
      end

    assign(socket, spec_errors: errors)
  end

  defp assign_spec_errors(socket, _), do: socket

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field}: #{&1}") end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-9/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 dark:bg-yellow-900/30 p-4">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form for={%{}} id="format-form" phx-change="validate" phx-submit="save" autocomplete="off">
        <div class="grid grid-cols-12 gap-2 mb-2">
          <div class="col-span-4">
            <label class="block text-sm font-medium">{gettext("Template")}</label>
            <select name="file_format[template]" class="w-full border rounded px-2 py-1 dark:bg-gray-800">
              <option value="">{gettext("-- choose --")}</option>
              <option :for={t <- @templates} value={t.code} selected={t.code == @form["template"]}>{t.name}</option>
            </select>
          </div>
          <div class="col-span-2 mt-6">
            <button type="button" id="load-template" phx-click="load_template" class="blue button">
              {gettext("Load template")}
            </button>
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2 mb-2">
          <div class="col-span-4">
            <label class="block text-sm font-medium">{gettext("Code")}</label>
            <input type="text" name="file_format[code]" value={@form["code"]} class="w-full border rounded px-2 py-1 dark:bg-gray-800" />
          </div>
          <div class="col-span-5">
            <label class="block text-sm font-medium">{gettext("Name")}</label>
            <input type="text" name="file_format[name]" value={@form["name"]} class="w-full border rounded px-2 py-1 dark:bg-gray-800" />
          </div>
          <div class="col-span-3">
            <label class="block text-sm font-medium">{gettext("Effective From")}</label>
            <input type="date" name="file_format[effective_from]" value={@form["effective_from"]} class="w-full border rounded px-2 py-1 dark:bg-gray-800" />
          </div>
        </div>

        <label class="block text-sm font-medium">{gettext("Spec (JSON)")}</label>
        <textarea name="file_format[spec]" rows="18" class="w-full font-mono text-sm border rounded px-2 py-1 dark:bg-gray-800">{@form["spec"]}</textarea>
        <p :for={msg <- @spec_errors} class="text-rose-600 text-sm">{msg}</p>
        <p :for={msg <- @save_errors} class="text-rose-600 text-sm">{msg}</p>

        <div class="mt-4 border rounded p-3 bg-white dark:bg-gray-800">
          <p class="font-semibold mb-2">{gettext("Preview")}</p>
          <div class="grid grid-cols-12 gap-2">
            <div class="col-span-6">
              <label class="block text-sm font-medium">{gettext("Profile")}</label>
              <select name="file_format[profile_id]" class="w-full border rounded px-2 py-1 dark:bg-gray-800">
                <option :for={p <- @profiles} value={p.id} selected={p.id == @form["profile_id"]}>{p.account_name}</option>
              </select>
            </div>
            <div class="col-span-3 mt-6">
              <button type="button" phx-click="preview" class="blue button">{gettext("Preview")}</button>
            </div>
          </div>
          <p :if={@preview_error} class="text-rose-600 mt-2">{@preview_error}</p>
          <pre :if={@preview_lines} class="mt-2 font-mono text-xs overflow-x-auto bg-gray-100 dark:bg-gray-900 p-2 rounded">{Enum.join(@preview_lines, "\n")}</pre>
        </div>

        <div :if={@confirm_replace} class="mt-4 border rounded border-amber-500 bg-amber-100 dark:bg-amber-900/40 p-3 text-center">
          <p class="font-semibold">
            {gettext("A version of '%{code}' effective %{date} already exists.", code: @form["code"], date: @form["effective_from"])}
          </p>
          <button type="button" phx-click="replace" class="red button" id="replace-version">
            {gettext("Replace this version")}
          </button>
        </div>

        <div class="flex justify-center mt-4 gap-2">
          <button type="submit" class="blue button">{gettext("Save")}</button>
          <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats"} class="blue button">{gettext("Cancel")}</.link>
        </div>
      </.form>
    </div>
    """
  end
end
```

- [ ] **Step 6: Dashboard link** — in `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, after the `Statutory Calcs` link block:

```heex
        <.link
          :if={@current_role == "admin"}
          navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"}
          class="button orange"
        >
          {gettext("Bank Payment Setup")}
        </.link>
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/bank_setup_live_test.exs`
Expected: PASS (if Task 14 is not done yet, temporarily omit the `/bank_batches` route line and add it in Task 14).

- [ ] **Step 8: Commit**

```bash
mix format lib/full_circle_web/live/bank_payment_profile_live/index.ex lib/full_circle_web/live/bank_payment_profile_live/form.ex lib/full_circle_web/live/bank_file_format_live/index.ex lib/full_circle_web/live/bank_file_format_live/form.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/bank_setup_live_test.exs
git add lib/full_circle_web/live/bank_payment_profile_live/ lib/full_circle_web/live/bank_file_format_live/ lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/bank_setup_live_test.exs
git commit -m "feat(bank-payment): admin pages for paying-account profiles and file formats

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Bank Batch screen, download controller, JS download

**Files:**
- Create: `lib/full_circle_web/live/bank_batch_live/index.ex`
- Create: `lib/full_circle_web/controllers/bank_batch_controller.ex`
- Modify: `lib/full_circle_web/router.ex` (`get "/bank_batches/download", …` beside `get "/csv", …`; `live("/bank_batches", …)` if not added in Task 13)
- Modify: `assets/js/app.js` (window `phx:download` listener)
- Modify: `lib/full_circle_web/live/dashboard_live/dashboard_live.ex` (manager/admin button next to Payments)
- Test: `test/full_circle_web/live/bank_batch_live_test.exs`

**Interfaces:**
- Consumes: `eligible_payments/2`, `create_batches/5`, `void_batch/4`, `list_batches/1`, `batch_files/3`, `zip/1`, `list_profiles/1`.
- Produces: route `GET /companies/:company_id/bank_batches/download?ids=a,b` (one file → that file; several → `bank_batches.zip`); push event `"download"` with `%{url: url}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.BankBatchLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    install_template!(com, admin, "rhb_bulk_pay")
    bank = bank_gl_account_fixture(com, admin)
    profile = profile_fixture(com, admin, bank)
    supplier = bank_contact_fixture(com, admin)
    p = bank_payment_fixture(com, admin, supplier, bank, "321.00")
    mgr = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, mgr, "manager", admin)
    %{admin: admin, com: com, profile: profile, p: p, mgr_conn: log_in_user(build_conn(), mgr)}
  end

  test "tick, create, download, then void", %{com: com, p: p, mgr_conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    assert html =~ p.payment_no

    lv |> element("#tick-#{p.id}") |> render_click()
    assert render(lv) =~ "321.00"

    lv |> element("#create-file") |> render_click()
    assert_push_event(lv, "download", %{url: url})
    html = render(lv)
    assert html =~ ~r/PAYMENT_123456_\d{8}_001\.CSV/
    refute html =~ "tick-#{p.id}"

    resp = get(conn, url)
    assert resp.status == 200
    assert [cd] = get_resp_header(resp, "content-disposition")
    assert cd =~ "PAYMENT_123456_"
    assert resp.resp_body =~ ",321.00,"

    [batch] = FullCircle.BankPayment.list_batches(com)
    lv |> element("#void-#{batch.id}") |> render_click()
    lv |> form("#void-form", %{"reason" => "bank rejected"}) |> render_submit()
    assert render(lv) =~ "tick-#{p.id}"
  end

  test "clerks are sent away and cannot download", %{admin: admin, com: com} do
    clerk = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, clerk, "clerk", admin)
    conn = log_in_user(build_conn(), clerk)
    assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    assert get(conn, ~p"/companies/#{com.id}/bank_batches/download?#{[ids: Ecto.UUID.generate()]}").status == 403
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/live/bank_batch_live_test.exs`
Expected: FAIL — no route / module.

- [ ] **Step 3: Implement**

Router — beside `get "/csv", CsvController, :show`:

```elixir
    get "/bank_batches/download", BankBatchController, :download
```

and, if Task 13 left it out, `live("/bank_batches", BankBatchLive.Index, :index)` in the live_session.

`lib/full_circle_web/controllers/bank_batch_controller.ex`:

```elixir
defmodule FullCircleWeb.BankBatchController do
  use FullCircleWeb, :controller

  alias FullCircle.BankPayment

  def download(conn, %{"company_id" => com_id, "ids" => ids}) do
    company = FullCircle.Sys.get_company!(com_id)
    ids = String.split(ids, ",", trim: true)

    case BankPayment.batch_files(ids, company, conn.assigns.current_user) do
      {:ok, [{name, text}]} ->
        send_download(conn, {:binary, text}, filename: name, content_type: MIME.from_path(name))

      {:ok, files} ->
        {:ok, zip} = BankPayment.zip(files)
        send_download(conn, {:binary, zip}, filename: "bank_batches.zip", content_type: "application/zip")

      :not_authorise ->
        conn |> put_status(403) |> text("not authorised")

      {:error, msg} ->
        conn |> put_status(404) |> text(msg)
    end
  end
end
```

`assets/js/app.js` — after the `phx:history_back` listener:

```js
// Bank batch files: the server pushes a download URL after creating a batch.
window.addEventListener("phx:download", (e) => {
  const a = document.createElement("a")
  a.href = e.detail.url
  document.body.appendChild(a)
  a.click()
  a.remove()
})
```

`lib/full_circle_web/live/bank_batch_live/index.ex`:

```elixir
defmodule FullCircleWeb.BankBatchLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(socket.assigns.current_user, :create_bank_payment_batch, com) do
      profiles = BankPayment.list_profiles(com)

      {:ok,
       socket
       |> assign(page_title: gettext("Bank Batches"))
       |> assign(profiles: profiles)
       |> assign(profile: List.first(profiles))
       |> assign(payment_date: Date.utc_today())
       |> assign(selected: MapSet.new(), errors: [], void_id: nil)
       |> load_rows()
       |> load_batches()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  defp load_rows(%{assigns: %{profile: nil}} = socket), do: assign(socket, rows: [])

  defp load_rows(socket) do
    assign(socket, rows: BankPayment.eligible_payments(socket.assigns.profile, socket.assigns.current_company))
  end

  defp load_batches(socket), do: assign(socket, batches: BankPayment.list_batches(socket.assigns.current_company))

  @impl true
  def handle_event("params", params, socket) do
    profile =
      Enum.find(socket.assigns.profiles, &(&1.id == params["profile_id"])) || socket.assigns.profile

    date =
      case Date.from_iso8601(params["payment_date"] || "") do
        {:ok, d} -> d
        _ -> socket.assigns.payment_date
      end

    socket = assign(socket, payment_date: date, errors: [])

    if profile && socket.assigns.profile && profile.id == socket.assigns.profile.id,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(profile: profile, selected: MapSet.new()) |> load_rows()}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.rows, &(&1.id == id and &1.has_bank)) do
      selected =
        if MapSet.member?(socket.assigns.selected, id),
          do: MapSet.delete(socket.assigns.selected, id),
          else: MapSet.put(socket.assigns.selected, id)

      {:noreply, assign(socket, selected: selected)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create", _params, socket) do
    %{profile: profile, selected: selected, payment_date: date, current_company: com, current_user: user} =
      socket.assigns

    case BankPayment.create_batches(profile && profile.id, MapSet.to_list(selected), date, com, user) do
      {:ok, batches} ->
        url = ~p"/companies/#{com.id}/bank_batches/download?#{[ids: Enum.map_join(batches, ",", & &1.id)]}"

        {:noreply,
         socket
         |> assign(selected: MapSet.new(), errors: [])
         |> load_rows()
         |> load_batches()
         |> put_flash(:info, gettext("Bank file created: %{files}", files: Enum.map_join(batches, ", ", & &1.filename)))
         |> push_event("download", %{url: url})}

      {:error, msgs} when is_list(msgs) ->
        {:noreply, assign(socket, errors: msgs)}

      {:error, msg} ->
        {:noreply, socket |> assign(errors: [msg]) |> load_rows()}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def handle_event("start_void", %{"id" => id}, socket), do: {:noreply, assign(socket, void_id: id)}

  @impl true
  def handle_event("cancel_void", _params, socket), do: {:noreply, assign(socket, void_id: nil)}

  @impl true
  def handle_event("void", %{"reason" => reason}, socket) do
    case BankPayment.void_batch(socket.assigns.void_id, reason, socket.assigns.current_company, socket.assigns.current_user) do
      {:ok, b} ->
        {:noreply,
         socket
         |> assign(void_id: nil)
         |> load_rows()
         |> load_batches()
         |> put_flash(:info, gettext("Batch %{file} voided.", file: b.filename))}

      {:error, msg} when is_binary(msg) ->
        {:noreply, assign(socket, errors: [msg])}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not void the batch."))}
    end
  end

  defp total(rows, selected) do
    rows
    |> Enum.filter(&MapSet.member?(selected, &1.id))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp money(d), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-10/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <p :if={@profiles == []} class="text-center">
        {gettext("No bank payment profile yet. An admin sets one up under Bank Payment Setup.")}
      </p>

      <form :if={@profiles != []} id="batch-params" phx-change="params" class="flex justify-center gap-2 mb-2">
        <select name="profile_id" class="border rounded px-2 py-1 dark:bg-gray-800">
          <option :for={p <- @profiles} value={p.id} selected={@profile && p.id == @profile.id}>
            {p.account_name} ({p.format_code})
          </option>
        </select>
        <input type="date" name="payment_date" value={Date.to_iso8601(@payment_date)} class="border rounded px-2 py-1 dark:bg-gray-800" />
      </form>

      <div :if={@errors != []} id="batch-errors" class="border rounded border-rose-500 bg-rose-50 dark:bg-rose-900/30 p-2 mb-2">
        <p :for={e <- @errors} class="text-rose-700 dark:text-rose-300 text-sm">{e}</p>
      </div>

      <div :if={@profile} class="mb-4">
        <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-1">
          <div class="col-span-1"></div>
          <div class="col-span-1">{gettext("Date")}</div>
          <div class="col-span-2">{gettext("Payment No")}</div>
          <div class="col-span-3">{gettext("Supplier")}</div>
          <div class="col-span-2">{gettext("Bank")}</div>
          <div class="col-span-2">{gettext("Account No")}</div>
          <div class="col-span-1 text-right">{gettext("Amount")}</div>
        </div>
        <div
          :for={r <- @rows}
          id={"row-#{r.id}"}
          class={["grid grid-cols-12 p-1 border-b items-center", !r.has_bank && "opacity-50"]}
        >
          <div class="col-span-1">
            <input
              :if={r.has_bank}
              type="checkbox"
              id={"tick-#{r.id}"}
              phx-click="toggle"
              phx-value-id={r.id}
              checked={MapSet.member?(@selected, r.id)}
            />
            <span
              :if={r.recent_change}
              class="text-xs rounded px-1 bg-amber-300 text-amber-900 dark:bg-amber-700 dark:text-amber-100"
              title={gettext("Bank details changed %{at}", at: to_string(r.changed_at))}
            >
              ⚠
            </span>
          </div>
          <div class="col-span-1">{FullCircleWeb.Helpers.format_date(r.payment_date)}</div>
          <div class="col-span-2">{r.payment_no}</div>
          <div class="col-span-3 truncate">{r.contact_name}</div>
          <div class="col-span-2 truncate">{if r.has_bank, do: r.bank_name, else: gettext("no bank details")}</div>
          <div class="col-span-2">{r.account_no}</div>
          <div class="col-span-1 text-right tabular-nums">{money(r.amount)}</div>
        </div>
        <div class="flex justify-center items-center gap-4 mt-2">
          <span>{gettext("%{n} ticked, total %{total}", n: MapSet.size(@selected), total: money(total(@rows, @selected)))}</span>
          <button id="create-file" phx-click="create" class="blue button" disabled={MapSet.size(@selected) == 0}>
            {gettext("Create file")}
          </button>
        </div>
      </div>

      <div class="font-bold bg-gray-200 dark:bg-gray-700 p-1">{gettext("Batch history")}</div>
      <div :for={b <- @batches} id={"batch-#{b.id}"} class="grid grid-cols-12 p-1 border-b items-center">
        <div class="col-span-2">{FullCircleWeb.Helpers.format_date(DateTime.to_date(b.inserted_at))}</div>
        <div class="col-span-4">{b.filename}</div>
        <div class="col-span-1">{FullCircleWeb.Helpers.format_date(b.payment_date)}</div>
        <div class="col-span-1 text-right">{b.count}</div>
        <div class="col-span-1 text-right tabular-nums">{money(b.total)}</div>
        <div class="col-span-1">{b.status}</div>
        <div class="col-span-2 flex gap-1 justify-end">
          <a href={~p"/companies/#{@current_company.id}/bank_batches/download?#{[ids: b.id]}"} class="blue button">
            {gettext("Download")}
          </a>
          <button :if={b.status == "exported"} id={"void-#{b.id}"} phx-click="start_void" phx-value-id={b.id} class="red button">
            {gettext("Void")}
          </button>
        </div>
        <form :if={@void_id == b.id} id="void-form" phx-submit="void" class="col-span-12 flex gap-2 justify-end mt-1">
          <input type="text" name="reason" placeholder={gettext("Reason")} class="border rounded px-2 py-1 dark:bg-gray-800" />
          <button type="submit" class="red button">{gettext("Confirm void")}</button>
          <button type="button" phx-click="cancel_void" class="blue button">{gettext("Cancel")}</button>
        </form>
      </div>
    </div>
    """
  end
end
```

Dashboard — after the Payments link:

```heex
        <.link
          :if={@current_role in ["admin", "manager"]}
          navigate={~p"/companies/#{@current_company.id}/bank_batches"}
          class="button blue"
        >
          {gettext("Bank Batches")}
        </.link>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle_web/live/bank_batch_live_test.exs test/full_circle_web/live/bank_setup_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Build assets and run the whole suite**

Run: `mix assets.build && mix test`
Expected: all green (2412 + new tests). Fix any failure before committing.

- [ ] **Step 6: Commit**

```bash
mix format lib/full_circle_web/live/bank_batch_live/index.ex lib/full_circle_web/controllers/bank_batch_controller.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/bank_batch_live_test.exs
git add lib/full_circle_web/live/bank_batch_live/ lib/full_circle_web/controllers/bank_batch_controller.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex assets/js/app.js test/full_circle_web/live/bank_batch_live_test.exs
git commit -m "feat(bank-payment): bank batch screen with tick, create, download and void

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Skill doc and CLAUDE.md (user confirms)

**Files:**
- Create: `.claude/skills/bank-bulk-payment.md`
- Modify: `CLAUDE.md` (domain table row + skill list)

- [ ] **Step 1: Draft the skill** with frontmatter `name: bank-bulk-payment` and description *"Use when changing bank payment files (RHB Reflex Bulk Pay, PB enterprise ECP), bank file format specs, supplier bank details, bank batches, or the FileSpec features computed/children/quote/allow/filename/max_rows."* Body: the spec clarifications list from this plan; both hash formulas; row vs header variables (`doc_date` vs `payment_date`); `params` declaration; seq counts voided batches; record ids from `bank_payment_record_seq`; re-download uses line snapshot + saved header + saved format version; payment lock fields; permissions table; "verify on first upload" items (PB footer in cents, PB account number left-aligned/space-padded).

- [ ] **Step 2: Ask the user to confirm** the skill text before committing (project convention: never create a skill silently).

- [ ] **Step 3: Update `CLAUDE.md`** — add `| BankPayment | Bank bulk payment files (RHB Bulk Pay, PB ECP): profiles, versioned formats, batches |` to the Domain Contexts table and `bank-bulk-payment.md` to the project skills list.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/bank-bulk-payment.md CLAUDE.md
git commit -m "docs: bank bulk payment skill and CLAUDE.md entries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
