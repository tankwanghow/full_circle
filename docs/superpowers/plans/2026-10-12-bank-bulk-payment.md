# Bank Bulk Payment Files Implementation Plan (revision 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn ticked supplier Payments into an RHB Reflex Bulk Pay CSV or a PB enterprise ECP Payment TXT that the bank's maker uploads and approver approves; track each batch through submitted/completed/rejected; import PB's result file; make every double-payment path a deliberate, logged manager/admin action.

**Architecture:** The shared `FullCircle.FileSpec` engine gains optional generic features (allowed sources, computed columns, child rows, CSV quoting, per-field allow lists, filename templates, `max_rows`), plus five PayScript builtins. A new `FullCircle.BankPayment` context owns versioned bank file formats (which can also describe the bank's result file), paying-account profiles, batches with a lifecycle, batch lines with per-line status, "paid outside file" dismissals and a download log. Supplier bank details live on `contacts` behind an admin/manager-only changeset.

**Tech Stack:** Elixir 1.19.5 / OTP 28, Phoenix 1.8, Phoenix LiveView 1.2, Ecto + PostgreSQL, Tailwind 4.

**Spec:** `docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md` (revision 2)

## Implementation notes (settled while planning; follow these)

1. **Row date variable is `doc_date`**; header `payment_date` is the batch's bank payment date (FileSpec merges the header over each row).
2. **`record_id`** = `record_no` from Postgres sequence `bank_payment_record_seq`, zero-padded to 12.
3. **`computed` columns** use only row and header variables, not each other.
4. **Bank spec top-level keys FileSpec ignores:** `params` (profile params the spec needs), `our_account_no_digits` (allowed lengths of our account number), `result` (bank result-file layout). `BankPayment.validate_spec/1` validates them.
5. **`batch_no`** header variable = company-local `YYYYMMDD` + 3-digit seq.
6. **Each batch stores its spec and header**; lines snapshot everything rendered. Re-download never reads the live format, contact or Payment.
7. **Payments have no delete path**; the lock is enforced in `BillPay.update_payment/4`.
8. **"Today"** is `BankPayment.today(company)` (company timezone), everywhere in this feature, including tests.

## Global Constraints

- `use FullCircle.Schema` for every new schema; migrations get `binary_id` keys automatically.
- **Never run bare `mix format`.** Run `mix format <files you touched>` only.
- Commit on `master`. Trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Warning flashes use kind **`:warn`** (`:warning` renders nothing).
- Every new colour works in light **and** dark themes (pair `bg-*-100` with `dark:bg-*-900/30`, text likewise).
- Existing statutory specs must render byte-for-byte the same: `test/full_circle/file_spec_test.exs`, `test/full_circle/file_spec_parity_test.exs`, `test/full_circle/statutory_config_test.exs`, `test/full_circle/statutory_config/` stay green after every FileSpec task.
- Roles: bank details `admin manager`; config `admin`; batch work (`:create_bank_payment_batch`) `admin manager`; `:admin_bank_payment_batch` (void submitted, mark paid line returned, download again after submission) `admin`; saved SQL queries `admin manager`.
- Batch payment date: company-local today … today + 59.
- RHB hash: `floor((Σ last6(account_no) × last6(int(amount))) × 24 + 2994) / 285)`. PB hash: total cents + Σ first 4 digits of every account number.
- RHB text fields allow only `A-Za-z0-9 /?:().,'+-`; `&` → `AND` first. RHB e-mail field `A-Za-z0-9@._+;-`. PB e-mail `A-Za-z0-9@._+-`.
- LiveView uploads: the file input's form must bind `phx-change` (see `.claude/skills/liveview-upload-gotchas.md`), pinned by a DOM assertion.
- Tests: `mix test <path>`. Credo is not installed.

## Review Focus

1. **Supplier name with `&` and a comma in the RHB CSV** → `AND`, whole value quoted. Pinned in Task 10.
2. **A voided batch's file** must not be downloadable (its Payments may be in a newer file). Pinned in Task 11.
3. **A Payment's amount edited while its batch is being created** → the open form's save fails stale; the file uses the re-read value. Pinned in Task 11.
4. **A bank result line for a line already released by hand, and re-importing the same result** → reported / no-op, never flipped. Pinned in Task 13.
5. **Clearing a contact's bank details** → saves, logs `(cleared)`, no crash. Pinned in Task 5.

## File Structure

Create:
- `priv/repo/migrations/20261012100000_create_bank_payments.exs`
- `lib/full_circle/bank_payment.ex` — context
- `lib/full_circle/bank_payment/banks.ex`, `file_format.ex`, `profile.ex`, `batch.ex`, `batch_line.ex`, `dismissal.ex`, `download.ex`, `rows.ex`, `result.ex`
- `priv/bank_file_templates/rhb_bulk_pay.json`, `priv/bank_file_templates/pbb_ecp_payment.json`
- `lib/full_circle_web/live/contact_live/bank_component.ex`
- `lib/full_circle_web/live/bank_file_format_live/index.ex`, `form.ex`
- `lib/full_circle_web/live/bank_payment_profile_live/index.ex`, `form.ex`
- `lib/full_circle_web/live/bank_batch_live/index.ex`
- `lib/full_circle_web/controllers/bank_batch_controller.ex`
- `test/support/fixtures/bank_payment_fixtures.ex`
- Tests: `test/full_circle/pay_script_text_builtins_test.exs`, `test/full_circle/file_spec_bank_test.exs`, `test/full_circle/contact_bank_test.exs`, `test/full_circle/user_queries_auth_test.exs`, `test/full_circle/bank_payment_schema_test.exs`, `test/full_circle/bank_payment_test.exs`, `test/full_circle/bank_payment_golden_test.exs`, `test/full_circle/bank_payment_lifecycle_test.exs`, `test/full_circle/bank_payment_result_test.exs`, `test/full_circle_web/live/contact_bank_live_test.exs`, `test/full_circle_web/live/bank_setup_live_test.exs`, `test/full_circle_web/live/bank_batch_live_test.exs`
- `.claude/skills/bank-bulk-payment.md` (Task 17, user confirms)

Modify: `lib/full_circle/pay_script/validator.ex`, `lib/full_circle/pay_script/evaluator.ex`, `lib/full_circle/file_spec.ex`, `lib/full_circle/accounting/contact.ex`, `lib/full_circle/accounting.ex`, `lib/full_circle/authorization.ex`, `lib/full_circle/bill_pay.ex`, `lib/full_circle_web/live/contact_live/form.ex`, `lib/full_circle_web/live/payment_live/form.ex`, `lib/full_circle_web/live/payment_live/index_component.ex`, `lib/full_circle_web/live/query_live/index.ex`, `lib/full_circle_web/live/query_live/form.ex`, `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`, `lib/full_circle_web/router.ex`, `assets/js/app.js`, `test/full_circle_web/live/query_live_test.exs`, `CLAUDE.md`.

---

### Task 1: PayScript builtins `left`, `right`, `mid`, `num`, `mod`

**Files:**
- Modify: `lib/full_circle/pay_script/validator.ex` (`@builtins`)
- Modify: `lib/full_circle/pay_script/evaluator.ex` (clauses above `defp eval_call("lookup", …)`, `eval_text/3` beside `eval_str/3`, `value_label/1` catch-alls after the existing clauses)
- Test: `test/full_circle/pay_script_text_builtins_test.exs`

**Interfaces:**
- Produces: `left(text, n)`, `right(text, n)`, `mid(text, start, n)` (1-based), `num(text)` (digits → number; `""` → 0; numbers pass through), `mod(a, b)` (floored; `mod(x, 0)` is an error). Slicing builtins accept a whole number as its digits. Type errors on any value (e.g. a Date) return `{:error, %Error{}}`, never raise.

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

  test "left accepts a whole number as text" do
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

  test "a date where text is expected is an error, not a crash" do
    assert {:error, %{message: msg}} = ev(~s|left(d, 4)|, %{"d" => ~D[2026-01-01]})
    assert msg =~ "date 2026-01-01"
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
Expected: FAIL — `unknown function left/2`.

- [ ] **Step 3: Implement**

`validator.ex` — add to `@builtins` (keep existing entries):

```elixir
    "left" => 2,
    "right" => 2,
    "mid" => 3,
    "num" => 1,
    "mod" => 2,
```

`evaluator.ex` — insert above `defp eval_call("lookup", [t, v, c], vars, env) do`:

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

Beside `defp eval_str/3`:

```elixir
  # Text for the slicing builtins: a whole number reads as its digits.
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

After the last existing `defp value_label(...)` clause:

```elixir
  defp value_label(%Date{} = d), do: "date #{d}"
  defp value_label(v), do: inspect(v)
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/pay_script_text_builtins_test.exs test/full_circle/pay_script_test.exs test/full_circle/pay_script`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/pay_script/validator.ex lib/full_circle/pay_script/evaluator.ex test/full_circle/pay_script_text_builtins_test.exs
git add lib/full_circle/pay_script/validator.ex lib/full_circle/pay_script/evaluator.ex test/full_circle/pay_script_text_builtins_test.exs
git commit -m "feat(payscript): left/right/mid/num/mod builtins; type errors never raise

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: FileSpec — allowed detail sources and `computed` columns

**Files:**
- Modify: `lib/full_circle/file_spec.ex`
- Test: `test/full_circle/file_spec_bank_test.exs` (new; Tasks 3–4 append)

**Interfaces:**
- Produces: `FileSpec.validate(spec, variables, sources)`; `FileSpec.render(spec, rows, header_ctx, variables \\ [], sources \\ ["statutory_rows"])`. Spec key `"computed"` (`%{name => expr}`), evaluated per row before filter/sort/aggregates. Any evaluation failure returns `{:error, msg}`.

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
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "x"}]}], %{"computed" => %{"x" => "nope + 1"}})
      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "computed x: unknown identifier 'nope'"
    end

    test "computed must be a map" do
      spec = delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"computed" => ["x"]})
      assert {:error, [msg]} = FileSpec.validate(spec, [], ["payments"])
      assert msg =~ "computed must be a map"
    end

    test "a computed evaluation error is returned, not raised" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "x"}]}], %{"computed" => %{"x" => "left(d, 4)"}})
      assert {:error, msg} = FileSpec.render(spec, [%{"d" => ~D[2026-01-01]}], %{}, ["d"], ["payments"])
      assert msg =~ "computed x"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/file_spec_bank_test.exs`
Expected: FAIL — `FileSpec.validate/3 is undefined`.

- [ ] **Step 3: Implement** in `lib/full_circle/file_spec.ex`

Below `@section_kinds`:

```elixir
  @default_sources ["statutory_rows"]
```

Replace `validate/2`:

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

Replace the `render` head and `with`:

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

Change `validate_sections/3` → `/4` and `validate_section/5` → `/6`, threading `sources`:

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

In `validate_section/6`, replace the `statutory_rows` clause with:

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
        rescue
          e -> {:error, "computed: " <> Exception.message(e)}
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

- [ ] **Step 4: Run tests including the statutory guard**

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
- Modify: `lib/full_circle/file_spec.ex`
- Test: `test/full_circle/file_spec_bank_test.exs`

**Interfaces:**
- Produces: detail `"children": [%{"source", "fields"}]`; top-level `"quote": "csv"` (delimited only); field `"allow"` (character-class body, applied before padding).

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

    test "a child needs a source" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "no"}], "children" => [%{"fields" => [%{"expr" => "no"}]}]}])
      assert {:error, [msg]} = FileSpec.validate(spec, ["no"], ["payments"])
      assert msg =~ "child 1: source is required"
    end
  end

  describe "quote csv" do
    test "wraps values holding the delimiter or quotes, doubling inner quotes" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name"}, %{"expr" => "note"}]}], %{"quote" => "csv", "line_ending" => "\n"})
      rows = [%{"name" => "Tan, Lee", "note" => ~s|say "hi"|}, %{"name" => "Plain", "note" => "x"}]

      assert {:ok, ~s|"Tan, Lee","say ""hi"""\nPlain,x\n|} =
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

      assert {:ok, "Tan  Sons M \n"} = FileSpec.render(spec, [%{"name" => "Tan & Sons (M)"}], %{}, ["name"], ["payments"])
    end

    test "an invalid class is rejected" do
      spec = delimited([%{"kind" => "detail", "source" => "payments", "fields" => [%{"expr" => "name", "allow" => "z-a"}]}])
      assert {:error, [msg]} = FileSpec.validate(spec, ["name"], ["payments"])
      assert msg =~ "allow is not a valid character class"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/file_spec_bank_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

Attributes (top of module):

```elixir
  @no_aggregates %{count: 0, sums: %{}}
```

`validate_top_level/2`:

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
      nil -> errors
      "csv" -> if Map.get(spec, "delimiter"), do: errors, else: ["quote requires a delimiter" | errors]
      other -> ["quote must be \"csv\", got #{inspect(other)}" | errors]
    end
  end
```

In `validate_section/6` `true ->` branch append `|> validate_children(section, prefix, delimiter, variables)`. Add:

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

In `validate_field/5`, add `|> validate_field_allow(field, prefix)` after `validate_field_pad`, and:

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

Replace `render_sections/3`, both `render_section/6` clauses and `render_line/4`:

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

In `render_field/3`, the success branch becomes:

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

- [ ] **Step 4: Run tests including the statutory guard**

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
- Modify: `lib/full_circle/file_spec.ex`
- Test: `test/full_circle/file_spec_bank_test.exs`

**Interfaces:**
- Produces: `FileSpec.filename(spec, ctx, seq | nil) :: String.t() | nil` — raises `ArgumentError` when `seq` is wider than `{seq:N}` (callers rescue). Inserted values and strftime output keep only `[A-Za-z0-9._-]`. `FileSpec.max_rows(spec) :: pos_integer | nil`. Validation rejects unknown names and bad date patterns.

- [ ] **Step 1: Write the failing tests** — append inside `FullCircle.FileSpecBankTest`:

```elixir
  describe "filename" do
    test "renders values, dates and a padded sequence" do
      spec = %{"filename" => "PAYMENT_{corporate_id}_{today:%d%m%Y}_{seq:3}.CSV"}
      ctx = %{"corporate_id" => "123456", "today" => ~D[2026-10-12]}
      assert FileSpec.filename(spec, ctx, 7) == "PAYMENT_123456_12102026_007.CSV"
      assert FileSpec.filename(spec, ctx, nil) == "PAYMENT_123456_12102026_.CSV"
    end

    test "drops unsafe characters from inserted values" do
      assert FileSpec.filename(%{"filename" => "{acct}PM.txt"}, %{"acct" => "3123 456/789"}, 1) == "3123456789PM.txt"
    end

    test "a sequence wider than its digits raises" do
      assert_raise ArgumentError, ~r/does not fit/, fn -> FileSpec.filename(%{"filename" => "{seq:2}"}, %{}, 100) end
    end

    test "nil without a template" do
      assert FileSpec.filename(%{}, %{}, 1) == nil
    end

    test "unknown names and bad date patterns are rejected" do
      spec = delimited([%{"kind" => "header", "fields" => [%{"expr" => "1"}]}], %{"filename" => "{nope}_{d:%Q}_{seq:2}.txt"})
      assert {:error, msgs} = FileSpec.validate(spec, ["d"], ["payments"])
      assert Enum.any?(msgs, &(&1 =~ "filename: unknown name 'nope'"))
      assert Enum.any?(msgs, &(&1 =~ "filename: bad date pattern"))
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

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/file_spec_bank_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

```elixir
  @filename_token ~r/\{([A-Za-z_][A-Za-z0-9_]*)(?::([^}]*))?\}/
```

In `validate/3` add `|> validate_filename(spec, variables)` after `validate_computed`; in `validate_top_level/2` add `|> validate_max_rows(spec)`. Add:

```elixir
  @doc """
  Renders the spec's `filename` template, or nil when it has none. `seq: nil`
  leaves the sequence part out (the stem). Raises ArgumentError when `seq` is
  wider than its `{seq:N}` digits.
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

    text = Integer.to_string(seq)

    if String.length(text) > width,
      do: raise(ArgumentError, "sequence #{seq} does not fit in #{width} digit(s)")

    String.pad_leading(text, width, "0")
  end

  defp filename_part(name, opt, ctx, _seq) do
    case Map.get(ctx, name) do
      %Date{} = d when opt != "" -> Calendar.strftime(d, opt)
      v -> to_string(v)
    end
    |> String.replace(~r/[^A-Za-z0-9._-]/, "")
  end

  defp validate_filename(errors, spec, variables) do
    case Map.get(spec, "filename") do
      nil ->
        errors

      tpl when is_binary(tpl) and tpl != "" ->
        @filename_token
        |> Regex.scan(tpl, capture: :all_but_first)
        |> Enum.reduce(errors, fn
          ["seq" | _], acc ->
            acc

          [name | rest], acc ->
            acc = if name in variables, do: acc, else: ["filename: unknown name '#{name}'" | acc]

            case rest do
              [opt] when opt != "" -> validate_date_pattern(acc, opt)
              _ -> acc
            end
        end)

      other ->
        ["filename must be a non-empty string, got #{inspect(other)}" | errors]
    end
  end

  defp validate_date_pattern(errors, opt) do
    Calendar.strftime(~D[2026-01-31], opt)
    errors
  rescue
    _ -> ["filename: bad date pattern '#{opt}'" | errors]
  end

  defp validate_max_rows(errors, spec) do
    case Map.get(spec, "max_rows") do
      nil -> errors
      n when is_integer(n) and n > 0 -> errors
      other -> ["max_rows must be a positive integer, got #{inspect(other)}" | errors]
    end
  end
```

- [ ] **Step 4: Run tests including the statutory guard**

Run: `mix test test/full_circle/file_spec_bank_test.exs test/full_circle/file_spec_test.exs test/full_circle/file_spec_parity_test.exs test/full_circle/statutory_config_test.exs test/full_circle/statutory_config`
Expected: PASS. (If `Calendar.strftime` accepts `%Q` without raising on this Elixir version, change the test's bad pattern to one that raises, e.g. `%`, and keep the assertion.)

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git add lib/full_circle/file_spec.ex test/full_circle/file_spec_bank_test.exs
git commit -m "feat(filespec): filename templates and max_rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Migration, bank list, supplier bank details, permissions

**Files:**
- Create: `priv/repo/migrations/20261012100000_create_bank_payments.exs`
- Create: `lib/full_circle/bank_payment/banks.ex`
- Modify: `lib/full_circle/accounting/contact.ex`, `lib/full_circle/accounting.ex`, `lib/full_circle/authorization.ex`
- Test: `test/full_circle/contact_bank_test.exs`

**Interfaces:**
- Produces: `Banks.all/0`, `get/1`, `name/1`, `options/0`; `Contact.bank_changeset/2`; `Accounting.save_contact_bank(contact, attrs, company, user) :: {:ok, Contact} | {:error, Changeset} | :not_authorise` (log entity `"contact_bank"`, only real changes, cleared values as `(cleared)`); `can?/3` for `:manage_contact_bank`, `:manage_bank_payment_config`, `:create_bank_payment_batch`, `:admin_bank_payment_batch`.

- [ ] **Step 1: Write the migration** (whole feature)

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

    # CASCADE keeps company deletion working; there is no other delete path
    # for formats, profiles or payments.
    create table(:bank_payment_batches) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :profile_id, references(:bank_payment_profiles, on_delete: :delete_all), null: false
      add :format_id, references(:bank_file_formats, on_delete: :delete_all), null: false
      add :spec, :map, null: false
      add :payment_date, :date, null: false
      add :filename_stem, :string, null: false
      add :filename, :string, null: false
      add :seq, :integer, null: false
      add :header, :map, null: false
      add :count, :integer, null: false
      add :total, :decimal, null: false
      add :status, :string, null: false, default: "exported"
      add :submitted_by_id, references(:users, on_delete: :nilify_all)
      add :submitted_at, :utc_datetime
      add :result_imported_at, :utc_datetime
      add :result_filename, :string
      add :void_reason, :string
      add :voided_by_id, references(:users, on_delete: :nilify_all)
      add :voided_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_payment_batches, [:company_id, :filename])
    create index(:bank_payment_batches, [:company_id, :filename_stem])

    # Banks require a record id that is never reused.
    execute "CREATE SEQUENCE bank_payment_record_seq", "DROP SEQUENCE bank_payment_record_seq"

    create table(:bank_payment_batch_lines) do
      add :batch_id, references(:bank_payment_batches, on_delete: :delete_all), null: false
      add :payment_id, references(:payments, on_delete: :delete_all), null: false
      add :record_no, :bigint, null: false
      add :status, :string, null: false, default: "pending"
      add :live, :boolean, null: false, default: true
      add :bank_reason, :string
      add :released_by_id, references(:users, on_delete: :nilify_all)
      add :released_at, :utc_datetime
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

    # A Payment is in at most one live line, so it is never paid twice by file.
    create unique_index(:bank_payment_batch_lines, [:payment_id],
             where: "live",
             name: :bank_payment_batch_lines_one_live_per_payment
           )

    create unique_index(:bank_payment_batch_lines, [:record_no])
    create index(:bank_payment_batch_lines, [:batch_id])

    create table(:bank_payment_dismissals) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :payment_id, references(:payments, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :note, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:bank_payment_dismissals, [:payment_id])

    create table(:bank_payment_downloads) do
      add :batch_id, references(:bank_payment_batches, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :reason, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:bank_payment_downloads, [:batch_id])
  end
