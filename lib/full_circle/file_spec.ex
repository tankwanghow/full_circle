defmodule FullCircle.FileSpec do
  @moduledoc """
  Validates and renders statutory file format specs (jsonb documents).
  """

  alias FullCircle.PayScript
  alias FullCircle.PayScript.{Error, Validator}

  @default_line_ending "\r\n"
  @section_kinds ~w(header detail footer)

  @doc """
  Validates a spec map. `variables` is the list of allowed PayScript identifiers
  (detail-row keys plus header context keys).
  """
  def validate(spec, variables) when is_map(spec) and is_list(variables) do
    errors =
      []
      |> validate_top_level(spec)
      |> validate_sections(spec, variables)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Renders a spec against detail rows and header/footer context.
  """
  def render(spec, rows, header_ctx) when is_map(spec) and is_list(rows) and is_map(header_ctx) do
    with :ok <- validate(spec, detail_variables(rows, header_ctx)),
         {:ok, prepared} <- prepare_rows(rows, header_ctx),
         {:ok, lines} <- render_sections(spec, prepared, header_ctx) do
      ending = line_ending(spec)
      text = Enum.join(lines, ending) <> ending
      {:ok, text}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, errors} when is_list(errors) -> {:error, Enum.join(errors, "; ")}
    end
  end

  defp detail_variables(rows, header_ctx) do
    row_keys =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&to_string/1)

    (row_keys ++ Map.keys(header_ctx))
    |> Enum.uniq()
  end

  defp validate_top_level(errors, spec) do
    errors
    |> validate_renderer(spec)
    |> validate_line_ending(spec)
    |> validate_delimiter(spec)
  end

  defp validate_renderer(errors, %{"renderer" => "text"}), do: errors

  defp validate_renderer(errors, %{"renderer" => other}),
    do: ["renderer must be \"text\", got #{inspect(other)}" | errors]

  defp validate_renderer(errors, _), do: ["renderer is required" | errors]

  defp validate_line_ending(errors, spec) do
    case Map.get(spec, "line_ending", @default_line_ending) do
      ending when is_binary(ending) -> errors
      other -> ["line_ending must be a string, got #{inspect(other)}" | errors]
    end
  end

  defp validate_delimiter(errors, spec) do
    case Map.get(spec, "delimiter") do
      nil -> errors
      d when is_binary(d) and byte_size(d) > 0 -> errors
      other -> ["delimiter must be a non-empty string or null, got #{inspect(other)}" | errors]
    end
  end

  defp validate_sections(errors, spec, variables) do
    case Map.get(spec, "sections") do
      sections when is_list(sections) and sections != [] ->
        delimiter = Map.get(spec, "delimiter")

        sections
        |> Enum.with_index(1)
        |> Enum.reduce(errors, fn {section, idx}, acc ->
          acc
          |> validate_section(section, idx, delimiter, variables)
        end)

      [] ->
        ["sections must be a non-empty list" | errors]

      _ ->
        ["sections must be a non-empty list" | errors]
    end
  end

  defp validate_section(errors, section, idx, delimiter, variables) do
    prefix = "section #{idx}"

    cond do
      not is_map(section) ->
        ["#{prefix}: must be a map" | errors]

      not Map.has_key?(section, "kind") ->
        ["#{prefix}: kind is required" | errors]

      section["kind"] not in @section_kinds ->
        ["#{prefix}: kind must be one of #{inspect(@section_kinds)}" | errors]

      section["kind"] == "detail" and section["source"] != "statutory_rows" ->
        ["#{prefix}: detail section requires source \"statutory_rows\"" | errors]

      true ->
        allow_aggregates = section["kind"] in ["header", "footer"]

        errors
        |> validate_filter(section, prefix, variables, allow_aggregates)
        |> validate_sort(section, prefix)
        |> validate_fields(section, prefix, delimiter, variables, allow_aggregates)
    end
  end

  defp validate_filter(errors, %{"filter" => filter}, prefix, variables, allow_aggregates)
       when is_binary(filter) do
    case validate_expression(filter, variables, allow_aggregates) do
      :ok -> errors
      {:error, msgs} -> Enum.map(msgs, &"#{prefix}, filter: #{&1}") ++ errors
    end
  end

  defp validate_filter(errors, _, _, _, _), do: errors

  defp validate_sort(errors, %{"sort" => sort}, _prefix) when is_binary(sort), do: errors

  defp validate_sort(errors, %{"sort" => _}, prefix),
    do: ["#{prefix}: sort must be a string" | errors]

  defp validate_sort(errors, _, _), do: errors

  defp validate_fields(errors, section, prefix, delimiter, variables, allow_aggregates) do
    case Map.get(section, "fields") do
      fields when is_list(fields) and fields != [] ->
        fields
        |> Enum.with_index(1)
        |> Enum.reduce(errors, fn {field, fidx}, acc ->
          validate_field(field, "#{prefix}, field #{fidx}", delimiter, variables, allow_aggregates) ++
            acc
        end)

      _ ->
        ["#{prefix}: fields must be a non-empty list" | errors]
    end
  end

  defp validate_field(field, prefix, delimiter, variables, allow_aggregates) do
    cond do
      not is_map(field) ->
        ["#{prefix}: must be a map"]

      not Map.has_key?(field, "expr") ->
        ["#{prefix}: expr is required"]

      not is_binary(field["expr"]) ->
        ["#{prefix}: expr must be a string"]

      delimiter != nil and Map.has_key?(field, "width") ->
        ["#{prefix}: width is not allowed when delimiter is set"]

      delimiter == nil and not Map.has_key?(field, "width") ->
        ["#{prefix}: width is required in fixed-width mode"]

      true ->
        []
        |> validate_field_width(field, prefix, delimiter)
        |> validate_field_format(field, prefix)
        |> validate_field_align(field, prefix)
        |> validate_field_pad(field, prefix)
        |> then(fn field_errors ->
          expr_errors =
            case validate_expression(field["expr"], variables, allow_aggregates) do
              :ok -> []
              {:error, msgs} -> Enum.map(msgs, &"#{prefix}: #{&1}")
            end

          field_errors ++ expr_errors
        end)
    end
  end

  defp validate_field_width(errors, _field, _prefix, delimiter) when not is_nil(delimiter), do: errors

  defp validate_field_width(errors, field, prefix, nil) do
    case field["width"] do
      w when is_integer(w) and w > 0 -> errors
      _ -> ["#{prefix}: width must be a positive integer" | errors]
    end
  end

  defp validate_field_format(errors, field, prefix) do
    case Map.get(field, "format", "text") do
      "text" ->
        errors

      "cents" ->
        errors

      "digits" ->
        errors

      <<"date:", pattern::binary>> when byte_size(pattern) > 0 ->
        errors

      <<"decimal:", n::binary>> ->
        case Integer.parse(n) do
          {_, ""} -> errors
          _ -> ["#{prefix}: decimal format requires an integer precision" | errors]
        end

      other ->
        ["#{prefix}: format must be text, cents, digits, decimal:<n>, or date:<pattern>, got #{inspect(other)}" |
          errors]
    end
  end

  defp validate_field_align(errors, field, prefix) do
    case Map.get(field, "align", "left") do
      a when a in ["left", "right"] -> errors
      other -> ["#{prefix}: align must be left or right, got #{inspect(other)}" | errors]
    end
  end

  defp validate_field_pad(errors, field, prefix) do
    case Map.get(field, "pad", " ") do
      p when is_binary(p) and byte_size(p) == 1 -> errors
      other -> ["#{prefix}: pad must be a single character, got #{inspect(other)}" | errors]
    end
  end

  defp validate_expression(source, variables, allow_aggregates) do
    with {:ok, expr} <- PayScript.parse_expression(source),
         :ok <- validate_aggregate_calls(expr, allow_aggregates),
         sanitized = substitute_aggregates_for_validation(expr, %{}),
         :ok <- Validator.validate_expression(sanitized, %{variables: variables}) do
      :ok
    else
      {:error, %Error{} = e} -> {:error, [Exception.message(e)]}
      {:error, errors} when is_list(errors) -> {:error, format_validation_errors(errors)}
      {:error, msg} when is_binary(msg) -> {:error, [msg]}
    end
  end

  defp format_validation_errors(errors) do
    Enum.map(errors, fn
      %Error{} = e -> Exception.message(e)
      msg when is_binary(msg) -> msg
    end)
  end

  defp validate_aggregate_calls(expr, allow_aggregates) do
    expr
    |> aggregate_calls()
    |> case do
      [] ->
        :ok

      calls when allow_aggregates ->
        errors =
          Enum.flat_map(calls, fn
            {:count, []} -> []
            {:count, bad} -> ["count() takes no arguments, got #{length(bad)}"]
            {:sum, col} when is_binary(col) -> []
            {:sum, _} -> ["sum() argument must be a string literal"]
          end)

        if errors == [], do: :ok, else: {:error, errors}

      _calls ->
        {:error, ["aggregate functions are only allowed in header/footer sections"]}
    end
  end

  defp aggregate_calls(expr) do
    walk_calls(expr, [])
  end

  defp walk_calls({:call, "count", args}, acc), do: walk_calls_args(args, [{:count, args} | acc])
  defp walk_calls({:call, "sum", args}, acc), do: walk_calls_args(args, [{:sum, sum_col(args)} | acc])

  defp walk_calls({:neg, e}, acc), do: walk_calls(e, acc)
  defp walk_calls({:not, e}, acc), do: walk_calls(e, acc)
  defp walk_calls({:binop, _, l, r}, acc), do: walk_calls(r, walk_calls(l, acc))
  defp walk_calls({:if, c, t, e}, acc), do: walk_calls(e, walk_calls(t, walk_calls(c, acc)))
  defp walk_calls({:list, items}, acc), do: Enum.reduce(items, acc, &walk_calls/2)
  defp walk_calls({:kw, _, e}, acc), do: walk_calls(e, acc)
  defp walk_calls({:call, _, args}, acc), do: walk_calls_args(args, acc)
  defp walk_calls(_, acc), do: acc

  defp walk_calls_args(args, acc),
    do: Enum.reduce(args, acc, &walk_calls/2)

  defp sum_col([{:str, col}]), do: col
  defp sum_col(_), do: nil

  defp substitute_aggregates_for_validation(expr, aggregates) do
    substitute_aggregates(expr, Map.put_new(aggregates, :count, 0) |> put_empty_sums())
  end

  defp put_empty_sums(%{sums: _} = agg), do: agg
  defp put_empty_sums(agg), do: Map.put(agg, :sums, %{})

  defp prepare_rows(rows, header_ctx) do
    prepared =
      Enum.map(rows, fn row ->
        row
        |> normalize_row()
        |> Map.merge(stringify_map(header_ctx))
      end)

    {:ok, prepared}
  end

  defp normalize_row(row) do
    Map.new(row, fn {k, v} ->
      key = to_string(k)
      {key, normalize_value(v)}
    end)
  end

  defp stringify_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp normalize_value(%Decimal{} = d), do: Decimal.to_float(d)
  defp normalize_value(nil), do: ""
  defp normalize_value(v) when is_atom(v), do: to_string(v)
  defp normalize_value(v), do: v

  defp render_sections(spec, rows, header_ctx) do
    delimiter = Map.get(spec, "delimiter")
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
          render_section(section, rows, filtered_detail, ctx, delimiter, aggregates)
        end)

      {:ok, lines}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp render_section(%{"kind" => "detail"} = section, rows, _filtered_detail, _ctx, delimiter, _aggregates) do
    rows
    |> apply_filter(Map.get(section, "filter"))
    |> apply_sort(Map.get(section, "sort"))
    |> Enum.map(fn row ->
      render_line(section["fields"], row, delimiter, %{count: 0, sums: %{}})
    end)
  end

  defp render_section(section, _rows, _filtered_detail, ctx, delimiter, aggregates) do
    [render_line(section["fields"], ctx, delimiter, aggregates)]
  end

  defp compute_aggregates(rows) do
    sums =
      rows
      |> Enum.reduce(%{}, fn row, acc ->
        Enum.reduce(row, acc, fn {col, val}, sacc ->
          if is_number(val) do
            Map.update(sacc, col, val, &(&1 + val))
          else
            sacc
          end
        end)
      end)

    %{count: length(rows), sums: sums}
  end

  defp apply_filter(rows, nil), do: rows

  defp apply_filter(rows, filter) do
    Enum.filter(rows, fn row ->
      case PayScript.eval_expression(filter, row, nil) do
        {:ok, true} -> true
        {:ok, false} -> false
        {:ok, other} -> raise "filter must evaluate to boolean, got #{inspect(other)}"
        {:error, %Error{} = e} -> raise Exception.message(e)
      end
    end)
  end

  defp apply_sort(rows, nil), do: rows

  defp apply_sort(rows, sort_key) do
    Enum.sort_by(rows, fn row ->
      case Map.get(row, sort_key, "") do
        val when is_binary(val) -> String.downcase(val)
        val -> val
      end
    end)
  end

  defp render_line(fields, ctx, delimiter, aggregates) do
    rendered =
      Enum.map(fields, fn field ->
        render_field(field, ctx, aggregates)
      end)

    if delimiter do
      Enum.join(rendered, delimiter)
    else
      Enum.join(rendered, "")
    end
  end

  defp render_field(field, ctx, aggregates) do
    expr = field["expr"]

    with {:ok, ast} <- PayScript.parse_expression(expr),
         ast = substitute_aggregates(ast, aggregates),
         {:ok, value} <- PayScript.eval_expression(ast, ctx, nil) do
      value
      |> format_value(Map.get(field, "format", "text"))
      |> pad_value(field)
    else
      {:error, %Error{} = e} -> raise Exception.message(e)
    end
  end

  defp substitute_aggregates({:call, "count", []}, %{count: count}), do: {:num, count * 1.0}

  defp substitute_aggregates({:call, "sum", [{:str, col}]}, %{sums: sums}) do
    {:num, Map.get(sums, col, 0) * 1.0}
  end

  defp substitute_aggregates({:neg, e}, agg), do: {:neg, substitute_aggregates(e, agg)}
  defp substitute_aggregates({:not, e}, agg), do: {:not, substitute_aggregates(e, agg)}

  defp substitute_aggregates({:binop, op, l, r}, agg) do
    {:binop, op, substitute_aggregates(l, agg), substitute_aggregates(r, agg)}
  end

  defp substitute_aggregates({:if, c, t, e}, agg) do
    {:if, substitute_aggregates(c, agg), substitute_aggregates(t, agg), substitute_aggregates(e, agg)}
  end

  defp substitute_aggregates({:list, items}, agg),
    do: {:list, Enum.map(items, &substitute_aggregates(&1, agg))}

  defp substitute_aggregates({:kw, key, e}, agg), do: {:kw, key, substitute_aggregates(e, agg)}
  defp substitute_aggregates({:call, name, args}, agg), do: {:call, name, Enum.map(args, &substitute_aggregates(&1, agg))}
  defp substitute_aggregates(other, _agg), do: other

  defp format_value(value, "text"), do: format_text(value)
  defp format_value(value, "cents"), do: format_cents(value)

  defp format_value(value, <<"date:", pattern::binary>>) do
    case value do
      %Date{} = d -> Timex.format!(d, pattern)
      _ -> raise "date format requires a Date value, got #{inspect(value)}"
    end
  end

  defp format_value(value, <<"decimal:", n::binary>>) do
    n = String.to_integer(n)

    value
    |> as_number!()
    |> Float.round(n)
    |> then(fn
      v when n == 0 -> v |> trunc() |> Integer.to_string()
      v -> :erlang.float_to_binary(v, decimals: n)
    end)
  end

  defp format_value(value, "digits") do
    value |> to_string() |> strip_digits()
  end

  defp format_text(value) when is_float(value) or is_integer(value) do
    :erlang.float_to_binary(value * 1.0, [:compact, decimals: 2])
  end

  defp format_text(value), do: to_string(value)

  defp format_cents(value) do
    value
    |> as_number!()
    |> Kernel.*(100)
    |> Float.round(0)
    |> trunc()
    |> Integer.to_string()
  end

  defp pad_value(text, field) do
    if Map.has_key?(field, "width") do
      width = field["width"]
      pad = Map.get(field, "pad", " ")
      align = Map.get(field, "align", "left")

      cond do
        String.length(text) > width and align == "right" and pad == "0" ->
          raise "field value #{inspect(text)} exceeds width #{width}"

        String.length(text) > width ->
          String.slice(text, 0, width)

        align == "right" ->
          String.pad_leading(text, width, pad)

        true ->
          String.pad_trailing(text, width, pad)
      end
    else
      text
    end
  end

  defp as_number!(value) when is_number(value), do: value * 1.0
  defp as_number!(value), do: raise("expected a number, got #{inspect(value)}")

  defp strip_digits(str) do
    str
    |> to_string()
    |> String.replace(~r/[^0-9]/, "")
  end

  defp line_ending(spec), do: Map.get(spec, "line_ending", @default_line_ending)
end