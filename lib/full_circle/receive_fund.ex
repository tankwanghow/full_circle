defmodule FullCircle.ReceiveFund do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.ReceiveFund.{Receipt, ReceiptDetail, ReceivedCheque, ReceiptTransactionMatcher}
  alias FullCircle.Accounting.{Contact, Transaction, SeedTransactionMatcher}
  alias Ecto.Multi

  def receipt_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    # qry =
    #   from(inv in subquery(receipt_raw_query(com, user)))

    # qry =
    #   if terms != "" do
    #     from inv in subquery(qry),
    #       order_by: ^similarity_order([:receipt_no, :contact_name, :particulars], terms)
    #   else
    #     qry
    #   end

    # qry =
    #   if date_from != "" do
    #     from inv in qry, where: inv.receipt_date >= ^date_from, order_by: inv.receipt_date
    #   else
    #     qry
    #   end

    # qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
    []
  end

  def get_receipt_by_id_index_component_field!(id, com, user) do
    from(i in subquery(receipt_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp receipt_raw_query(company, user) do
    # from rec in Receipt,
    #   join: com in subquery(Sys.user_company(company, user)),
    #   on: com.id == rec.company_id,
    #   join: cont in Contact,
    #   on: cont.id == rec.contact_id,
    #   join: acc in Account,
    #   on: acc.id == rec.account_id
  end

  def receipt_match_transactions(ctid, recid, sdate, edate, com) do
    qry =
      from txn in Transaction,
        left_join: stxm in SeedTransactionMatcher,
        on: stxm.transaction_id == txn.id,
        left_join: rectxm in ReceiptTransactionMatcher,
        on: rectxm.transaction_id == txn.id,
        where: txn.contact_id == ^ctid,
        where: txn.company_id == ^com.id,
        where: txn.doc_date >= ^sdate,
        where: txn.doc_date <= ^edate,
        order_by: txn.doc_date,
        select: %ReceiptTransactionMatcher{
          id: coalesce(rectxm.id, nil),
          transaction_id: txn.id,
          doc_date: txn.doc_date,
          doc_type: txn.doc_type,
          doc_no: txn.doc_no,
          amount: txn.amount,
          balance:
            txn.amount + coalesce(sum(stxm.match_amount), 0) +
              coalesce(sum(rectxm.match_amount), 0),
          match_amount: coalesce(rectxm.match_amount, 0)
        },
        group_by: [
          txn.id,
          txn.doc_type,
          txn.doc_no,
          txn.doc_date,
          txn.amount,
          rectxm.match_amount,
          rectxm.id
        ]

    qry |> Repo.all()
  end
end
