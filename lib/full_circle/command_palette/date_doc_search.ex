defmodule FullCircle.CommandPalette.DateDocSearch do
  @moduledoc """
  Document search by type and/or date when there is no contact name fragment.

  Examples: `inv 5/2/2026`, `1/2/2026 - 14/2/2026`, `receipt 5/2/2026`.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.{DateFilter, Query, Types}

  @doc """
  Run only when contact_terms is empty and there is a type and/or date filter.
  """
  def search(company, user, %Query{} = q) do
    if q.contact_terms != "" do
      []
    else
      if q.doc_types == nil and q.date_mode == :none do
        []
      else
        allowed = narrow_types(company, user, q.doc_types)

        if allowed == [] do
          []
        else
          do_search(company, user, allowed, q)
        end
      end
    end
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms))
  end

  defp narrow_types(company, user, nil), do: Types.allowed_types(company, user)

  defp narrow_types(company, user, wanted) do
    allowed = MapSet.new(Types.allowed_types(company, user))
    Enum.filter(wanted, &MapSet.member?(allowed, &1))
  end

  defp do_search(company, user, allowed_types, %Query{} = q) do
    meta = Types.type_meta()

    from(t in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == t.company_id,
      left_join: c in Contact,
      on: c.id == t.contact_id,
      where: t.doc_type in ^allowed_types,
      where: not is_nil(t.doc_id)
    )
    |> DateFilter.apply(q)
    |> then(fn query ->
      from([t, _com, c] in query,
        group_by: [t.doc_type, t.doc_id, t.doc_no, t.doc_date],
        order_by: [desc: t.doc_date, desc: t.doc_no],
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
  end
end
