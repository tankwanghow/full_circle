defmodule FullCircle.CommandPalette.DocNoSearch do
  @moduledoc """
  Document-number search over `transactions` for the command palette.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.{DateFilter, GoodFilter, Query, Types}

  def search(company, user, %Query{} = q) do
    terms = doc_no_terms(q)

    if String.length(terms) < Types.min_length() do
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
        do_search(company, user, terms, allowed, q)
      end
    end
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms) |> Query.resolve_good(company, user))
  end

  defp doc_no_terms(%Query{contact_terms: ct, good_terms: g})
       when ct != "" and g in [nil, ""],
       do: ct

  defp doc_no_terms(%Query{good_terms: g})
       when is_binary(g) and g != "",
       do: ""

  defp doc_no_terms(%Query{raw: raw, doc_types: types, date_mode: mode, good_terms: g}) do
    if types != nil or mode != :none or (is_binary(g) and g != "") do
      ""
    else
      raw
    end
  end

  defp do_search(company, user, terms, allowed_types, %Query{} = q) do
    pattern = "%#{Types.escape_like(terms)}%"
    meta = Types.type_meta()

    from(t in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == t.company_id,
      left_join: c in Contact,
      on: c.id == t.contact_id,
      where: t.doc_type in ^allowed_types,
      where: not is_nil(t.doc_id),
      where: ilike(t.doc_no, ^pattern)
    )
    |> DateFilter.apply(q)
    |> GoodFilter.apply(q)
    |> then(fn query ->
      from([t, _com, c] in query,
        group_by: [t.doc_type, t.doc_id, t.doc_no, t.doc_date],
        order_by: [
          desc: fragment("COALESCE(word_similarity(?, ?), 0)", ^terms, t.doc_no),
          desc: t.doc_date,
          asc: t.doc_no
        ],
        limit: ^Types.limit(),
        select: %{
          doc_type: t.doc_type,
          doc_id: t.doc_id,
          doc_no: t.doc_no,
          doc_date: t.doc_date,
          contact_name: max(c.name)
        }
      )
    end)
    |> Repo.all()
    |> Enum.map(&Types.to_hit(&1, company.id, meta))
    |> Enum.reject(&is_nil/1)
    |> GoodFilter.attach_good_names(q)
  end
end
