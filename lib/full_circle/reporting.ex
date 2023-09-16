defmodule FullCircle.Reporting do
  import Ecto.Query, warn: false

  alias FullCircle.Accounting.{Account, Transaction, Contact}
  alias FullCircle.{Repo, Accounting}
  alias FullCircle.Cheque.{Deposit, ReturnCheque}
  alias FullCircle.ReceiveFund.{ReceivedCheque, Receipt}
  import FullCircle.Helpers

  def post_dated_cheques(terms, flag, rdate, ddate, com) do
    qry = from(q in subquery(post_dated_chq_raw_query(com)))

    qry =
      if terms != "" do
        from rec in qry,
          order_by:
            ^similarity_order(
              [:cheque_no, :contact_name, :bank, :deposit_bank_name, :return_reason],
              terms
            )
      else
        qry
      end

    qry =
      if rdate != "" do
        from rec in qry, where: rec.receipt_date >= ^rdate, order_by: rec.receipt_date
      else
        qry
      end

    qry =
      if ddate != "" and flag != "Can-Be-Return" do
        from rec in qry, where: rec.due_date <= ^ddate, order_by: rec.due_date
      else
        qry
      end

    qry =
      cond do
        flag == "Banked-In" ->
          from rec in qry, where: not is_nil(rec.deposit_id)

        flag == "In-Hand" ->
          from rec in qry,
            where: is_nil(rec.deposit_id),
            where: is_nil(rec.return_id)

        flag == "Can-Be-Return" ->
          ddate =
            ddate
            |> Timex.parse!("{YYYY}-{0M}-{0D}")
            |> NaiveDateTime.to_date()
            |> Timex.shift(days: -14)

          from rec in qry,
            where: rec.deposit_date >= ^ddate or is_nil(rec.deposit_id)

        true ->
          qry
      end

    qry |> Repo.all()
  end

  defp post_dated_chq_raw_query(com) do
    from chq in ReceivedCheque,
      join: rec in Receipt,
      on: rec.id == chq.receipt_id,
      join: cont in Contact,
      on: cont.id == rec.contact_id,
      left_join: dep in Deposit,
      on: dep.id == chq.deposit_id,
      left_join: bank in Account,
      on: bank.id == dep.bank_id,
      left_join: rtn in ReturnCheque,
      on: rtn.id == chq.return_cheque_id,
      where: rec.company_id == ^com.id,
      select: %{
        id: chq.id,
        contact_name: cont.name,
        contact_id: cont.id,
        receipt_date: rec.receipt_date,
        receipt_id: rec.id,
        bank: chq.bank,
        city: chq.city,
        state: chq.state,
        due_date: chq.due_date,
        amount: chq.amount,
        cheque_no: chq.cheque_no,
        deposit_date: dep.deposit_date,
        deposit_bank_name: bank.name,
        deposit_bank_id: bank.id,
        deposit_id: dep.id,
        deposit_no: dep.deposit_no,
        return_date: rtn.return_date,
        return_id: rtn.id,
        return_no: rtn.return_no,
        return_reason: rtn.return_reason,
        checked: false
      }
  end

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
          doc_id: type(^Ecto.UUID.generate(), :string),
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
          doc_id: type(coalesce(q.doc_id, ^Ecto.UUID.bingenerate()), :string),
          particulars: coalesce(q.contact_particulars, q.particulars),
          amount: q.amount,
          reconciled: q.reconciled,
          old_data: q.old_data,
          inserted_at: q.inserted_at,
          id: type(q.id, :string)
        }

    union_all(bal_qry, ^txn_qry) |> order_by([1, 8, 2]) |> Repo.all()
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
          doc_id: type(^Ecto.UUID.generate(), :string),
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
          doc_id: type(coalesce(q.doc_id, ^Ecto.UUID.bingenerate()), :string),
          particulars: q.particulars,
          amount: q.amount,
          reconciled: q.reconciled,
          old_data: q.old_data,
          inserted_at: q.inserted_at,
          id: type(q.id, :string)
        }

    union_all(bal_qry, ^txn_qry) |> order_by([1, 8, 2]) |> Repo.all()
  end
end
