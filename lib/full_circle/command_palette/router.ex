defmodule FullCircle.CommandPalette.Router do
  @moduledoc """
  Chooses how to interpret palette input.

  Search: document number + contact name + optional type keywords
  (`swee heng inv`). Later: structured date/good query / assistant.
  """

  alias FullCircle.CommandPalette.{ContactDocSearch, DocNoSearch, Query, Types}

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
      q = Query.parse(terms)
      {:hits, merge_hits(company, user, q)}
    end
  end

  # Doc-number matches first, then contact-name docs. De-dupe; cap at limit.
  defp merge_hits(company, user, %Query{} = q) do
    by_no = DocNoSearch.search(company, user, q)
    by_contact = ContactDocSearch.search(company, user, q)

    {merged, _seen} =
      Enum.reduce(by_no ++ by_contact, {[], MapSet.new()}, fn hit, {acc, seen} ->
        key = {hit.doc_type, hit.doc_id}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {acc ++ [hit], MapSet.put(seen, key)}
        end
      end)

    Enum.take(merged, Types.limit())
  end
end
