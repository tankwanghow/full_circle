defmodule FullCircle.CommandPalette.Router do
  @moduledoc """
  Command palette routing.

  - **Actions** (single token): `newinv`, `newpur`, …
  - **Contacts**: open contact master by name
  - **Search**: doc number, contact docs, type, dates, good on lines
  """

  alias FullCircle.CommandPalette.{
    ActionSearch,
    ContactDocSearch,
    ContactMasterSearch,
    DateDocSearch,
    DepositSearch,
    DocNoSearch,
    FundsDocSearch,
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

    if String.length(terms) < Types.min_length() do
      {:hits, []}
    else
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

      contacts = ContactMasterSearch.search(company, user, q)
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
        end)

      # Contacts first (quick jump to master), then documents
      Enum.take(contacts ++ docs, Types.limit())
    end
  end

  defp single_token?(terms), do: not String.match?(terms, ~r/\s/)

  defp action_like?(terms) do
    n = Types.normalize_token(terms)
    String.starts_with?(n, "new")
  end
end
