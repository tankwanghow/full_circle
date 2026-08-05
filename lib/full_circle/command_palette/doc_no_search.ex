defmodule FullCircle.CommandPalette.DocNoSearch do
  @moduledoc """
  Document-number search over `transactions` for the command palette.
  """

  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Contact, Transaction}
  alias FullCircle.CommandPalette.Hit

  @type_specs [
    {"Invoice", :update_invoice, "Invoice", "Invoice"},
    {"PurInvoice", :update_pur_invoice, "Purchase Invoice", "PurInvoice"},
    {"Receipt", :update_receipt, "Receipt", "Receipt"},
    {"Payment", :update_payment, "Payment", "Payment"},
    {"CreditNote", :update_credit_note, "Credit Note", "CreditNote"},
    {"DebitNote", :update_debit_note, "Debit Note", "DebitNote"},
    {"Journal", :update_journal, "Journal", "Journal"}
  ]

  @min_length 2
  @limit 20

  @doc """
  Search company documents by partial `doc_no`. Returns at most #{@limit} hits.
  """
  def search(company, user, terms) when is_binary(terms) do
    terms = String.trim(terms)

    if String.length(terms) < @min_length do
      []
    else
      allowed = allowed_types(company, user)

      if allowed == [] do
        []
      else
        do_search(company, user, terms, allowed)
      end
    end
  end

  defp allowed_types(company, user) do
    for {doc_type, action, _label, _route} <- @type_specs,
        can?(user, action, company),
        do: doc_type
  end

  defp do_search(company, user, terms, allowed_types) do
    pattern = "%#{escape_like(terms)}%"
    meta = Map.new(@type_specs, fn {t, _a, label, route} -> {t, {label, route}} end)

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
      limit: ^@limit,
      select: %{
        doc_type: t.doc_type,
        doc_id: t.doc_id,
        doc_no: t.doc_no,
        doc_date: t.doc_date,
        contact_name: max(c.name)
      }
    )
    |> Repo.all()
    |> Enum.map(&to_hit(&1, company.id, meta))
    |> Enum.reject(&is_nil/1)
  end

  defp to_hit(row, company_id, meta) do
    case Map.get(meta, row.doc_type) do
      {label, route_seg} ->
        %Hit{
          doc_type: row.doc_type,
          doc_id: row.doc_id,
          doc_no: row.doc_no,
          doc_date: row.doc_date,
          contact_name: row.contact_name,
          label: label,
          path: "/companies/#{company_id}/#{route_seg}/#{row.doc_id}/edit"
        }

      nil ->
        nil
    end
  end

  # Escape LIKE metacharacters so user input is literal.
  defp escape_like(terms) do
    terms
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
