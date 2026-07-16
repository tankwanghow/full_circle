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
    "upper" => 1,
    "lower" => 1,
    "trim" => 1,
    "replace" => 3,
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

  def validate_expression(expr, schema) do
    known = MapSet.new(Map.get(schema, :variables, []))
    errors = walk(expr, known, schema)

    if errors == [], do: :ok, else: {:error, errors}
  end

  def calc_deps(bindings) do
    bindings |> Enum.flat_map(fn {_name, expr} -> deps(expr) end) |> Enum.uniq()
  end

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
