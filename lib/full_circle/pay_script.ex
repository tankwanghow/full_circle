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

  alias FullCircle.PayScript.{Error, Evaluator, Lexer, Parser, Validator}

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

  @doc "Parses a single PayScript expression."
  def parse_expression(source) when is_binary(source) do
    with {:ok, tokens} <- Lexer.tokenize(source) do
      Parser.parse_expression(tokens)
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

  @doc """
  Evaluates a single expression and returns the raw value (no Decimal coercion).
  """
  def eval_expression(expr_or_source, context, env) when is_binary(expr_or_source) do
    with {:ok, expr} <- parse_expression(expr_or_source),
         do: eval_expression(expr, context, env)
  end

  def eval_expression(expr, context, env) do
    Evaluator.eval(expr, context, env)
  end

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

  @doc "Save-time validation for a single expression."
  def validate_expression(source, schema) when is_binary(source) do
    with {:ok, expr} <- parse_expression(source),
         do: Validator.validate_expression(expr, schema)
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
end