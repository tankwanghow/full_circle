defmodule FullCircle.CommandPalette.ContactDocSearch do
  @moduledoc """
  Find finance documents whose contact name matches the search terms,
  optionally filtered by document type, dates, and good on lines.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.{DateFilter, GoodFilter, Query, Types}

  @max_contacts 5

  def search(company, user, %Query{} = q) do
    name_terms = q.contact_terms

    if String.length(name_terms) < Types.min_length() do
      []
    else
      allowed =
        company
        |> Types.allowed_types(user)
        |> then(fn a ->
          if q.doc_types, do: Enum.filter(a, &(&1 in q.doc_types)), else: a
        end)
        |> GoodFilter.restrict_types(q)

      if allowed == [] do
        []
      else
        contact_ids = match_contact_ids(company, user, name_terms)

        if contact_ids == [] do
          []
        else
          docs_for_contacts(company, user, contact_ids, allowed, q)
        end
      end
    end
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms) |> Query.resolve_good(company, user))
  end

  defp match_contact_ids(company, user, terms) do
    pattern = "%#{Types.escape_like(terms)}%"

    from(c in Contact,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == c.company_id,
      where: ilike(c.name, ^pattern),
      order_by: [
        desc: fragment("COALESCE(word_similarity(?, ?), 0)", ^terms, c.name),
        asc: c.name
      ],
      limit: ^@max_contacts,
      select: c.id
    )
    |> Repo.all()
  end

  defp docs_for_contacts(company, user, contact_ids, allowed_types, %Query{} = q) do
    meta = Types.type_meta()

    from(t in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == t.company_id,
      join: c in Contact,
      on: c.id == t.contact_id,
      where: t.contact_id in ^contact_ids,
      where: t.doc_type in ^allowed_types,
      where: not is_nil(t.doc_id)
    )
    |> DateFilter.apply(q)
    |> GoodFilter.apply(q)
    |> then(fn query ->
      from([t, _com, c] in query,
        group_by: [t.doc_type, t.doc_id, t.doc_no, t.doc_date, c.name],
        order_by: [desc: t.doc_date, desc: t.doc_no],
        limit: ^Types.limit(),
        select: %{
          doc_type: t.doc_type,
          doc_id: t.doc_id,
          doc_no: t.doc_no,
          doc_date: t.doc_date,
          contact_name: c.name
        }
      )
    end)
    |> Repo.all()
    |> Enum.map(&Types.to_hit(&1, company.id, meta))
    |> Enum.reject(&is_nil/1)
    |> GoodFilter.attach_good_names(q)
  end
end
