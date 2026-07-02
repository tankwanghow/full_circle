# PayScript Engine Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the PayScript language engine — lexer, parser, evaluator, validation, and dependency/cycle analysis — as a pure, heavily unit-tested library with data-access builtins behind a behaviour, per section 2 of `docs/superpowers/specs/2026-07-02-statutory-zero-redeploy-design.md`.

**Architecture:** Hand-rolled lexer (binary pattern matching) → recursive-descent parser producing a plain-tuple AST → tree-walking evaluator over a context map. Builtins needing data (`lookup`, `ytd_sum`, `calc`) delegate to a `FullCircle.PayScript.Env` behaviour so tests use a map-backed stub; the real DB-backed env is Phase 2. No `Code.eval_*`, no `String.to_atom` on script text anywhere.

**Tech Stack:** Pure Elixir (no new deps). `Decimal` (already a dep via Ecto) for the final result. ExUnit with `async: true` (no DB).

## Global Constraints

- Elixir 1.19.5 / OTP 28; no new hex dependencies.
- Arithmetic is **float** internally (parity with `salary_note_cal_func.ex`); only the final script result is converted to `Decimal`.
- Scripts are a sequence of `name = expression` lines; the **last binding must be `result`**; no rebinding; `#` comments; newlines inside `(...)`/`[...]` are continuations.
- Operator precedence (low→high): `or`, `and`, `not`, comparisons (`== != > >= < <=`, non-chaining), `+ -`, `* /`, unary `-`, parentheses.
- All errors are returned as `{:error, %FullCircle.PayScript.Error{}}` tuples — the engine never raises on bad input and **never silently returns 0**.
- Every new module gets unit tests in the same task; run only the new test file(s) in test steps (`mix test <path>`), and note the 2 pre-existing `pay_run_test` failures are unrelated if a full `mix test` is ever run.

## File Structure

| File | Responsibility |
|---|---|
| `lib/full_circle/pay_script/error.ex` | Error struct (line, binding, message) |
| `lib/full_circle/pay_script/lexer.ex` | Source → token list |
| `lib/full_circle/pay_script/parser.ex` | Tokens → script AST (bindings list) |
| `lib/full_circle/pay_script/evaluator.ex` | AST + context + env → value |
| `lib/full_circle/pay_script/env.ex` | Behaviour for `lookup` / `ytd_sum` / `calc` |
| `lib/full_circle/pay_script/validator.ex` | Save-time AST validation + `calc()` dependency extraction |
| `lib/full_circle/pay_script.ex` | Public API: `parse`, `eval`, `validate`, `calc_deps`, `check_cycles`, `standard_variables` |
| `test/support/pay_script_stub_env.ex` | Map-backed stub env for tests |

---

### Task 1: Error struct and Lexer

