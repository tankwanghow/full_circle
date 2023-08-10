defmodule FullCircle.Reporting do
  import Ecto.Query, warn: false

  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.{Repo, Accounting}

  def prev_close_date(at_date, com) do
    Date.new!(at_date.year - 1, com.closing_month, com.closing_day)
  end

  def balance_sheet_query(at_date, com) do
    from(ac in Account,
      join: txn in Transaction,
      on: ac.id == txn.account_id,
      where: ac.company_id == ^com.id,
      where: ac.account_type in ^FullCircle.Accounting.balance_sheet_account_types(),
      where: txn.doc_date <= ^at_date,
      select: %{type: ac.account_type, name: ac.name, balance: sum(txn.amount)},
      group_by: [ac.account_type, ac.name]
    )
  end

  def profit_loss_query(at_date, com) do
    from(ac in Account,
      join: txn in Transaction,
      on: ac.id == txn.account_id,
      where: ac.company_id == ^com.id,
      where: ac.account_type in ^FullCircle.Accounting.profit_loss_account_types(),
      where: txn.doc_date <= ^at_date,
      where: txn.doc_date > ^prev_close_date(at_date, com),
      select: %{type: ac.account_type, name: ac.name, balance: sum(txn.amount)},
      group_by: [ac.account_type, ac.name]
    )
  end

  def trail_balance(at_date, com) do
    union_all(profit_loss_query(at_date, com), ^balance_sheet_query(at_date, com))
    |> order_by([1, 2])
    |> Repo.all()
  end

  def contact_transactions(ct, sdate, edate, com) do
    qry =
      from txn in Transaction,
        where: txn.contact_id == ^ct.id,
        where: txn.company_id == ^com.id

    bal_qry = from q in qry, where: q.doc_date < ^sdate

    bal_qry =
      from q in bal_qry,
        select: %{
          doc_date: ^Timex.shift(sdate, days: -1),
          doc_type: "",
          doc_no: "",
          particulars: "Balance Brought Forward",
          amount: coalesce(sum(q.amount), 0),
          reconciled: true,
          old_data: true,
          inserted_at: ^DateTime.utc_now(),
          id: type(^Ecto.UUID.generate(), :string)
        }

    txn_qry =
      from q in qry,
        where: q.doc_date >= ^sdate,
        where: q.doc_date <= ^edate,
        select: %{
          doc_date: q.doc_date,
          doc_type: q.doc_type,
          doc_no: q.doc_no,
          particulars: coalesce(q.contact_particulars, q.particulars),
          amount: q.amount,
          reconciled: q.reconciled,
          old_data: q.old_data,
          inserted_at: q.inserted_at,
          id: type(q.id, :string)
        }

    union_all(bal_qry, ^txn_qry) |> order_by([1, 2, 3]) |> Repo.all()
  end

  def account_transactions(ac, sdate, edate, com) do
    qry =
      from txn in Transaction,
        where: txn.account_id == ^ac.id,
        where: txn.company_id == ^com.id

    bal_qry =
      if Accounting.is_balance_sheet_account?(ac) do
        from q in qry, where: q.doc_date < ^sdate
      else
        from q in qry,
          where: q.doc_date < ^sdate,
          where: q.doc_date > ^prev_close_date(sdate, com)
      end

    bal_qry =
      from q in bal_qry,
        select: %{
          doc_date: ^Timex.shift(sdate, days: -1),
          doc_type: "",
          doc_no: "",
          particulars: "Balance Brought Forward",
          amount: coalesce(sum(q.amount), 0),
          reconciled: true,
          old_data: true,
          inserted_at: ^DateTime.utc_now(),
          id: type(^Ecto.UUID.generate(), :string)
        }

    txn_qry =
      from q in qry,
        where: q.doc_date >= ^sdate,
        where: q.doc_date <= ^edate,
        select: %{
          doc_date: q.doc_date,
          doc_type: q.doc_type,
          doc_no: q.doc_no,
          particulars: q.particulars,
          amount: q.amount,
          reconciled: q.reconciled,
          old_data: q.old_data,
          inserted_at: q.inserted_at,
          id: type(q.id, :string)
        }

    union_all(bal_qry, ^txn_qry) |> order_by([1, 2, 3]) |> Repo.all()
  end
end
