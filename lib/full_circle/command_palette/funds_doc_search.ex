defmodule FullCircle.CommandPalette.FundsDocSearch do
  @moduledoc """
  Search Receipts and Payments by document number, contact name, and funds account name.
  """

  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.{Account, Contact}
  alias FullCircle.ReceiveFund.Receipt
  alias FullCircle.BillPay.Payment
  alias FullCircle.CommandPalette.{Hit, Query, Types}

  def search(company, user, %Query{} = q) do
    match = match_terms(q)

    receipt_hits =
      if type_allowed?(q, "Receipt") and can?(user, :update_receipt, company) do
        search_receipts(company, user, q, match)
      else
        []
      end

    payment_hits =
      if type_allowed?(q, "Payment") and can?(user, :update_payment, company) do
        search_payments(company, user, q, match)
      else
        []
      end

    (receipt_hits ++ payment_hits)
    |> Enum.sort_by(&{&1.doc_date && Date.to_erl(&1.doc_date), &1.doc_no}, :desc)
    |> Enum.take(Types.limit())
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms) |> Query.resolve_good(company, user))
  end

  defp type_allowed?(%Query{doc_types: nil}, _type), do: true
  defp type_allowed?(%Query{doc_types: types}, type), do: type in types

  defp match_terms(%Query{funds_terms: f}) when is_binary(f) and f != "", do: String.trim(f)
  defp match_terms(%Query{bank_terms: b}) when is_binary(b) and b != "", do: String.trim(b)
  defp match_terms(%Query{contact_terms: c}), do: String.trim(c || "")

  defp search_receipts(company, user, %Query{} = q, match) do
    if should_run?(q, match, "Receipt") do
      list_docs(
        company,
        user,
        q,
        match,
        Receipt,
        :receipt_no,
        :receipt_date,
        "Receipt",
        "Receipt",
        :update_receipt
      )
    else
      []
    end
  end

  defp search_payments(company, user, %Query{} = q, match) do
    if should_run?(q, match, "Payment") do
      list_docs(
        company,
        user,
        q,
        match,
        Payment,
        :payment_no,
        :payment_date,
        "Payment",
        "Payment",
        :update_payment
      )
    else
      []
    end
  end

  defp should_run?(%Query{} = q, match, type) do
    cond do
      match != "" -> true
      q.doc_types == [type] -> true
      q.funds_terms not in [nil, ""] -> true
      true -> false
    end
  end

  defp list_docs(
         company,
         user,
         %Query{} = palette_q,
         match,
         schema,
         no_field,
         date_field,
         doc_type,
         label,
         _action
       ) do
    pattern = if match in [nil, ""], do: nil, else: "%#{Types.escape_like(match)}%"

    ecto_q =
      from(doc in schema,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == doc.company_id,
        left_join: funds in Account,
        on: funds.id == doc.funds_account_id,
        left_join: cont in Contact,
        on: cont.id == doc.contact_id,
        order_by: [desc: field(doc, ^date_field), desc: field(doc, ^no_field)],
        limit: ^Types.limit(),
        select: %{
          doc_type: ^doc_type,
          doc_id: doc.id,
          doc_no: field(doc, ^no_field),
          doc_date: field(doc, ^date_field),
          contact_name: cont.name,
          bank_name: funds.name,
          label: ^label
        }
      )

    ecto_q =
      if pattern do
        from([doc, _com, funds, cont] in ecto_q,
          where:
            ilike(field(doc, ^no_field), ^pattern) or ilike(funds.name, ^pattern) or
              ilike(cont.name, ^pattern)
        )
      else
        ecto_q
      end

    ecto_q
    |> apply_dates(palette_q, date_field)
    |> Repo.all()
    |> Enum.map(&to_hit(&1, company.id, doc_type, label))
  end

  defp apply_dates(query, %Query{date_mode: :none}, _date_field), do: query

  defp apply_dates(query, %Query{date_mode: :on_or_before, date_to: %Date{} = to}, date_field) do
    where(query, [doc], field(doc, ^date_field) <= ^to)
  end

  defp apply_dates(
         query,
         %Query{date_mode: :range, date_from: %Date{} = from, date_to: %Date{} = to},
         date_field
       ) do
    where(query, [doc], field(doc, ^date_field) >= ^from and field(doc, ^date_field) <= ^to)
  end

  defp apply_dates(query, _, _), do: query

  defp to_hit(row, company_id, doc_type, label) do
    route = if doc_type == "Receipt", do: "Receipt", else: "Payment"

    %Hit{
      kind: :document,
      doc_type: doc_type,
      doc_id: row.doc_id,
      doc_no: row.doc_no,
      doc_date: row.doc_date,
      contact_name: row.contact_name,
      good_name: nil,
      bank_name: row.bank_name,
      label: label,
      path: "/companies/#{company_id}/#{route}/#{row.doc_id}/edit"
    }
  end
end
