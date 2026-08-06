defmodule FullCircle.CommandPalette.GoodFilter do
  @moduledoc false

  import Ecto.Query, warn: false

  alias FullCircle.Repo
  alias FullCircle.Billing.{InvoiceDetail, PurInvoiceDetail}
  alias FullCircle.Product.Good
  alias FullCircle.CommandPalette.{Hit, Query, Types}

  @line_types ~w(Invoice PurInvoice)

  def line_types, do: @line_types

  @doc """
  When a good filter is active, keep only Invoice / PurInvoice among allowed types.
  """
  def restrict_types(allowed, %Query{good_terms: g}) when g in [nil, ""], do: allowed

  def restrict_types(allowed, %Query{}) do
    Enum.filter(allowed, &(&1 in @line_types))
  end

  @doc """
  Restrict transactions to those with a matching good on invoice lines.
  """
  def apply(query, %Query{good_terms: g}) when g in [nil, ""], do: query

  def apply(query, %Query{good_terms: terms}) when is_binary(terms) do
    pattern = "%#{Types.escape_like(terms)}%"

    inv_ids =
      from(d in InvoiceDetail,
        join: g in Good,
        on: g.id == d.good_id,
        where: ilike(g.name, ^pattern),
        select: d.invoice_id
      )

    pur_ids =
      from(d in PurInvoiceDetail,
        join: g in Good,
        on: g.id == d.good_id,
        where: ilike(g.name, ^pattern),
        select: d.pur_invoice_id
      )

    where(
      query,
      [t],
      (t.doc_type == "Invoice" and t.doc_id in subquery(inv_ids)) or
        (t.doc_type == "PurInvoice" and t.doc_id in subquery(pur_ids))
    )
  end

  def apply(query, _), do: query

  @doc """
  Fill `good_name` on document hits with the matching line good names for the filter.
  """
  def attach_good_names(hits, %Query{good_terms: g}) when g in [nil, ""], do: hits

  def attach_good_names(hits, %Query{good_terms: terms}) when is_binary(terms) do
    pattern = "%#{Types.escape_like(terms)}%"

    inv_ids =
      for %Hit{kind: :document, doc_type: "Invoice", doc_id: id} <- hits, do: id

    pur_ids =
      for %Hit{kind: :document, doc_type: "PurInvoice", doc_id: id} <- hits, do: id

    inv_map = matching_good_names(InvoiceDetail, :invoice_id, inv_ids, pattern)
    pur_map = matching_good_names(PurInvoiceDetail, :pur_invoice_id, pur_ids, pattern)

    Enum.map(hits, fn
      %Hit{kind: :document, doc_type: "Invoice", doc_id: id} = hit ->
        %{hit | good_name: Map.get(inv_map, id)}

      %Hit{kind: :document, doc_type: "PurInvoice", doc_id: id} = hit ->
        %{hit | good_name: Map.get(pur_map, id)}

      hit ->
        hit
    end)
  end

  def attach_good_names(hits, _), do: hits

  defp matching_good_names(_detail, _fk, [], _pattern), do: %{}

  defp matching_good_names(detail_mod, fk, ids, pattern) do
    ids = Enum.uniq(ids)

    from(d in detail_mod,
      join: g in Good,
      on: g.id == d.good_id,
      where: field(d, ^fk) in ^ids,
      where: ilike(g.name, ^pattern),
      group_by: field(d, ^fk),
      select: {field(d, ^fk), fragment("string_agg(DISTINCT ?, ', ' ORDER BY ?)", g.name, g.name)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
