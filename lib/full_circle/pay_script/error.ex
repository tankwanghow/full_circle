defmodule FullCircle.PayScript.Error do
  @moduledoc """
  A PayScript error. `line` is set for lex/parse errors, `binding` for
  validation/runtime errors (the `name =` line the error occurred in).
  """
  defexception line: nil, binding: nil, message: ""

  @impl true
  def message(%__MODULE__{} = e) do
    cond do
      e.binding -> "in '#{e.binding}': #{e.message}"
      e.line -> "line #{e.line}: #{e.message}"
      true -> e.message
    end
  end
end
