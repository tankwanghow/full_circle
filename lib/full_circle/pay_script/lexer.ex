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
