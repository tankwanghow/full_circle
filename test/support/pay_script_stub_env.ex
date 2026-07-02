defmodule FullCircle.PayScriptStubEnv do
  @moduledoc """
  Map-backed PayScript env for tests.

  State: `%{tables: %{code => %{columns: [...], rows: [[...]]}},
            ytd: %{{kind, keys} => number}, calcs: %{code => number}}`
  """

  @behaviour FullCircle.PayScript.Env

  @impl true
  def lookup(state, table, value, column) do
    case Map.fetch(state.tables, table) do
      {:ok, %{columns: cols, rows: rows}} ->
        case Enum.find_index(cols, &(&1 == column)) do
          nil ->
            {:error, "unknown column '#{column}' in table '#{table}'"}

          idx ->
            row = Enum.find(rows, fn [from, to | _] -> value > from and value <= to end)
            {:ok, if(row, do: Enum.at(row, idx), else: 0.0)}
        end

      :error ->
        {:error, "unknown table '#{table}'"}
    end
  end

  @impl true
  def ytd_sum(state, kind, keys), do: {:ok, Map.get(state.ytd, {kind, keys}, 0.0)}

  @impl true
  def calc(state, code) do
    case Map.fetch(state.calcs, code) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "unknown calc '#{code}'"}
    end
  end
end