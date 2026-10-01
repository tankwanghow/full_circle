defmodule FullCircle.CommandPalette.Router do
  @moduledoc """
  Command palette routing.

  - **Actions** (single token): `newinv`, `newpur`, …
  - **Contacts**: open contact master by name
  - **Search**: doc number, contact docs, type, dates, good on lines
  - **Notes**: `note <words>` searches notes only; other searches end with a
    "Search notes for …" row (`NoteSearch`)
  """

  alias FullCircle.CommandPalette.{
    ActionSearch,
    ContactDocSearch,
    ContactMasterSearch,
    DateDocSearch,
    DepositSearch,
    DocNoSearch,
    FundsDocSearch,
    NoteSearch,
    Query,
    Types
  }

  @type outcome ::
          {:hits, [FullCircle.CommandPalette.Hit.t()]}
          | {:proposal, term()}
          | {:message, String.t()}

  @spec dispatch(map(), map(), String.t(), map()) :: outcome()
  def dispatch(company, user, text, _page_context \\ %{}) do
    terms = text |> to_string() |> String.trim()

    cond do
      String.length(terms) < Types.min_length() ->
        {:hits, []}

      match?({:ok, _}, NoteSearch.prefix(terms)) ->
        {:ok, words} = NoteSearch.prefix(terms)

        {:hits,
         NoteSearch.search(company, user, words) ++
           List.wrap(NoteSearch.fallback_hit(company, user, words))}

      true ->
        {:hits, merge_hits(company, user, terms)}
    end
  end

  defp merge_hits(company, user, terms) do
    actions = ActionSearch.search(company, user, terms)

    if actions != [] and single_token?(terms) and action_like?(terms) do
      Enum.take(actions, Types.limit())
    else
      q =
        terms
        |> Query.parse()
        |> Query.resolve_good(company, user)

      # Skip contact-master noise when the query is clearly a document number
      contacts =
        if Types.doc_number_like?(terms) or Types.doc_number_like?(q.contact_terms) do
          []
        else
          ContactMasterSearch.search(company, user, q)
        end

      by_no = DocNoSearch.search(company, user, q)
      by_contact = ContactDocSearch.search(company, user, q)
      by_date = DateDocSearch.search(company, user, q)
      by_deposit = DepositSearch.search(company, user, q)
      by_funds = FundsDocSearch.search(company, user, q)

      {docs, _seen} =
        Enum.reduce(
          by_no ++ by_contact ++ by_date ++ by_deposit ++ by_funds,
          {[], MapSet.new()},
          fn hit, {acc, seen} ->
            key = {hit.doc_type, hit.doc_id}

            if MapSet.member?(seen, key) do
              {acc, seen}
            else
              {acc ++ [hit], MapSet.put(seen, key)}
            end
          end
        )

      # Contacts first (when shown), then documents; note search offered last
      Enum.take(contacts ++ docs, Types.limit()) ++
        List.wrap(NoteSearch.fallback_hit(company, user, terms))
    end
  end

  defp single_token?(terms), do: not String.match?(terms, ~r/\s/)

  defp action_like?(terms) do
    n = Types.normalize_token(terms)
    String.starts_with?(n, "new")
  end
end
