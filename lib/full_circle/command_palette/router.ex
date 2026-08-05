defmodule FullCircle.CommandPalette.Router do
  @moduledoc """
  Chooses how to interpret palette input.

  v1 always uses document-number search. Later modes (structured query, assistant)
  plug in here without changing the UI shell.
  """

  alias FullCircle.CommandPalette.DocNoSearch

  @type outcome ::
          {:hits, [FullCircle.CommandPalette.Hit.t()]}
          | {:proposal, term()}
          | {:message, String.t()}

  @doc """
  Dispatch free-text input for the active company and user.
  """
  @spec dispatch(map(), map(), String.t(), map()) :: outcome()
  def dispatch(company, user, text, _page_context \\ %{}) do
    terms = text |> to_string() |> String.trim()
    {:hits, DocNoSearch.search(company, user, terms)}
  end
end
