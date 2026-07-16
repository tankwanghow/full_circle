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

  def parse_expression(tokens) do
    with {:ok, expr, rest} <- parse_expr(tokens),
         :ok <- expect_end_of_expression(rest) do
      {:ok, expr}
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
    do:
      {:error,
       %Error{line: tok_line(tok), message: "expected end of line, got #{tok_label(tok)}"}}

  defp expect_end_of_expression([{:eof, _}]), do: :ok

  defp expect_end_of_expression([tok | _]),
    do: {:error, %Error{line: tok_line(tok), message: "expected end of expression"}}

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
