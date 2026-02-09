defmodule FullCircleWeb.LogLive.DeltaDiff do
  @moduledoc """
  Structural parser and differ for log delta strings.

  Delta strings use `&^key: value^&` markers with `[nested]` blocks.
  This module parses them into nested maps and produces field-by-field
  diff entries for clean rendering.
  """

  @doc """
  Parse a delta string into a nested map.

  Returns `%{}` for nil/empty, `%{"raw_content" => delta}` for unformatted legacy deltas.

  ## Examples

      iex> parse("&^name: Alice^& &^age: 30^&")
      %{"name" => "Alice", "age" => "30"}

      iex> parse("&^details: [&^0: [&^qty: 5^&]^&]^&")
      %{"details" => %{"0" => %{"qty" => "5"}}}
  """
  def parse(nil), do: %{}
  def parse(""), do: %{}

  def parse(delta) when is_binary(delta) do
    if formatted?(delta) do
      parse_fields(delta)
    else
      %{"raw_content" => delta}
    end
  end

  @doc """
  Diff two parsed maps, returning a list of diff entry maps.

  Each entry has `:key`, `:status`, and value fields depending on status:
  - `:unchanged` — `%{key, status: :unchanged, value}`
  - `:changed` — `%{key, status: :changed, old_value, new_value}`
  - `:added` — `%{key, status: :added, value}`
  - `:removed` — `%{key, status: :removed, value}`
  - `:nested` — `%{key, status: :nested, children}` (children is recursive diff list)
  - `:added_nested` — `%{key, status: :added_nested, value}` (value is the nested map)
  - `:removed_nested` — `%{key, status: :removed_nested, value}` (value is the nested map)
  """
  def diff(old_map, new_map) when is_map(old_map) and is_map(new_map) do
    all_keys =
      (Map.keys(old_map) ++ Map.keys(new_map))
      |> Enum.uniq()
      |> sort_keys()

    Enum.map(all_keys, fn key ->
      old_val = Map.get(old_map, key)
      new_val = Map.get(new_map, key)
      diff_entry(key, old_val, new_val)
    end)
  end

  # --- Parsing internals ---

  defp formatted?(delta) do
    String.contains?(delta, "&^") and String.contains?(delta, "^&")
  end

  defp parse_fields(str) do
    extract_pairs(str)
    |> Map.new()
  end

  # Extract all &^key: value^& pairs at the current nesting level.
  # Value may contain nested [...] blocks which we parse recursively.
  defp extract_pairs(str) do
    do_extract_pairs(str, [])
  end

  defp do_extract_pairs("", acc), do: Enum.reverse(acc)

  defp do_extract_pairs(str, acc) do
    case find_next_field(str) do
      nil ->
        Enum.reverse(acc)

      {key, value, rest} ->
        parsed_value = parse_value(value)
        do_extract_pairs(rest, [{key, parsed_value} | acc])
    end
  end

  # Find the next &^key: value^& field, handling nested brackets.
  defp find_next_field(str) do
    case :binary.match(str, "&^") do
      :nomatch ->
        nil

      {start, 2} ->
        after_marker = binary_part(str, start + 2, byte_size(str) - start - 2)

        case String.split(after_marker, ": ", parts: 2) do
          [key, rest_with_value] ->
            {value, rest} = extract_value(rest_with_value, 0, "")
            {String.trim(key), value, rest}

          _ ->
            nil
        end
    end
  end

  # Extract the value portion, tracking bracket depth so we don't terminate
  # on a ^& that belongs to a nested field.
  defp extract_value("", _depth, acc), do: {String.trim(acc), ""}

  defp extract_value("^&" <> rest, 0, acc) do
    {String.trim(acc), rest}
  end

  defp extract_value("[" <> rest, depth, acc) do
    extract_value(rest, depth + 1, acc <> "[")
  end

  defp extract_value("]" <> rest, depth, acc) when depth > 0 do
    extract_value(rest, depth - 1, acc <> "]")
  end

  defp extract_value(<<c::utf8, rest::binary>>, depth, acc) do
    extract_value(rest, depth, acc <> <<c::utf8>>)
  end

  # If the value is a bracketed block, recursively parse it.
  defp parse_value(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]") do
      inner = String.slice(trimmed, 1..(String.length(trimmed) - 2)//1)
      parse_fields(inner)
    else
      trimmed
    end
  end

  # --- Diffing internals ---

  # Sort keys with numeric awareness: "0" < "1" < "10" < "a" < "b"
  defp sort_keys(keys) do
    Enum.sort(keys, fn a, b ->
      case {Integer.parse(a), Integer.parse(b)} do
        {{int_a, ""}, {int_b, ""}} -> int_a <= int_b
        {{_, ""}, _} -> true
        {_, {_, ""}} -> false
        _ -> a <= b
      end
    end)
  end

  defp diff_entry(key, nil, new_val) when is_map(new_val) do
    %{key: key, status: :added_nested, value: new_val}
  end

  defp diff_entry(key, nil, new_val) do
    %{key: key, status: :added, value: new_val}
  end

  defp diff_entry(key, old_val, nil) when is_map(old_val) do
    %{key: key, status: :removed_nested, value: old_val}
  end

  defp diff_entry(key, old_val, nil) do
    %{key: key, status: :removed, value: old_val}
  end

  defp diff_entry(key, old_val, new_val) when is_map(old_val) and is_map(new_val) do
    children = diff(old_val, new_val)

    if all_unchanged?(children) do
      %{key: key, status: :nested, children: children}
    else
      %{key: key, status: :nested, children: children}
    end
  end

  defp diff_entry(key, old_val, new_val) when is_map(old_val) do
    %{key: key, status: :changed, old_value: inspect_map(old_val), new_value: new_val}
  end

  defp diff_entry(key, old_val, new_val) when is_map(new_val) do
    %{key: key, status: :changed, old_value: old_val, new_value: inspect_map(new_val)}
  end

  defp diff_entry(key, old_val, new_val) when old_val == new_val do
    %{key: key, status: :unchanged, value: old_val}
  end

  defp diff_entry(key, old_val, new_val) do
    %{key: key, status: :changed, old_value: old_val, new_value: new_val}
  end

  defp all_unchanged?(entries) do
    Enum.all?(entries, fn
      %{status: :unchanged} -> true
      %{status: :nested, children: children} -> all_unchanged?(children)
      _ -> false
    end)
  end

  defp inspect_map(map), do: inspect(map)

  @doc """
  Flatten a parsed nested map into a flat list of `{key, value}` display pairs,
  useful for rendering added_nested / removed_nested blocks.
  """
  def flatten_map(map, prefix \\ "") do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.flat_map(fn
      {k, v} when is_map(v) ->
        label = if prefix == "", do: k, else: "#{prefix}.#{k}"
        flatten_map(v, label)

      {k, v} ->
        label = if prefix == "", do: k, else: "#{prefix}.#{k}"
        [{label, v}]
    end)
  end
end
