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
      assert {:binop, :or,
              {:binop, :and, {:not, {:binop, :gt, {:var, "a"}, {:num, 1.0}}}, {:var, "b"}},
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
      assert {:ok,
              [
                {"a", {:num, 1.0}},
                {"b", {:binop, :add, {:var, "a"}, {:num, 2.0}}},
                {"result", {:var, "b"}}
              ]} =
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
