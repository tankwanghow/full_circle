defmodule FullCircle.CommandPalette.DocNoSearch do
  @moduledoc """
  Document-number search over `transactions` for the command palette.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.{Query, Types}

  @doc """
  Search by partial `doc_no`. Accepts a raw string or a parsed `Query`.

  When the query has type filters, only those doc types are returned.
  Doc-number text is the full raw input, or the non-type tokens when types
  were stripped (so `"inv 001"` searches doc_no for `001` among invoices).
  """
  def search(company, user, %Query{} = q) do
    terms = doc_no_terms(q)

    if String.length(terms) < Types.min_length() do
      []
    else
      allowed = narrow_types(company, user, q.doc_types)

      if allowed == [] do
        []
      else
        do_search(company, user, terms, allowed)
      end
    end
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms))
  end

  # Prefer non-type tokens when present ("inv 001" → "001"); else full raw ("INV-12" or "inv").
  defp doc_no_terms(%Query{contact_terms: ct}) when ct != "", do: ct
  defp doc_no_terms(%Query{raw: raw}), do: raw

  defp narrow_types(company, user, nil), do: Types.allowed_types(company, user)

  defp narrow_types(company, user, wanted) do
    allowed = MapSet.new(Types.allowed_types(company, user))
    Enum.filter(wanted, &MapSet.member?(allowed, &1))
  end

  defp do_search(company, user, terms, allowed_types) do
    pattern = "%#{Types.escape_like(terms)}%"
    meta = Types.type_meta()

    from(t in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == t.company_id,
      left_join: c in Contact,
      on: c.id == t.contact_id,
      where: t.doc_type in ^allowed_types,
      where: not is_nil(t.doc_id),
      where: ilike(t.doc_no, ^pattern),
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
    |> Repo.all()
    |> Enum.map(&Types.to_hit(&1, company.id, meta))
    |> Enum.reject(&is_nil/1)
  end
end