end
```

Run: `mix ecto.migrate` — expected: runs cleanly.

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
    test_authorise_to(:admin_bank_payment_batch, ["admin"])
  end

  test "Banks lists Maybank, Ryt Bank and Public Bank's own BICs" do
    assert %{name: "Malayan Banking Berhad (Maybank)", lengths: [12]} = Banks.get("MBBEMYKL")
    assert Banks.get("SCCHMYKL")
    assert Banks.get("PBBEMYKL")
    assert Banks.get("PIBEMYK1")
    assert Banks.get("NOPE") == nil
    assert {"RHB Bank Berhad", "RHBBMYKL"} in Banks.options()
  end

  defp bank_logs(c), do: Repo.all(from l in Log, where: l.entity == "contact_bank" and l.entity_id == ^c.id, order_by: l.inserted_at)

  describe "save_contact_bank/4" do
    test "strips non-digits, trims the name, stamps the change and logs under contact_bank", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)

      assert {:ok, c} =
               Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL", "bank_account_no" => "1122-3344 5566", "bank_account_name" => " Tan Sdn Bhd "}, company, admin)

      assert c.bank_account_no == "112233445566"
      assert c.bank_account_name == "Tan Sdn Bhd"
      assert c.bank_details_changed_at
      assert [%Log{action: "update_contact_bank"}] = bank_logs(c)
      assert Repo.all(from l in Log, where: l.entity == "contacts" and l.entity_id == ^c.id and l.action == "update_contact_bank") == []
    end

    test "clearing details saves and logs (cleared)", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)
      {:ok, c} = Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL", "bank_account_no" => "112233445566", "bank_account_name" => "Tan"}, company, admin)
      assert {:ok, c} = Accounting.save_contact_bank(c, %{"bank_code" => "", "bank_account_no" => "", "bank_account_name" => ""}, company, admin)
      assert c.bank_code == nil
      assert [_, %Log{delta: delta}] = bank_logs(c)
      assert delta =~ "(cleared)"
    end

    test "saving nothing on a blank contact is fine and logs nothing", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)
      assert {:ok, _} = Accounting.save_contact_bank(c, %{"bank_code" => "", "bank_account_no" => "", "bank_account_name" => ""}, company, admin)
      assert bank_logs(c) == []
    end

    test "all three together", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)
      assert {:error, cs} = Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL"}, company, admin)
      assert "required when bank details are filled" in errors_on(cs).bank_account_no
    end

    test "account length must suit the bank; name at most 120", %{company: company, admin: admin} do
      c = contact_fixture(company, admin)
      assert {:error, cs} = Accounting.save_contact_bank(c, %{"bank_code" => "RHBBMYKL", "bank_account_no" => "12345", "bank_account_name" => String.duplicate("x", 121)}, company, admin)
      assert [msg] = errors_on(cs).bank_account_no
      assert msg =~ "must be 14 digits for RHB Bank Berhad"
      assert errors_on(cs).bank_account_name != []
    end

    test "clerks may not; another company's contact may not", %{company: company, admin: admin} do
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)
      c = contact_fixture(company, admin)
      assert :not_authorise = Accounting.save_contact_bank(c, %{"bank_code" => "MBBEMYKL"}, company, clerk)

      %{company: other, admin: other_admin} = billing_setup()
      theirs = contact_fixture(other, other_admin)
      assert :not_authorise = Accounting.save_contact_bank(theirs, %{}, company, admin)
    end
  end

  test "the ordinary contact changeset never writes bank fields", %{company: company, admin: admin} do
    c = contact_fixture(company, admin)
    {:ok, c} = StdInterface.update(Contact, "contact", c, %{"name" => c.name, "bank_account_no" => "999999999999", "bank_code" => "MBBEMYKL"}, company, admin)
    assert c.bank_account_no == nil
    assert c.bank_code == nil
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/full_circle/contact_bank_test.exs`
Expected: FAIL — `Banks` undefined.

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
    {"United Overseas Bank (Malaysia) Berhad", "UOVBMYKL", [7, 9, 10, 11, 12, 13, 14, 17]},
    {"YTL Digital Bank Berhad (Ryt Bank)", "SCCHMYKL", [10]}
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

`lib/full_circle/accounting/contact.ex` — schema fields after `field :misc_code, :string`:

```elixir
    # Supplier bank details for bank payment files. Written only through
    # bank_changeset/2 (admin/manager); changeset/2 never casts them.
    field :bank_code, :string
    field :bank_account_no, :string
    field :bank_account_name, :string
    field :bank_details_changed_at, :utc_datetime
```

and after `changeset/2`:

```elixir
  @bank_fields [:bank_code, :bank_account_no, :bank_account_name]

  def bank_changeset(contact, attrs) do
    contact
    |> cast(attrs, @bank_fields)
    |> update_change(:bank_account_no, &(&1 && String.replace(&1, ~r/\D/, "")))
    |> update_change(:bank_account_name, &(&1 && String.trim(&1)))
    |> validate_length(:bank_account_name, max: 120)
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
            add_error(cs, :bank_account_no, gettext("must be %{lengths} digits for %{bank}",
              lengths: Enum.join(bank.lengths, "/"),
              bank: bank.name
            ))
    end
  end

  defp stamp_bank_change(cs) do
    if Enum.any?(@bank_fields, &Map.has_key?(cs.changes, &1)),
      do: put_change(cs, :bank_details_changed_at, DateTime.utc_now() |> DateTime.truncate(:second)),
      else: cs
  end
```

`lib/full_circle/accounting.ex` — after `get_contact_by_name/3` (alias `Contact` in the `alias FullCircle.Accounting.{...}` list if missing):

```elixir
  @doc """
  Saves a contact's bank details. Admin/manager only. Logs only real changes,
  under entity "contact_bank", so the contact's ordinary log — which any
  contact editor sees — never shows account numbers.
  """
  def save_contact_bank(%Contact{} = contact, attrs, com, user) do
    if can?(user, :manage_contact_bank, com) and contact.company_id == com.id do
      cs = Contact.bank_changeset(contact, attrs)

      delta =
        cs.changes
        |> Map.take([:bank_code, :bank_account_no, :bank_account_name])
        |> Map.new(fn {k, v} -> {k, v || "(cleared)"} end)
        |> Sys.attr_to_string()

      Multi.new()
      |> Multi.update(:update_contact_bank, cs)
      |> then(fn multi ->
        if delta == "" do
          multi
        else
          Multi.insert(multi, :log, fn %{update_contact_bank: c} ->
            Sys.Log.changeset(%Sys.Log{}, %{
              entity: "contact_bank",
              entity_id: c.id,
              action: "update_contact_bank",
              delta: delta,
              user_id: user.id,
              company_id: com.id
            })
          end)
        end
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{update_contact_bank: c}} -> {:ok, c}
        {:error, _step, cs, _} -> {:error, cs}
      end
    else
      :not_authorise
    end
  end
```

`lib/full_circle/authorization.ex` — below `:manage_statutory_config`:

```elixir
  def can?(user, :manage_contact_bank, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :manage_bank_payment_config, company),
    do: allow_roles(~w(admin), company, user)

  def can?(user, :create_bank_payment_batch, company),
    do: allow_roles(~w(admin manager), company, user)

  def can?(user, :admin_bank_payment_batch, company),
    do: allow_roles(~w(admin), company, user)
```

- [ ] **Step 5: Run tests**

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
- Modify: `lib/full_circle_web/live/contact_live/form.ex`
- Test: `test/full_circle_web/live/contact_bank_live_test.exs`

**Interfaces:**
- Consumes: `Accounting.save_contact_bank/4`, `Contact.bank_changeset/2`, `Banks.options/0`.
- Produces: `FullCircleWeb.ContactLive.BankComponent` (assigns `contact`, `current_company`, `current_user`); form `#contact-bank-form`, params key `contact_bank`. It keeps its own contact/form after the first mount (the parent re-renders with the original struct).

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
    %{admin: admin, com: com, contact: contact_fixture(com, admin)}
  end

  defp conn_as(com, admin, role) do
    user = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, user, role, admin)
    log_in_user(build_conn(), user)
  end

  test "a manager saves bank details and they survive a parent re-render", %{admin: admin, com: com, contact: contact} do
    {:ok, lv, html} = live(conn_as(com, admin, "manager"), ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")
    assert html =~ "Bank details"

    lv
    |> form("#contact-bank-form", %{"contact_bank" => %{"bank_code" => "MBBEMYKL", "bank_account_no" => "112233445566", "bank_account_name" => "Tan"}})
    |> render_submit()

    assert render(lv) =~ "Saved"
    assert FullCircle.Repo.get!(FullCircle.Accounting.Contact, contact.id).bank_account_no == "112233445566"

    lv |> form("#object-form", %{"contact" => %{"phone" => "012"}}) |> render_change()
    assert lv |> element("#contact-bank-form") |> render() =~ "112233445566"
  end

  test "a clerk never sees the bank block", %{admin: admin, com: com, contact: contact} do
    {:ok, _lv, html} = live(conn_as(com, admin, "clerk"), ~p"/companies/#{com.id}/contacts/#{contact.id}/edit")
    refute html =~ "Bank details"
    refute html =~ "contact-bank-form"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle_web/live/contact_bank_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

`lib/full_circle_web/live/contact_live/bank_component.ex`:

```elixir
defmodule FullCircleWeb.ContactLive.BankComponent do
  @moduledoc "Supplier bank details on the contact form. Rendered only for :manage_contact_bank."
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting
  alias FullCircle.Accounting.Contact
  alias FullCircle.BankPayment.Banks

  # The parent passes its original contact struct on every re-render; keep our
  # own copy after mount so a re-render never brings back stale bank details.
  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.delete(assigns, :contact))

    if socket.assigns[:form] do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(contact: assigns.contact, saved: false)
       |> assign(form: to_form(Contact.bank_changeset(assigns.contact, %{}), as: :contact_bank))}
    end
  end

  @impl true
  def handle_event("validate", %{"contact_bank" => params}, socket) do
    cs = socket.assigns.contact |> Contact.bank_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(cs, as: :contact_bank), saved: false)}
  end

  @impl true
  def handle_event("save", %{"contact_bank" => params}, socket) do
    case Accounting.save_contact_bank(socket.assigns.contact, params, socket.assigns.current_company, socket.assigns.current_user) do
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
    <div id={@id} class="mt-2 border rounded-lg border-emerald-500 bg-emerald-50 dark:bg-emerald-900/30 p-2">
      <p class="font-semibold">{gettext("Bank details")}</p>
      <.form for={@form} id="contact-bank-form" phx-target={@myself} phx-change="validate" phx-submit="save" autocomplete="off">
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-5">
            <.input field={@form[:bank_code]} type="select" label={gettext("Bank")} options={Banks.options()} prompt={gettext("-- none --")} />
          </div>
          <div class="col-span-3">
            <.input field={@form[:bank_account_no]} label={gettext("Account No")} inputmode="numeric" />
          </div>
          <div class="col-span-4">
            <.input field={@form[:bank_account_name]} label={gettext("Account Holder Name")} value={@form[:bank_account_name].value || @contact.name} />
          </div>
        </div>
        <div class="flex justify-center items-center gap-x-2 mt-1">
          <button type="submit" class="blue button" id="save-bank">{gettext("Save Bank Details")}</button>
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

`lib/full_circle_web/live/contact_live/form.ex` — in `mount/3` before `{:ok, socket}`:

```elixir
    socket =
      assign(socket, :can_bank,
        FullCircle.Authorization.can?(socket.assigns.current_user, :manage_contact_bank, socket.assigns.current_company)
      )
```

In `render/1`, directly after the contact `</.form>` (inside the `w-6/12` container):

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

- [ ] **Step 4: Run tests**

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
- Modify: `lib/full_circle/authorization.ex` (four query clauses), `lib/full_circle_web/live/query_live/index.ex`, `lib/full_circle_web/live/query_live/form.ex`
- Test: `test/full_circle/user_queries_auth_test.exs`; append to `test/full_circle_web/live/query_live_test.exs`

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

Append to `FullCircleWeb.QueryLiveTest`:

```elixir
  for role <- ["clerk", "supervisor"] do
    test "a #{role} is sent away from the query pages", %{company: company, user: admin} do
      u = user_fixture()
      FullCircle.Sys.allow_user_to_access(company, u, unquote(role), admin)
      conn = log_in_user(build_conn(), u)

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/companies/#{company.id}/queries")
      assert to =~ "/dashboard"
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/companies/#{company.id}/queries/new")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

`authorization.ex`:

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

`query_live/index.ex` — replace `mount/3` and guard `handle_params/3`:

```elixir
  @impl true
  def mount(_params, _session, socket) do
    if allowed?(socket) do
      {:ok, assign(socket, page_title: gettext("Queries Listing"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if allowed?(socket) do
      terms = get_in(params, ["search", "terms"]) || ""

      {:noreply,
       socket
       |> assign(search: %{terms: terms})
       |> filter_objects(terms, true, 1)}
    else
      {:noreply, socket}
    end
  end

  defp allowed?(socket),
    do: FullCircle.Authorization.can?(socket.assigns.current_user, :execute_query, socket.assigns.current_company)
```

`query_live/form.ex` — rename the existing `mount/3` to `defp mount_allowed(params, session, socket)` (drop its `@impl true`) and add:

```elixir
  @impl true
  def mount(params, session, socket) do
    if FullCircle.Authorization.can?(socket.assigns.current_user, :execute_query, socket.assigns.current_company) do
      mount_allowed(params, session, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{socket.assigns.current_company.id}/dashboard")}
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs test/full_circle/authorization_test.exs`
Expected: PASS. Update any old query-role expectation in `authorization_test.exs` to `["admin", "manager"]` — that is the intended change.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/authorization.ex lib/full_circle_web/live/query_live/index.ex lib/full_circle_web/live/query_live/form.ex test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs
git add lib/full_circle/authorization.ex lib/full_circle_web/live/query_live/ test/full_circle/user_queries_auth_test.exs test/full_circle_web/live/query_live_test.exs
git commit -m "feat(queries): saved SQL queries are admin/manager only

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: BankPayment schemas

**Files:**
- Create: `lib/full_circle/bank_payment/file_format.ex`, `profile.ex`, `batch.ex`, `batch_line.ex`, `dismissal.ex`, `download.ex`; minimal `lib/full_circle/bank_payment.ex`
- Test: `test/full_circle/bank_payment_schema_test.exs`

**Interfaces:**
- Produces: `FileFormat.changeset/2` (spec validated via `BankPayment.validate_spec/1`); `Profile.changeset/2` (Bank-type account, reserved/invalid param names refused), `Profile.parse_params/1`, `Profile.params_text/1`; `Batch.changeset/2`, `submit_changeset/2`, `result_changeset/2`, `void_changeset/2`, `status_changeset/2`; `BatchLine.changeset/2` (live-per-payment unique constraint), `resolve_changeset/2`; `Dismissal.changeset/2`; `Download.changeset/2`; `BankPayment.reserved_variables/0`, `spec_params/1`, `format_variables/1`, `validate_spec/1`.

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

  test "a param named like a built-in variable is refused" do
    cs = Profile.changeset(%Profile{}, %{"params" => %{"bank_code" => "PBBEMYKL", "Bad Name" => "x"}})
    msgs = for {:params, {m, opts}} <- cs.errors, do: String.replace(m, "%{key}", to_string(opts[:key]))
    assert "bank_code is a built-in variable name" in msgs
    assert Enum.any?(msgs, &(&1 =~ "is not a valid name"))
  end

  test "batch line requires its snapshot fields" do
    cs = BatchLine.changeset(%BatchLine{}, %{})
    refute cs.valid?
    assert cs.errors[:payment_id]
    assert cs.errors[:bank_account_no]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_schema_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement**

Minimal `lib/full_circle/bank_payment.ex` (Task 9 replaces it):

```elixir
defmodule FullCircle.BankPayment do
  @moduledoc """
  Bank bulk payment files. See docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md.
  """

  alias FullCircle.FileSpec

  @sources ["payments"]
  @row_vars ~w(record_id payment_no doc_date amount bank_code account_no account_name contact_name reg_no email emails descriptions advice advice_text)
  @child_vars ~w(advice_doc_no advice_doc_date advice_amount)
  @header_vars ~w(our_account_no payment_date today company_name seq batch_no)

  def reserved_variables, do: @row_vars ++ @child_vars ++ @header_vars

  def spec_params(spec), do: spec |> Map.get("params", []) |> List.wrap() |> Enum.filter(&is_binary/1)

  def format_variables(spec), do: reserved_variables() ++ spec_params(spec)

  def validate_spec(spec), do: FileSpec.validate(spec, format_variables(spec), @sources)
end
```

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
    |> validate_format(:code, ~r/^[a-z0-9_]+$/, message: gettext("only lowercase letters, digits and underscore"))
    |> validate_spec()
    |> unique_constraint([:company_id, :code, :effective_from],
      name: :bank_file_formats_unique_code_effective,
      error_key: :effective_from,
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
    |> validate_params()
    |> validate_bank_account()
    |> unique_constraint(:account_id,
      name: :bank_payment_profiles_company_id_account_id_index,
      message: gettext("already has a bank payment profile")
    )
  end

  # A param named like a row variable would replace that value on every line.
  defp validate_params(cs) do
    reserved = FullCircle.BankPayment.reserved_variables()

    (get_field(cs, :params) || %{})
    |> Map.keys()
    |> Enum.reduce(cs, fn k, acc ->
      cond do
        k in reserved -> add_error(acc, :params, gettext("%{key} is a built-in variable name"), key: k)
        not (is_binary(k) and k =~ ~r/\A[a-z_][a-z0-9_]*\z/) -> add_error(acc, :params, gettext("%{key} is not a valid name"), key: inspect(k))
        true -> acc
      end
    end)
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
  def params_text(params) when is_map(params), do: params |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)
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
    field :spec, :map
    field :payment_date, :date
    field :filename_stem, :string
    field :filename, :string
    field :seq, :integer
    field :header, :map
    field :count, :integer
    field :total, :decimal
    field :status, :string, default: "exported"
    belongs_to :submitted_by, FullCircle.UserAccounts.User
    field :submitted_at, :utc_datetime
    field :result_imported_at, :utc_datetime
    field :result_filename, :string
    field :void_reason, :string
    belongs_to :voided_by, FullCircle.UserAccounts.User
    field :voided_at, :utc_datetime
    belongs_to :created_by, FullCircle.UserAccounts.User
    has_many :lines, FullCircle.BankPayment.BatchLine
    timestamps(type: :utc_datetime)
  end

  @fields [:company_id, :profile_id, :format_id, :spec, :payment_date, :filename_stem, :filename, :seq, :header, :count, :total, :created_by_id]

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:filename, name: :bank_payment_batches_company_id_filename_index)
  end

  def submit_changeset(batch, attrs) do
    batch
    |> cast(attrs, [:submitted_by_id, :submitted_at])
    |> validate_required([:submitted_by_id, :submitted_at])
    |> put_change(:status, "submitted")
  end

  def result_changeset(batch, attrs) do
    cs = cast(batch, attrs, [:result_imported_at, :result_filename, :submitted_at, :submitted_by_id])
    if batch.status == "exported", do: put_change(cs, :status, "submitted"), else: cs
  end

  def void_changeset(batch, attrs) do
    batch
    |> cast(attrs, [:void_reason, :voided_by_id, :voided_at])
    |> validate_required([:void_reason, :voided_by_id, :voided_at])
    |> put_change(:status, "voided")
  end

  def status_changeset(batch, status), do: change(batch, status: status)
