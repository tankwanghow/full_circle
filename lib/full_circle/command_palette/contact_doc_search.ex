defmodule FullCircle.CommandPalette.ContactDocSearch do
  @moduledoc """
  Find finance documents whose contact name matches the search terms.
  """

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.Types

  @max_contacts 5

  @doc """
  Match contacts by name, then return their recent documents (same v1 types).
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
        contact_ids = match_contact_ids(company, user, terms)

        if contact_ids == [] do
          []
        else
          docs_for_contacts(company, user, contact_ids, allowed)
        end
      end
    end
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

  defp docs_for_contacts(company, user, contact_ids, allowed_types) do
    meta = Types.type_meta()

    from(t in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == t.company_id,
      join: c in Contact,
      on: c.id == t.contact_id,
      where: t.contact_id in ^contact_ids,
      where: t.doc_type in ^allowed_types,
      where: not is_nil(t.doc_id),
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
    |> Repo.all()
    |> Enum.map(&Types.to_hit(&1, company.id, meta))
    |> Enum.reject(&is_nil/1)
  end
end
