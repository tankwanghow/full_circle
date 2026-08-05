defmodule FullCircle.CommandPalette do
  @moduledoc """
  App-wide command palette facade.

  v1: document-number jump. Future: assistant proposals and rich queries share
  the same UI shell via `CommandPalette.Router`.
  """

  alias FullCircle.CommandPalette.Router

  @doc """
  Interpret palette input. Returns a tagged outcome (`:hits`, later `:proposal`).
  """
  def dispatch(company, user, text, page_context \\ %{}) do
    Router.dispatch(company, user, text, page_context)
  end

  @doc """
  Convenience for v1 callers that only need hit lists.
  """
  def search(company, user, text) do
    case dispatch(company, user, text) do
      {:hits, hits} -> hits
      _ -> []
    end
  end
end
