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

  test "string builtins" do
    ctx = %{"name" => " ali ", "id" => "a-b"}

    assert {:ok, " ALI "} = eval_expr(~s|upper(name)|, ctx)
    assert {:ok, " ali "} = eval_expr(~s|lower(name)|, ctx)
    assert {:ok, "ali"} = eval_expr(~s|trim(name)|, ctx)
    assert {:ok, "axb"} = eval_expr(~s|replace(id, "-", "x")|, ctx)
  end

  test "string builtin type errors" do
    assert {:error, %Error{message: msg}} = eval_expr(~s|upper(1)|, %{})
    assert msg =~ "expected a string"
  end

  defp eval_expr(source, context) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, expr} = Parser.parse_expression(tokens)
    Evaluator.eval(expr, context, nil)
  end
end
