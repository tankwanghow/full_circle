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
    assert {:error, %Error{line: 1, message: "unterminated string"}} =
             Lexer.tokenize(~s(a = "oops))
  end

  test "Error message includes line or binding prefix" do
    assert Exception.message(%Error{line: 3, message: "boom"}) == "line 3: boom"
    assert Exception.message(%Error{binding: "k1", message: "boom"}) == "in 'k1': boom"
    assert Exception.message(%Error{message: "boom"}) == "boom"
  end
end