end
```

`lib/full_circle/bank_payment/batch_line.ex`:

```elixir
defmodule FullCircle.BankPayment.BatchLine do
  use FullCircle.Schema
  import Ecto.Changeset

  # Snapshot of what went into the file, so a re-download is byte-identical.
  schema "bank_payment_batch_lines" do
    belongs_to :batch, FullCircle.BankPayment.Batch
    belongs_to :payment, FullCircle.BillPay.Payment
    field :record_no, :integer
    field :status, :string, default: "pending"
    field :live, :boolean, default: true
    field :bank_reason, :string
    belongs_to :released_by, FullCircle.UserAccounts.User
    field :released_at, :utc_datetime
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

  @required [:batch_id, :payment_id, :record_no, :payment_no, :doc_date, :amount, :bank_code, :bank_account_no, :bank_account_name, :contact_name]

  def changeset(line, attrs) do
    line
    |> cast(attrs, @required ++ [:email, :reg_no, :descriptions, :advice])
    |> validate_required(@required)
    |> unique_constraint(:payment_id, name: :bank_payment_batch_lines_one_live_per_payment)
  end

  def resolve_changeset(line, attrs),
    do: cast(line, attrs, [:status, :live, :bank_reason, :released_by_id, :released_at])
end
```

`lib/full_circle/bank_payment/dismissal.ex`:

```elixir
defmodule FullCircle.BankPayment.Dismissal do
  use FullCircle.Schema
  import Ecto.Changeset
  use Gettext, backend: FullCircleWeb.Gettext

  # "Paid outside file": a Payment paid by cheque or manual transfer.
  schema "bank_payment_dismissals" do
    belongs_to :company, FullCircle.Sys.Company
    belongs_to :payment, FullCircle.BillPay.Payment
    belongs_to :user, FullCircle.UserAccounts.User
    field :note, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:company_id, :payment_id, :user_id, :note])
    |> validate_required([:company_id, :payment_id, :user_id])
    |> validate_length(:note, max: 200)
    |> unique_constraint(:payment_id,
      name: :bank_payment_dismissals_payment_id_index,
      message: gettext("is already marked paid outside file")
    )
  end
