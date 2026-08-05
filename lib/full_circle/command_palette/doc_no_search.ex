defmodule FullCircle.CommandPalette.DocNoSearch do
  @moduledoc """
  Document-number search over `transactions` for the command palette.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.Types

  @doc """
  Search company documents by partial `doc_no`.
  """
  def search(company, user, terms) when is_binary(terms) do
    terms = String.trim(terms)

    if String.length(terms) < Types.min_length() do
      []
    else
      allowed = Types.allowed_types(company, user)

      if allowed == [] do
        []
      else
        do_search(company, user, terms, allowed)
      end
    end
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
