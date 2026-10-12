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