end
```

`lib/full_circle/bank_payment/download.ex`:

```elixir
defmodule FullCircle.BankPayment.Download do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "bank_payment_downloads" do
    belongs_to :batch, FullCircle.BankPayment.Batch
    belongs_to :user, FullCircle.UserAccounts.User
    field :reason, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:batch_id, :user_id, :reason])
    |> validate_required([:batch_id, :user_id])
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/bank_payment_schema_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex lib/full_circle/bank_payment/*.ex test/full_circle/bank_payment_schema_test.exs
git add lib/full_circle/bank_payment.ex lib/full_circle/bank_payment/ test/full_circle/bank_payment_schema_test.exs
git commit -m "feat(bank-payment): schemas for formats, profiles, batches, lines, dismissals, downloads

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Formats, templates and profiles in the context

**Files:**
- Modify: `lib/full_circle/bank_payment.ex` (replace)
- Create: `priv/bank_file_templates/rhb_bulk_pay.json`, `priv/bank_file_templates/pbb_ecp_payment.json`
- Create: `test/support/fixtures/bank_payment_fixtures.ex`
- Test: `test/full_circle/bank_payment_test.exs` (new)

**Interfaces:**
- Produces: `today(company) :: Date`; `validate_spec/1` (FileSpec + `params`/`our_account_no_digits` checks; Task 13 adds `result`); `render_file(spec, rows, header)`; `list_formats/1`, `format_codes/1`, `effective_format/3`, `format_version_exists?/3`, `save_format/4` (`replace: true`); `templates/0`, `load_template/1`; `list_profiles/1`, `get_profile/2`, `bank_accounts/1`, `save_profile/4`, `profile_warnings(profile, company) :: :no_format | [String.t()]`. Fixtures listed in Step 2.

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
    "our_account_no_digits": [14],
    "max_rows": 300,
    "computed": {
      "hash_part": "num(right(account_no, 6)) * mod(floor(amount), 1000000)"
    },
    "sections": [
      {
        "kind": "header",
        "fields": [
          {"expr": "\"00\""},
          {"expr": "\"01\""},
          {"expr": "corporate_id", "format": "digits"},
          {"expr": "\"\""},
          {"expr": "left(replace(corporate_name, \"&\", \"AND\"), 40)", "allow": "A-Za-z0-9 /?:().,'+-"},
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
          {"expr": "left(replace(account_name, \"&\", \"AND\"), 96)", "allow": "A-Za-z0-9 /?:().,'+-"},
          {"expr": "account_no", "format": "digits"},
          {"expr": "if(reg_no == \"\", \"\", \"05\")"},
          {"expr": "left(reg_no, 15)", "allow": "A-Za-z0-9"},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "\"\""},
          {"expr": "left(payment_no, 20)", "allow": "A-Za-z0-9 /?:().,'+-"},
          {"expr": "left(replace(descriptions, \"&\", \"AND\"), 20)", "allow": "A-Za-z0-9 /?:().,'+-"},
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
          {"expr": "emails", "allow": "A-Za-z0-9@._+;-"},
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
              {"expr": "left(replace(advice_doc_no, \"&\", \"AND\"), 20)", "allow": "A-Za-z0-9 /?:().,'+-"},
              {"expr": "left(replace(if(advice_doc_no == \"\", payment_no, advice_doc_no), \"&\", \"AND\"), 20)", "allow": "A-Za-z0-9 /?:().,'+-"},
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
    "our_account_no_digits": [10],
    "computed": {
      "acct4": "num(left(account_no, 4))"
    },
    "result": {
      "layout": "fixed",
      "header": {"identifier": "H", "filename": [10, 23]},
      "detail": {"identifier": "D", "record_id": [2, 16], "amount": [201, 18], "status": [259, 2], "reason": [261, 40]},
      "amount_in_cents": true,
      "success": ["01"]
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
          {"expr": "email", "width": 70, "allow": "A-Za-z0-9@._+-"},
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

- [ ] **Step 2: Write the fixtures** — `test/support/fixtures/bank_payment_fixtures.ex`:

```elixir
defmodule FullCircle.BankPaymentFixtures do
  alias FullCircle.{Accounting, BankPayment, BillPay, Repo, StdInterface}
  alias FullCircle.Accounting.{Account, TaxCode}

  import FullCircle.BillingFixtures
  import Ecto.Query

  def bank_gl_account_fixture(company, user) do
    {:ok, account} =
      StdInterface.create(Account, "account", %{"name" => "Bank #{System.unique_integer([:positive])}", "account_type" => "Bank", "descriptions" => "test bank"}, company, user)

    account
  end

  def bank_contact_fixture(company, user, bank \\ %{}) do
    c = contact_fixture(company, user, %{"email" => "sup#{System.unique_integer([:positive])}@example.com"})
    attrs = Map.merge(%{"bank_code" => "MBBEMYKL", "bank_account_no" => "112233445566", "bank_account_name" => c.name}, bank)
    {:ok, c} = Accounting.save_contact_bank(c, attrs, company, user)
    c
  end

  def install_template!(company, user, code) do
    {:ok, t} = BankPayment.load_template(code)
    {:ok, f} = BankPayment.save_format(%{"code" => t["code"], "name" => t["name"], "effective_from" => "2026-01-01", "spec" => t["spec"]}, company, user)
    f
  end

  def profile_fixture(company, user, account, attrs \\ %{}) do
    defaults = %{
      "account_id" => account.id,
      "format_code" => "rhb_bulk_pay",
      "our_account_no" => "21234500012345",
      "start_date" => Date.to_iso8601(Date.add(BankPayment.today(company), -30)),
      "params" => %{"corporate_id" => "123456", "corporate_name" => "TEST SDN BHD"}
    }

    {:ok, p} = BankPayment.save_profile(%BankPayment.Profile{}, Map.merge(defaults, attrs), company, user)
    p
  end

  def payment_attrs_for(company, user, contact, funds_account, amount) do
    good = good_fixture(company, user)
    pur = Accounting.get_account_by_name("General Purchases", company, user)
    no_ptax = Repo.one!(from tc in TaxCode, where: tc.company_id == ^company.id and tc.code == "NoPTax")

    FullCircle.BillPayFixtures.payment_attrs(contact, good, pur, no_ptax, funds_account,
      funds_amount: amount,
      quantity: "1",
      unit_price: amount,
      tax_rate: "0"
    )
  end

  def bank_payment_fixture(company, user, contact, funds_account, amount \\ "100.00") do
    attrs = payment_attrs_for(company, user, contact, funds_account, amount)
    {:ok, %{create_payment: p}} = BillPay.create_payment(attrs, company, user)
    p
  end

  @doc "A PB Payment Status Feedback file (ECP guide §7) for `rows` of {record_id, cents, status, reason}."
  def psf_text(uploaded_filename, rows) do
    header = String.pad_trailing("H" <> "20261013" <> String.pad_trailing(uploaded_filename, 23), 365)

    details =
      for {rec, cents, status, reason} <- rows do
        "D" <> String.pad_trailing(rec, 16) <> String.duplicate(" ", 183) <>
          String.pad_leading("#{cents}", 18, "0") <> String.duplicate(" ", 40) <> status <>
          String.pad_trailing(reason, 40)
      end

    Enum.join([header | details] ++ ["F" <> String.duplicate("0", 50)], "\r\n") <> "\r\n"
  end
end
```

- [ ] **Step 3: Write the failing test** — `test/full_circle/bank_payment_test.exs`:

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
      assert [%{code: "pbb_ecp_payment"}, %{code: "rhb_bulk_pay"}] = BankPayment.templates()

      for code <- ["rhb_bulk_pay", "pbb_ecp_payment"] do
        assert {:ok, %{"spec" => spec}} = BankPayment.load_template(code)
        assert :ok = BankPayment.validate_spec(spec)
      end
    end

    test "unknown or unsafe template codes are refused" do
      assert {:error, _} = BankPayment.load_template("../../etc/passwd")
      assert {:error, _} = BankPayment.load_template("nope")
    end

    test "bank keys are validated" do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")
      assert {:error, msgs} = BankPayment.validate_spec(Map.put(spec, "our_account_no_digits", ["x"]))
      assert Enum.any?(msgs, &(&1 =~ "our_account_no_digits"))
    end
  end

  test "today/1 is the company's local date", %{company: company} do
    assert BankPayment.today(company) == DateTime.to_date(DateTime.now!(company.timezone))
  end

  describe "formats" do
    test "save, effective version by date, replace in place", %{company: company, admin: admin} do
      f = install_template!(company, admin, "rhb_bulk_pay")
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2026-10-12]).id == f.id
      assert BankPayment.effective_format(company.id, "rhb_bulk_pay", ~D[2025-12-31]) == nil
      assert BankPayment.format_version_exists?(company.id, "rhb_bulk_pay", "2026-01-01")

      attrs = %{"code" => "rhb_bulk_pay", "name" => "Renamed", "effective_from" => "2026-01-01", "spec" => f.spec}
      assert {:error, cs} = BankPayment.save_format(attrs, company, admin)
      assert errors_on(cs).effective_from != []
      assert {:ok, f2} = BankPayment.save_format(attrs, company, admin, replace: true)
      assert {f2.id, f2.name} == {f.id, "Renamed"}
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
               BankPayment.save_profile(%Profile{}, %{"account_id" => cash.id, "format_code" => "rhb_bulk_pay", "our_account_no" => "1", "start_date" => "2026-01-01"}, company, admin)

      assert "must be a Bank account of this company" in errors_on(cs).account_id
    end

    test "warnings list missing params and a wrong account length", %{company: company, admin: admin} do
      bank = bank_gl_account_fixture(company, admin)
      p = profile_fixture(company, admin, bank, %{"params" => %{"corporate_id" => "123456"}, "our_account_no" => "123"})
      assert BankPayment.profile_warnings(p, company) == :no_format
      install_template!(company, admin, "rhb_bulk_pay")
      assert [w1, w2] = BankPayment.profile_warnings(p, company)
      assert w1 =~ "corporate_name"
      assert w2 =~ "14 digits"
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

- [ ] **Step 5: Implement** — replace `lib/full_circle/bank_payment.ex`:

```elixir
defmodule FullCircle.BankPayment do
  @moduledoc """
  Bank bulk payment files: supplier Payments → a bank upload file (RHB Reflex
  Bulk Pay, PB enterprise ECP Payment), batch lifecycle, bank result import.
  See docs/superpowers/specs/2026-10-12-bank-bulk-payment-design.md and
  .claude/skills/bank-bulk-payment.md.
  """
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  alias FullCircle.{FileSpec, Repo, Sys}
  alias FullCircle.Accounting.Account
  alias FullCircle.BankPayment.{FileFormat, Profile}

  @sources ["payments"]
  @row_vars ~w(record_id payment_no doc_date amount bank_code account_no account_name contact_name reg_no email emails descriptions advice advice_text)
  @child_vars ~w(advice_doc_no advice_doc_date advice_amount)
  @header_vars ~w(our_account_no payment_date today company_name seq batch_no)

  # ── Basics ─────────────────────────────────────────

  @doc "The company's local date. Every 'today' in this feature uses it."
  def today(company), do: (company.timezone || "Asia/Kuala_Lumpur") |> DateTime.now!() |> DateTime.to_date()

  def reserved_variables, do: @row_vars ++ @child_vars ++ @header_vars

  @doc "Profile params the spec declares under \"params\"."
  def spec_params(spec), do: spec |> Map.get("params", []) |> List.wrap() |> Enum.filter(&is_binary/1)

  def format_variables(spec), do: reserved_variables() ++ spec_params(spec)

  def validate_spec(spec) do
    errors =
      case FileSpec.validate(spec, format_variables(spec), @sources) do
        :ok -> []
        {:error, e} -> e
      end

    case errors ++ bank_key_errors(spec) do
      [] -> :ok
      all -> {:error, all}
    end
  end

  defp bank_key_errors(spec) do
    digits =
      case Map.get(spec, "our_account_no_digits") do
        nil -> []
        l when is_list(l) and l != [] -> if Enum.all?(l, &(is_integer(&1) and &1 > 0)), do: [], else: ["our_account_no_digits must be a list of positive integers"]
        _ -> ["our_account_no_digits must be a list of positive integers"]
      end

    params =
      case Map.get(spec, "params") do
        nil -> []
        l when is_list(l) -> if Enum.all?(l, &is_binary/1), do: [], else: ["params must be a list of names"]
        _ -> ["params must be a list of names"]
      end

    digits ++ params
  end

  @doc "Renders a bank spec against FileSpec rows and a header context."
  def render_file(spec, rows, header), do: FileSpec.render(spec, rows, header, format_variables(spec), @sources)

  # ── Formats ────────────────────────────────────────

  def list_formats(company_id) do
    from(f in FileFormat, where: f.company_id == ^company_id, order_by: [asc: f.code, desc: f.effective_from])
    |> Repo.all()
  end

  def format_codes(company_id) do
    from(f in FileFormat, where: f.company_id == ^company_id, distinct: true, select: f.code) |> Repo.all()
  end

  def effective_format(company_id, code, date) do
    from(f in FileFormat,
      where: f.company_id == ^company_id and f.code == ^code and f.effective_from <= ^date,
      order_by: [desc: f.effective_from],
      limit: 1
    )
    |> Repo.one()
  end

  def format_version_exists?(company_id, code, date_string), do: find_format(company_id, code, date_string) != nil

  defp find_format(company_id, code, date_string) do
    with true <- is_binary(code),
         {:ok, date} <- Date.from_iso8601(to_string(date_string)) do
      Repo.get_by(FileFormat, company_id: company_id, code: code, effective_from: date)
    else
      _ -> nil
    end
  end

  @doc "Saves a format version; `replace: true` updates the same (code, effective_from) row. Batches keep their own spec copy."
  def save_format(attrs, company, user, opts \\ []) do
    if can?(user, :manage_bank_payment_config, company) do
      attrs = attrs |> stringify() |> Map.put("company_id", company.id)
      base = (opts[:replace] && find_format(company.id, attrs["code"], attrs["effective_from"])) || %FileFormat{}

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

  defp profiles_query(company) do
    from(p in Profile,
      join: a in Account,
      on: a.id == p.account_id,
      where: p.company_id == ^company.id,
      select: %{p | account_name: a.name}
    )
  end

  def list_profiles(company), do: company |> profiles_query() |> order_by([_p, a], a.name) |> Repo.all()

  def get_profile(id, company) do
    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> company |> profiles_query() |> where([p], p.id == ^uuid) |> Repo.one()
      :error -> nil
    end
  end

  def bank_accounts(company) do
    from(a in Account, where: a.company_id == ^company.id and a.account_type == "Bank", order_by: a.name, select: {a.name, a.id})
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

  @doc "What the profile lacks for its format in force today; :no_format when none is."
  def profile_warnings(%Profile{} = profile, company) do
    case effective_format(company.id, profile.format_code, today(company)) do
      nil -> :no_format
      f -> missing_params(f.spec, profile) ++ our_account_errors(f.spec, profile)
    end
  end

  defp missing_params(spec, profile) do
    have = for {k, v} <- profile.params || %{}, v not in [nil, ""], do: k
    Enum.map(spec_params(spec) -- have, &"missing param: #{&1}")
  end

  defp our_account_errors(spec, profile) do
    case Map.get(spec, "our_account_no_digits") do
      l when is_list(l) and l != [] ->
        if String.length(profile.our_account_no || "") in l,
          do: [],
          else: ["our account number must be #{Enum.join(l, "/")} digits for this format"]

      _ ->
        []
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
```

- [ ] **Step 6: Run tests**

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

### Task 10: Rows and golden files

**Files:**
- Create: `lib/full_circle/bank_payment/rows.ex`
- Test: `test/full_circle/bank_payment_golden_test.exs`

**Interfaces:**
- Produces: `Rows.line_attrs(payment)` (preload `:contact`, `payment_details: :good`, `transaction_matchers: :transaction`); `Rows.to_row(line)` (string keys incl. `email`, `emails`, `advice`, `advice_text`); `Rows.advice_text/1`; `Rows.emails/1`.

- [ ] **Step 1: Write the failing golden test**

```elixir
defmodule FullCircle.BankPaymentGoldenTest do
  use ExUnit.Case, async: true

  alias FullCircle.{BankPayment, FileSpec}
  alias FullCircle.BankPayment.Rows

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
        "emails" => "",
        "descriptions" => "",
        "advice" => [],
        "advice_text" => ""
      },
      attrs
    )
  end

  defp lines(text), do: String.split(text, "\r\n", trim: true)

  test "e-mails: first single address, all joined with ;" do
    assert Rows.emails("a@x.com, b@y.com; junk") == {"a@x.com", "a@x.com;b@y.com"}
    assert Rows.emails(nil) == {"", ""}
  end

  describe "RHB Reflex Bulk Pay" do
    setup do
      {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")

      header = %{
        "corporate_id" => "123456",
        "corporate_name" => "FULL CIRCLE & CO SDN BHD",
        "our_account_no" => "21234500012345",
        "payment_date" => ~D[2026-10-15],
        "today" => ~D[2026-10-12],
        "company_name" => "Full Circle",
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
        |> Enum.map(fn {acct, i} -> row(%{"account_no" => acct, "record_id" => String.pad_leading("#{i}", 12, "0")}) end)

      assert {:ok, text} = BankPayment.render_file(spec, rows, header)
      assert List.last(lines(text)) == "99,20261012001,5,5000.00,164632936,,,,,"
    end

    test "cents and amounts over RM1M", %{spec: spec, header: header} do
      rows = [
        row(%{"account_no" => "112233374890", "amount" => Decimal.new("1234567.89")}),
        row(%{"account_no" => "5000184560001", "amount" => Decimal.new("1000.50"), "record_id" => "000000000002"})
      ]

      assert {:ok, text} = BankPayment.render_file(spec, rows, header)
      assert List.last(lines(text)) == "99,20261012001,2,1235568.39,7452364105,,,,,"
    end

    test "header, quoted name with & → AND, e-mails, advice children, filename", %{spec: spec, header: header} do
      r =
        row(%{
          "account_name" => "Tan, Lee & Sons",
          "reg_no" => "REG001",
          "descriptions" => "Test payment",
          "emails" => "ah@example.com;b@example.com",
          "advice" => [
            %{"doc_no" => "INV-1", "doc_date" => ~D[2026-10-01], "amount" => Decimal.new("995.00")},
            %{"doc_no" => "", "doc_date" => ~D[2026-10-10], "amount" => Decimal.new("5.00")}
          ]
        })

      assert {:ok, text} = BankPayment.render_file(spec, [r], header)
      [h, d, a1, a2, _f] = lines(text)

      assert h ==
               Enum.join(["00", "01", "123456", "", "FULL CIRCLE AND CO SDN BHD", "21234500012345", "15102026", "20261012001", "", "A"] ++ List.duplicate("", 9), ",")

      assert d ==
               Enum.join(
                 ["10", "10", "000000000001", "1000.00", "MBBEMYKL", "1", ~s|"Tan, Lee AND Sons"|, "112233374890", "05", "REG001", "", "", "", "PV-000001", "Test payment"] ++
                   List.duplicate("", 12) ++ ["ah@example.com;b@example.com"] ++ List.duplicate("", 5),
                 ","
               )

      assert a1 == "30,01102026,995.00,INV-1,INV-1,,,,"
      assert a2 == "30,10102026,5.00,,PV-000001,,,,"
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
        "company_name" => "Full Circle",
        "seq" => 1,
        "batch_no" => "20261012001"
      }

      %{spec: spec, header: header}
    end

    test "fixed widths, PBB vs IBG, cents, hash and e-mail advice lines", %{spec: spec, header: header} do
      pbb = row(%{"bank_code" => "PBBEMYKL", "account_no" => "3123456789", "amount" => Decimal.new("1200.50"), "advice_text" => "INV-9 01/10/2026 1200.50", "email" => "pé@x.com"})
      ibg = row(%{"record_id" => "000000000002", "amount" => Decimal.new("99.99")})

      assert {:ok, text} = BankPayment.render_file(spec, [pbb, ibg], header)
      [h, d1, d2, f] = lines(text)

      assert h == "H399999999920261015"
      assert byte_size(d1) == 781
      assert byte_size(d2) == 781
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
Expected: FAIL — `Rows` undefined.

- [ ] **Step 3: Implement** — `lib/full_circle/bank_payment/rows.ex`:

```elixir
defmodule FullCircle.BankPayment.Rows do
  @moduledoc """
  Payment → batch line snapshot → FileSpec row. The row's own date is
  `doc_date`; `payment_date` is the batch's header value (FileSpec merges the
  header over each row).
  """

  alias FullCircle.BillPay.Payment

  @doc "Snapshot attrs. Preload :contact, payment_details: :good, transaction_matchers: :transaction."
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
          "doc_no" => d.descriptions || (d.good && d.good.name) || "",
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
    {email, emails} = emails(line.email)

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
      "email" => email,
      "emails" => emails,
      "descriptions" => line.descriptions || "",
      "advice" => advice,
      "advice_text" => advice_text(advice)
    }
  end

  @doc "{first address (blank if over 70 chars), all addresses joined with ;}"
  def emails(nil), do: {"", ""}

  def emails(text) do
    all = text |> String.split(~r/[\s,;\/]+/, trim: true) |> Enum.filter(&String.contains?(&1, "@"))

    first =
      case all do
        [a | _] when byte_size(a) <= 70 -> a
        _ -> ""
      end

    {first, Enum.join(all, ";")}
  end

  defp load_advice(a) do
    %{"doc_no" => a["doc_no"] || "", "doc_date" => Date.from_iso8601!(a["doc_date"]), "amount" => Decimal.new(a["amount"])}
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

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/bank_payment_golden_test.exs`
Expected: PASS. (The PB `pé@x.com` e-mail becomes `p@x.com` through `allow`, keeping 781 bytes.)

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment/rows.ex test/full_circle/bank_payment_golden_test.exs
git add lib/full_circle/bank_payment/rows.ex test/full_circle/bank_payment_golden_test.exs
git commit -m "feat(bank-payment): payment rows and golden RHB/PB files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Eligibility, batch creation, downloads

**Files:**
- Modify: `lib/full_circle/bank_payment.ex`
- Test: `test/full_circle/bank_payment_test.exs`

**Interfaces:**
- Produces:
  - `eligible_payments(profile, company) :: [%{id, payment_no, payment_date, amount, contact_name, bank_code, bank_name, account_no, account_name, changed_at, has_bank, recent_change, last_reason}]`
  - `create_batches(profile_id, payment_ids, payment_date, company, user, opts \\ []) :: {:ok, [Batch]} | {:duplicates, [String.t()]} | {:error, String.t() | [String.t()]} | :not_authorise` (`force: true` skips the duplicate warning)
  - `download_files(ids, reason, company, user) :: {:ok, [{filename, text}]} | {:error, String.t()} | :not_authorise`
  - `list_batches(company)` (preloads `:created_by`), `downloads_by_batch(ids) :: %{batch_id => [Download with :user]}`, `zip(files)`, `preview(spec, profile, company)`, `live_batch_filename(payment_id)`

- [ ] **Step 1: Write the failing tests** — append to `FullCircle.BankPaymentTest`:

```elixir
  defp setup_bank(company, admin, format \\ "rhb_bulk_pay", attrs \\ %{}) do
    install_template!(company, admin, format)
    bank = bank_gl_account_fixture(company, admin)
    profile = profile_fixture(company, admin, bank, Map.merge(%{"format_code" => format}, attrs))
    %{bank: bank, profile: profile}
  end

  defp pb_bank(company, admin), do: setup_bank(company, admin, "pbb_ecp_payment", %{"our_account_no" => "3999999999", "params" => %{}})

  defp pb_contact(company, admin), do: bank_contact_fixture(company, admin, %{"bank_code" => "PBBEMYKL", "bank_account_no" => "3123456789"})

  describe "eligible_payments/2" do
    test "the account's payments since start date, unbatched; flags missing bank details", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      with_bank = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      no_bank = bank_payment_fixture(company, admin, contact_fixture(company, admin), bank)
      other = FullCircle.BillPayFixtures.pay_funds_account_fixture(company, admin)
      _elsewhere = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), other)

      rows = BankPayment.eligible_payments(profile, company)
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([with_bank.id, no_bank.id])
      assert Enum.find(rows, &(&1.id == with_bank.id)).has_bank
      assert Enum.find(rows, &(&1.id == with_bank.id)).recent_change
      refute Enum.find(rows, &(&1.id == no_bank.id)).has_bank

      {:ok, _} = BankPayment.save_profile(profile, %{"start_date" => Date.to_iso8601(Date.add(BankPayment.today(company), 1))}, company, admin)
      assert BankPayment.eligible_payments(BankPayment.get_profile(profile.id, company), company) == []
    end
  end

  describe "create_batches/6" do
    test "creates a batch, removes its payments from the list, renders the file", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "250.00")

      assert {:ok, [batch]} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)
      assert batch.count == 1
      assert Decimal.equal?(batch.total, Decimal.new("250.00"))
      assert batch.filename =~ ~r/^PAYMENT_123456_\d{8}_001\.CSV$/
      assert batch.spec["filename"]
      assert BankPayment.live_batch_filename(p.id) == batch.filename
      assert BankPayment.eligible_payments(profile, company) == []

      assert {:ok, [{name, text}]} = BankPayment.download_files([batch.id], nil, company, admin)
      assert name == batch.filename
      assert text =~ ",250.00,MBBEMYKL,"
    end

    test "pre-flight: no bank details, more than 2 decimals; nothing saved", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p1 = bank_payment_fixture(company, admin, contact_fixture(company, admin), bank)
      p2 = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      FullCircle.Repo.update_all(from(x in FullCircle.BillPay.Payment, where: x.id == ^p2.id), set: [funds_amount: Decimal.new("100.005")])

      assert {:error, msgs} = BankPayment.create_batches(profile.id, [p1.id, p2.id], BankPayment.today(company), company, admin)
      assert Enum.any?(msgs, &(&1 =~ p1.payment_no and &1 =~ "no bank details"))
      assert Enum.any?(msgs, &(&1 =~ p2.payment_no and &1 =~ "2 decimal"))
      assert BankPayment.list_batches(company) == []
    end

    test "payment date must be today .. today+59 (company-local)", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      assert {:error, msg} = BankPayment.create_batches(profile.id, [p.id], Date.add(BankPayment.today(company), 60), company, admin)
      assert msg =~ "payment date"
    end

    test "our account number length must suit the format", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin, "rhb_bulk_pay", %{"our_account_no" => "123"})
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      assert {:error, msg} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)
      assert msg =~ "14 digits"
    end

    test "a payment cannot be batched twice", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      {:ok, _} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)
      assert {:error, [msg]} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)
      assert msg =~ "already in a bank batch"
    end

    test "duplicate warning: same supplier and amount, then Create anyway", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      c = bank_contact_fixture(company, admin)
      p1 = bank_payment_fixture(company, admin, c, bank, "80.00")
      p2 = bank_payment_fixture(company, admin, c, bank, "80.00")
      {:ok, _} = BankPayment.create_batches(profile.id, [p1.id], BankPayment.today(company), company, admin)

      assert {:duplicates, [msg]} = BankPayment.create_batches(profile.id, [p2.id], BankPayment.today(company), company, admin)
      assert msg =~ p1.payment_no
      assert {:ok, [_]} = BankPayment.create_batches(profile.id, [p2.id], BankPayment.today(company), company, admin, force: true)
    end

    test "an open Payment form can't save a stale amount after batching", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      stale = FullCircle.BillPay.get_payment!(p.id, company, admin)
      {:ok, [_]} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)
      fresh = FullCircle.BillPay.get_payment!(p.id, company, admin)
      assert fresh.lock_version == stale.lock_version + 1
    end

    test "splits at max_rows with consecutive sequence numbers", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = pb_bank(company, admin)
      f = BankPayment.effective_format(company.id, "pbb_ecp_payment", BankPayment.today(company))
      {:ok, _} = BankPayment.save_format(%{"code" => f.code, "name" => f.name, "effective_from" => "2026-01-01", "spec" => Map.put(f.spec, "max_rows", 2)}, company, admin, replace: true)
      ids = for _ <- 1..3, do: bank_payment_fixture(company, admin, pb_contact(company, admin), bank).id

      assert {:ok, [b1, b2]} = BankPayment.create_batches(profile.id, ids, BankPayment.today(company), company, admin, force: true)
      assert {b1.count, b2.count} == {2, 1}
      assert {b1.seq, b2.seq} == {1, 2}
      assert b1.filename =~ ~r/^3999999999PM\d{6}01\.txt$/
      assert {:ok, [_, _]} = BankPayment.download_files([b1.id, b2.id], nil, company, admin)
    end

    test "managers may, clerks may not", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      clerk = FullCircle.UserAccountsFixtures.user_fixture()
      FullCircle.Sys.allow_user_to_access(company, clerk, "clerk", admin)
      assert :not_authorise = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, clerk)
    end
  end

  describe "download_files/4" do
    test "second download needs a reason; each download is logged", %{company: company, admin: admin} do
      %{bank: bank, profile: profile} = setup_bank(company, admin)
      p = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank)
      {:ok, [b]} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(company), company, admin)

      assert {:ok, [{_, first}]} = BankPayment.download_files([b.id], nil, company, admin)
      assert {:error, msg} = BankPayment.download_files([b.id], " ", company, admin)
      assert msg =~ "reason"
      assert {:ok, [{_, ^first}]} = BankPayment.download_files([b.id], "browser lost it", company, admin)
      assert [_, %{reason: "browser lost it"}] = BankPayment.downloads_by_batch([b.id])[b.id]
    end
  end

  test "preview renders an unsaved spec against eligible payments only", %{company: company, admin: admin} do
    %{bank: bank, profile: profile} = setup_bank(company, admin)
    bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "12.34")
    batched = bank_payment_fixture(company, admin, bank_contact_fixture(company, admin), bank, "56.78")
    {:ok, _} = BankPayment.create_batches(profile.id, [batched.id], BankPayment.today(company), company, admin)
    {:ok, %{"spec" => spec}} = BankPayment.load_template("rhb_bulk_pay")
    assert {:ok, text} = BankPayment.preview(spec, profile, company)
    assert text =~ ",12.34,"
    refute text =~ ",56.78,"
  end
```

Add `import Ecto.Query` at the top of the test module.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/bank_payment_test.exs`
Expected: FAIL — `eligible_payments/2` undefined.

- [ ] **Step 3: Implement** — add to `lib/full_circle/bank_payment.ex`.

Aliases and attributes:

```elixir
  alias FullCircle.BillPay.Payment
  alias FullCircle.BankPayment.{Banks, Batch, BatchLine, Dismissal, Download, FileFormat, Profile, Rows}

  @max_days_ahead 59
  @recent_change_days 30
  @duplicate_days 14
  @preload [:contact, payment_details: :good, transaction_matchers: :transaction]
```

(Replace the earlier `alias FullCircle.BankPayment.{FileFormat, Profile}` line.)

Code:

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
  defp dismissed_payment_ids, do: from(d in Dismissal, select: d.payment_id)

  defp eligible_query(profile, company) do
    from(p in base_query(profile, company),
      where: p.id not in subquery(live_payment_ids()) and p.id not in subquery(dismissed_payment_ids())
    )
  end

  def eligible_payments(%Profile{} = profile, company) do
    since = DateTime.add(DateTime.utc_now(), -@recent_change_days * 86_400, :second)

    rows =
      from([p, contact: c] in eligible_query(profile, company),
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

    reasons = last_bank_reasons(Enum.map(rows, & &1.id))

    Enum.map(rows, fn r ->
      Map.merge(r, %{
        bank_name: Banks.name(r.bank_code),
        has_bank: not is_nil(r.bank_code) and not is_nil(r.account_no) and not is_nil(r.account_name),
        recent_change: not is_nil(r.changed_at) and DateTime.compare(r.changed_at, since) == :gt,
        last_reason: Map.get(reasons, r.id)
      })
    end)
  end

  defp last_bank_reasons(ids) do
    from(l in BatchLine, where: l.payment_id in ^ids and l.status == "rejected", order_by: l.record_no, select: {l.payment_id, l.bank_reason})
    |> Repo.all()
    |> Map.new()
  end

  # ── Batch creation ─────────────────────────────────

  def create_batches(profile_id, payment_ids, %Date{} = payment_date, company, user, opts \\ []) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Profile{} = profile <- get_profile(profile_id, company) || {:error, "bank payment profile not found"},
         :ok <- check_payment_date(payment_date, company),
         %FileFormat{} = format <-
           effective_format(company.id, profile.format_code, today(company)) ||
             {:error, "no bank file format '#{profile.format_code}' in force today"},
         :ok <- check_profile(format.spec, profile),
         {:ok, payments} <- load_selected(profile, payment_ids, company),
         :ok <- preflight(payments),
         :ok <- if(opts[:force], do: :ok, else: no_duplicates(payments, company)) do
      do_create(profile, format, Enum.map(payments, & &1.id), payment_date, company, user)
    end
  end

  defp check_payment_date(date, company) do
    first = today(company)
    last = Date.add(first, @max_days_ahead)

    if Date.compare(date, first) != :lt and Date.compare(date, last) != :gt,
      do: :ok,
      else: {:error, "payment date must be between #{first} and #{last}"}
  end

  defp check_profile(spec, profile) do
    case missing_params(spec, profile) ++ our_account_errors(spec, profile) do
      [] -> :ok
      problems -> {:error, "the bank payment profile needs fixing: " <> Enum.join(problems, "; ")}
    end
  end

  defp load_selected(profile, payment_ids, company) do
    ids = payment_ids |> List.wrap() |> Enum.uniq()
    payments = from(p in base_query(profile, company), where: p.id in ^ids, preload: ^@preload) |> Repo.all()

    cond do
      ids == [] -> {:error, "tick at least one payment"}
      length(payments) != length(ids) -> {:error, "some ticked payments are not eligible for this bank account"}
      true -> {:ok, Enum.sort_by(payments, &{&1.payment_date, &1.payment_no})}
    end
  end

  defp preflight(payments) do
    ids = Enum.map(payments, & &1.id)
    live = MapSet.new(Repo.all(from(l in BatchLine, where: l.live and l.payment_id in ^ids, select: l.payment_id)))
    dismissed = MapSet.new(Repo.all(from(d in Dismissal, where: d.payment_id in ^ids, select: d.payment_id)))

    errors =
      Enum.flat_map(payments, fn p ->
        c = p.contact
        bank = Banks.get(c.bank_code)

        cond do
          MapSet.member?(live, p.id) -> ["#{p.payment_no}: already in a bank batch"]
          MapSet.member?(dismissed, p.id) -> ["#{p.payment_no}: marked paid outside file"]
          is_nil(c.bank_code) or is_nil(c.bank_account_no) or is_nil(c.bank_account_name) -> ["#{p.payment_no}: #{c.name} has no bank details"]
          is_nil(bank) or String.length(c.bank_account_no) not in bank.lengths -> ["#{p.payment_no}: #{c.name}'s account number does not suit #{c.bank_code}"]
          not Decimal.equal?(p.funds_amount, Decimal.round(p.funds_amount, 2)) -> ["#{p.payment_no}: amount #{p.funds_amount} has more than 2 decimal places"]
          true -> []
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp no_duplicates(payments, company) do
    since = DateTime.add(DateTime.utc_now(), -@duplicate_days * 86_400, :second)
    ids = Enum.map(payments, & &1.id)

    existing =
      from(l in BatchLine,
        join: b in Batch,
        on: b.id == l.batch_id,
        join: p in Payment,
        on: p.id == l.payment_id,
        where: b.company_id == ^company.id and l.live and b.inserted_at >= ^since and l.payment_id not in ^ids,
        select: {p.contact_id, l.amount, l.payment_no, b.filename}
      )
      |> Repo.all()

    in_files =
      for p <- payments, {cid, amt, no, file} <- existing, cid == p.contact_id and Decimal.equal?(amt, p.funds_amount) do
        "#{p.payment_no}: #{p.contact.name} #{p.funds_amount} looks like #{no} already in #{file}"
      end

    within =
      payments
      |> Enum.group_by(&{&1.contact_id, Decimal.normalize(&1.funds_amount)})
      |> Enum.filter(fn {_, ps} -> length(ps) > 1 end)
      |> Enum.map(fn {_, ps} -> "#{Enum.map_join(ps, ", ", & &1.payment_no)}: same supplier and amount in this selection" end)

    case in_files ++ within do
      [] -> :ok
      msgs -> {:duplicates, msgs}
    end
  end

  defp do_create(profile, format, ids, payment_date, company, user) do
    Repo.transaction(fn ->
      # Serialises batch creation per profile so sequence numbers never collide.
      Repo.one!(from(p in Profile, where: p.id == ^profile.id, lock: "FOR UPDATE", select: p.id))
      # Any open Payment form now saves stale instead of changing the amount.
      Repo.update_all(from(p in Payment, where: p.id in ^ids), inc: [lock_version: 1])

      payments =
        with {:ok, ps} <- load_selected(profile, ids, company),
             :ok <- preflight(ps) do
          ps
        else
          {:error, e} -> Repo.rollback(e)
        end

      base = header_ctx(profile, company, payment_date)
      stem = filename!(fn -> FileSpec.filename(format.spec, base, nil) end) || "#{format.code}_#{Calendar.strftime(payment_date, "%Y%m%d")}_"
      first = next_seq(company.id, stem)

      payments
      |> Enum.chunk_every(FileSpec.max_rows(format.spec) || length(payments))
      |> Enum.with_index(first)
      |> Enum.map(fn {chunk, seq} -> insert_batch!(profile, format, chunk, base, stem, seq, payment_date, company, user) end)
    end)
  end

  defp header_ctx(profile, company, payment_date) do
    profile.params
    |> Kernel.||(%{})
    |> Map.drop(reserved_variables())
    |> Map.merge(%{
      "our_account_no" => profile.our_account_no,
      "payment_date" => payment_date,
      "today" => today(company),
      "company_name" => company.name
    })
  end

  defp filename!(fun) do
    fun.()
  rescue
    e in ArgumentError -> Repo.rollback(Exception.message(e))
  end

  # Voided batches count: banks refuse a filename that was already uploaded.
  defp next_seq(company_id, stem) do
    (Repo.one(from(b in Batch, where: b.company_id == ^company_id and b.filename_stem == ^stem, select: max(b.seq))) || 0) + 1
  end

  defp batch_no(company, seq), do: Calendar.strftime(today(company), "%Y%m%d") <> String.pad_leading("#{seq}", 3, "0")

  defp insert_batch!(profile, format, chunk, base, stem, seq, payment_date, company, user) do
    header = base |> Map.put("seq", seq) |> Map.put("batch_no", batch_no(company, seq))
    filename = filename!(fn -> FileSpec.filename(format.spec, base, seq) end) || "#{stem}#{seq}.#{FileSpec.extension(format.spec)}"
    total = Enum.reduce(chunk, Decimal.new(0), &Decimal.add(&1.funds_amount, &2))

    batch =
      %Batch{}
      |> Batch.changeset(%{
        company_id: company.id,
        profile_id: profile.id,
        format_id: format.id,
        spec: format.spec,
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
        attrs = p |> Rows.line_attrs() |> Map.merge(%{batch_id: batch.id, payment_id: p.id, record_no: next_record_no()})

        case %BatchLine{} |> BatchLine.changeset(attrs) |> Repo.insert() do
          {:ok, l} ->
            l

          {:error, cs} ->
            if Keyword.has_key?(cs.errors, :payment_id),
              do: Repo.rollback("#{p.payment_no} was just batched by someone else"),
              else: Repo.rollback("#{p.payment_no}: " <> Enum.map_join(cs.errors, "; ", fn {f, {m, _}} -> "#{f} #{m}" end))
        end
      end)

    case render_file(format.spec, Enum.map(lines, &Rows.to_row/1), header) do
      {:ok, _} -> :ok
      {:error, msg} -> Repo.rollback(msg)
    end

    Repo.insert!(Sys.log_changeset(:create_bank_payment_batch, batch, %{"filename" => filename, "count" => "#{batch.count}", "total" => Decimal.to_string(total)}, company, user))
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
    Enum.reduce(["payment_date", "today"], header, fn k, acc -> Map.update(acc, k, nil, &Date.from_iso8601!/1) end)
  end

  # ── Listing and downloads ──────────────────────────

  defp get_batch(id, company) do
    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> Repo.get_by(Batch, id: uuid, company_id: company.id)
      :error -> nil
    end
  end

  def list_batches(company) do
    from(b in Batch, where: b.company_id == ^company.id, order_by: [desc: b.inserted_at, desc: b.seq], limit: 50, preload: [:created_by])
    |> Repo.all()
  end

  def downloads_by_batch(ids) do
    from(d in Download, where: d.batch_id in ^ids, order_by: d.inserted_at, preload: [:user])
    |> Repo.all()
    |> Enum.group_by(& &1.batch_id)
  end

  @doc """
  Rebuilds each batch's file from its saved lines, header and spec, logging the
  download. A batch already downloaded needs a reason; after submission only an
  admin may download again; voided batches never.
  """
  def download_files(ids, reason, company, user) do
    reason = String.trim(reason || "")

    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise do
      Repo.transaction(fn ->
        Enum.map(List.wrap(ids), fn id ->
          case download_one(id, reason, company, user) do
            {:ok, file} -> file
            {:error, msg} -> Repo.rollback(msg)
          end
        end)
      end)
    end
  end

  defp download_one(id, reason, company, user) do
    with %Batch{} = batch <- get_batch(id, company) || {:error, "batch not found"},
         :ok <- may_download(batch, reason, company, user),
         {:ok, file} <- batch_file(batch) do
      Repo.insert!(Download.changeset(%Download{}, %{batch_id: batch.id, user_id: user.id, reason: if(reason == "", do: nil, else: reason)}))
      Repo.insert!(Sys.log_changeset(:download_bank_payment_batch, batch, %{"filename" => batch.filename, "reason" => reason}, company, user))
      {:ok, file}
    end
  end

  defp may_download(%Batch{status: "voided", filename: f}, _reason, _company, _user),
    do: {:error, "#{f} is voided and cannot be downloaded; its payments may be in a newer file"}

  defp may_download(batch, reason, company, user) do
    cond do
      not Repo.exists?(from(d in Download, where: d.batch_id == ^batch.id)) -> :ok
      reason == "" -> {:error, "a reason is needed to download #{batch.filename} again"}
      batch.status != "exported" and not can?(user, :admin_bank_payment_batch, company) -> {:error, "#{batch.filename} was submitted to the bank; only an admin can download it again"}
      true -> :ok
    end
  end

  defp batch_file(batch) do
    lines = Repo.all(from(l in BatchLine, where: l.batch_id == ^batch.id, order_by: l.record_no))

    case render_file(batch.spec, Enum.map(lines, &Rows.to_row/1), load_header(batch.header)) do
      {:ok, text} -> {:ok, {batch.filename, text}}
      {:error, msg} -> {:error, msg}
    end
  end

  def zip(files) do
    entries = Enum.map(files, fn {name, text} -> {String.to_charlist(name), text} end)
    {:ok, {_name, bin}} = :zip.create(~c"bank_batches.zip", entries, [:memory])
    {:ok, bin}
  end

  @doc "Renders `spec` (saved or not) against up to 10 currently eligible payments with bank details."
  def preview(spec, %Profile{} = profile, company) do
    rows =
      from([p, contact: c] in eligible_query(profile, company),
        where: not is_nil(c.bank_code) and not is_nil(c.bank_account_no) and not is_nil(c.bank_account_name),
        order_by: [desc: p.payment_date],
        limit: 10,
        preload: ^@preload
      )
      |> Repo.all()
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> p |> Rows.line_attrs() |> Map.put(:record_no, i) |> Rows.to_row() end)

    header = profile |> header_ctx(company, today(company)) |> Map.merge(%{"seq" => 1, "batch_no" => batch_no(company, 1)})
    render_file(spec, rows, header)
  end

  # ── Payment lock ───────────────────────────────────

  def live_batch_filename(payment_id) do
    from(l in BatchLine, join: b in Batch, on: b.id == l.batch_id, where: l.payment_id == ^payment_id and l.live, select: b.filename)
    |> Repo.one()
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/bank_payment_test.exs test/full_circle/bank_payment_golden_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex test/full_circle/bank_payment_test.exs
git add lib/full_circle/bank_payment.ex test/full_circle/bank_payment_test.exs
git commit -m "feat(bank-payment): eligibility, guarded batch creation, logged downloads

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Batch lifecycle, line release, paid outside file

**Files:**
- Modify: `lib/full_circle/bank_payment.ex`
- Test: `test/full_circle/bank_payment_lifecycle_test.exs`

**Interfaces:**
- Produces: `mark_submitted(batch_id, company, user)`, `void_batch(batch_id, reason, company, user)`, `release_line(line_id, reason, company, user)`, `return_line(line_id, reason, company, user)`, `batch_lines(batch_id, company) :: [BatchLine]`, `dismiss_payment(payment_id, note, company, user)`, `undismiss_payment(payment_id, company, user)`, `list_dismissed(company) :: [map]`. Each returns `{:ok, struct} | {:error, String.t() | Changeset} | :not_authorise`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.BankPaymentLifecycleTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    install_template!(company, admin, "rhb_bulk_pay")
    bank = bank_gl_account_fixture(company, admin)
    profile = profile_fixture(company, admin, bank)
    mgr = FullCircle.UserAccountsFixtures.user_fixture()
    FullCircle.Sys.allow_user_to_access(company, mgr, "manager", admin)
    %{admin: admin, company: company, bank: bank, profile: profile, mgr: mgr}
  end

  defp batch!(ctx, n \\ 1) do
    ps = for _ <- 1..n, do: bank_payment_fixture(ctx.company, ctx.admin, bank_contact_fixture(ctx.company, ctx.admin), ctx.bank)
    {:ok, [b]} = BankPayment.create_batches(ctx.profile.id, Enum.map(ps, & &1.id), BankPayment.today(ctx.company), ctx.company, ctx.admin, force: true)
    {b, ps}
  end

  test "void an exported batch frees its payments; voided batches can't be downloaded; seq moves on", ctx do
    {b1, [p]} = batch!(ctx)
    assert {:error, _} = BankPayment.void_batch(b1.id, " ", ctx.company, ctx.mgr)
    assert {:ok, %{status: "voided"}} = BankPayment.void_batch(b1.id, "never uploaded", ctx.company, ctx.mgr)
    assert BankPayment.live_batch_filename(p.id) == nil
    assert {:error, msg} = BankPayment.download_files([b1.id], "x", ctx.company, ctx.admin)
    assert msg =~ "voided"

    {:ok, [b2]} = BankPayment.create_batches(ctx.profile.id, [p.id], BankPayment.today(ctx.company), ctx.company, ctx.admin)
    assert b2.seq == 2
    [l1] = BankPayment.batch_lines(b1.id, ctx.company)
    [l2] = BankPayment.batch_lines(b2.id, ctx.company)
    refute l1.record_no == l2.record_no
  end

  test "a submitted batch: only an admin may void it or download it again", ctx do
    {b, _} = batch!(ctx)
    {:ok, _} = BankPayment.download_files([b.id], nil, ctx.company, ctx.mgr)
    assert {:ok, %{status: "submitted"}} = BankPayment.mark_submitted(b.id, ctx.company, ctx.mgr)
    assert {:error, _} = BankPayment.mark_submitted(b.id, ctx.company, ctx.mgr)

    assert {:error, msg} = BankPayment.void_batch(b.id, "oops", ctx.company, ctx.mgr)
    assert msg =~ "only an admin"
    assert {:error, msg} = BankPayment.download_files([b.id], "again", ctx.company, ctx.mgr)
    assert msg =~ "only an admin"
    assert {:ok, _} = BankPayment.download_files([b.id], "again", ctx.company, ctx.admin)
    assert {:ok, %{status: "voided"}} = BankPayment.void_batch(b.id, "bank rejected the file", ctx.company, ctx.admin)
  end

  test "release one rejected line; the rest stay locked; returning a paid line is admin only", ctx do
    {b, [p1, p2]} = batch!(ctx, 2)
    {:ok, _} = BankPayment.mark_submitted(b.id, ctx.company, ctx.mgr)
    [l1, l2] = BankPayment.batch_lines(b.id, ctx.company)

    assert {:ok, %{status: "rejected", live: false}} = BankPayment.release_line(l1.id, "wrong account no", ctx.company, ctx.mgr)
    released = if l1.payment_id == p1.id, do: p1, else: p2
    kept = if released == p1, do: p2, else: p1
    assert BankPayment.live_batch_filename(released.id) == nil
    assert BankPayment.live_batch_filename(kept.id) == b.filename
    assert [%{last_reason: "wrong account no"}] = BankPayment.eligible_payments(ctx.profile, ctx.company)

    assert {:error, _} = BankPayment.return_line(l2.id, "returned", ctx.company, ctx.admin)
    # Simulate a bank result that paid l2 (Task 13 does this for real).
    FullCircle.Repo.update!(FullCircle.BankPayment.BatchLine.resolve_changeset(l2, %{status: "paid"}))
    FullCircle.Repo.update!(FullCircle.BankPayment.Batch.status_changeset(FullCircle.Repo.reload!(b), "partly_rejected"))
    assert :not_authorise = BankPayment.return_line(l2.id, "returned", ctx.company, ctx.mgr)
    assert {:ok, %{status: "rejected"}} = BankPayment.return_line(l2.id, "returned by receiving bank", ctx.company, ctx.admin)
  end

  test "a batch with a bank result can't be voided", ctx do
    {b, _} = batch!(ctx)
    FullCircle.Repo.update!(FullCircle.BankPayment.Batch.status_changeset(b, "completed"))
    assert {:error, msg} = BankPayment.void_batch(b.id, "x", ctx.company, ctx.admin)
    assert msg =~ "bank result"
  end

  test "paid outside file: leaves the list, can't be batched, undo brings it back", ctx do
    p = bank_payment_fixture(ctx.company, ctx.admin, bank_contact_fixture(ctx.company, ctx.admin), ctx.bank)
    assert {:ok, _} = BankPayment.dismiss_payment(p.id, "paid by cheque 1234", ctx.company, ctx.mgr)
    assert BankPayment.eligible_payments(ctx.profile, ctx.company) == []
    assert [%{payment_no: no, note: "paid by cheque 1234"}] = BankPayment.list_dismissed(ctx.company)
    assert no == p.payment_no
    assert {:error, [msg]} = BankPayment.create_batches(ctx.profile.id, [p.id], BankPayment.today(ctx.company), ctx.company, ctx.admin)
    assert msg =~ "paid outside file"

    assert {:ok, _} = BankPayment.undismiss_payment(p.id, ctx.company, ctx.mgr)
    assert [_] = BankPayment.eligible_payments(ctx.profile, ctx.company)
  end

  test "a batched payment can't be dismissed", ctx do
    {_b, [p]} = batch!(ctx)
    assert {:error, msg} = BankPayment.dismiss_payment(p.id, nil, ctx.company, ctx.mgr)
    assert msg =~ "bank batch"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_lifecycle_test.exs`
Expected: FAIL — `void_batch/4` undefined.

- [ ] **Step 3: Implement** — add to `lib/full_circle/bank_payment.ex`:

```elixir
  # ── Lifecycle ──────────────────────────────────────

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def batch_lines(batch_id, company) do
    case get_batch(batch_id, company) do
      nil -> []
      b -> Repo.all(from(l in BatchLine, where: l.batch_id == ^b.id, order_by: l.record_no))
    end
  end

  def mark_submitted(batch_id, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Batch{status: "exported"} = batch <- get_batch(batch_id, company) || {:error, "batch not found"} do
      Multi.new()
      |> Multi.update(:submit_bank_payment_batch, Batch.submit_changeset(batch, %{submitted_by_id: user.id, submitted_at: now()}))
      |> Sys.insert_log_for(:submit_bank_payment_batch, %{"filename" => batch.filename}, company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{submit_bank_payment_batch: b}} -> {:ok, b}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      %Batch{} -> {:error, "only an exported batch can be marked submitted"}
      other -> other
    end
  end

  def void_batch(batch_id, reason, company, user) do
    reason = String.trim(reason || "")

    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Batch{} = batch <- get_batch(batch_id, company) || {:error, "batch not found"},
         :ok <- may_void(batch, company, user),
         true <- reason != "" || {:error, "a reason is required to void a batch"} do
      Multi.new()
      |> Multi.update(:void_bank_payment_batch, Batch.void_changeset(batch, %{void_reason: reason, voided_by_id: user.id, voided_at: now()}))
      |> Multi.update_all(:free_lines, from(l in BatchLine, where: l.batch_id == ^batch.id), set: [live: false])
      |> Sys.insert_log_for(:void_bank_payment_batch, %{"reason" => reason, "filename" => batch.filename}, company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{void_bank_payment_batch: b}} -> {:ok, b}
        {:error, _, cs, _} -> {:error, cs}
      end
    end
  end

  defp may_void(%Batch{status: "exported"}, _company, _user), do: :ok

  defp may_void(%Batch{status: "submitted"}, company, user) do
    if can?(user, :admin_bank_payment_batch, company),
      do: :ok,
      else: {:error, "this batch was submitted to the bank; only an admin can void it"}
  end

  defp may_void(%Batch{status: "voided"}, _company, _user), do: {:error, "batch is already voided"}
  defp may_void(_batch, _company, _user), do: {:error, "this batch has a bank result; release single lines instead"}

  def release_line(line_id, reason, company, user), do: resolve_line(line_id, reason, company, user, :release)
  def return_line(line_id, reason, company, user), do: resolve_line(line_id, reason, company, user, :return)

  defp resolve_line(line_id, reason, company, user, kind) do
    reason = String.trim(reason || "")
    action = if kind == :release, do: :create_bank_payment_batch, else: :admin_bank_payment_batch

    with true <- can?(user, action, company) || :not_authorise,
         {%BatchLine{} = line, %Batch{} = batch} <- get_line(line_id, company) || {:error, "line not found"},
         :ok <- may_resolve(kind, line, batch),
         true <- reason != "" || {:error, "a reason is required"} do
      log_name = if kind == :release, do: :release_bank_payment_line, else: :return_bank_payment_line

      Repo.transaction(fn ->
        line =
          line
          |> BatchLine.resolve_changeset(%{status: "rejected", live: false, bank_reason: reason, released_by_id: user.id, released_at: now()})
          |> Repo.update!()

        batch = refresh_batch_status!(batch)
        Repo.insert!(Sys.log_changeset(log_name, batch, %{"payment_no" => line.payment_no, "reason" => reason}, company, user))
        line
      end)
    end
  end

  defp may_resolve(:release, %BatchLine{status: "pending"}, %Batch{status: s}) when s in ["submitted", "partly_rejected"], do: :ok
  defp may_resolve(:release, _line, _batch), do: {:error, "only a pending line of a submitted batch can be released"}
  defp may_resolve(:return, %BatchLine{status: "paid"}, %Batch{status: s}) when s in ["completed", "partly_rejected"], do: :ok
  defp may_resolve(:return, _line, _batch), do: {:error, "only a paid line of a completed batch can be marked returned"}

  defp get_line(line_id, company) do
    case Ecto.UUID.cast(line_id || "") do
      {:ok, uuid} ->
        from(l in BatchLine, join: b in Batch, on: b.id == l.batch_id, where: l.id == ^uuid and b.company_id == ^company.id, select: {l, b})
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp refresh_batch_status!(%Batch{} = batch) do
    statuses = Repo.all(from(l in BatchLine, where: l.batch_id == ^batch.id, select: l.status))

    status =
      cond do
        "pending" in statuses -> batch.status
        Enum.all?(statuses, &(&1 == "paid")) -> "completed"
        true -> "partly_rejected"
      end

    if status == batch.status, do: batch, else: batch |> Batch.status_changeset(status) |> Repo.update!()
  end

  # ── Paid outside file ──────────────────────────────

  defp get_payment(id, company) do
    case Ecto.UUID.cast(id || "") do
      {:ok, uuid} -> Repo.get_by(Payment, id: uuid, company_id: company.id)
      :error -> nil
    end
  end

  def dismiss_payment(payment_id, note, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Payment{} = p <- get_payment(payment_id, company) || {:error, "payment not found"},
         nil <- live_batch_filename(p.id) do
      Multi.new()
      |> Multi.insert(:dismiss_bank_payment, Dismissal.changeset(%Dismissal{}, %{company_id: company.id, payment_id: p.id, user_id: user.id, note: note}))
      |> Sys.insert_log_for(:dismiss_bank_payment, %{"payment_no" => p.payment_no, "note" => note || ""}, company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{dismiss_bank_payment: d}} -> {:ok, d}
        {:error, _, cs, _} -> {:error, cs}
      end
    else
      filename when is_binary(filename) -> {:error, "this payment is in bank batch #{filename}"}
      other -> other
    end
  end

  def undismiss_payment(payment_id, company, user) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         %Payment{} = p <- get_payment(payment_id, company) || {:error, "payment not found"},
         %Dismissal{} = d <- Repo.get_by(Dismissal, payment_id: p.id) || {:error, "payment is not marked paid outside file"} do
      Multi.new()
      |> Multi.delete(:undismiss_bank_payment, d)
      |> Sys.insert_log_for(:undismiss_bank_payment, %{"payment_no" => p.payment_no}, company, user)
      |> Repo.transaction()
      |> case do
        {:ok, %{undismiss_bank_payment: d}} -> {:ok, d}
        {:error, _, cs, _} -> {:error, cs}
      end
    end
  end

  def list_dismissed(company) do
    from(d in Dismissal,
      join: p in Payment,
      on: p.id == d.payment_id,
      join: c in assoc(p, :contact),
      where: d.company_id == ^company.id,
      order_by: [desc: d.inserted_at],
      limit: 200,
      select: %{payment_id: p.id, payment_no: p.payment_no, payment_date: p.payment_date, contact_name: c.name, amount: p.funds_amount, note: d.note, inserted_at: d.inserted_at}
    )
    |> Repo.all()
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/bank_payment_lifecycle_test.exs test/full_circle/bank_payment_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex test/full_circle/bank_payment_lifecycle_test.exs
git add lib/full_circle/bank_payment.ex test/full_circle/bank_payment_lifecycle_test.exs
git commit -m "feat(bank-payment): batch lifecycle, line release/return, paid outside file

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Bank result import (PB PSF)

**Files:**
- Create: `lib/full_circle/bank_payment/result.ex`
- Modify: `lib/full_circle/bank_payment.ex` (`bank_key_errors/1` adds result validation; `import_result/3`)
- Test: `test/full_circle/bank_payment_result_test.exs`

**Interfaces:**
- Produces: `Result.validate(result_spec | nil) :: [String.t()]`, `Result.parse(text, result_spec) :: {:ok, %{filename, lines: [%{record_id, record_no, amount, status, success, reason}]}} | {:error, String.t()}`, `Result.same_file?(a, b)`; `BankPayment.import_result(text, company, user) :: {:ok, %{batch, paid, rejected, unmatched, mismatched, conflicts, missing}} | {:error, String.t()} | :not_authorise`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircle.BankPaymentResultTest do
  use FullCircle.DataCase

  alias FullCircle.BankPayment
  alias FullCircle.BankPayment.Result

  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  setup do
    %{admin: admin, company: company} = billing_setup()
    install_template!(company, admin, "pbb_ecp_payment")
    bank = bank_gl_account_fixture(company, admin)
    profile = profile_fixture(company, admin, bank, %{"format_code" => "pbb_ecp_payment", "our_account_no" => "3999999999", "params" => %{}})

    ps =
      for amt <- ["100.00", "200.50", "300.00"] do
        c = bank_contact_fixture(company, admin, %{"bank_code" => "PBBEMYKL", "bank_account_no" => "3123456789"})
        bank_payment_fixture(company, admin, c, bank, amt)
      end

    {:ok, [batch]} = BankPayment.create_batches(profile.id, Enum.map(ps, & &1.id), BankPayment.today(company), company, admin, force: true)
    lines = BankPayment.batch_lines(batch.id, company)
    %{admin: admin, company: company, profile: profile, batch: batch, lines: lines}
  end

  defp rec(l), do: String.pad_leading("#{l.record_no}", 12, "0")
  defp cents(l), do: l.amount |> Decimal.mult(100) |> Decimal.to_integer()

  test "parses PSF fixed positions" do
    {:ok, %{"spec" => %{"result" => r}}} = BankPayment.load_template("pbb_ecp_payment")
    assert Result.validate(r) == []
    text = psf_text("3999999999PM13102601", [{"000000000007", 12_050, "02", "INVALID ACCOUNT"}])
    assert {:ok, %{filename: "3999999999PM13102601", lines: [l]}} = Result.parse(text, r)
    assert {l.record_no, l.status, l.success, l.reason} == {7, "02", false, "INVALID ACCOUNT"}
    assert Decimal.equal?(l.amount, Decimal.new("120.50"))
  end

  test "success, failure, unknown id and amount mismatch; then a no-op re-import", %{company: company, admin: admin, batch: batch, lines: [l1, l2, l3]} do
    text =
      psf_text(Path.rootname(batch.filename), [
        {rec(l1), cents(l1), "01", ""},
        {rec(l2), cents(l2), "02", "INVALID ACCOUNT"},
        {rec(l3), cents(l3) + 1, "01", ""},
        {"999999999999", 100, "01", ""}
      ])

    assert {:ok, report} = BankPayment.import_result(text, company, admin)
    assert report.paid == [l1.payment_no]
    assert report.rejected == [l2.payment_no]
    assert [mm] = report.mismatched
    assert mm =~ l3.payment_no
    assert report.unmatched == ["999999999999"]
    assert report.missing == [l3.payment_no]
    assert report.batch.status == "submitted"
    assert report.batch.result_imported_at

    [n1, n2, n3] = BankPayment.batch_lines(batch.id, company)
    assert {n1.status, n1.live} == {"paid", true}
    assert {n2.status, n2.live, n2.bank_reason} == {"rejected", false, "INVALID ACCOUNT"}
    assert n3.status == "pending"

    assert {:ok, again} = BankPayment.import_result(text, company, admin)
    assert again.paid == [] and again.rejected == [] and again.conflicts == []
  end

  test "a result contradicting a manual release is reported, not applied", %{company: company, admin: admin, batch: batch, lines: [l1, _, _]} do
    {:ok, _} = BankPayment.mark_submitted(batch.id, company, admin)
    {:ok, _} = BankPayment.release_line(l1.id, "bank phoned: wrong account", company, admin)
    text = psf_text(Path.rootname(batch.filename), [{rec(l1), cents(l1), "01", ""}])

    assert {:ok, report} = BankPayment.import_result(text, company, admin)
    assert [c] = report.conflicts
    assert c =~ l1.payment_no
    assert hd(BankPayment.batch_lines(batch.id, company)).status == "rejected"
  end

  test "all lines paid → completed", %{company: company, admin: admin, batch: batch, lines: lines} do
    text = psf_text(Path.rootname(batch.filename), Enum.map(lines, &{rec(&1), cents(&1), "01", ""}))
    assert {:ok, %{batch: %{status: "completed"}}} = BankPayment.import_result(text, company, admin)
  end

  test "an unknown file is refused", %{company: company, admin: admin} do
    assert {:error, msg} = BankPayment.import_result(psf_text("NOPE", []), company, admin)
    assert msg =~ "no batch"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_result_test.exs`
Expected: FAIL — `Result` undefined.

- [ ] **Step 3: Implement**

`lib/full_circle/bank_payment/result.ex`:

```elixir
defmodule FullCircle.BankPayment.Result do
  @moduledoc """
  Reads a bank's result file with the format's "result" spec. Positions are
  1-based [from, length]. Only "fixed" layout for now (PB PSF, ECP guide §7);
  RHB's return file needs a "csv" layout once its sample is available.
  """

  @detail_fields ~w(record_id amount status reason)

  def validate(nil), do: []

  def validate(%{"layout" => "fixed"} = r) do
    header =
      case r["header"] do
        %{"identifier" => id, "filename" => pos} when is_binary(id) -> pos_errors("header filename", pos)
        _ -> ["result: header needs identifier and filename"]
      end

    detail =
      case r["detail"] do
        %{"identifier" => id} = d when is_binary(id) -> Enum.flat_map(@detail_fields, &pos_errors("detail #{&1}", d[&1]))
        _ -> ["result: detail needs identifier and positions"]
      end

    success =
      if is_list(r["success"]) and r["success"] != [] and Enum.all?(r["success"], &is_binary/1),
        do: [],
        else: ["result: success must list the success status codes"]

    header ++ detail ++ success
  end

  def validate(_), do: ["result: layout must be \"fixed\""]

  defp pos_errors(_name, [from, len]) when is_integer(from) and from > 0 and is_integer(len) and len > 0, do: []
  defp pos_errors(name, _), do: ["result: #{name} must be [from, length]"]

  def parse(text, r) do
    lines = String.split(text, ~r/\r?\n/, trim: true)
    h = r["header"]
    d = r["detail"]

    case Enum.find(lines, &String.starts_with?(&1, h["identifier"])) do
      nil ->
        {:error, "no header line in the result file"}

      header ->
        details = Enum.filter(lines, &String.starts_with?(&1, d["identifier"]))
        {:ok, %{filename: header |> slice(h["filename"]) |> String.trim(), lines: Enum.map(details, &detail(&1, d, r))}}
    end
  end

  defp detail(line, d, r) do
    record_id = line |> slice(d["record_id"]) |> String.trim()
    status = line |> slice(d["status"]) |> String.trim()

    %{
      record_id: record_id,
      record_no:
        case Integer.parse(record_id) do
          {n, ""} -> n
          _ -> nil
        end,
      amount: amount(slice(line, d["amount"]), r["amount_in_cents"]),
      status: status,
      success: status in r["success"],
      reason: line |> slice(d["reason"]) |> String.trim()
    }
  end

  defp slice(line, [from, len]), do: String.slice(line, from - 1, len) || ""

  defp amount(text, cents?) do
    digits = String.replace(text, ~r/[^0-9.]/, "")

    cond do
      digits == "" -> Decimal.new(0)
      cents? -> digits |> String.to_integer() |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)
      true -> Decimal.new(digits)
    end
  end

  @doc "PB's header holds 23 chars of the uploaded name, so compare without extension."
  def same_file?(a, b), do: normalize(a) != "" and normalize(a) == normalize(b)

  defp normalize(name), do: name |> to_string() |> String.trim() |> Path.rootname() |> String.downcase()
end
```

In `lib/full_circle/bank_payment.ex`, alias `Result` (add to the `alias FullCircle.BankPayment.{...}` list), and change the end of `bank_key_errors/1` to:

```elixir
    digits ++ params ++ Result.validate(Map.get(spec, "result"))
```

Add:

```elixir
  # ── Bank result import ─────────────────────────────

  def import_result(text, company, user) when is_binary(text) do
    with true <- can?(user, :create_bank_payment_batch, company) || :not_authorise,
         {:ok, batch, parsed} <- find_result_batch(text, company) do
      apply_result(batch, parsed, company, user)
    end
  end

  defp find_result_batch(text, company) do
    from(b in Batch, where: b.company_id == ^company.id and b.status != "voided", order_by: [desc: b.inserted_at], limit: 200)
    |> Repo.all()
    |> Enum.find_value({:error, "no batch matches this result file"}, fn b ->
      with %{} = r <- b.spec["result"],
           {:ok, parsed} <- Result.parse(text, r),
           true <- Result.same_file?(parsed.filename, b.filename) do
        {:ok, b, parsed}
      else
        _ -> nil
      end
    end)
  end

  defp apply_result(batch, parsed, company, user) do
    Repo.transaction(fn ->
      batch = Repo.one!(from(b in Batch, where: b.id == ^batch.id, lock: "FOR UPDATE"))
      lines = Repo.all(from(l in BatchLine, where: l.batch_id == ^batch.id)) |> Map.new(&{&1.record_no, &1})
      empty = %{paid: [], rejected: [], unmatched: [], mismatched: [], conflicts: [], seen: MapSet.new()}

      report =
        Enum.reduce(parsed.lines, empty, fn r, acc ->
          line = Map.get(lines, r.record_no)
          target = if r.success, do: "paid", else: "rejected"

          cond do
            is_nil(line) ->
              %{acc | unmatched: acc.unmatched ++ [r.record_id]}

            not Decimal.equal?(r.amount, line.amount) ->
              %{acc | mismatched: acc.mismatched ++ ["#{line.payment_no}: bank #{r.amount}, file #{line.amount}"]}

            line.status == target ->
              %{acc | seen: MapSet.put(acc.seen, line.record_no)}

            line.status == "pending" ->
              attrs =
                if r.success,
                  do: %{status: "paid"},
                  else: %{status: "rejected", live: false, bank_reason: r.reason}

              line |> BatchLine.resolve_changeset(attrs) |> Repo.update!()
              key = if r.success, do: :paid, else: :rejected
              acc |> Map.update!(key, &(&1 ++ [line.payment_no])) |> Map.update!(:seen, &MapSet.put(&1, line.record_no))

            true ->
              %{acc | conflicts: acc.conflicts ++ ["#{line.payment_no}: bank says #{target}, already #{line.status}"], seen: MapSet.put(acc.seen, line.record_no)}
          end
        end)

      missing =
        for {no, l} <- Enum.sort_by(lines, &elem(&1, 0)), l.status == "pending", not MapSet.member?(report.seen, no), do: l.payment_no

      batch =
        batch
        |> Batch.result_changeset(%{
          result_imported_at: now(),
          result_filename: parsed.filename,
          submitted_at: batch.submitted_at || now(),
          submitted_by_id: batch.submitted_by_id || user.id
        })
        |> Repo.update!()
        |> refresh_batch_status!()

      Repo.insert!(
        Sys.log_changeset(:import_bank_payment_result, batch, %{
          "result_file" => parsed.filename,
          "paid" => "#{length(report.paid)}",
          "rejected" => "#{length(report.rejected)}"
        }, company, user)
      )

      report |> Map.delete(:seen) |> Map.merge(%{batch: batch, missing: missing})
    end)
  end
```

Note: `refresh_batch_status!/1` returns the batch unchanged while any line is still pending, so a partially answered batch stays `submitted`.

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/bank_payment_result_test.exs test/full_circle/bank_payment_test.exs test/full_circle/bank_payment_lifecycle_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment/result.ex lib/full_circle/bank_payment.ex test/full_circle/bank_payment_result_test.exs
git add lib/full_circle/bank_payment/result.ex lib/full_circle/bank_payment.ex test/full_circle/bank_payment_result_test.exs
git commit -m "feat(bank-payment): import PB payment status feedback results line by line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Lock batched Payments

**Files:**
- Modify: `lib/full_circle/bank_payment.ex` (`assert_payment_unlocked/2`), `lib/full_circle/bill_pay.ex` (`update_payment/4`), `lib/full_circle_web/live/payment_live/form.ex`, `lib/full_circle_web/live/payment_live/index_component.ex`
- Test: `test/full_circle/bank_payment_lifecycle_test.exs`

**Interfaces:**
- Produces: `BankPayment.assert_payment_unlocked(payment, changeset) :: :ok | {:error, :bank_batched, filename}`; `BillPay.update_payment/4` may return `{:error, :bank_batched, filename}`.

- [ ] **Step 1: Write the failing test** — append to `FullCircle.BankPaymentLifecycleTest`:

```elixir
  test "locked fields refused while a line is live; other edits pass; release unlocks", ctx do
    {b, [p]} = batch!(ctx)
    assert :ok = BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, descriptions: "x"))
    assert {:error, :bank_batched, name} = BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, funds_amount: Decimal.new("1")))
    assert name == b.filename

    fresh = FullCircle.BillPay.get_payment!(p.id, ctx.company, ctx.admin)
    assert {:error, :bank_batched, ^name} = FullCircle.BillPay.update_payment(fresh, %{"funds_amount" => "1.00"}, ctx.company, ctx.admin)

    {:ok, _} = BankPayment.void_batch(b.id, "redo", ctx.company, ctx.admin)
    assert :ok = BankPayment.assert_payment_unlocked(p, Ecto.Changeset.change(p, funds_amount: Decimal.new("1")))
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/full_circle/bank_payment_lifecycle_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

`bank_payment.ex`, under "Payment lock":

```elixir
  @locked_fields [:funds_amount, :contact_id, :funds_account_id, :payment_date]

  @doc "Refuses changes to a batched Payment's amount, supplier, funds account or date."
  def assert_payment_unlocked(%Payment{id: id}, %Ecto.Changeset{} = cs) do
    case live_batch_filename(id) do
      nil -> :ok
      filename -> if Enum.any?(@locked_fields, &Map.has_key?(cs.changes, &1)), do: {:error, :bank_batched, filename}, else: :ok
    end
  end
```

`bill_pay.ex` `update_payment/4`:

```elixir
    with true <- can?(user, :update_payment, com) || :not_authorise,
         :ok <- Accounting.assert_doc_editable(payment.id, "Payment", com.id, check_matchers: false),
         :ok <- FullCircle.BankPayment.assert_payment_unlocked(payment, make_changeset(Payment, payment, attrs, com, user)) do
```

`payment_live/form.ex`:
- `mount/3` final pipeline: add `|> assign_new(:bank_batch, fn -> nil end)`.
- `mount_edit/2`: add `|> assign(:bank_batch, FullCircle.BankPayment.live_batch_filename(object.id))` before `|> assign(:form, to_form(cs))`.
- In the edit `case BillPay.update_payment(...)`, before the `{:error, failed_operation, changeset, _}` clause:

```elixir
      {:error, :bank_batched, filename} ->
        {:noreply,
         put_flash(socket, :error,
           gettext("In bank batch %{file}: the amount, supplier, funds account and date can't change.", file: filename)
         )}
```

- In `render/1`, after the page title `<p>`:

```heex
        <div :if={@bank_batch} id="bank-batch-banner" class="text-center rounded border border-amber-500 bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100 p-1 mb-1">
          {gettext("In bank batch %{file}: amount, supplier, funds account and date are locked.", file: @bank_batch)}
        </div>
```

`payment_live/index_component.ex`:
- `update/2`: after `|> assign(assigns)` add `|> assign_new(:bank_batch, fn %{obj: obj} -> FullCircle.BankPayment.live_batch_filename(obj.id) end)`.
- After `<.row_notes_badge count={@note_count} tasks={@task_count} id={@obj.id} />`:

```heex
            <span :if={@bank_batch} class="text-xs rounded px-1 bg-amber-200 text-amber-900 dark:bg-amber-800 dark:text-amber-100" title={@bank_batch}>
              {gettext("Bank")}
            </span>
```

- [ ] **Step 4: Run tests**

Run: `mix test test/full_circle/bank_payment_lifecycle_test.exs test/full_circle/bill_pay_test.exs test/full_circle_web/live/payment_receipt_capture_live_test.exs test/full_circle_web/live/stale_save_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format lib/full_circle/bank_payment.ex lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/form.ex lib/full_circle_web/live/payment_live/index_component.ex test/full_circle/bank_payment_lifecycle_test.exs
git add lib/full_circle/bank_payment.ex lib/full_circle/bill_pay.ex lib/full_circle_web/live/payment_live/ test/full_circle/bank_payment_lifecycle_test.exs
git commit -m "feat(bank-payment): lock a batched Payment's amount, supplier, account and date

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Settings pages — profiles and file formats

**Files:**
- Create: `lib/full_circle_web/live/bank_payment_profile_live/index.ex`, `form.ex`; `lib/full_circle_web/live/bank_file_format_live/index.ex`, `form.ex`
- Modify: `lib/full_circle_web/router.ex`, `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`
- Test: `test/full_circle_web/live/bank_setup_live_test.exs`

**Interfaces:**
- Routes (live_session `:require_authenticated_user_n_active_company`, after `live("/statutory_bundle/import", …)`): `/bank_payment_profiles`, `/bank_payment_profiles/new`, `/bank_payment_profiles/:id/edit`, `/bank_file_formats`, `/bank_file_formats/new`.

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
    lv |> form("#format-form", %{"file_format" => %{"template" => "rhb_bulk_pay"}}) |> render_change()
    assert lv |> element("#load-template") |> render_click() =~ "hash_part"

    lv |> form("#format-form") |> render_submit()
    {:ok, _, html} = live(conn, ~p"/companies/#{com.id}/bank_file_formats")
    assert html =~ "rhb_bulk_pay"
  end

  test "create a profile and warn about what it lacks", %{conn: conn, com: com, admin: admin} do
    install_template!(com, admin, "rhb_bulk_pay")
    bank = bank_gl_account_fixture(com, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_payment_profiles/new")

    lv
    |> form("#profile-form", %{"profile" => %{"account_id" => bank.id, "format_code" => "rhb_bulk_pay", "our_account_no" => "21234500012345", "start_date" => "2026-10-01", "params_text" => "corporate_id=123456"}})
    |> render_submit()

    {path, flash} = assert_redirect(lv)
    assert path =~ "/bank_payment_profiles"
    assert flash["warn"] =~ "corporate_name"
  end

  test "a reserved param name is refused", %{conn: conn, com: com, admin: admin} do
    bank = bank_gl_account_fixture(com, admin)
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_payment_profiles/new")

    html =
      lv
      |> form("#profile-form", %{"profile" => %{"account_id" => bank.id, "format_code" => "rhb_bulk_pay", "our_account_no" => "21234500012345", "start_date" => "2026-10-01", "params_text" => "bank_code=PBBEMYKL"}})
      |> render_submit()

    assert html =~ "bank_code is a built-in variable name"
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

- [ ] **Step 3: Routes** — after `live("/statutory_bundle/import", StatutoryBundleLive.Import, :new)`:

```elixir
      live("/bank_payment_profiles", BankPaymentProfileLive.Index, :index)
      live("/bank_payment_profiles/new", BankPaymentProfileLive.Form, :new)
      live("/bank_payment_profiles/:id/edit", BankPaymentProfileLive.Form, :edit)

      live("/bank_file_formats", BankFileFormatLive.Index, :index)
      live("/bank_file_formats/new", BankFileFormatLive.Form, :new)
```

- [ ] **Step 4: Profile pages**

`lib/full_circle_web/live/bank_payment_profile_live/index.ex`:

```elixir
defmodule FullCircleWeb.BankPaymentProfileLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(socket.assigns.current_user, :manage_bank_payment_config, com) do
      {:ok, socket |> assign(page_title: gettext("Bank Payment Profiles")) |> assign(profiles: BankPayment.list_profiles(com))}
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
    <div class="w-8/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <div class="text-center mb-2 flex justify-center gap-2">
        <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles/new"} class="blue button" id="new_profile">{gettext("New Profile")}</.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats"} class="blue button">{gettext("Bank File Formats")}</.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_batches"} class="blue button">{gettext("Bank Batches")}</.link>
      </div>
      <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-2">
        <div class="col-span-4">{gettext("Bank Account")}</div>
        <div class="col-span-3">{gettext("Format")}</div>
        <div class="col-span-3">{gettext("Our Account No")}</div>
        <div class="col-span-2">{gettext("Start Date")}</div>
      </div>
      <div :for={p <- @profiles} id={"profile-#{p.id}"} class="grid grid-cols-12 p-2 border-b">
        <div class="col-span-4">
          <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles/#{p.id}/edit"} class="text-blue-600 dark:text-blue-400 hover:font-bold">{p.account_name}</.link>
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
       |> assign(profile: profile, bank_accounts: BankPayment.bank_accounts(com), format_codes: BankPayment.format_codes(com.id), errors: [])
       |> assign(form: %{
         "account_id" => profile.account_id,
         "format_code" => profile.format_code || "",
         "our_account_no" => profile.our_account_no || "",
         "start_date" => Date.to_iso8601(profile.start_date || BankPayment.today(com)),
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
  def handle_event("validate", %{"profile" => params}, socket), do: {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params))}

  @impl true
  def handle_event("save", %{"profile" => params}, socket) do
    form = Map.merge(socket.assigns.form, params)
    attrs = form |> Map.put("params", Profile.parse_params(form["params_text"])) |> Map.delete("params_text")
    com = socket.assigns.current_company

    case BankPayment.save_profile(socket.assigns.profile, attrs, com, socket.assigns.current_user) do
      {:ok, profile} ->
        socket =
          case BankPayment.profile_warnings(profile, com) do
            [] -> put_flash(socket, :info, gettext("Bank payment profile saved."))
            :no_format -> put_flash(socket, :warn, gettext("Saved. No file format '%{code}' is in force yet.", code: profile.format_code))
            warnings -> put_flash(socket, :warn, gettext("Saved, but: %{w}", w: Enum.join(warnings, "; ")))
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
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} -> Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end) end)
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
            <datalist id="format-codes"><option :for={c <- @format_codes} value={c} /></datalist>
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
        <p :for={msg <- @errors} class="text-rose-600 dark:text-rose-400 text-sm">{msg}</p>
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

- [ ] **Step 5: Format pages**

`lib/full_circle_web/live/bank_file_format_live/index.ex`:

```elixir
defmodule FullCircleWeb.BankFileFormatLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company

    if FullCircle.Authorization.can?(socket.assigns.current_user, :manage_bank_payment_config, com) do
      {:ok, socket |> assign(page_title: gettext("Bank File Formats")) |> assign(formats: BankPayment.list_formats(com.id))}
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
        <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats/new"} class="blue button" id="new_format">{gettext("New Version")}</.link>
        <.link navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"} class="blue button">{gettext("Bank Payment Profiles")}</.link>
      </div>
      <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-2">
        <div class="col-span-4">{gettext("Code")}</div>
        <div class="col-span-5">{gettext("Name")}</div>
        <div class="col-span-3">{gettext("Effective From")}</div>
      </div>
      <div :for={f <- @formats} id={"format-#{f.id}"} class="grid grid-cols-12 p-2 border-b">
        <div class="col-span-4">
          <.link navigate={~p"/companies/#{@current_company.id}/bank_file_formats/new?#{[code: f.code]}"} class="text-blue-600 dark:text-blue-400 hover:font-bold">{f.code}</.link>
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
       |> assign(page_title: gettext("New Bank File Format Version"), templates: BankPayment.templates(), profiles: profiles)
       |> assign(form: %{
         "code" => code,
         "name" => name,
         "effective_from" => Date.to_iso8601(BankPayment.today(com)),
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
    {:noreply, socket |> assign(form: Map.merge(socket.assigns.form, params), confirm_replace: false) |> assign_spec_errors(params["spec"])}
  end

  @impl true
  def handle_event("load_template", _params, socket) do
    case BankPayment.load_template(socket.assigns.form["template"] || "") do
      {:ok, t} ->
        form = Map.merge(socket.assigns.form, %{"code" => t["code"], "name" => t["name"], "spec" => Jason.encode!(t["spec"], pretty: true)})
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
      {:noreply, assign(socket, preview_lines: text |> String.split(~r/\r?\n/, trim: true) |> Enum.take(20), preview_error: nil)}
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
      {:error, _} -> {:noreply, assign(socket, confirm_replace: false, save_errors: [gettext("fix spec errors before saving")])}
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
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} -> Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end) end)
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
            <button type="button" id="load-template" phx-click="load_template" class="blue button">{gettext("Load template")}</button>
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
        <p :for={msg <- @spec_errors} class="text-rose-600 dark:text-rose-400 text-sm">{msg}</p>
        <p :for={msg <- @save_errors} class="text-rose-600 dark:text-rose-400 text-sm">{msg}</p>

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
          <p :if={@preview_error} class="text-rose-600 dark:text-rose-400 mt-2">{@preview_error}</p>
          <pre :if={@preview_lines} class="mt-2 font-mono text-xs overflow-x-auto bg-gray-100 dark:bg-gray-900 p-2 rounded">{Enum.join(@preview_lines, "\n")}</pre>
        </div>

        <div :if={@confirm_replace} class="mt-4 border rounded border-amber-500 bg-amber-100 dark:bg-amber-900/40 p-3 text-center">
          <p class="font-semibold">{gettext("A version of '%{code}' effective %{date} already exists.", code: @form["code"], date: @form["effective_from"])}</p>
          <p class="text-sm mb-2">{gettext("Existing batches keep the layout they were made with.")}</p>
          <button type="button" phx-click="replace" class="red button" id="replace-version">{gettext("Replace this version")}</button>
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

- [ ] **Step 6: Dashboard** — after the `Statutory Calcs` link:

```heex
        <.link :if={@current_role == "admin"} navigate={~p"/companies/#{@current_company.id}/bank_payment_profiles"} class="button orange">
          {gettext("Bank Payment Setup")}
        </.link>
```

- [ ] **Step 7: Run tests**

Run: `mix test test/full_circle_web/live/bank_setup_live_test.exs`
Expected: PASS. (The profile index links to `/bank_batches`, added in Task 16; verified routes warn until then — that is expected for one task.)

- [ ] **Step 8: Commit**

```bash
mix format lib/full_circle_web/live/bank_payment_profile_live/*.ex lib/full_circle_web/live/bank_file_format_live/*.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/bank_setup_live_test.exs
git add lib/full_circle_web/live/bank_payment_profile_live/ lib/full_circle_web/live/bank_file_format_live/ lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/bank_setup_live_test.exs
git commit -m "feat(bank-payment): admin pages for paying-account profiles and file formats

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Bank Batches screen, download controller, JS download

**Files:**
- Create: `lib/full_circle_web/live/bank_batch_live/index.ex`, `lib/full_circle_web/controllers/bank_batch_controller.ex`
- Modify: `lib/full_circle_web/router.ex`, `assets/js/app.js`, `lib/full_circle_web/live/dashboard_live/dashboard_live.ex`
- Test: `test/full_circle_web/live/bank_batch_live_test.exs`

**Interfaces:**
- Routes: `get "/bank_batches/download", BankBatchController, :download` (beside `get "/csv", …`; params `ids` comma-separated, optional `reason`); `live("/bank_batches", BankBatchLive.Index, :index)`.
- Push event `"download"` with `%{url: url}`.
- DOM ids: `#batch-params`, `#tick-<payment_id>`, `#dismiss-<payment_id>`, `#create-file`, `#create-anyway`, `#action-form` (field `reason`), `#show-dismissed`, `#undismiss-<payment_id>`, `#open-<batch_id>`, `#submit-<batch_id>`, `#void-<batch_id>`, `#download-<batch_id>`, `#download-again-<batch_id>`, `#release-<line_id>`, `#return-<line_id>`, `#result-upload-form`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule FullCircleWeb.BankBatchLiveTest do
  use FullCircleWeb.ConnCase

  import Phoenix.LiveViewTest
  import FullCircle.SysFixtures
  import FullCircle.UserAccountsFixtures
  import FullCircle.BillingFixtures
  import FullCircle.BankPaymentFixtures

  alias FullCircle.BankPayment

  setup do
    admin = user_fixture()
    com = company_fixture(admin, %{})
    install_template!(com, admin, "pbb_ecp_payment")
    bank = bank_gl_account_fixture(com, admin)
    profile = profile_fixture(com, admin, bank, %{"format_code" => "pbb_ecp_payment", "our_account_no" => "3999999999", "params" => %{}})
    supplier = bank_contact_fixture(com, admin, %{"bank_code" => "PBBEMYKL", "bank_account_no" => "3123456789"})
    p = bank_payment_fixture(com, admin, supplier, bank, "321.00")
    mgr = user_fixture()
    FullCircle.Sys.allow_user_to_access(com, mgr, "manager", admin)
    %{admin: admin, com: com, bank: bank, profile: profile, supplier: supplier, p: p, mgr_conn: log_in_user(build_conn(), mgr)}
  end

  test "tick, create, download, submit, import result", %{com: com, p: p, mgr_conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    assert html =~ p.payment_no

    lv |> element("#tick-#{p.id}") |> render_click()
    assert render(lv) =~ "1 ticked, total 321.00"

    lv |> element("#create-file") |> render_click()
    assert_push_event(lv, "download", %{url: url})
    refute render(lv) =~ "tick-#{p.id}"

    resp = get(conn, url)
    assert resp.status == 200
    assert [cd] = get_resp_header(resp, "content-disposition")
    assert cd =~ "3999999999PM"

    [batch] = BankPayment.list_batches(com)
    lv |> element("#submit-#{batch.id}") |> render_click()
    assert render(lv) =~ "submitted"
    refute has_element?(lv, "#void-#{batch.id}")

    [line] = BankPayment.batch_lines(batch.id, com)
    text = psf_text(Path.rootname(batch.filename), [{String.pad_leading("#{line.record_no}", 12, "0"), 32_100, "01", ""}])
    assert lv |> element("#result-upload-form") |> render() =~ "phx-change"
    upload = file_input(lv, "#result-upload-form", :result, [%{name: "PSF#{batch.filename}", content: text, type: "text/plain"}])
    html = render_upload(upload, "PSF#{batch.filename}")
    assert html =~ "1 paid"
    assert html =~ "completed"
  end

  test "download again needs a reason", %{com: com, p: p, profile: profile, admin: admin, mgr_conn: conn} do
    {:ok, [b]} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(com), com, admin)
    assert get(conn, ~p"/companies/#{com.id}/bank_batches/download?#{[ids: b.id]}").status == 200
    assert get(conn, ~p"/companies/#{com.id}/bank_batches/download?#{[ids: b.id]}").status == 422

    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    lv |> element("#download-again-#{b.id}") |> render_click()
    lv |> form("#action-form", %{"reason" => "lost the file"}) |> render_submit()
    assert_push_event(lv, "download", %{url: url})
    assert url =~ "reason=lost"
  end

  test "duplicate warning then Create anyway", %{com: com, supplier: supplier, bank: bank, p: p, profile: profile, admin: admin, mgr_conn: conn} do
    {:ok, _} = BankPayment.create_batches(profile.id, [p.id], BankPayment.today(com), com, admin)
    p2 = bank_payment_fixture(com, admin, supplier, bank, "321.00")
    {:ok, lv, _} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    lv |> element("#tick-#{p2.id}") |> render_click()
    assert lv |> element("#create-file") |> render_click() =~ p.payment_no
    lv |> element("#create-anyway") |> render_click()
    assert_push_event(lv, "download", %{url: _})
  end

  test "paid outside file and undo; greyed row without bank details", %{com: com, admin: admin, bank: bank, p: p, mgr_conn: conn} do
    nob = bank_payment_fixture(com, admin, contact_fixture(com, admin), bank)
    {:ok, lv, html} = live(conn, ~p"/companies/#{com.id}/bank_batches")
    assert html =~ "no bank details"
    refute has_element?(lv, "#tick-#{nob.id}")

    lv |> element("#dismiss-#{p.id}") |> render_click()
    lv |> form("#action-form", %{"reason" => "cheque 1234"}) |> render_submit()
    refute has_element?(lv, "#tick-#{p.id}")

    lv |> element("#show-dismissed") |> render_click()
    lv |> element("#undismiss-#{p.id}") |> render_click()
    assert has_element?(lv, "#tick-#{p.id}")
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
Expected: FAIL — no route.

- [ ] **Step 3: Router, controller, JS**

Router beside `get "/csv", CsvController, :show`:

```elixir
    get "/bank_batches/download", BankBatchController, :download
```

and in the live_session after the bank format routes:

```elixir
      live("/bank_batches", BankBatchLive.Index, :index)
```

`lib/full_circle_web/controllers/bank_batch_controller.ex`:

```elixir
defmodule FullCircleWeb.BankBatchController do
  use FullCircleWeb, :controller

  alias FullCircle.BankPayment

  def download(conn, %{"company_id" => com_id, "ids" => ids} = params) do
    company = FullCircle.Sys.get_company!(com_id)
    ids = String.split(ids, ",", trim: true)

    case BankPayment.download_files(ids, params["reason"], company, conn.assigns.current_user) do
      {:ok, [{name, text}]} ->
        send_download(conn, {:binary, text}, filename: name, content_type: MIME.from_path(name))

      {:ok, files} ->
        {:ok, zip} = BankPayment.zip(files)
        send_download(conn, {:binary, zip}, filename: "bank_batches.zip", content_type: "application/zip")

      :not_authorise ->
        conn |> put_status(403) |> text("not authorised")

      {:error, msg} ->
        conn |> put_status(422) |> text(msg)
    end
  end
end
```

`assets/js/app.js`, after the `phx:history_back` listener:

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

- [ ] **Step 4: The LiveView** — `lib/full_circle_web/live/bank_batch_live/index.ex`:

```elixir
defmodule FullCircleWeb.BankBatchLive.Index do
  use FullCircleWeb, :live_view

  alias FullCircle.BankPayment

  @impl true
  def mount(_params, _session, socket) do
    com = socket.assigns.current_company
    user = socket.assigns.current_user

    if FullCircle.Authorization.can?(user, :create_bank_payment_batch, com) do
      profiles = BankPayment.list_profiles(com)
      today = BankPayment.today(com)

      {:ok,
       socket
       |> assign(page_title: gettext("Bank Batches"), today: today)
       |> assign(is_admin: FullCircle.Authorization.can?(user, :admin_bank_payment_batch, com))
       |> assign(profiles: profiles, profile: List.first(profiles), payment_date: today)
       |> assign(selected: MapSet.new(), errors: [], duplicates: [], action: nil, open_id: nil, open_lines: [])
       |> assign(import_report: nil, show_dismissed: false)
       |> allow_upload(:result, accept: ~w(.txt .csv), max_entries: 1, max_file_size: 5_000_000, auto_upload: true, progress: &handle_result_progress/3)
       |> load_rows()
       |> load_batches()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You are not authorised to perform this action"))
       |> push_navigate(to: ~p"/companies/#{com.id}/dashboard")}
    end
  end

  defp load_rows(%{assigns: %{profile: nil}} = socket), do: assign(socket, rows: [], dismissed: [])

  defp load_rows(socket) do
    com = socket.assigns.current_company
    assign(socket, rows: BankPayment.eligible_payments(socket.assigns.profile, com), dismissed: BankPayment.list_dismissed(com))
  end

  defp load_batches(socket) do
    batches = BankPayment.list_batches(socket.assigns.current_company)

    socket
    |> assign(batches: batches, downloads: BankPayment.downloads_by_batch(Enum.map(batches, & &1.id)))
    |> refresh_open()
  end

  defp refresh_open(%{assigns: %{open_id: nil}} = socket), do: assign(socket, open_lines: [])
  defp refresh_open(socket), do: assign(socket, open_lines: BankPayment.batch_lines(socket.assigns.open_id, socket.assigns.current_company))

  defp download_url(com, ids, reason \\ nil) do
    params = [ids: Enum.join(ids, ",")] ++ if(reason, do: [reason: reason], else: [])
    ~p"/companies/#{com.id}/bank_batches/download?#{params}"
  end

  # ── Selection and creation ──

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("params", params, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.id == params["profile_id"])) || socket.assigns.profile

    date =
      case Date.from_iso8601(params["payment_date"] || "") do
        {:ok, d} -> d
        _ -> socket.assigns.payment_date
      end

    socket = assign(socket, payment_date: date, errors: [], duplicates: [])

    if profile && socket.assigns.profile && profile.id == socket.assigns.profile.id,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(profile: profile, selected: MapSet.new()) |> load_rows()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.rows, &(&1.id == id and &1.has_bank)) do
      sel = socket.assigns.selected
      sel = if MapSet.member?(sel, id), do: MapSet.delete(sel, id), else: MapSet.put(sel, id)
      {:noreply, assign(socket, selected: sel, duplicates: [])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create", _params, socket), do: create(socket, [])
  def handle_event("create_anyway", _params, socket), do: create(socket, force: true)
  def handle_event("cancel_duplicates", _params, socket), do: {:noreply, assign(socket, duplicates: [])}

  # ── Batch actions ──

  def handle_event("open", %{"id" => id}, socket) do
    open_id = if socket.assigns.open_id == id, do: nil, else: id
    {:noreply, socket |> assign(open_id: open_id) |> refresh_open()}
  end

  def handle_event("submit", %{"id" => id}, socket) do
    result(socket, BankPayment.mark_submitted(id, socket.assigns.current_company, socket.assigns.current_user), gettext("Marked submitted to bank."))
  end

  def handle_event("start", %{"kind" => kind, "id" => id}, socket) do
    {:noreply, assign(socket, action: {kind, id}, errors: [])}
  end

  def handle_event("show_dismissed", _params, socket), do: {:noreply, update(socket, :show_dismissed, &(!&1))}

  def handle_event("undismiss", %{"id" => id}, socket) do
    result(socket, BankPayment.undismiss_payment(id, socket.assigns.current_company, socket.assigns.current_user), gettext("Back on the list."))
  end

  def handle_event("cancel_action", _params, socket), do: {:noreply, assign(socket, action: nil)}

  def handle_event("do_action", %{"reason" => reason}, socket) do
    %{current_company: com, current_user: user} = socket.assigns

    case socket.assigns.action do
      {"void", id} ->
        result(assign(socket, action: nil), BankPayment.void_batch(id, reason, com, user), gettext("Batch voided."))

      {"release", id} ->
        result(assign(socket, action: nil), BankPayment.release_line(id, reason, com, user), gettext("Line released."))

      {"return", id} ->
        result(assign(socket, action: nil), BankPayment.return_line(id, reason, com, user), gettext("Line marked returned."))

      {"dismiss", id} ->
        result(assign(socket, action: nil), BankPayment.dismiss_payment(id, reason, com, user), gettext("Marked paid outside file."))

      {"download", id} ->
        if String.trim(reason) == "",
          do: {:noreply, assign(socket, errors: [gettext("a reason is required")])},
          else: {:noreply, socket |> assign(action: nil) |> push_event("download", %{url: download_url(com, [id], reason)}) |> load_batches()}

      _ ->
        {:noreply, assign(socket, action: nil)}
    end
  end

  defp create(socket, opts) do
    %{profile: profile, selected: selected, payment_date: date, current_company: com, current_user: user} = socket.assigns

    case BankPayment.create_batches(profile && profile.id, MapSet.to_list(selected), date, com, user, opts) do
      {:ok, batches} ->
        {:noreply,
         socket
         |> assign(selected: MapSet.new(), errors: [], duplicates: [])
         |> load_rows()
         |> load_batches()
         |> put_flash(:info, gettext("Bank file created: %{files}", files: Enum.map_join(batches, ", ", & &1.filename)))
         |> push_event("download", %{url: download_url(com, Enum.map(batches, & &1.id))})}

      {:duplicates, msgs} ->
        {:noreply, assign(socket, duplicates: msgs, errors: [])}

      {:error, msgs} when is_list(msgs) ->
        {:noreply, assign(socket, errors: msgs, duplicates: [])}

      {:error, msg} ->
        {:noreply, socket |> assign(errors: [msg], duplicates: []) |> load_rows()}

      :not_authorise ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp result(socket, outcome, ok_msg) do
    case outcome do
      {:ok, _} -> {:noreply, socket |> assign(errors: []) |> load_rows() |> load_batches() |> put_flash(:info, ok_msg)}
      {:error, msg} when is_binary(msg) -> {:noreply, assign(socket, errors: [msg])}
      {:error, %Ecto.Changeset{} = cs} -> {:noreply, assign(socket, errors: Enum.map(cs.errors, fn {f, {m, _}} -> "#{f} #{m}" end))}
      :not_authorise -> {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  # ── Result upload ──

  defp handle_result_progress(:result, entry, socket) do
    if entry.done? do
      [text] = consume_uploaded_entries(socket, :result, fn %{path: path}, _entry -> {:ok, File.read!(path)} end)

      case BankPayment.import_result(text, socket.assigns.current_company, socket.assigns.current_user) do
        {:ok, report} -> {:noreply, socket |> assign(import_report: report, errors: []) |> load_rows() |> load_batches()}
        {:error, msg} -> {:noreply, assign(socket, import_report: nil, errors: [msg])}
        :not_authorise -> {:noreply, put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── View helpers ──

  defp money(d), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp total(rows, selected),
    do: rows |> Enum.filter(&MapSet.member?(selected, &1.id)) |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))

  defp stale_date?(b, today),
    do: b.status == "exported" and String.contains?(b.spec["filename"] || "", "{today") and b.header["today"] != Date.to_iso8601(today)

  defp action_prompt({"void", _}), do: gettext("Void only if the bank rejected this file or it was never uploaded/approved. Voiding lets these payments go into a new file. Reason:")
  defp action_prompt({"download", _}), do: gettext("This file may already be at the bank. Why download it again?")
  defp action_prompt({"release", _}), do: gettext("Why did the bank reject this payment?")
  defp action_prompt({"return", _}), do: gettext("Why was this paid payment returned?")
  defp action_prompt({"dismiss", _}), do: gettext("How was it paid? (cheque no, transfer ref)")
  defp action_prompt(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>

      <p :if={@profiles == []} class="text-center">{gettext("No bank payment profile yet. An admin sets one up under Bank Payment Setup.")}</p>

      <form :if={@profiles != []} id="batch-params" phx-change="params" class="flex justify-center gap-2 mb-2">
        <select name="profile_id" class="border rounded px-2 py-1 dark:bg-gray-800">
          <option :for={p <- @profiles} value={p.id} selected={@profile && p.id == @profile.id}>{p.account_name} ({p.format_code})</option>
        </select>
        <input type="date" name="payment_date" value={Date.to_iso8601(@payment_date)} class="border rounded px-2 py-1 dark:bg-gray-800" />
      </form>

      <div :if={@errors != []} id="batch-errors" class="border rounded border-rose-500 bg-rose-50 dark:bg-rose-900/30 p-2 mb-2">
        <p :for={e <- @errors} class="text-rose-700 dark:text-rose-300 text-sm">{e}</p>
      </div>

      <div :if={@action} class="border rounded border-amber-500 bg-amber-50 dark:bg-amber-900/30 p-2 mb-2">
        <form id="action-form" phx-submit="do_action" class="flex flex-wrap gap-2 items-center justify-center">
          <span class="text-sm">{action_prompt(@action)}</span>
          <input type="text" name="reason" class="border rounded px-2 py-1 dark:bg-gray-800 w-96" />
          <button type="submit" class="red button">{gettext("Confirm")}</button>
          <button type="button" phx-click="cancel_action" class="blue button">{gettext("Cancel")}</button>
        </form>
      </div>

      <div :if={@duplicates != []} id="duplicates" class="border rounded border-amber-500 bg-amber-50 dark:bg-amber-900/30 p-2 mb-2">
        <p class="font-semibold">{gettext("These may already be paid:")}</p>
        <p :for={d <- @duplicates} class="text-sm">{d}</p>
        <div class="flex gap-2 justify-center mt-1">
          <button id="create-anyway" phx-click="create_anyway" class="red button">{gettext("Create anyway")}</button>
          <button phx-click="cancel_duplicates" class="blue button">{gettext("Cancel")}</button>
        </div>
      </div>

      <div :if={@profile} class="mb-4">
        <div class="grid grid-cols-12 bg-amber-200 dark:bg-amber-800 border-y-2 border-amber-500 font-bold p-1">
          <div class="col-span-1"></div>
          <div class="col-span-1">{gettext("Date")}</div>
          <div class="col-span-2">{gettext("Payment No")}</div>
          <div class="col-span-3">{gettext("Supplier")}</div>
          <div class="col-span-2">{gettext("Bank / Account")}</div>
          <div class="col-span-1 text-right">{gettext("Amount")}</div>
          <div class="col-span-2"></div>
        </div>
        <div :for={r <- @rows} id={"row-#{r.id}"} class={["grid grid-cols-12 p-1 border-b items-center", !r.has_bank && "opacity-50"]}>
          <div class="col-span-1 flex gap-1 items-center">
            <input :if={r.has_bank} type="checkbox" id={"tick-#{r.id}"} phx-click="toggle" phx-value-id={r.id} checked={MapSet.member?(@selected, r.id)} />
            <span :if={r.recent_change} class="text-xs rounded px-1 bg-amber-300 text-amber-900 dark:bg-amber-700 dark:text-amber-100" title={gettext("Bank details changed %{at}", at: to_string(r.changed_at))}>⚠</span>
          </div>
          <div class="col-span-1">{FullCircleWeb.Helpers.format_date(r.payment_date)}</div>
          <div class="col-span-2">{r.payment_no}</div>
          <div class="col-span-3 truncate">
            {r.contact_name}
            <span :if={r.last_reason} class="block text-xs text-rose-700 dark:text-rose-300">{gettext("last rejected: %{r}", r: r.last_reason)}</span>
          </div>
          <div class="col-span-2 truncate">{if r.has_bank, do: "#{r.bank_name} #{r.account_no}", else: gettext("no bank details")}</div>
          <div class="col-span-1 text-right tabular-nums">{money(r.amount)}</div>
          <div class="col-span-2 text-right">
            <button id={"dismiss-#{r.id}"} phx-click="start" phx-value-kind="dismiss" phx-value-id={r.id} class="text-xs underline">{gettext("Paid outside file")}</button>
          </div>
        </div>
        <div class="flex justify-center items-center gap-4 mt-2">
          <span>{gettext("%{n} ticked, total %{total}", n: MapSet.size(@selected), total: money(total(@rows, @selected)))}</span>
          <button id="create-file" phx-click="create" class="blue button" disabled={MapSet.size(@selected) == 0}>{gettext("Create file")}</button>
          <button id="show-dismissed" phx-click="show_dismissed" class="text-sm underline">{gettext("Paid outside file (%{n})", n: length(@dismissed))}</button>
        </div>
        <div :if={@show_dismissed} class="mt-2 border rounded p-2">
          <div :for={d <- @dismissed} class="grid grid-cols-12 text-sm border-b p-1">
            <div class="col-span-2">{d.payment_no}</div>
            <div class="col-span-4 truncate">{d.contact_name}</div>
            <div class="col-span-2 text-right tabular-nums">{money(d.amount)}</div>
            <div class="col-span-3 truncate">{d.note}</div>
            <div class="col-span-1 text-right"><button id={"undismiss-#{d.payment_id}"} phx-click="undismiss" phx-value-id={d.payment_id} class="underline">{gettext("Undo")}</button></div>
          </div>
        </div>
      </div>

      <div class="flex justify-between items-center font-bold bg-gray-200 dark:bg-gray-700 p-1">
        <span>{gettext("Batch history")}</span>
        <form id="result-upload-form" phx-change="noop" class="text-sm font-normal flex items-center gap-2">
          <span>{gettext("Import bank result:")}</span>
          <.live_file_input upload={@uploads.result} />
        </form>
      </div>

      <div :if={@import_report} id="import-report" class="border rounded border-emerald-500 bg-emerald-50 dark:bg-emerald-900/30 p-2 text-sm">
        <p>{gettext("%{file}: %{p} paid, %{r} rejected; batch %{s}", file: @import_report.batch.filename, p: length(@import_report.paid), r: length(@import_report.rejected), s: @import_report.batch.status)}</p>
        <p :for={m <- @import_report.mismatched} class="text-rose-700 dark:text-rose-300">{gettext("amount mismatch: %{m}", m: m)}</p>
        <p :for={m <- @import_report.conflicts} class="text-rose-700 dark:text-rose-300">{gettext("conflict: %{m}", m: m)}</p>
        <p :for={m <- @import_report.unmatched} class="text-rose-700 dark:text-rose-300">{gettext("unknown record: %{m}", m: m)}</p>
        <p :if={@import_report.missing != []}>{gettext("not in the result yet: %{m}", m: Enum.join(@import_report.missing, ", "))}</p>
      </div>

      <div :for={b <- @batches} id={"batch-#{b.id}"} class="border-b p-1">
        <div class="grid grid-cols-12 items-center text-sm">
          <div class="col-span-1">{FullCircleWeb.Helpers.format_date(DateTime.to_date(b.inserted_at))}</div>
          <div class="col-span-3">
            <button id={"open-#{b.id}"} phx-click="open" phx-value-id={b.id} class="text-blue-600 dark:text-blue-400 underline">{b.filename}</button>
            <span :if={stale_date?(b, @today)} class="block text-xs text-amber-700 dark:text-amber-300">
              {gettext("created on %{d}; RHB expects today's date — void and create a new file if RHB refuses it", d: b.header["today"])}
            </span>
          </div>
          <div class="col-span-1">{FullCircleWeb.Helpers.format_date(b.payment_date)}</div>
          <div class="col-span-1 text-right">{b.count}</div>
          <div class="col-span-1 text-right tabular-nums">{money(b.total)}</div>
          <div class="col-span-1">{b.status}</div>
          <div class="col-span-2 text-xs">
            {b.created_by && b.created_by.email}
            <span :if={dl = List.first(@downloads[b.id] || [])} class="block">
              {gettext("first download %{at}, %{n}×", at: Calendar.strftime(dl.inserted_at, "%d/%m %H:%M"), n: length(@downloads[b.id]))}
            </span>
          </div>
          <div class="col-span-2 flex flex-wrap gap-1 justify-end">
            <a :if={b.status != "voided" and (@downloads[b.id] || []) == []} id={"download-#{b.id}"} href={download_url(@current_company, [b.id])} class="blue button">{gettext("Download")}</a>
            <button :if={b.status != "voided" and (@downloads[b.id] || []) != [] and (b.status == "exported" or @is_admin)} id={"download-again-#{b.id}"} phx-click="start" phx-value-kind="download" phx-value-id={b.id} class="blue button">{gettext("Download again")}</button>
            <button :if={b.status == "exported"} id={"submit-#{b.id}"} phx-click="submit" phx-value-id={b.id} class="blue button">{gettext("Mark submitted")}</button>
            <button :if={b.status == "exported" or (b.status == "submitted" and @is_admin)} id={"void-#{b.id}"} phx-click="start" phx-value-kind="void" phx-value-id={b.id} class="red button">{gettext("Void")}</button>
          </div>
        </div>
        <div :if={@open_id == b.id} class="ml-8 mt-1 text-sm">
          <div :for={l <- @open_lines} class="grid grid-cols-12 border-b p-1">
            <div class="col-span-2">{l.payment_no}</div>
            <div class="col-span-3 truncate">{l.contact_name}</div>
            <div class="col-span-2 text-right tabular-nums">{money(l.amount)}</div>
            <div class="col-span-1">{l.status}</div>
            <div class="col-span-3 truncate">{l.bank_reason}</div>
            <div class="col-span-1 text-right">
              <button :if={l.status == "pending" and b.status in ["submitted", "partly_rejected"]} id={"release-#{l.id}"} phx-click="start" phx-value-kind="release" phx-value-id={l.id} class="underline">{gettext("Rejected")}</button>
              <button :if={l.status == "paid" and @is_admin} id={"return-#{l.id}"} phx-click="start" phx-value-kind="return" phx-value-id={l.id} class="underline">{gettext("Returned")}</button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
```

Dashboard — after the Payments link:

```heex
        <.link :if={@current_role in ["admin", "manager"]} navigate={~p"/companies/#{@current_company.id}/bank_batches"} class="button blue">
          {gettext("Bank Batches")}
        </.link>
```

- [ ] **Step 5: Run tests**

Run: `mix test test/full_circle_web/live/bank_batch_live_test.exs test/full_circle_web/live/bank_setup_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Build assets and run the whole suite**

Run: `mix assets.build && mix test`
Expected: all green (2412 existing + new). Fix any failure before committing.

- [ ] **Step 7: Manual browser check** — run `mix phx.server`, open Bank Batches as a manager, choose a result file and confirm the network tab shows upload traffic (the upload skill's checklist), and that Create file triggers a download.

- [ ] **Step 8: Commit**

```bash
mix format lib/full_circle_web/live/bank_batch_live/index.ex lib/full_circle_web/controllers/bank_batch_controller.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex test/full_circle_web/live/bank_batch_live_test.exs
git add lib/full_circle_web/live/bank_batch_live/ lib/full_circle_web/controllers/bank_batch_controller.ex lib/full_circle_web/router.ex lib/full_circle_web/live/dashboard_live/dashboard_live.ex assets/js/app.js test/full_circle_web/live/bank_batch_live_test.exs
git commit -m "feat(bank-payment): bank batches screen — create, download, submit, void, release, import result

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: Skill doc and CLAUDE.md (user confirms)

**Files:**
- Create: `.claude/skills/bank-bulk-payment.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Draft the skill** — frontmatter `name: bank-bulk-payment`, description: *"Use when changing bank payment files (RHB Reflex Bulk Pay, PB enterprise ECP), bank file format or result specs, supplier bank details, bank batches and their lifecycle, paid-outside-file dismissals, or the FileSpec features computed/children/quote/allow/filename/max_rows."* Body sections:
  1. **Contracts:** the implementation notes at the top of this plan; both hash formulas; `doc_date` vs `payment_date`; reserved variable names; `params` / `our_account_no_digits` / `result` keys; RHB allowed characters and `&` → `AND`; `max_rows: 300` keeps the RHB hash exact.
  2. **Money rules:** one live line per Payment (partial unique index); voided batches never download; batches keep their spec copy; lock_version bump + re-read inside the batch transaction; locked Payment fields; seq counts voided batches; record ids from `bank_payment_record_seq`.
  3. **Lifecycle table** and who may do each step (copy from the spec).
  4. **Result import:** PSF positions, filename matched without extension, idempotent re-import, conflicts reported.
  5. **Verify on first upload:** PB footer in cents; PB account number left-aligned/space-padded; `PIBEMYK1` as `PBB`; PB beneficiary ID checking off; obtain an RHB return file sample to add a `"layout": "csv"` result spec.
  6. **Gotchas:** CASCADE FKs exist only for company deletion — never add a delete path for formats/profiles/payments without revisiting batch history; dates are company-local (`BankPayment.today/1`).

- [ ] **Step 2: Ask the user to confirm** the skill text before committing.

- [ ] **Step 3: Update `CLAUDE.md`** — Domain Contexts row `| BankPayment | Bank bulk payment files (RHB Bulk Pay, PB ECP): profiles, versioned formats, batch lifecycle, result import |`, and add `bank-bulk-payment.md` to the project skills list.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/bank-bulk-payment.md CLAUDE.md
git commit -m "docs: bank bulk payment skill and CLAUDE.md entries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
