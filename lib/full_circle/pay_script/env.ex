defmodule FullCircle.PayScript.Env do
  @moduledoc """
  Runtime environment for PayScript builtins that need data access.

  The evaluator receives `{module, state}`; each callback gets `state` as its
  first argument. Phase 2 provides the DB-backed implementation (company- and
  effective-date-scoped); tests use `FullCircle.PayScriptStubEnv`.
  """

  @type state :: term()

  @callback lookup(state, table :: String.t(), value :: number(), column :: String.t()) ::
              {:ok, number()} | {:error, String.t()}

  @callback ytd_sum(state, kind :: :code | :type | :name, keys :: [String.t()]) ::
              {:ok, number()} | {:error, String.t()}

  @callback calc(state, code :: String.t()) :: {:ok, number()} | {:error, String.t()}
end