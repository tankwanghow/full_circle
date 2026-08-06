defmodule FullCircle.CommandPalette.DepositSearch do
  @moduledoc """
  Search deposits by deposit number and/or deposit bank account name.
  """

  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias FullCircle.Repo
  alias FullCircle.Sys
  alias FullCircle.Accounting.Account
  alias FullCircle.Cheque.Deposit
  alias FullCircle.CommandPalette.{Hit, Query, Types}

  def search(company, user, %Query{} = q) do
    if not can?(user, :update_deposit, company) do
      []
    else
      if deposit_type_allowed?(q) do
        do_search(company, user, q)
      else
        []
      end
    end
  end

  def search(company, user, terms) when is_binary(terms) do
    search(company, user, Query.parse(terms) |> Query.resolve_good(company, user))
  end

  defp deposit_type_allowed?(%Query{doc_types: nil}), do: true
  defp deposit_type_allowed?(%Query{doc_types: types}), do: "Deposit" in types

  defp do_search(company, user, %Query{} = q) do
    match = match_terms(q)

    cond do
      # Pure deposit type (optional dates): list deposits with bank names
      match == "" and q.doc_types == ["Deposit"] ->
        list_deposits(company, user, q, nil)

      match != "" ->
        list_deposits(company, user, q, match)

      true ->
        []
    end
  end

  defp match_terms(%Query{bank_terms: b}) when is_binary(b) and b != "", do: String.trim(b)
  defp match_terms(%Query{contact_terms: c}), do: String.trim(c || "")

  defp list_deposits(company, user, %Query{} = palette_q, match) do
    pattern = if match in [nil, ""], do: nil, else: "%#{Types.escape_like(match)}%"

    ecto_q =
      from(d in Deposit,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == d.company_id,
        join: bank in Account,
        on: bank.id == d.bank_id,
        order_by: [desc: d.deposit_date, desc: d.deposit_no],
        limit: ^Types.limit(),
        select: %{
          doc_type: "Deposit",
          doc_id: d.id,
          doc_no: d.deposit_no,
          doc_date: d.deposit_date,
          contact_name: nil,
          bank_name: bank.name
        }
      )

    ecto_q =
      if pattern do
        from([d, _com, bank] in ecto_q,
          where: ilike(d.deposit_no, ^pattern) or ilike(bank.name, ^pattern)
        )
      else
        ecto_q
      end

    ecto_q
    |> apply_deposit_dates(palette_q)
    |> Repo.all()
    |> Enum.map(&to_hit(&1, company.id))
  end

  defp apply_deposit_dates(query, %Query{date_mode: :none}), do: query

  defp apply_deposit_dates(query, %Query{date_mode: :on_or_before, date_to: %Date{} = to}) do
    where(query, [d], d.deposit_date <= ^to)
  end

  defp apply_deposit_dates(query, %Query{
         date_mode: :range,
         date_from: %Date{} = from,
         date_to: %Date{} = to
       }) do
    where(query, [d], d.deposit_date >= ^from and d.deposit_date <= ^to)
  end

  defp apply_deposit_dates(query, _), do: query

  defp to_hit(row, company_id) do
    %Hit{
      kind: :document,
      doc_type: "Deposit",
      doc_id: row.doc_id,
      doc_no: row.doc_no,
      doc_date: row.doc_date,
      contact_name: row.contact_name,
      good_name: nil,
      bank_name: row.bank_name,
      label: "Deposit",
      path: "/companies/#{company_id}/Deposit/#{row.doc_id}/edit"
    }
  end
end