**Files:**
- Create: `lib/full_circle/pay_script/error.ex`
- Create: `lib/full_circle/pay_script/lexer.ex`
- Test: `test/full_circle/pay_script/lexer_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `FullCircle.PayScript.Error` struct with fields `:line`, `:binding`, `:message` (all defaulting to nil) and `message/1` via `defexception`. `FullCircle.PayScript.Lexer.tokenize(source :: String.t()) :: {:ok, [token]} | {:error, Error.t()}`. Tokens are `{:num, float, line}`, `{:str, String.t(), line}`, `{:ident, String.t(), line}`, `{:bool, boolean, line}`, and 2-tuples `{type, line}` for `:assign :plus :minus :star :slash :eq :neq :gt :gte :lt :lte :lparen :rparen :lbracket :rbracket :comma :colon :and_op :or_op :not_op :newline :eof`. Numbers are always floats. Newline tokens are **suppressed** while paren/bracket depth > 0. The token list always ends with `{:eof, line}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/full_circle/pay_script/lexer_test.exs
defmodule FullCircle.PayScript.LexerTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript.{Error, Lexer}

  test "tokenizes numbers as floats" do
    assert {:ok, [{:num, 42.0, 1}, {:num, 0.11, 1}, {:eof, 1}]} = Lexer.tokenize("42 0.11")
  end

  test "tokenizes strings" do
    assert {:ok, [{:str, "Single", 1}, {:eof, 1}]} = Lexer.tokenize(~s("Single"))
  end

  test "tokenizes identifiers, keywords and booleans" do
    assert {:ok,
            [
              {:ident, "wages", 1},
              {:and_op, 1},
              {:ident, "epf_2", 1},
              {:or_op, 1},
              {:not_op, 1},
              {:bool, true, 1},
              {:bool, false, 1},
              {:eof, 1}
            ]} = Lexer.tokenize("wages and epf_2 or not true false")
  end

  test "tokenizes operators and punctuation" do
    assert {:ok,
            [
              {:assign, 1},
              {:plus, 1},
              {:minus, 1},
              {:star, 1},
              {:slash, 1},
              {:eq, 1},
              {:neq, 1},
              {:gte, 1},
              {:lte, 1},
              {:gt, 1},
              {:lt, 1},
              {:comma, 1},
              {:colon, 1},
              {:eof, 1}
            ]} = Lexer.tokenize("= + - * / == != >= <= > < , :")
  end

  test "emits newline tokens at depth zero and tracks line numbers" do
    assert {:ok,
            [
              {:ident, "a", 1},
              {:assign, 1},
              {:num, 1.0, 1},
              {:newline, 1},
              {:ident, "b", 2},
              {:assign, 2},
              {:num, 2.0, 2},
              {:newline, 2},
              {:eof, 3}
            ]} = Lexer.tokenize("a = 1\nb = 2\n")
  end

  test "suppresses newlines inside parens and brackets" do
    assert {:ok, tokens} = Lexer.tokenize("a = if(1 > 2,\n  3,\n  [4,\n   5])")
    refute Enum.any?(tokens, &match?({:newline, _}, &1))
    assert {:eof, 4} = List.last(tokens)
  end

  test "strips comments to end of line, keeping the newline" do
    assert {:ok,
            [
              {:ident, "a", 1},
              {:assign, 1},
              {:num, 1.0, 1},
              {:newline, 1},
              {:eof, 2}
            ]} = Lexer.tokenize("a = 1 # socso rate\n# whole line comment")
  end

  test "errors on unexpected characters with line number" do
    assert {:error, %Error{line: 2, message: msg}} = Lexer.tokenize("a = 1\nb = 2 @ 3")
    assert msg =~ "unexpected character"
  end

  test "errors on unterminated string" do
    assert {:error, %Error{line: 1, message: "unterminated string"}} = Lexer.tokenize(~s(a = "oops))
  end

  test "Error message includes line or binding prefix" do
    assert Exception.message(%Error{line: 3, message: "boom"}) == "line 3: boom"
    assert Exception.message(%Error{binding: "k1", message: "boom"}) == "in 'k1': boom"
    assert Exception.message(%Error{message: "boom"}) == "boom"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/pay_script/lexer_test.exs`
Expected: compilation error — `FullCircle.PayScript.Lexer` is undefined.

- [ ] **Step 3: Implement Error and Lexer**

```elixir
# lib/full_circle/pay_script/error.ex
defmodule FullCircle.PayScript.Error do
  @moduledoc """
  A PayScript error. `line` is set for lex/parse errors, `binding` for
  validation/runtime errors (the `name =` line the error occurred in).
  """
  defexception line: nil, binding: nil, message: ""

  @impl true
  def message(%__MODULE__{} = e) do
    cond do
      e.binding -> "in '#{e.binding}': #{e.message}"
      e.line -> "line #{e.line}: #{e.message}"
      true -> e.message
    end
  end
end
```

```elixir
# lib/full_circle/pay_script/lexer.ex
defmodule FullCircle.PayScript.Lexer do
  @moduledoc false

  alias FullCircle.PayScript.Error

  def tokenize(source) when is_binary(source) do
    do_tokenize(source, 1, 0, [])
  end

  defp do_tokenize(<<>>, line, _depth, acc), do: {:ok, Enum.reverse([{:eof, line} | acc])}

  defp do_tokenize(<<c, rest::binary>>, line, depth, acc) when c in [?\s, ?\t, ?\r],
    do: do_tokenize(rest, line, depth, acc)

  defp do_tokenize(<<?\n, rest::binary>>, line, depth, acc) do
    acc = if depth == 0, do: [{:newline, line} | acc], else: acc
    do_tokenize(rest, line + 1, depth, acc)
  end

  defp do_tokenize(<<?#, rest::binary>>, line, depth, acc),
    do: do_tokenize(skip_comment(rest), line, depth, acc)

  defp do_tokenize(<<"==", rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:eq, line} | acc])

  defp do_tokenize(<<"!=", rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:neq, line} | acc])

  defp do_tokenize(<<">=", rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:gte, line} | acc])

  defp do_tokenize(<<"<=", rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:lte, line} | acc])

  defp do_tokenize(<<?>, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:gt, line} | acc])

  defp do_tokenize(<<?<, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:lt, line} | acc])

  defp do_tokenize(<<?=, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:assign, line} | acc])

  defp do_tokenize(<<?+, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:plus, line} | acc])

  defp do_tokenize(<<?-, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:minus, line} | acc])

  defp do_tokenize(<<?*, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:star, line} | acc])

  defp do_tokenize(<<?/, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:slash, line} | acc])

  defp do_tokenize(<<?(, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth + 1, [{:lparen, line} | acc])

  defp do_tokenize(<<?), rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, max(depth - 1, 0), [{:rparen, line} | acc])

  defp do_tokenize(<<?[, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth + 1, [{:lbracket, line} | acc])

  defp do_tokenize(<<?], rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, max(depth - 1, 0), [{:rbracket, line} | acc])

  defp do_tokenize(<<?,, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:comma, line} | acc])

  defp do_tokenize(<<?:, rest::binary>>, line, depth, acc),
    do: do_tokenize(rest, line, depth, [{:colon, line} | acc])

  defp do_tokenize(<<?", rest::binary>>, line, depth, acc) do
    case read_string(rest, []) do
      {:ok, s, rest} -> do_tokenize(rest, line, depth, [{:str, s, line} | acc])
      :error -> {:error, %Error{line: line, message: "unterminated string"}}
    end
  end

  defp do_tokenize(<<c, _::binary>> = source, line, depth, acc) when c in ?0..?9 do
    {num, rest} = read_number(source, [])
    do_tokenize(rest, line, depth, [{:num, num, line} | acc])
  end

  defp do_tokenize(<<c, _::binary>> = source, line, depth, acc)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest} = read_ident(source, [])

    token =
      case word do
        "and" -> {:and_op, line}
        "or" -> {:or_op, line}
        "not" -> {:not_op, line}
        "true" -> {:bool, true, line}
        "false" -> {:bool, false, line}
        _ -> {:ident, word, line}
      end

    do_tokenize(rest, line, depth, [token | acc])
  end

  defp do_tokenize(<<c, _::binary>>, line, _depth, _acc) do
    {:error, %Error{line: line, message: "unexpected character #{inspect(<<c>>)}"}}
  end

  defp skip_comment(<<>>), do: <<>>
  defp skip_comment(<<?\n, _::binary>> = rest), do: rest
  defp skip_comment(<<_, rest::binary>>), do: skip_comment(rest)

  defp read_string(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string(), rest}

  defp read_string(<<?\n, _::binary>>, _acc), do: :error
  defp read_string(<<>>, _acc), do: :error
  defp read_string(<<c, rest::binary>>, acc), do: read_string(rest, [c | acc])

  defp read_number(<<c, rest::binary>>, acc) when c in ?0..?9, do: read_number(rest, [c | acc])

  defp read_number(<<?., c, rest::binary>>, acc) when c in ?0..?9,
    do: read_fraction(rest, [c, ?. | acc])

  defp read_number(rest, acc), do: {finish_number(acc), rest}

  defp read_fraction(<<c, rest::binary>>, acc) when c in ?0..?9,
    do: read_fraction(rest, [c | acc])

  defp read_fraction(rest, acc), do: {finish_number(acc), rest}

  defp finish_number(acc) do
    {f, ""} = acc |> Enum.reverse() |> List.to_string() |> Float.parse()
    f
  end

  defp read_ident(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: read_ident(rest, [c | acc])

  defp read_ident(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/pay_script/lexer_test.exs`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_script/error.ex lib/full_circle/pay_script/lexer.ex test/full_circle/pay_script/lexer_test.exs
git commit -m "feat(payscript): error struct and lexer"
```

---

### Task 2: Parser

**Files:**
- Create: `lib/full_circle/pay_script/parser.ex`
- Test: `test/full_circle/pay_script/parser_test.exs`

**Interfaces:**
- Consumes: `Lexer.tokenize/1` token list (Task 1).
- Produces: `FullCircle.PayScript.Parser.parse_script(tokens) :: {:ok, [{name :: String.t(), expr}]} | {:error, Error.t()}`. Expression AST nodes: `{:num, float}`, `{:str, s}`, `{:bool, b}`, `{:list, [expr]}`, `{:var, name}`, `{:neg, expr}`, `{:not, expr}`, `{:binop, op, l, r}` with `op` in `:or :and :eq :neq :gt :gte :lt :lte :add :sub :mul :div`, `{:if, cond, then, else}`, `{:call, name, args}` where an arg may be `{:kw, key :: String.t(), expr}`. Parser enforces: at least one binding, no duplicate binding names, last binding named `result`, `if()` has exactly 3 args.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/full_circle/pay_script/parser_test.exs
defmodule FullCircle.PayScript.ParserTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript.{Error, Lexer, Parser}

  defp parse(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    Parser.parse_script(tokens)
  end

  defp parse_one(expr_source) do
    {:ok, [{"result", ast}]} = parse("result = " <> expr_source)
    ast
  end

  describe "expression grammar" do
    test "multiplication binds tighter than addition" do
      assert {:binop, :add, {:num, 1.0}, {:binop, :mul, {:num, 2.0}, {:num, 3.0}}} =
               parse_one("1 + 2 * 3")
    end

    test "parentheses override precedence" do
      assert {:binop, :mul, {:binop, :add, {:num, 1.0}, {:num, 2.0}}, {:num, 3.0}} =
               parse_one("(1 + 2) * 3")
    end

    test "same-precedence operators are left-associative" do
      assert {:binop, :sub, {:binop, :sub, {:num, 10.0}, {:num, 3.0}}, {:num, 2.0}} =
               parse_one("10 - 3 - 2")

      assert {:binop, :div, {:binop, :div, {:num, 100.0}, {:num, 10.0}}, {:num, 5.0}} =
               parse_one("100 / 10 / 5")
    end

    test "comparison binds tighter than not, and, or" do
      assert {:binop, :or, {:binop, :and, {:not, {:binop, :gt, {:var, "a"}, {:num, 1.0}}}, {:var, "b"}},
              {:var, "c"}} = parse_one("not a > 1 and b or c")
    end

    test "unary minus" do
      assert {:binop, :add, {:num, 1.0}, {:neg, {:var, "x"}}} = parse_one("1 + -x")
    end

    test "if() becomes an if node" do
      assert {:if, {:binop, :gte, {:var, "age"}, {:num, 60.0}}, {:num, 0.0}, {:var, "x"}} =
               parse_one("if(age >= 60, 0, x)")
    end

    test "if() with wrong arity is an error" do
      {:ok, tokens} = Lexer.tokenize("result = if(1 > 2, 3)")
      assert {:error, %Error{message: msg}} = Parser.parse_script(tokens)
      assert msg =~ "if() takes exactly 3 arguments"
    end

    test "function calls with positional and keyword args" do
      assert {:call, "lookup", [{:str, "socso"}, {:var, "wages"}, {:str, "employee"}]} =
               parse_one(~s|lookup("socso", wages, "employee")|)

      assert {:call, "ytd_sum", [{:kw, "code", {:str, "epf_employee"}}]} =
               parse_one(~s|ytd_sum(code: "epf_employee")|)
    end

    test "list literals" do
      assert {:call, "ytd_sum", [{:kw, "name", {:list, [{:str, "A"}, {:str, "B"}]}}]} =
               parse_one(~s|ytd_sum(name: ["A", "B"])|)
    end
  end

  describe "script structure" do
    test "parses multiple bindings in order" do
      assert {:ok, [{"a", {:num, 1.0}}, {"b", {:binop, :add, {:var, "a"}, {:num, 2.0}}}, {"result", {:var, "b"}}]} =
               parse("a = 1\nb = a + 2\nresult = b")
    end

    test "skips blank lines and comment-only lines" do
      assert {:ok, [{"result", {:num, 1.0}}]} = parse("\n# header comment\n\nresult = 1\n\n")
    end

    test "multi-line expressions inside parens" do
      assert {:ok, [{"result", {:if, _, _, _}}]} =
               parse("result = if(1 > 2,\n  3,\n  4)")
    end

    test "empty script is an error" do
      assert {:error, %Error{message: "script is empty"}} = parse("# nothing here\n")
    end

    test "last binding must be result" do
      assert {:error, %Error{message: "last binding must be 'result'"}} = parse("a = 1")
    end

    test "duplicate binding names are an error" do
      assert {:error, %Error{message: msg}} = parse("a = 1\na = 2\nresult = a")
      assert msg =~ "'a' is bound more than once"
    end

    test "missing '=' is an error with line number" do
      assert {:error, %Error{line: 2}} = parse("a = 1\nb 2\nresult = a")
    end

    test "trailing garbage after an expression is an error" do
      assert {:error, %Error{message: msg}} = parse("a = 1 2\nresult = a")
      assert msg =~ "expected end of line"
    end

    test "script may end without trailing newline" do
      assert {:ok, [{"result", {:num, 5.0}}]} = parse("result = 5")
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/pay_script/parser_test.exs`
Expected: compilation error — `FullCircle.PayScript.Parser` is undefined.

- [ ] **Step 3: Implement the parser**

```elixir
# lib/full_circle/pay_script/parser.ex
defmodule FullCircle.PayScript.Parser do
  @moduledoc false

  alias FullCircle.PayScript.Error

  @comparison_ops [:eq, :neq, :gt, :gte, :lt, :lte]

  def parse_script(tokens) do
    with {:ok, bindings} <- parse_bindings(skip_newlines(tokens), []),
         :ok <- check_bindings(bindings) do
      {:ok, bindings}
    end
  end

  defp parse_bindings([{:eof, _}], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_bindings([{:ident, name, _}, {:assign, _} | rest], acc) do
    with {:ok, expr, rest} <- parse_expr(rest),
         {:ok, rest} <- expect_line_end(rest) do
      parse_bindings(skip_newlines(rest), [{name, expr} | acc])
    end
  end

  defp parse_bindings([tok | _], _acc) do
    {:error,
     %Error{line: tok_line(tok), message: "expected 'name = expression', got #{tok_label(tok)}"}}
  end

  defp expect_line_end([{:newline, _} | rest]), do: {:ok, rest}
  defp expect_line_end([{:eof, _}] = rest), do: {:ok, rest}

  defp expect_line_end([tok | _]),
    do: {:error, %Error{line: tok_line(tok), message: "expected end of line, got #{tok_label(tok)}"}}

  defp check_bindings([]), do: {:error, %Error{message: "script is empty"}}

  defp check_bindings(bindings) do
    names = Enum.map(bindings, fn {name, _} -> name end)

    cond do
      (dup = List.first(names -- Enum.uniq(names))) != nil ->
        {:error, %Error{message: "'#{dup}' is bound more than once"}}

      List.last(names) != "result" ->
        {:error, %Error{message: "last binding must be 'result'"}}

      true ->
        :ok
    end
  end

  # -- Expressions (precedence low -> high) ----------------------------------

  def parse_expr(tokens), do: parse_or(tokens)

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: loop_or(left, rest)
  end

  defp loop_or(left, [{:or_op, _} | rest]) do
    with {:ok, right, rest} <- parse_and(rest), do: loop_or({:binop, :or, left, right}, rest)
  end

  defp loop_or(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens), do: loop_and(left, rest)
  end

  defp loop_and(left, [{:and_op, _} | rest]) do
    with {:ok, right, rest} <- parse_not(rest), do: loop_and({:binop, :and, left, right}, rest)
  end

  defp loop_and(left, rest), do: {:ok, left, rest}

  defp parse_not([{:not_op, _} | rest]) do
    with {:ok, e, rest} <- parse_not(rest), do: {:ok, {:not, e}, rest}
  end

  defp parse_not(tokens), do: parse_comparison(tokens)

  defp parse_comparison(tokens) do
    with {:ok, left, rest} <- parse_additive(tokens) do
      case rest do
        [{op, _} | rest2] when op in @comparison_ops ->
          with {:ok, right, rest3} <- parse_additive(rest2),
               do: {:ok, {:binop, op, left, right}, rest3}

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_additive(tokens) do
    with {:ok, left, rest} <- parse_multiplicative(tokens), do: loop_additive(left, rest)
  end

  defp loop_additive(left, [{:plus, _} | rest]) do
    with {:ok, r, rest} <- parse_multiplicative(rest),
         do: loop_additive({:binop, :add, left, r}, rest)
  end

  defp loop_additive(left, [{:minus, _} | rest]) do
    with {:ok, r, rest} <- parse_multiplicative(rest),
         do: loop_additive({:binop, :sub, left, r}, rest)
  end

  defp loop_additive(left, rest), do: {:ok, left, rest}

  defp parse_multiplicative(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens), do: loop_multiplicative(left, rest)
  end

  defp loop_multiplicative(left, [{:star, _} | rest]) do
    with {:ok, r, rest} <- parse_unary(rest),
         do: loop_multiplicative({:binop, :mul, left, r}, rest)
  end

  defp loop_multiplicative(left, [{:slash, _} | rest]) do
    with {:ok, r, rest} <- parse_unary(rest),
         do: loop_multiplicative({:binop, :div, left, r}, rest)
  end

  defp loop_multiplicative(left, rest), do: {:ok, left, rest}

  defp parse_unary([{:minus, _} | rest]) do
    with {:ok, e, rest} <- parse_unary(rest), do: {:ok, {:neg, e}, rest}
  end

  defp parse_unary(tokens), do: parse_primary(tokens)

  defp parse_primary([{:num, n, _} | rest]), do: {:ok, {:num, n}, rest}
  defp parse_primary([{:str, s, _} | rest]), do: {:ok, {:str, s}, rest}
  defp parse_primary([{:bool, b, _} | rest]), do: {:ok, {:bool, b}, rest}

  defp parse_primary([{:lparen, _} | rest]) do
    with {:ok, e, rest} <- parse_expr(rest) do
      case rest do
        [{:rparen, _} | rest] -> {:ok, e, rest}
        [tok | _] -> {:error, %Error{line: tok_line(tok), message: "expected ')'"}}
      end
    end
  end

  defp parse_primary([{:lbracket, _} | rest]), do: parse_list(rest, [])

  defp parse_primary([{:ident, name, line}, {:lparen, _} | rest]),
    do: parse_call(name, line, rest)

  defp parse_primary([{:ident, name, _} | rest]), do: {:ok, {:var, name}, rest}

  defp parse_primary([tok | _]),
    do: {:error, %Error{line: tok_line(tok), message: "unexpected #{tok_label(tok)}"}}

  defp parse_list([{:rbracket, _} | rest], acc), do: {:ok, {:list, Enum.reverse(acc)}, rest}

  defp parse_list(tokens, acc) do
    with {:ok, e, rest} <- parse_expr(tokens) do
      case rest do
        [{:comma, _} | rest] -> parse_list(rest, [e | acc])
        [{:rbracket, _} | rest] -> {:ok, {:list, Enum.reverse([e | acc])}, rest}
        [tok | _] -> {:error, %Error{line: tok_line(tok), message: "expected ',' or ']'"}}
      end
    end
  end

  defp parse_call(name, line, tokens) do
    with {:ok, args, rest} <- parse_args(tokens, []) do
      case {name, args} do
        {"if", [c, t, e]} ->
          {:ok, {:if, c, t, e}, rest}

        {"if", args} ->
          {:error,
           %Error{line: line, message: "if() takes exactly 3 arguments, got #{length(args)}"}}

        _ ->
          {:ok, {:call, name, args}, rest}
      end
    end
  end

  defp parse_args([{:rparen, _} | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_args(tokens, acc) do
    with {:ok, arg, rest} <- parse_arg(tokens) do
      case rest do
        [{:comma, _} | rest] -> parse_args(rest, [arg | acc])
        [{:rparen, _} | rest] -> {:ok, Enum.reverse([arg | acc]), rest}
        [tok | _] -> {:error, %Error{line: tok_line(tok), message: "expected ',' or ')'"}}
      end
    end
  end

  # keyword argument: `key: expr` (used by ytd_sum)
  defp parse_arg([{:ident, key, _}, {:colon, _} | rest]) do
    with {:ok, e, rest} <- parse_expr(rest), do: {:ok, {:kw, key, e}, rest}
  end

  defp parse_arg(tokens), do: parse_expr(tokens)

  defp skip_newlines([{:newline, _} | rest]), do: skip_newlines(rest)
  defp skip_newlines(tokens), do: tokens

  defp tok_line({_, line}), do: line
  defp tok_line({_, _, line}), do: line

  defp tok_label({:ident, name, _}), do: "'#{name}'"
  defp tok_label({:num, n, _}), do: "number #{n}"
  defp tok_label({:str, s, _}), do: "string #{inspect(s)}"
  defp tok_label({:bool, b, _}), do: to_string(b)
  defp tok_label({:newline, _}), do: "end of line"
  defp tok_label({:eof, _}), do: "end of script"
  defp tok_label({type, _}), do: "'#{type}'"
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/pay_script/parser_test.exs`
Expected: all tests PASS. Also run `mix test test/full_circle/pay_script/` to confirm lexer tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_script/parser.ex test/full_circle/pay_script/parser_test.exs
git commit -m "feat(payscript): recursive-descent parser"
```

---

### Task 3: Evaluator — expressions, script flow, math builtins

**Files:**
- Create: `lib/full_circle/pay_script/evaluator.ex`
- Test: `test/full_circle/pay_script/evaluator_test.exs`

**Interfaces:**
- Consumes: parser AST (Task 2).
- Produces: `FullCircle.PayScript.Evaluator.eval_script(bindings, context :: %{String.t() => term}, env :: {module, term} | nil) :: {:ok, value} | {:error, Error.t()}` and `eval(expr, vars, env)` (public, used later by FileSpec). Values: floats/ints, booleans, strings, lists. Runtime errors carry the binding name in `error.binding`. Math builtins `min/2 max/2 ceil/1 floor/1 abs/1 round/2` evaluate with no env. Data builtins (`lookup`, `ytd_sum`, `calc`) are **left for Task 4** — this task implements every other node; unknown functions error.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/full_circle/pay_script/evaluator_test.exs
defmodule FullCircle.PayScript.EvaluatorTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript.{Error, Evaluator, Lexer, Parser}

  defp run(source, context \\ %{}) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, bindings} = Parser.parse_script(tokens)
    Evaluator.eval_script(bindings, context, nil)
  end

  test "arithmetic with precedence" do
    assert {:ok, 7.0} = run("result = 1 + 2 * 3")
    assert {:ok, 2.5} = run("result = 5 / 2")
    assert {:ok, -4.0} = run("result = -(2 + 2)")
  end

  test "bindings chain and context variables resolve" do
    assert {:ok, 660.0} = run("rate = 0.11\nresult = wages * rate + 110", %{"wages" => 5000.0})
  end

  test "later bindings shadow context variables" do
    assert {:ok, 1.0} = run("wages = 1\nresult = wages", %{"wages" => 5000.0})
  end

  test "comparisons and equality" do
    assert {:ok, true} = run("result = 3 > 2")
    assert {:ok, true} = run(~s(result = "Single" == "Single"))
    assert {:ok, false} = run(~s(result = "a" != "a"))
    assert {:ok, true} = run("result = 2 <= 2")
  end

  test "boolean logic short-circuits" do
    # `1 / 0` on the right side must not be evaluated
    assert {:ok, false} = run("result = false and 1 / 0 > 0")
    assert {:ok, true} = run("result = true or 1 / 0 > 0")
    assert {:ok, true} = run("result = not false")
  end

  test "if evaluates only the taken branch" do
    assert {:ok, 10.0} = run("result = if(true, 10, 1 / 0)")
    assert {:ok, 20.0} = run("result = if(false, 1 / 0, 20)")
  end

  test "math builtins" do
    assert {:ok, 3.0} = run("result = min(3, 7)")
    assert {:ok, 7.0} = run("result = max(3, 7)")
    assert {:ok, 651.0} = run("result = ceil(650.2)")
    assert {:ok, 650.0} = run("result = floor(650.9)")
    assert {:ok, 5.0} = run("result = abs(0 - 5)")
    assert {:ok, 64.1} = run("result = round(64.1428, 1)")
  end

  test "division by zero is a named error" do
    assert {:error, %Error{binding: "k1", message: "division by zero"}} =
             run("k1 = 1 / 0\nresult = k1")
  end

  test "type errors are reported, not coerced" do
    assert {:error, %Error{binding: "result", message: msg}} = run(~s(result = "a" + 1))
    assert msg =~ "cannot apply '+'"

    assert {:error, %Error{message: msg}} = run("result = if(1, 2, 3)")
    assert msg =~ "if condition"

    assert {:error, %Error{message: msg}} = run(~s(result = 1 == "a"))
    assert msg =~ "cannot compare"

    assert {:error, %Error{message: msg}} = run("result = 1 and true")
    assert msg =~ "'and'"
  end

  test "unknown identifier at runtime is an error" do
    assert {:error, %Error{binding: "result", message: msg}} = run("result = mystery")
    assert msg =~ "unknown identifier 'mystery'"
  end

  test "unknown function is an error" do
    assert {:error, %Error{message: msg}} = run("result = sqrt(4)")
    assert msg =~ "unknown function sqrt/1"
  end

  test "integer context values work in arithmetic and comparison" do
    assert {:ok, 6.0} = run("result = 12 - pay_month", %{"pay_month" => 6})
    assert {:ok, true} = run("result = children == 2", %{"children" => 2})
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/pay_script/evaluator_test.exs`
Expected: compilation error — `FullCircle.PayScript.Evaluator` is undefined.

- [ ] **Step 3: Implement the evaluator**

```elixir
# lib/full_circle/pay_script/evaluator.ex
defmodule FullCircle.PayScript.Evaluator do
  @moduledoc false

  alias FullCircle.PayScript.Error

  @ytd_keys %{"code" => :code, "type" => :type, "name" => :name}

  def eval_script(bindings, context, env) do
    bindings
    |> Enum.reduce_while({:ok, context}, fn {name, expr}, {:ok, vars} ->
      case eval(expr, vars, env) do
        {:ok, val} -> {:cont, {:ok, Map.put(vars, name, val)}}
        {:error, %Error{} = e} -> {:halt, {:error, %{e | binding: e.binding || name}}}
      end
    end)
    |> case do
      {:ok, vars} -> {:ok, Map.fetch!(vars, "result")}
      err -> err
    end
  end

  def eval({:num, n}, _vars, _env), do: {:ok, n}
  def eval({:str, s}, _vars, _env), do: {:ok, s}
  def eval({:bool, b}, _vars, _env), do: {:ok, b}

  def eval({:list, items}, vars, env) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case eval(item, vars, env) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  def eval({:var, name}, vars, _env) do
    case Map.fetch(vars, name) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, %Error{message: "unknown identifier '#{name}'"}}
    end
  end

  def eval({:neg, e}, vars, env) do
    with {:ok, v} <- eval_num(e, vars, env), do: {:ok, -v}
  end

  def eval({:not, e}, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      if is_boolean(v), do: {:ok, not v}, else: type_error("not", v)
    end
  end

  def eval({:if, c, t, e}, vars, env) do
    with {:ok, cond_v} <- eval(c, vars, env) do
      case cond_v do
        true -> eval(t, vars, env)
        false -> eval(e, vars, env)
        other -> type_error("if condition", other)
      end
    end
  end

  def eval({:binop, op, l, r}, vars, env) when op in [:and, :or],
    do: eval_logic(op, l, r, vars, env)

  def eval({:binop, op, l, r}, vars, env) do
    with {:ok, lv} <- eval(l, vars, env),
         {:ok, rv} <- eval(r, vars, env),
         do: apply_binop(op, lv, rv)
  end

  def eval({:call, name, args}, vars, env), do: eval_call(name, args, vars, env)

  def eval({:kw, key, _}, _vars, _env),
    do: {:error, %Error{message: "unexpected keyword argument '#{key}:'"}}

  # -- logic ------------------------------------------------------------------

  defp eval_logic(op, l, r, vars, env) do
    with {:ok, lv} <- eval(l, vars, env) do
      case {op, lv} do
        {:and, false} ->
          {:ok, false}

        {:or, true} ->
          {:ok, true}

        {_, b} when is_boolean(b) ->
          with {:ok, rv} <- eval(r, vars, env) do
            if is_boolean(rv), do: {:ok, rv}, else: type_error("'#{op}'", rv)
          end

        {_, other} ->
          type_error("'#{op}'", other)
      end
    end
  end

  # -- binary operators ---------------------------------------------------------

  defp apply_binop(:add, l, r) when is_number(l) and is_number(r), do: {:ok, l + r}
  defp apply_binop(:sub, l, r) when is_number(l) and is_number(r), do: {:ok, l - r}
  defp apply_binop(:mul, l, r) when is_number(l) and is_number(r), do: {:ok, l * r}

  defp apply_binop(:div, l, r) when is_number(l) and is_number(r) do
    if r == 0 do
      {:error, %Error{message: "division by zero"}}
    else
      {:ok, l / r}
    end
  end

  defp apply_binop(:eq, l, r), do: compare_eq(l, r, & &1)
  defp apply_binop(:neq, l, r), do: compare_eq(l, r, &(not &1))

  defp apply_binop(op, l, r)
       when op in [:gt, :gte, :lt, :lte] and is_number(l) and is_number(r) do
    result =
      case op do
        :gt -> l > r
        :gte -> l >= r
        :lt -> l < r
        :lte -> l <= r
      end

    {:ok, result}
  end

  defp apply_binop(op, l, r) do
    {:error,
     %Error{
       message: "cannot apply '#{op_text(op)}' to #{value_label(l)} and #{value_label(r)}"
     }}
  end

  defp compare_eq(l, r, f) when is_number(l) and is_number(r), do: {:ok, f.(l == r)}
  defp compare_eq(l, r, f) when is_binary(l) and is_binary(r), do: {:ok, f.(l == r)}
  defp compare_eq(l, r, f) when is_boolean(l) and is_boolean(r), do: {:ok, f.(l == r)}

  defp compare_eq(l, r, _f),
    do: {:error, %Error{message: "cannot compare #{value_label(l)} with #{value_label(r)}"}}

  # -- builtin calls ------------------------------------------------------------

  defp eval_call("min", [a, b], vars, env), do: num2(a, b, vars, env, &min/2)
  defp eval_call("max", [a, b], vars, env), do: num2(a, b, vars, env, &max/2)
  defp eval_call("ceil", [a], vars, env), do: num1(a, vars, env, &Float.ceil/1)
  defp eval_call("floor", [a], vars, env), do: num1(a, vars, env, &Float.floor/1)
  defp eval_call("abs", [a], vars, env), do: num1(a, vars, env, &abs/1)

  defp eval_call("round", [a, b], vars, env) do
    with {:ok, x} <- eval_num(a, vars, env),
         {:ok, n} <- eval_num(b, vars, env),
         do: {:ok, Float.round(x, trunc(n))}
  end

  defp eval_call("lookup", [t, v, c], vars, env) do
    with {:ok, table} <- eval_str(t, vars, env),
         {:ok, value} <- eval_num(v, vars, env),
         {:ok, column} <- eval_str(c, vars, env),
         do: env_call(env, :lookup, [table, value, column])
  end

  defp eval_call("ytd_sum", [{:kw, key, e}], vars, env) when is_map_key(@ytd_keys, key) do
    with {:ok, val} <- eval(e, vars, env),
         {:ok, keys} <- string_list(key, val),
         do: env_call(env, :ytd_sum, [@ytd_keys[key], keys])
  end

  defp eval_call("ytd_sum", _args, _vars, _env) do
    {:error,
     %Error{message: "ytd_sum expects a single 'code:', 'type:' or 'name:' argument"}}
  end

  defp eval_call("calc", [e], vars, env) do
    with {:ok, code} <- eval_str(e, vars, env), do: env_call(env, :calc, [code])
  end

  defp eval_call(name, args, _vars, _env),
    do: {:error, %Error{message: "unknown function #{name}/#{length(args)}"}}

  # -- helpers ------------------------------------------------------------------

  defp num1(a, vars, env, f) do
    with {:ok, x} <- eval_num(a, vars, env), do: {:ok, f.(x)}
  end

  defp num2(a, b, vars, env, f) do
    with {:ok, x} <- eval_num(a, vars, env),
         {:ok, y} <- eval_num(b, vars, env),
         do: {:ok, f.(x, y)}
  end

  defp eval_num(e, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      if is_number(v) do
        {:ok, v * 1.0}
      else
        {:error, %Error{message: "expected a number, got #{value_label(v)}"}}
      end
    end
  end

  defp eval_str(e, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      if is_binary(v) do
        {:ok, v}
      else
        {:error, %Error{message: "expected a string, got #{value_label(v)}"}}
      end
    end
  end

  defp string_list(_key, v) when is_binary(v), do: {:ok, [v]}

  defp string_list(key, v) when is_list(v) do
    if v != [] and Enum.all?(v, &is_binary/1) do
      {:ok, v}
    else
      {:error, %Error{message: "ytd_sum #{key}: must be a string or list of strings"}}
    end
  end

  defp string_list(key, _v),
    do: {:error, %Error{message: "ytd_sum #{key}: must be a string or list of strings"}}

  defp env_call(nil, fun, _args),
    do: {:error, %Error{message: "#{fun} is not available in this context"}}

  defp env_call({mod, state}, fun, args) do
    case apply(mod, fun, [state | args]) do
      {:ok, v} when is_number(v) -> {:ok, v * 1.0}
      {:error, msg} when is_binary(msg) -> {:error, %Error{message: msg}}
      {:error, %Error{} = e} -> {:error, e}
    end
  end

  defp type_error(what, v),
    do: {:error, %Error{message: "#{what} expects a boolean, got #{value_label(v)}"}}

  defp value_label(v) when is_number(v), do: "number #{v}"
  defp value_label(v) when is_binary(v), do: "string #{inspect(v)}"
  defp value_label(v) when is_boolean(v), do: "boolean #{v}"
  defp value_label(v) when is_list(v), do: "a list"

  defp op_text(:add), do: "+"
  defp op_text(:sub), do: "-"
  defp op_text(:mul), do: "*"
  defp op_text(:div), do: "/"
  defp op_text(op), do: to_string(op)
end
```

Note: `eval({:neg, ...})` uses `eval_num`, so `-x` on a string reports "expected a number". The `{:num, n}` node returns the float unchanged; integer values only enter via context variables and are handled by `is_number` guards, with `eval_num` coercing to float where a float API (`Float.ceil/round`) needs one. `round(64.1428, 1)` works because `eval_num` coerces `x` to float. Data builtins compile here but need Task 4's env to succeed; with `env = nil` they return an error tuple, never crash.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/pay_script/evaluator_test.exs`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_script/evaluator.ex test/full_circle/pay_script/evaluator_test.exs
git commit -m "feat(payscript): tree-walking evaluator with math builtins"
```

---

### Task 4: Env behaviour, stub env, data builtins, public API

**Files:**
- Create: `lib/full_circle/pay_script/env.ex`
- Create: `lib/full_circle/pay_script.ex`
- Create: `test/support/pay_script_stub_env.ex`
- Test: `test/full_circle/pay_script_test.exs`

**Interfaces:**
- Consumes: `Lexer.tokenize/1`, `Parser.parse_script/1`, `Evaluator.eval_script/3`.
- Produces:
  - `FullCircle.PayScript.Env` behaviour: `lookup(state, table, value, column) :: {:ok, number} | {:error, String.t()}`, `ytd_sum(state, kind :: :code | :type | :name, keys :: [String.t()]) :: {:ok, number} | {:error, String.t()}`, `calc(state, code) :: {:ok, number} | {:error, String.t()}`.
  - `FullCircle.PayScript.parse(source) :: {:ok, bindings} | {:error, Error.t()}`.
  - `FullCircle.PayScript.eval(source_or_bindings, context, {env_mod, env_state}) :: {:ok, Decimal.t()} | {:error, Error.t()}`.
  - `FullCircle.PayScript.standard_variables() :: [String.t()]` — exactly `~w(wages bonus age malaysian nationality marital_status partner_working children pay_month pay_year service_years)`.
  - `FullCircle.PayScriptStubEnv` (test support): state is `%{tables: %{code => %{columns: [String.t()], rows: [[number]]}}, ytd: %{{kind, keys} => number}, calcs: %{code => number}}`; `lookup` uses bracket semantics `value > row_from and value <= row_to` on the first two columns, returning `0.0` when no bracket matches (spec behavior); `ytd_sum` defaults to `0.0` for missing keys; `calc` errors for unknown codes.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/full_circle/pay_script_test.exs
defmodule FullCircle.PayScriptTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript
  alias FullCircle.PayScript.Error
  alias FullCircle.PayScriptStubEnv

  @socso_rows [
    [2900.0, 3000.0, 51.65, 14.75, 36.9, 22.15],
    [3000.0, 3100.0, 53.35, 15.25, 38.1, 22.85]
  ]

  defp env(overrides \\ %{}) do
    state =
      Map.merge(
        %{
          tables: %{
            "socso" => %{
              columns: ["wage_from", "wage_to", "employer", "employee", "employer_only", "employee_24hour"],
              rows: @socso_rows
            }
          },
          ytd: %{},
          calcs: %{"epf_employee" => 550.0}
        },
        overrides
      )

    {PayScriptStubEnv, state}
  end

  test "standard_variables lists the spec's context variables" do
    assert PayScript.standard_variables() ==
             ~w(wages bonus age malaysian nationality marital_status partner_working children pay_month pay_year service_years)
  end

  test "eval returns a Decimal" do
    assert {:ok, dec} = PayScript.eval("result = 1 + 1", %{}, env())
    assert Decimal.equal?(dec, Decimal.new("2"))
  end

  test "lookup finds the bracket row and column" do
    assert {:ok, dec} =
             PayScript.eval(~s|result = lookup("socso", wages, "employee")|, %{"wages" => 2950.0}, env())

    assert Decimal.equal?(dec, Decimal.new("14.75"))
  end

  test "lookup boundary: value equal to wage_to belongs to the lower bracket" do
    assert {:ok, dec} =
             PayScript.eval(~s|result = lookup("socso", wages, "employee")|, %{"wages" => 3000.0}, env())

    assert Decimal.equal?(dec, Decimal.new("14.75"))
  end

  test "lookup outside all brackets returns 0.0" do
    assert {:ok, dec} =
             PayScript.eval(~s|result = lookup("socso", wages, "employee")|, %{"wages" => 99_999.0}, env())

    assert Decimal.equal?(dec, Decimal.new("0"))
  end

  test "lookup unknown table or column errors" do
    assert {:error, %Error{message: msg}} =
             PayScript.eval(~s|result = lookup("nope", 1, "employee")|, %{}, env())

    assert msg =~ "unknown table 'nope'"

    assert {:error, %Error{message: msg}} =
             PayScript.eval(~s|result = lookup("socso", 1, "nope")|, %{}, env())

    assert msg =~ "unknown column 'nope'"
  end

  test "ytd_sum with single string and with list keys" do
    e = env(%{ytd: %{{:type, ["Addition"]} => 25_000.0, {:name, ["A", "B"]} => 400.0}})

    assert {:ok, dec} = PayScript.eval(~s|result = ytd_sum(type: "Addition")|, %{}, e)
    assert Decimal.equal?(dec, Decimal.new("25000"))

    assert {:ok, dec} = PayScript.eval(~s|result = ytd_sum(name: ["A", "B"])|, %{}, e)
    assert Decimal.equal?(dec, Decimal.new("400"))
  end

  test "ytd_sum for unknown key defaults to 0" do
    assert {:ok, dec} = PayScript.eval(~s|result = ytd_sum(code: "whatever")|, %{}, env())
    assert Decimal.equal?(dec, Decimal.new("0"))
  end

  test "calc resolves other calcs and errors for unknown codes" do
    assert {:ok, dec} = PayScript.eval(~s|result = calc("epf_employee") * 2|, %{}, env())
    assert Decimal.equal?(dec, Decimal.new("1100"))

    assert {:error, %Error{binding: "result", message: msg}} =
             PayScript.eval(~s|result = calc("missing")|, %{}, env())

    assert msg =~ "unknown calc 'missing'"
  end

  test "non-numeric result is an error" do
    assert {:error, %Error{binding: "result", message: msg}} =
             PayScript.eval(~s(result = "abc"), %{}, env())

    assert msg =~ "result must be a number"
  end

  test "parse errors pass through eval" do
    assert {:error, %Error{}} = PayScript.eval("result = 1 +", %{}, env())
  end

  test "eval accepts pre-parsed bindings" do
    {:ok, bindings} = PayScript.parse("result = 2 * 3")
    assert {:ok, dec} = PayScript.eval(bindings, %{}, env())
    assert Decimal.equal?(dec, Decimal.new("6"))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/pay_script_test.exs`
Expected: compilation error — `FullCircle.PayScript` is undefined.

- [ ] **Step 3: Implement Env behaviour, stub env, and public API**

```elixir
# lib/full_circle/pay_script/env.ex
defmodule FullCircle.PayScript.Env do
  @moduledoc """
  Runtime environment for PayScript builtins that need data access.

  The evaluator receives `{module, state}`; each callback gets `state` as its
  first argument. Phase 2 provides the DB-backed implementation (company- and
  effective-date-scoped); tests use `FullCircle.PayScriptStubEnv`.
  """

  @type state :: term()

  @callback lookup(state, table :: String.t(), value :: number(), column :: String.t()) ::
              {:ok, number()} | {:error, String.t()}

  @callback ytd_sum(state, kind :: :code | :type | :name, keys :: [String.t()]) ::
              {:ok, number()} | {:error, String.t()}

  @callback calc(state, code :: String.t()) :: {:ok, number()} | {:error, String.t()}
end
```

```elixir
# test/support/pay_script_stub_env.ex
defmodule FullCircle.PayScriptStubEnv do
  @moduledoc """
  Map-backed PayScript env for tests.

  State: `%{tables: %{code => %{columns: [...], rows: [[...]]}},
            ytd: %{{kind, keys} => number}, calcs: %{code => number}}`
  """

  @behaviour FullCircle.PayScript.Env

  @impl true
  def lookup(state, table, value, column) do
    case Map.fetch(state.tables, table) do
      {:ok, %{columns: cols, rows: rows}} ->
        case Enum.find_index(cols, &(&1 == column)) do
          nil ->
            {:error, "unknown column '#{column}' in table '#{table}'"}

          idx ->
            row = Enum.find(rows, fn [from, to | _] -> value > from and value <= to end)
            {:ok, if(row, do: Enum.at(row, idx), else: 0.0)}
        end

      :error ->
        {:error, "unknown table '#{table}'"}
    end
  end

  @impl true
  def ytd_sum(state, kind, keys), do: {:ok, Map.get(state.ytd, {kind, keys}, 0.0)}

  @impl true
  def calc(state, code) do
    case Map.fetch(state.calcs, code) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "unknown calc '#{code}'"}
    end
  end
end
```

```elixir
# lib/full_circle/pay_script.ex
defmodule FullCircle.PayScript do
  @moduledoc """
  PayScript: the safe payroll calculation language.

  A script is a sequence of `name = expression` lines ending in `result = ...`.
  See `docs/superpowers/specs/2026-07-02-statutory-zero-redeploy-design.md`
  section 2 for the language definition.

      iex> env = {FullCircle.PayScriptStubEnv, %{tables: %{}, ytd: %{}, calcs: %{}}}
      iex> FullCircle.PayScript.eval("result = wages * 0.11", %{"wages" => 5000.0}, env)
      {:ok, Decimal.new("550.0")}
  """

  alias FullCircle.PayScript.{Error, Evaluator, Lexer, Parser}

  @standard_variables ~w(wages bonus age malaysian nationality marital_status
                         partner_working children pay_month pay_year service_years)

  @doc "Context variables every statutory calc may reference."
  def standard_variables, do: @standard_variables

  @doc "Parses PayScript source into bindings, `{:ok, bindings} | {:error, Error.t()}`."
  def parse(source) when is_binary(source) do
    with {:ok, tokens} <- Lexer.tokenize(source) do
      Parser.parse_script(tokens)
    end
  end

  @doc """
  Evaluates a script (source string or pre-parsed bindings) against a context
  map and an env `{module, state}` implementing `FullCircle.PayScript.Env`.
  Returns `{:ok, Decimal.t()}` or `{:error, Error.t()}`.
  """
  def eval(source, context, env) when is_binary(source) do
    with {:ok, bindings} <- parse(source), do: eval(bindings, context, env)
  end

  def eval(bindings, context, env) when is_list(bindings) do
    case Evaluator.eval_script(bindings, context, env) do
      {:ok, v} when is_number(v) ->
        {:ok, Decimal.from_float(v * 1.0)}

      {:ok, other} ->
        {:error,
         %Error{binding: "result", message: "result must be a number, got #{inspect(other)}"}}

      {:error, e} ->
        {:error, e}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/pay_script_test.exs`
Expected: all tests PASS. (If `FullCircle.PayScriptStubEnv` is not found, confirm the file is under `test/support/` — `mix.exs` already compiles that path in `:test`.)

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_script/env.ex lib/full_circle/pay_script.ex test/support/pay_script_stub_env.ex test/full_circle/pay_script_test.exs
git commit -m "feat(payscript): env behaviour, stub env and public eval API"
```

---

### Task 5: Validator — save-time validation, calc_deps, check_cycles

**Files:**
- Create: `lib/full_circle/pay_script/validator.ex`
- Modify: `lib/full_circle/pay_script.ex` (add `validate/2`, `calc_deps/1`, `check_cycles/1`)
- Test: `test/full_circle/pay_script/validator_test.exs`

**Interfaces:**
- Consumes: `PayScript.parse/1`, parser AST.
- Produces:
  - `FullCircle.PayScript.validate(source, schema \\ %{}) :: :ok | {:error, [Error.t()]}`. Schema keys (all optional): `:variables` (defaults to `standard_variables()`), `:tables` (`%{table_code => [column_names]}`; when present, `lookup` literals are checked), `:calcs` (`[codes]`; when present, `calc` literals are checked — when absent, any code passes).
  - `FullCircle.PayScript.calc_deps(source) :: {:ok, [String.t()]} | {:error, Error.t()}` — unique `calc("...")` codes referenced.
  - `FullCircle.PayScript.check_cycles(%{code => source}) :: :ok | {:error, Error.t()}` — parses every source, builds the dependency graph, errors on cycles and on references to codes missing from the map.
  - Rules enforced: unknown identifiers (bindings may reference schema variables and earlier bindings only), unknown functions, builtin arity, `lookup` table/column must be **string literals** and exist in `schema.tables`, `ytd_sum` takes exactly one `code:`/`type:`/`name:` keyword whose value is a string literal or non-empty list of string literals, `calc` argument must be a string literal.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/full_circle/pay_script/validator_test.exs
defmodule FullCircle.PayScript.ValidatorTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript
  alias FullCircle.PayScript.Error

  @schema %{
    tables: %{"socso" => ["wage_from", "wage_to", "employer", "employee"]},
    calcs: ["epf_employee", "epf_relief_cap"]
  }

  defp errors(source, schema \\ @schema) do
    {:error, errs} = PayScript.validate(source, schema)
    Enum.map(errs, &Exception.message/1)
  end

  test "a correct script validates" do
    script = """
    base = wages + bonus
    result = if(age >= 60, 0, lookup("socso", base, "employee"))
    """

    assert :ok = PayScript.validate(script, @schema)
  end

  test "standard variables are known by default; unknown identifiers are reported per binding" do
    assert ["in 'result': unknown identifier 'wage'"] = errors("result = wage + 1")
  end

  test "bindings can reference earlier bindings but not later ones" do
    assert :ok = PayScript.validate("a = wages\nresult = a", @schema)
    assert ["in 'a': unknown identifier 'b'" | _] = errors("a = b\nb = 1\nresult = a")
  end

  test "unknown function and wrong builtin arity" do
    assert ["in 'result': unknown function 'sqrt'"] = errors("result = sqrt(4)")
    assert ["in 'result': min() takes 2 argument(s), got 1"] = errors("result = min(1)")
  end

  test "lookup table and column must be literals that exist" do
    assert ["in 'result': unknown table 'nope'"] = errors(~s|result = lookup("nope", 1, "employee")|)
    assert ["in 'result': unknown column 'nope' in table 'socso'"] =
             errors(~s|result = lookup("socso", 1, "nope")|)
    assert ["in 'result': lookup() table and column must be string literals"] =
             errors(~s|result = lookup("so" + "cso", 1, "employee")|)
  end

  test "without schema tables, lookup literals are not checked" do
    assert :ok = PayScript.validate(~s|result = lookup("anything", 1, "col")|, %{})
  end

  test "ytd_sum argument shape" do
    assert :ok = PayScript.validate(~s|result = ytd_sum(code: "x")|, %{})
    assert :ok = PayScript.validate(~s|result = ytd_sum(name: ["a", "b"])|, %{})

    assert ["in 'result': ytd_sum expects a single 'code:', 'type:' or 'name:' argument"] =
             errors(~s|result = ytd_sum("x")|, %{})

    assert ["in 'result': ytd_sum name: must be a string or list of strings"] =
             errors(~s|result = ytd_sum(name: [1])|, %{})
  end

  test "calc code checked against schema when given" do
    assert :ok = PayScript.validate(~s|result = calc("epf_employee")|, @schema)
    assert ["in 'result': unknown calc 'nope'"] = errors(~s|result = calc("nope")|)
    assert ["in 'result': calc() argument must be a string literal"] =
             errors("result = calc(wages)", %{})
  end

  test "multiple errors are all collected" do
    errs = errors("a = boom\nresult = sqrt(a)")
    assert length(errs) == 2
  end

  test "parse errors come back as a single-element error list" do
    assert {:error, [%Error{}]} = PayScript.validate("result = 1 +", %{})
  end

  test "calc_deps returns unique referenced codes" do
    script = """
    a = calc("epf_employee") + calc("epf_relief_cap")
    result = a + calc("epf_employee")
    """

    assert {:ok, deps} = PayScript.calc_deps(script)
    assert Enum.sort(deps) == ["epf_employee", "epf_relief_cap"]
  end

  test "check_cycles passes an acyclic set" do
    assert :ok =
             PayScript.check_cycles(%{
               "pcb_employee" => ~s(result = calc("epf_employee")),
               "epf_employee" => "result = wages * 0.11"
             })
  end

  test "check_cycles reports a cycle" do
    assert {:error, %Error{message: msg}} =
             PayScript.check_cycles(%{
               "a" => ~s(result = calc("b")),
               "b" => ~s(result = calc("a"))
             })

    assert msg =~ "calc cycle:"
  end

  test "check_cycles reports self-reference" do
    assert {:error, %Error{message: msg}} =
             PayScript.check_cycles(%{"a" => ~s(result = calc("a"))})

    assert msg =~ "calc cycle:"
  end

  test "check_cycles reports references to missing calcs" do
    assert {:error, %Error{message: msg}} =
             PayScript.check_cycles(%{"a" => ~s(result = calc("ghost"))})

    assert msg =~ "references unknown calc 'ghost'"
  end

  test "check_cycles reports which calc failed to parse" do
    assert {:error, %Error{message: msg}} = PayScript.check_cycles(%{"bad" => "result = 1 +"})
    assert msg =~ "in calc 'bad'"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/full_circle/pay_script/validator_test.exs`
Expected: FAIL — `PayScript.validate/2` undefined (UndefinedFunctionError).

- [ ] **Step 3: Implement the validator and public API functions**

```elixir
# lib/full_circle/pay_script/validator.ex
defmodule FullCircle.PayScript.Validator do
  @moduledoc false

  alias FullCircle.PayScript.Error

  @builtins %{
    "min" => 2,
    "max" => 2,
    "ceil" => 1,
    "floor" => 1,
    "abs" => 1,
    "round" => 2,
    "lookup" => 3,
    "ytd_sum" => 1,
    "calc" => 1
  }
  @ytd_keys ~w(code type name)

  def validate(bindings, schema) do
    known0 = MapSet.new(Map.get(schema, :variables, []))

    {errors, _known} =
      Enum.reduce(bindings, {[], known0}, fn {name, expr}, {errs, known} ->
        new_errs = expr |> walk(known, schema) |> Enum.map(&%{&1 | binding: name})
        {errs ++ new_errs, MapSet.put(known, name)}
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  def calc_deps(bindings) do
    bindings |> Enum.flat_map(fn {_name, expr} -> deps(expr) end) |> Enum.uniq()
  end

  # -- AST walk -----------------------------------------------------------------

  defp walk({:num, _}, _known, _schema), do: []
  defp walk({:str, _}, _known, _schema), do: []
  defp walk({:bool, _}, _known, _schema), do: []
  defp walk({:list, items}, known, schema), do: Enum.flat_map(items, &walk(&1, known, schema))

  defp walk({:var, name}, known, _schema) do
    if MapSet.member?(known, name),
      do: [],
      else: [%Error{message: "unknown identifier '#{name}'"}]
  end

  defp walk({:neg, e}, known, schema), do: walk(e, known, schema)
  defp walk({:not, e}, known, schema), do: walk(e, known, schema)

  defp walk({:binop, _op, l, r}, known, schema),
    do: walk(l, known, schema) ++ walk(r, known, schema)

  defp walk({:if, c, t, e}, known, schema),
    do: walk(c, known, schema) ++ walk(t, known, schema) ++ walk(e, known, schema)

  defp walk({:kw, _key, e}, known, schema), do: walk(e, known, schema)

  defp walk({:call, "lookup", args}, known, schema),
    do: walk_args(args, known, schema) ++ check_lookup(args, schema)

  defp walk({:call, "ytd_sum", args}, known, schema),
    do: walk_args(args, known, schema) ++ check_ytd(args)

  defp walk({:call, "calc", args}, known, schema),
    do: walk_args(args, known, schema) ++ check_calc(args, schema)

  defp walk({:call, name, args}, known, schema) do
    arity_errors =
      case Map.fetch(@builtins, name) do
        {:ok, arity} when length(args) == arity ->
          []

        {:ok, arity} ->
          [%Error{message: "#{name}() takes #{arity} argument(s), got #{length(args)}"}]

        :error ->
          [%Error{message: "unknown function '#{name}'"}]
      end

    arity_errors ++ walk_args(args, known, schema)
  end

  defp walk_args(args, known, schema), do: Enum.flat_map(args, &walk(&1, known, schema))

  # -- builtin-specific checks ----------------------------------------------------

  defp check_lookup([{:str, table}, _value, {:str, column}], schema) do
    case Map.get(schema, :tables) do
      nil ->
        []

      tables ->
        case Map.fetch(tables, table) do
          {:ok, columns} ->
            if column in columns,
              do: [],
              else: [%Error{message: "unknown column '#{column}' in table '#{table}'"}]

          :error ->
            [%Error{message: "unknown table '#{table}'"}]
        end
    end
  end

  defp check_lookup([_, _, _], _schema),
    do: [%Error{message: "lookup() table and column must be string literals"}]

  defp check_lookup(args, _schema),
    do: [%Error{message: "lookup() takes 3 argument(s), got #{length(args)}"}]

  defp check_ytd([{:kw, key, value}]) when key in @ytd_keys do
    case value do
      {:str, _} ->
        []

      {:list, items} when items != [] ->
        if Enum.all?(items, &match?({:str, _}, &1)),
          do: [],
          else: [%Error{message: "ytd_sum #{key}: must be a string or list of strings"}]

      _ ->
        [%Error{message: "ytd_sum #{key}: must be a string or list of strings"}]
    end
  end

  defp check_ytd(_args),
    do: [%Error{message: "ytd_sum expects a single 'code:', 'type:' or 'name:' argument"}]

  defp check_calc([{:str, code}], schema) do
    case Map.get(schema, :calcs) do
      nil ->
        []

      known ->
        if code in known, do: [], else: [%Error{message: "unknown calc '#{code}'"}]
    end
  end

  defp check_calc([_], _schema),
    do: [%Error{message: "calc() argument must be a string literal"}]

  defp check_calc(args, _schema),
    do: [%Error{message: "calc() takes 1 argument(s), got #{length(args)}"}]

  # -- calc dependency extraction ---------------------------------------------------

  defp deps({:call, "calc", [{:str, code}]}), do: [code]
  defp deps({:call, _name, args}), do: Enum.flat_map(args, &deps/1)
  defp deps({:binop, _op, l, r}), do: deps(l) ++ deps(r)
  defp deps({:if, c, t, e}), do: deps(c) ++ deps(t) ++ deps(e)
  defp deps({:neg, e}), do: deps(e)
  defp deps({:not, e}), do: deps(e)
  defp deps({:kw, _key, e}), do: deps(e)
  defp deps({:list, items}), do: Enum.flat_map(items, &deps/1)
  defp deps(_), do: []
end
```

Add to `lib/full_circle/pay_script.ex` (inside the module, after `eval/3`; also add `Validator` to the existing `alias FullCircle.PayScript.{...}` line):

```elixir
  @doc """
  Save-time validation. Schema keys (all optional): `:variables` (defaults to
  `standard_variables/0`), `:tables` (`%{code => [columns]}`), `:calcs` (`[codes]`).
  Returns `:ok` or `{:error, [Error.t()]}`.
  """
  def validate(source, schema \\ %{}) when is_binary(source) do
    schema = Map.put_new(schema, :variables, @standard_variables)

    case parse(source) do
      {:ok, bindings} -> Validator.validate(bindings, schema)
      {:error, %Error{} = e} -> {:error, [e]}
    end
  end

  @doc "Unique `calc(\"...\")` codes a script references."
  def calc_deps(source) when is_binary(source) do
    with {:ok, bindings} <- parse(source), do: {:ok, Validator.calc_deps(bindings)}
  end

  @doc """
  Given `%{code => source}` for a complete calc set, errors on `calc()` cycles
  and on references to codes missing from the map.
  """
  def check_cycles(sources) when is_map(sources) do
    with {:ok, graph} <- build_graph(sources) do
      Enum.reduce_while(Map.keys(graph), :ok, fn code, :ok ->
        case dfs(code, graph, [code]) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp build_graph(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn {code, source}, {:ok, acc} ->
      case calc_deps(source) do
        {:ok, deps} ->
          {:cont, {:ok, Map.put(acc, code, deps)}}

        {:error, %Error{} = e} ->
          {:halt, {:error, %{e | message: "in calc '#{code}': #{e.message}"}}}
      end
    end)
  end

  defp dfs(code, graph, path) do
    Enum.reduce_while(Map.get(graph, code, []), :ok, fn dep, :ok ->
      cond do
        dep in path ->
          cycle = Enum.reverse([dep | path]) |> Enum.join(" -> ")
          {:halt, {:error, %Error{message: "calc cycle: #{cycle}"}}}

        not Map.has_key?(graph, dep) ->
          {:halt, {:error, %Error{message: "calc '#{code}' references unknown calc '#{dep}'"}}}

        true ->
          case dfs(dep, graph, [dep | path]) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
      end
    end)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/full_circle/pay_script/validator_test.exs`
Expected: all tests PASS. Then run the whole engine suite: `mix test test/full_circle/pay_script/ test/full_circle/pay_script_test.exs` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/pay_script/validator.ex lib/full_circle/pay_script.ex test/full_circle/pay_script/validator_test.exs
git commit -m "feat(payscript): save-time validation, calc deps and cycle detection"
```

---

### Task 6: Acceptance — reference statutory scripts

These scripts are the executable proof that PayScript can express every current statutory calculation, and become the seed templates in Phase 2. Expected values are hand-computed from `lib/full_circle/salary_note_cal_func.ex` current behavior.

**Files:**
- Test: `test/full_circle/pay_script_acceptance_test.exs`

**Interfaces:**
- Consumes: `PayScript.eval/3`, `PayScript.validate/2`, `FullCircle.PayScriptStubEnv` (Task 4/5 shapes).
- Produces: nothing new — acceptance coverage only.

- [ ] **Step 1: Write the acceptance tests**

```elixir
# test/full_circle/pay_script_acceptance_test.exs
defmodule FullCircle.PayScriptAcceptanceTest do
  use ExUnit.Case, async: true

  alias FullCircle.PayScript
  alias FullCircle.PayScriptStubEnv

  # Real rows copied from salary_note_cal_func.ex socso_table/0 (post-SKBBK)
  @socso %{
    columns: ["wage_from", "wage_to", "employer", "employee", "employer_only", "employee_24hour"],
    rows: [
      [2900.0, 3000.0, 51.65, 14.75, 36.9, 22.15],
      [4900.0, 5000.0, 86.65, 24.75, 61.9, 37.15],
      [6000.0, 999_999.0, 104.15, 29.75, 74.4, 44.65]
    ]
  }

  # Full pcb_table_normal/0 with named columns
  @pcb_normal %{
    columns: ["p_from", "p_to", "m", "r", "b13", "b2"],
    rows: [
      [5001.0, 20_000.0, 5000.0, 0.01, -400.0, -800.0],
      [20_001.0, 35_000.0, 20_000.0, 0.03, -250.0, -650.0],
      [35_001.0, 50_000.0, 35_000.0, 0.06, 600.0, 600.0],
      [50_001.0, 70_000.0, 50_000.0, 0.11, 1500.0, 1500.0],
      [70_001.0, 100_000.0, 70_000.0, 0.19, 3700.0, 3700.0],
      [100_001.0, 400_000.0, 100_000.0, 0.25, 9400.0, 9400.0],
      [400_001.0, 600_000.0, 400_000.0, 0.26, 84_400.0, 84_400.0],
      [600_001.0, 2_000_000.0, 600_000.0, 0.28, 136_400.0, 136_400.0],
      [2_000_000.01, 999_999_999.0, 2_000_000.0, 0.3, 528_400.0, 528_400.0]
    ]
  }

  @epf_employer_script """
  total = wages + bonus
  rate = if(total <= 10, 0,
         if(not malaysian, 0.02,
         if(age >= 60, 0.04,
         if(total <= 5000, 0.13, 0.12))))
  result = ceil(total * rate)
  """

  @epf_employee_script """
  total = wages + bonus
  rate = if(total <= 10, 0,
         if(not malaysian, 0.02,
         if(age >= 60, 0, 0.11)))
  result = ceil(total * rate)
  """

  @socso_employee_script """
  result = if(age >= 60, 0, lookup("socso", wages, "employee"))
  """

  @socso_24hour_script """
  result = lookup("socso", wages, "employee_24hour")
  """

  @pcb_script """
  cap = calc("epf_relief_cap")
  y   = ytd_sum(type: "Addition") + ytd_sum(name: "Employee Current Year Income")
  k   = min(ytd_sum(name: ["EPF By Employee", "EPF By Employee Current Year"]), cap)
  y1  = wages
  k1  = if(k >= cap, 0, min(calc("epf_employee"), cap - k))
  y2  = y1
  n   = 12 - pay_month
  k2  = if(k + k1 == 0, 0, if(k + k1 * n >= cap, 0, cap - (k + k1 * n)))
  yt  = bonus
  kt  = if(k + k1 + k2 == 0, 0,
        if(k + k1 + k2 >= cap, 0, min(calc("epf_employee"), cap - (k + k1 + k2))))
  d   = calc("pcb_individual_deduction")
  s   = if(marital_status == "Married" and not partner_working,
           calc("pcb_spouse_deduction"), 0)
  q   = calc("pcb_child_deduction")
  p   = y - k + (y1 - k1) + (y2 - k2) * n + (yt - kt) - (d + s + q * children)
  m   = lookup("pcb_normal", p, "m")
  r   = lookup("pcb_normal", p, "r")
  b   = if(marital_status == "Married" and not partner_working,
           lookup("pcb_normal", p, "b2"),
           lookup("pcb_normal", p, "b13"))
  x   = ytd_sum(name: ["Employee PCB", "PCB Current Year"])
  z   = ytd_sum(name: ["Employee Zakat", "Zakat Current Year"])
  pcb = ((p - m) * r + b - (z + x)) / (n + 1)
  result = if(pcb > 0, round(pcb, 1), 0)
  """

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        "wages" => 5000.0,
        "bonus" => 0.0,
        "age" => 35,
        "malaysian" => true,
        "nationality" => "Malaysian",
        "marital_status" => "Married",
        "partner_working" => false,
        "children" => 2,
        "pay_month" => 6,
        "pay_year" => 2026,
        "service_years" => 10
      },
      overrides
    )
  end

  defp env(overrides \\ %{}) do
    state =
      Map.merge(
        %{
          tables: %{"socso" => @socso, "pcb_normal" => @pcb_normal},
          ytd: %{
            {:type, ["Addition"]} => 25_000.0,
            {:name, ["EPF By Employee", "EPF By Employee Current Year"]} => 2_750.0,
            {:name, ["Employee PCB", "PCB Current Year"]} => 400.0
          },
          calcs: %{
            "epf_employee" => 550.0,
            "epf_relief_cap" => 4_000.0,
            "pcb_individual_deduction" => 9_000.0,
            "pcb_spouse_deduction" => 4_000.0,
            "pcb_child_deduction" => 2_000.0
          }
        },
        overrides
      )

    {PayScriptStubEnv, state}
  end

  defp assert_eval(script, ctx, env_tuple, expected) do
    assert {:ok, dec} = PayScript.eval(script, ctx, env_tuple)

    assert Decimal.equal?(dec, Decimal.new(expected)),
           "expected #{expected}, got #{Decimal.to_string(dec)}"
  end

  test "all reference scripts pass validation with a full schema" do
    schema = %{
      tables: %{
        "socso" => @socso.columns,
        "pcb_normal" => @pcb_normal.columns
      },
      calcs: ~w(epf_employee epf_relief_cap pcb_individual_deduction
                pcb_spouse_deduction pcb_child_deduction)
    }

    for script <- [
          @epf_employer_script,
          @epf_employee_script,
          @socso_employee_script,
          @socso_24hour_script,
          @pcb_script
        ] do
      assert :ok = PayScript.validate(script, schema)
    end
  end

  describe "epf_employer (parity with calculate_value(:epf_employer, ...))" do
    test "malaysian under 60, wages <= 5000 -> 13%" do
      # ceil(5000 * 0.13) = 650
      assert_eval(@epf_employer_script, context(), env(), "650.0")
    end

    test "malaysian under 60, wages > 5000 -> 12%" do
      # ceil(6000 * 0.12) = 720
      assert_eval(@epf_employer_script, context(%{"wages" => 6000.0}), env(), "720.0")
    end

    test "malaysian 60+ -> 4%" do
      # ceil(5000 * 0.04) = 200
      assert_eval(@epf_employer_script, context(%{"age" => 60}), env(), "200.0")
    end

    test "non-malaysian (any age) -> 2%" do
      # ceil(5000 * 0.02) = 100
      assert_eval(
        @epf_employer_script,
        context(%{"malaysian" => false, "age" => 65}),
        env(),
        "100.0"
      )
    end

    test "income <= 10 -> 0" do
      assert_eval(@epf_employer_script, context(%{"wages" => 10.0}), env(), "0.0")
    end
  end

  describe "epf_employee (parity with calculate_value(:epf_employee, ...))" do
    test "malaysian under 60 -> 11%" do
      # ceil(5000 * 0.11) = 550
      assert_eval(@epf_employee_script, context(), env(), "550.0")
    end

    test "malaysian 60+ -> 0" do
      assert_eval(@epf_employee_script, context(%{"age" => 61}), env(), "0.0")
    end

    test "non-malaysian -> 2%" do
      assert_eval(@epf_employee_script, context(%{"malaysian" => false}), env(), "100.0")
    end
  end

  describe "socso scripts (parity with socso_table lookups)" do
    test "socso_employee at wages 2950 -> 14.75; 60+ -> 0" do
      assert_eval(@socso_employee_script, context(%{"wages" => 2950.0}), env(), "14.75")
      assert_eval(@socso_employee_script, context(%{"wages" => 2950.0, "age" => 60}), env(), "0.0")
    end

    test "socso_24hour applies regardless of age, ceiling bracket above 6000" do
      assert_eval(@socso_24hour_script, context(%{"wages" => 2950.0, "age" => 61}), env(), "22.15")
      assert_eval(@socso_24hour_script, context(%{"wages" => 20_000.0}), env(), "44.65")
    end
  end

  describe "pcb_employee (parity with calculate_value(:pcb_employee, ...))" do
    test "married, partner not working, 2 children, mid-year" do
      # Hand-computed against salary_note_cal_func.ex:
      # cap=4000 y=25000 k=min(2750,4000)=2750 y1=5000
      # k1=min(550, 4000-2750=1250)=550 y2=5000 n=6
      # k2: k+k1*n = 2750+3300 = 6050 >= 4000 -> 0
      # yt=0 kt: k+k1+k2=3300 < 4000 -> min(550, 700)=550
      # d=9000 s=4000 q=2000
      # p = 25000-2750 + 4450 + 5000*6 + (0-550) - (9000+4000+4000)
      #   = 22250 + 4450 + 30000 - 550 - 17000 = 39150
      # bracket [35001, 50000]: m=35000 r=0.06 b2=600
      # pcb = ((39150-35000)*0.06 + 600 - (0+400)) / 7 = 449/7 = 64.142857 -> 64.1
      assert_eval(@pcb_script, context(), env(), "64.1")
    end

    test "negative PCB clamps to 0" do
      # Low income: y=0 ytd, wages 1000 -> p far below first bracket, lookup -> 0s
      # pcb = ((p-0)*0 + 0 - 400)/7 < 0 -> 0
      low_env =
        env(%{
          ytd: %{
            {:type, ["Addition"]} => 0.0,
            {:name, ["EPF By Employee", "EPF By Employee Current Year"]} => 0.0,
            {:name, ["Employee PCB", "PCB Current Year"]} => 400.0
          },
          calcs: %{
            "epf_employee" => 110.0,
            "epf_relief_cap" => 4_000.0,
            "pcb_individual_deduction" => 9_000.0,
            "pcb_spouse_deduction" => 4_000.0,
            "pcb_child_deduction" => 2_000.0
          }
        })

      assert_eval(@pcb_script, context(%{"wages" => 1000.0}), low_env, "0.0")
    end

    test "runtime error in December is avoided: n + 1 = 1, no division by zero" do
      # pay_month = 12 -> n = 0 -> divides by n + 1 = 1: must succeed
      assert {:ok, _dec} = PayScript.eval(@pcb_script, context(%{"pay_month" => 12}), env())
    end
  end

  test "a genuinely broken script surfaces a named runtime error" do
    assert {:error, err} =
             PayScript.eval("boom = 1 / (wages - wages)\nresult = boom", context(), env())

    assert Exception.message(err) == "in 'boom': division by zero"
  end
end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/full_circle/pay_script_acceptance_test.exs`
Expected: all tests PASS with **no implementation changes**. If any fail, the engine (not the test) is wrong — debug the engine using superpowers:systematic-debugging; the expected values above are derived from `salary_note_cal_func.ex` and must not be adjusted to fit.

- [ ] **Step 3: Run the full engine suite plus existing HR tests for regressions**

Run: `mix test test/full_circle/pay_script/ test/full_circle/pay_script_test.exs test/full_circle/pay_script_acceptance_test.exs`
Expected: all PASS. (Nothing in existing app code was modified in this phase, so the wider suite is unaffected; the 2 pre-existing `pay_run_test` failures are known and unrelated.)

- [ ] **Step 4: Commit**

```bash
git add test/full_circle/pay_script_acceptance_test.exs
git commit -m "test(payscript): acceptance suite with reference statutory scripts"
```

---

## Out of scope for this plan (later phases)

- DB schemas, migrations, seeding, the real `Env` implementation (Phase 2 — the reference scripts in Task 6 become the seed templates).
- `calculate_pay/2` dispatch changes, `SalaryType` validation, reporting (Phase 2/3).
- Admin LiveViews, bundle export/import, `mix statutory.validate` (Phase 2/3).
- FileSpec (Phase 4).
