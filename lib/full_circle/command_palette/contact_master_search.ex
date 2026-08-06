defmodule FullCircle.CommandPalette.ContactMasterSearch do
  @moduledoc """
  Jump to contact master records by name.
  """

  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.Contact
  alias FullCircle.CommandPalette.{Hit, Query, Types}

  @max 5

  def search(company, user, %Query{contact_terms: terms}) do
    terms = String.trim(terms || "")

    cond do
      String.length(terms) < Types.min_length() ->
        []

      not can?(user, :update_contact, company) ->
        []

      true ->
        do_search(company, user, terms)
    end
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms))
  end

  defp do_search(company, user, terms) do
    pattern = "%#{Types.escape_like(terms)}%"

    from(c in Contact,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == c.company_id,
      where: ilike(c.name, ^pattern),
      order_by: [
        desc: fragment("COALESCE(word_similarity(?, ?), 0)", ^terms, c.name),
        asc: c.name
      ],
      limit: ^@max,
      select: %{id: c.id, name: c.name}
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %Hit{
        kind: :contact,
        doc_type: "Contact",
        doc_id: row.id,
        doc_no: row.name,
        doc_date: nil,
        contact_name: nil,
        label: "Contact",
        path: "/companies/#{company.id}/contacts/#{row.id}/edit"
      }
    end)
  end
end
