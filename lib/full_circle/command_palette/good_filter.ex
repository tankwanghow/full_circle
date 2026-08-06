defmodule FullCircle.CommandPalette.GoodFilter do
  @moduledoc false

  import Ecto.Query, warn: false

  alias FullCircle.Billing.{InvoiceDetail, PurInvoiceDetail}
  alias FullCircle.Product.Good
  alias FullCircle.CommandPalette.{Query, Types}

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
end
