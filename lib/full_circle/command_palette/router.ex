defmodule FullCircle.CommandPalette.Router do
  @moduledoc """
  Command palette routing.

  - **Actions** (single token): `newinv`, `newpur`, `newcn`, …
  - **Search**: doc number, contact, type keywords, dates
  """

  alias FullCircle.CommandPalette.{
    ActionSearch,
    ContactDocSearch,
    DateDocSearch,
    DocNoSearch,
    Query,
    Types
  }

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

    if String.length(terms) < Types.min_length() do
      {:hits, []}
    else
      {:hits, merge_hits(company, user, terms)}
    end
  end

  defp merge_hits(company, user, terms) do
    actions = ActionSearch.search(company, user, terms)
    q = Query.parse(terms)

    by_no = DocNoSearch.search(company, user, q)
    by_contact = ContactDocSearch.search(company, user, q)
    by_date = DateDocSearch.search(company, user, q)

    {docs, _seen} =
      Enum.reduce(by_no ++ by_contact ++ by_date, {[], MapSet.new()}, fn hit, {acc, seen} ->
        key = {hit.doc_type, hit.doc_id}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {acc ++ [hit], MapSet.put(seen, key)}
        end
      end)

    hits =
      if actions != [] and single_token?(terms) and action_like?(terms) do
        actions
      else
        actions ++ docs
      end

    Enum.take(hits, Types.limit())
  end

  defp single_token?(terms), do: not String.match?(terms, ~r/\s/)

  defp action_like?(terms) do
    n = Types.normalize_token(terms)
    String.starts_with?(n, "new")
  end
end
