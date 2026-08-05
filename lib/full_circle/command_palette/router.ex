defmodule FullCircle.CommandPalette.Router do
  @moduledoc """
  Chooses how to interpret palette input.

  v1–v1.1: document number + contact name → document hits.
  Later: structured query / assistant proposals.
  """

  alias FullCircle.CommandPalette.{ContactDocSearch, DocNoSearch, Types}

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

  # Doc-number matches first (user often has a number), then contact-name docs.
  # De-dupe by {doc_type, doc_id}. Cap at Types.limit().
  defp merge_hits(company, user, terms) do
    by_no = DocNoSearch.search(company, user, terms)
    by_contact = ContactDocSearch.search(company, user, terms)

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
