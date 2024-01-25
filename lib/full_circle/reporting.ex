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

  def debtors_balance(gt, at_date, com) do
    from(cont in Contact,
      join: txn in Transaction,
      on: cont.id == txn.contact_id,
      where: cont.company_id == ^com.id,
      where: txn.doc_date <= ^at_date,
      select: %{checked: false, id: cont.id, name: cont.name, balance: sum(txn.amount)},
      group_by: [cont.id],
      having: sum(txn.amount) > ^gt,
      order_by: cont.name
    )
    |> Repo.all()
  end

  defp balance_sheet_query(at_date, com) do
    bs_acc =
      FullCircle.Accounting.balance_sheet_account_types()
      |> Enum.reject(fn x -> x == "Inventory" end)

    a =
      from(ac in Account,
        join: txn in Transaction,
        on: ac.id == txn.account_id,
        where: ac.company_id == ^com.id,
        where: ac.account_type in ^bs_acc,
        where: txn.doc_date <= ^at_date,
        select: %{id: ac.id, type: ac.account_type, name: ac.name, balance: sum(txn.amount)},
        group_by: [ac.account_type, ac.id],
        having: sum(txn.amount) != 0
      )

    b =
      from(ac in Account,
        join: txn in Transaction,
        on: ac.id == txn.account_id,
        where: ac.company_id == ^com.id,
        where: ac.account_type == "Inventory",
        where: txn.doc_date <= ^at_date,
        where: txn.doc_date > ^prev_close_date(at_date, com),
        select: %{id: ac.id, type: ac.account_type, name: ac.name, balance: sum(txn.amount)},
        group_by: [ac.account_type, ac.id],
        having: sum(txn.amount) != 0
      )

    union_all(a, ^b)
  end

  defp profit_loss_query(at_date, com) do
    from(ac in Account,
      join: txn in Transaction,
      on: ac.id == txn.account_id,
      where: ac.company_id == ^com.id,
      where: ac.account_type in ^FullCircle.Accounting.profit_loss_account_types(),
      where: txn.doc_date <= ^at_date,
      where: txn.doc_date > ^prev_close_date(at_date, com),
      select: %{id: ac.id, type: ac.account_type, name: ac.name, balance: sum(txn.amount)},
      group_by: [ac.account_type, ac.id],
      having: sum(txn.amount) != 0
    )
  end

  def balance_sheet(at_date, com) do
    balance_sheet_query(at_date, com)
    |> order_by([2, 3])
    |> Repo.all()
  end

  def profit_loss(at_date, com) do
    profit_loss_query(at_date, com)
    |> order_by([2, 3])
    |> Repo.all()
  end

  def trail_balance(at_date, com) do
    union_all(profit_loss_query(at_date, com), ^balance_sheet_query(at_date, com))
    |> order_by([2, 3])
    |> Repo.all()
  end

  def statements(ids, sdate, edate, com) do
    conts =
      from(cont in Contact,
        where: cont.id in ^ids,
        where: cont.company_id == ^com.id,
        select: cont
      )
      |> Repo.all()

    agings =
      (contact_aging_query(ids, edate, 30, com.id) <> " and p1 + p2 + p3 + p4 + p5 >= 0")
      |> exec_query()
      |> fix_unmatch_balance("debtor")

    conts
    |> Enum.map(fn c ->
      c
      |> Map.merge(%{aging: Enum.find(agings, fn a -> a.contact_id == c.id end)})
      |> Map.merge(%{
        transactions:
          contact_transactions(c, sdate, edate, com)
          |> Enum.map(fn a -> Map.merge(a, %{running: Decimal.to_float(a.amount)}) end)
          |> Enum.scan(fn h1, h2 ->
            Map.merge(h1, %{running: h1.running + h2.running})
          end)
      })
    end)
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

  def debtor_aging_report(edate, days, com_id) do
    (contact_aging_query(edate, days, com_id) <> " and p1 + p2 + p3 + p4 + p5 > 0")
    |> exec_query()
    |> fix_unmatch_balance("debtor")
  end

  def creditor_aging_report(edate, days, com_id) do
    (contact_aging_query(edate, days, com_id) <> " and p1 + p2 + p3 + p4 + p5 < 0")
    |> exec_query()
    |> fix_unmatch_balance("creditor")
  end

  defp fix_unmatch_balance(list, debcre) do
    list
    |> Enum.map(fn %{
                     contact_id: id,
                     contact_name: cn,
                     p1: p1,
                     p2: p2,
                     p3: p3,
                     p4: p4,
                     p5: p5,
                     total: tot
                   } ->
      {_, k} =
        fix_total(
          [
            p5 |> Decimal.to_float(),
            p4 |> Decimal.to_float(),
            p3 |> Decimal.to_float(),
            p2 |> Decimal.to_float(),
            p1 |> Decimal.to_float()
          ],
          {0, []},
          debcre
        )

      %{
        contact_id: id,
        contact_name: cn,
        p1: Enum.at(k, 0),
        p2: Enum.at(k, 1),
        p3: Enum.at(k, 2),
        p4: Enum.at(k, 3),
        p5: Enum.at(k, 4),
        total: tot
      }
    end)
  end

  def fix_total([h | t], {acc, a}, "debtor") do
    cond do
      h + acc < 0 -> fix_total(t, {h + acc, [0 | a]}, "debtor")
      true -> {h + acc, [t |> Enum.reverse(), h + acc | a] |> List.flatten()}
    end
  end

  def fix_total([h | t], {acc, a}, "creditor") do
    cond do
      h + acc > 0 -> fix_total(t, {h + acc, [0 | a]}, "creditor")
      true -> {h + acc, [t |> Enum.reverse(), h + acc | a] |> List.flatten()}
    end
  end

  def fix_total([], {acc, a}, _debcre) do
    {acc, a}
  end

  defp contact_aging_query(ids, edate, days, com_id) do
    "with
        has_balance_contacts as (
          select c.id, c.name
            from contacts c
           where c.company_id = '#{com_id}'
             and c.id = ANY('{#{Enum.join(ids, ",")}}')
           group by c.id),
        has_balance_txn as (
          select t.doc_date, t.doc_type, t.doc_no, t.doc_id, t.contact_id, c.name as contact_name,
                 t.amount + coalesce(sum(stm.match_amount), 0) + coalesce(sum(tm.match_amount), 0) as balance
            from transactions t inner join has_balance_contacts c
              on c.id = t.contact_id left outer join seed_transaction_matchers stm
              on stm.transaction_id = t.id and stm.m_doc_date <= '#{edate}' left outer join transaction_matchers tm
              on tm.transaction_id = t.id and tm.doc_date <= '#{edate}'
           where t.contact_id is not null
             and t.doc_date <= '#{edate}'
           group by t.id, c.name
          having t.amount + coalesce(sum(stm.match_amount), 0) + coalesce(sum(tm.match_amount), 0) <> 0),
        has_balance_txn_1 as (
          select hbt.doc_date, hbt.doc_type, hbt.doc_no, hbt.contact_id, hbt.contact_name,
                 hbt.balance - coalesce(sum(stm.match_amount), 0) - coalesce(sum(tm.match_amount), 0) as balance
            from has_balance_txn hbt left outer join seed_transaction_matchers stm
              on stm.m_doc_type = hbt.doc_type and stm.m_doc_id::varchar = hbt.doc_no
            left outer join transaction_matchers tm
              on tm.doc_type = hbt.doc_type and tm.doc_id = hbt.doc_id
           group by hbt.doc_date, hbt.doc_type, hbt.doc_no, hbt.contact_id, hbt.contact_name, hbt.balance
          having hbt.balance - coalesce(sum(stm.match_amount), 0) - coalesce(sum(tm.match_amount), 0)  <> 0),
        aging_list as (
          select contact_name, contact_id,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days} then balance else 0 end) as p1,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days * 2} and
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days} then balance else 0 end) as p2,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days * 3} and
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days * 2} then balance else 0 end) as p3,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days * 4} and
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days * 3} then balance else 0 end) as p4,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days * 4} then balance else 0 end) as p5
            from has_balance_txn_1
           group by contact_name, contact_id)

        select contact_id, contact_name, p1, p2, p3, p4, p5,
               p1 + p2 + p3 + p4 + p5 as total
          from aging_list where true
    "
  end

  defp contact_aging_query(edate, days, com_id) do
    "with
        has_balance_contacts as (
          select c.id, c.name
            from contacts c inner join transactions t
              on t.contact_id = c.id
           where t.doc_date <= '#{edate}'
             and c.company_id = '#{com_id}'
           group by c.id
          having sum(t.amount) <> 0),
        has_balance_txn as (
          select t.doc_date, t.doc_type, t.doc_no, t.doc_id, t.contact_id, c.name as contact_name,
                 t.amount + coalesce(sum(stm.match_amount), 0) + coalesce(sum(tm.match_amount), 0) as balance
            from transactions t inner join has_balance_contacts c
              on c.id = t.contact_id left outer join seed_transaction_matchers stm
              on stm.transaction_id = t.id and stm.m_doc_date <= '#{edate}' left outer join transaction_matchers tm
              on tm.transaction_id = t.id and tm.doc_date <= '#{edate}'
           where t.contact_id is not null
             and t.doc_date <= '#{edate}'
           group by t.id, c.name
          having t.amount + coalesce(sum(stm.match_amount), 0) + coalesce(sum(tm.match_amount), 0) <> 0
        ),
        has_balance_txn_1 as (
          select hbt.doc_date, hbt.doc_type, hbt.doc_no, hbt.contact_id, hbt.contact_name,
                 hbt.balance - coalesce(sum(stm.match_amount), 0) - coalesce(sum(tm.match_amount), 0) as balance
            from has_balance_txn hbt left outer join seed_transaction_matchers stm
              on stm.m_doc_type = hbt.doc_type and stm.m_doc_id::varchar = hbt.doc_no
            left outer join transaction_matchers tm
              on tm.doc_type = hbt.doc_type and tm.doc_id = hbt.doc_id
           group by hbt.doc_date, hbt.doc_type, hbt.doc_no, hbt.contact_id, hbt.contact_name, hbt.balance
          having hbt.balance - coalesce(sum(stm.match_amount), 0) - coalesce(sum(tm.match_amount), 0)  <> 0),
        aging_list as (
          select contact_name, contact_id,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days} then balance else 0 end) as p1,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days * 2} and
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days} then balance else 0 end) as p2,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days * 3} and
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days * 2} then balance else 0 end) as p3,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) <= #{days * 4} and
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days * 3} then balance else 0 end) as p4,
                 sum(case when
                       extract(day from '#{edate}'::timestamp - doc_date::timestamp) > #{days * 4} then balance else 0 end) as p5
            from has_balance_txn_1
           group by contact_name, contact_id)

        select contact_id, contact_name, p1, p2, p3, p4, p5,
               p1 + p2 + p3 + p4 + p5 as total
          from aging_list where true
    "
  end
end
