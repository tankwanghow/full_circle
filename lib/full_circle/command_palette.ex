defmodule FullCircle.CommandPalette do
  @moduledoc """
  App-wide command palette (Ctrl/Cmd+K).

  - **Search:** document number, contact name, type keywords (`swee heng inv`)
  - **Actions:** compound tokens (`newinv`, `newpur`, `newcn`, …) → create form
  """

  alias FullCircle.CommandPalette.Router

  @doc """
  Interpret palette input. Returns a tagged outcome (`:hits`, later `:proposal`).
  """
  def dispatch(company, user, text, page_context \\ %{}) do
    Router.dispatch(company, user, text, page_context)
  end

  @doc """
  Convenience for callers that only need hit lists.
  """
  def search(company, user, text) do
    case dispatch(company, user, text) do
      {:hits, hits} -> hits
      _ -> []
    end
  end
end
