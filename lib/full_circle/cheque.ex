defmodule FullCircle.Cheque do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.Cheque.{Deposit, ReturnCheque}
  alias FullCircle.Accounting.{Account, Transaction}
  alias FullCircle.{Repo, Sys, StdInterface, Accounting}
  alias Ecto.Multi

  def get_print_return_cheque!(ids, company, user) do
    Repo.all(
      from rtnq in ReturnCheque,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rtnq.company_id,
        join: chq in FullCircle.ReceiveFund.ReceivedCheque,
        on: chq.return_cheque_id == rtnq.id,
        left_join: owner in FullCircle.Accounting.Contact,
        on: owner.id == rtnq.cheque_owner_id,
        left_join: bank in Account,
        on: bank.id == rtnq.return_from_bank_id,
        where: rtnq.id in ^ids,
        preload: [:cheque, :cheque_owner],
        select: rtnq,
        select_merge: %{
          return_from_bank_name: bank.name,
          return_from_bank_id: bank.id,
          cheque_owner_name: owner.name,
          cheque_owner_id: owner.id,
          cheque_no: chq.cheque_no,
          cheque_due_date: chq.due_date,
          cheque_amount: chq.amount
        }
    )
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("return_cheques", x.id, x.company_id)})
    end)
  end

  def get_return_cheque!(id, company, user) do
    Repo.one(
      from rtnq in ReturnCheque,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rtnq.company_id,
        join: chq in FullCircle.ReceiveFund.ReceivedCheque,
        on: chq.return_cheque_id == rtnq.id,
        left_join: owner in FullCircle.Accounting.Contact,
        on: owner.id == rtnq.cheque_owner_id,
        left_join: bank in Account,
        on: bank.id == rtnq.return_from_bank_id,
        where: rtnq.id == ^id,
        preload: [:cheque],
        select: rtnq,
        select_merge: %{
          return_from_bank_name: bank.name,
          return_from_bank_id: bank.id,
          cheque_owner_name: owner.name,
          cheque_owner_id: owner.id,
          cheque_no: chq.cheque_no,
          cheque_due_date: chq.due_date,
          cheque_amount: chq.amount
        }
    )
  end

  def return_cheque_index_query(terms, r_date, com, user, page: page, per_page: per_page) do
    from(q in subquery(return_cheque_raw_query(com, user)))
    |> apply_simple_filters(terms, r_date,
      search_fields: [:particulars, :doc_no],
      date_field: :doc_date
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  defp return_cheque_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "ReturnCheque",
      join: owner in FullCircle.Accounting.Contact,
      on: owner.id == txn.contact_id,
      left_join: rtnq in ReturnCheque,
      on: txn.doc_id == rtnq.id,
      left_join: rtn_bank in FullCircle.Accounting.Account,
      on: rtn_bank.id == rtnq.return_from_bank_id,
      where: txn.amount > 0,
      select: txn,
      select_merge: %{
        doc_date: txn.doc_date,
        return_from_bank_name: rtn_bank.name,
        cheque_owner_name: owner.name,
        return_reason: rtnq.return_reason,
        return_id: rtnq.id
      }
  end

  def deposit_index_query(terms, d_date, com, user, page: page, per_page: per_page) do
    from(q in subquery(deposit_raw_query(com, user)))
    |> apply_simple_filters(terms, d_date,
      search_fields: [:particulars, :deposit_no, :deposit_bank_name],
      date_field: :deposit_date
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  defp deposit_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "Deposit",
      join: bank in Account,
      on: bank.id == txn.account_id,
      left_join: dep in Deposit,
      on: txn.doc_no == dep.deposit_no,
      left_join: funds_from in Account,
      on: funds_from.id == dep.funds_from_id,
      where: txn.amount > 0,
      select: %{
        id: txn.id,
        deposit_id: dep.id,
        deposit_no: txn.doc_no,
        deposit_date: txn.doc_date,
        deposit_bank_name: bank.name,
        particulars: txn.particulars,
        amount: txn.amount,
        old_data: txn.old_data
      }
  end

  def get_deposit!(id, company, user) do
    Repo.one(
      from dep in Deposit,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == dep.company_id,
        join: bank in Account,
        on: bank.id == dep.bank_id,
        left_join: funds_from in Account,
        on: funds_from.id == dep.funds_from_id,
        where: dep.id == ^id,
        preload: [:cheques],
        select: dep,
        select_merge: %{bank_name: bank.name, funds_from_name: funds_from.name}
    )
  end

  def create_deposit(attrs, com, user) do
    case can?(user, :create_deposit, com) do
      true ->
        Multi.new()
        |> create_deposit_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_deposit_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    deposit_name = :create_deposit

    multi
    |> get_gapless_doc_id(gapless_name, "Deposit", "DS", com)
    |> Multi.insert(deposit_name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(Deposit, %Deposit{}, Map.merge(attrs, %{"deposit_no" => doc}), com)
    end)
    |> Multi.insert("#{deposit_name}_log", fn %{^deposit_name => entity} ->
      FullCircle.Sys.log_changeset(
        deposit_name,
        entity,
        Map.merge(attrs, %{"deposit_no" => entity.deposit_no}),
        com,
        user
      )
    end)
    |> create_deposit_transactions(deposit_name, com, user)
  end

  def update_deposit(%Deposit{} = deposit, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "deposit_no")

    case can?(user, :update_deposit, com) do
      true ->
        Multi.new()
        |> update_deposit_multi(deposit, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_deposit_multi(multi, deposit, attrs, com, user) do
    deposit_name = :update_deposit

    cs = Deposit.changeset(deposit, attrs)

    multi
    |> Multi.update(deposit_name, cs)
    |> Sys.insert_log_for(deposit_name, attrs, com, user)
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "Deposit",
        where: txn.doc_no == ^deposit.deposit_no,
        where: txn.doc_id == ^deposit.id,
        where: txn.company_id == ^com.id
      )
    )
    |> create_deposit_transactions(deposit_name, com, user)
  end

  # ── Return Cheque ───────────────────────────────────

  def create_return_cheque(attrs, com, user) do
    case can?(user, :create_return_cheque, com) do
      true ->
        Multi.new()
        |> create_return_cheque_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_return_cheque_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    return_name = :create_return_cheque

    multi
    |> get_gapless_doc_id(gapless_name, "ReturnCheque", "RQ", com)
    |> Multi.insert(return_name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(
        ReturnCheque,
        %ReturnCheque{},
        Map.merge(attrs, %{"return_no" => doc}),
        com
      )
    end)
    |> Multi.insert("#{return_name}_log", fn %{^return_name => entity} ->
      FullCircle.Sys.log_changeset(
        return_name,
        entity,
        Map.merge(attrs, %{"return_no" => entity.return_no}),
        com,
        user
      )
    end)
    |> create_return_cheque_transactions(return_name, com, user)
  end

  def update_return_cheque(%ReturnCheque{} = return_cheque, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "return_no")

    case can?(user, :update_return_cheque, com) do
      true ->
        Multi.new()
        |> update_return_cheque_multi(return_cheque, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_return_cheque_multi(multi, return_cheque, attrs, com, user) do
    return_cheque_name = :update_return_cheque

    cs = ReturnCheque.changeset(return_cheque, attrs)

    multi
    |> Multi.update(return_cheque_name, cs)
    |> Sys.insert_log_for(return_cheque_name, attrs, com, user)
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "ReturnCheque",
        where: txn.doc_no == ^return_cheque.return_no,
        where: txn.doc_id == ^return_cheque.id,
        where: txn.company_id == ^com.id
      )
    )
    |> create_return_cheque_transactions(return_cheque_name, com, user)
  end

  # ── Private Helpers ─────────────────────────────────

  defp apply_simple_filters(qry, terms, date_from, opts) do
    search_fields = Keyword.fetch!(opts, :search_fields)
    date_field = Keyword.fetch!(opts, :date_field)

    qry =
      if terms != "" do
        from rec in subquery(qry),
          order_by: ^similarity_order(search_fields, terms)
      else
        qry
      end

    if date_from != "" do
      from rec in qry,
        where: field(rec, ^date_field) >= ^date_from,
        order_by: field(rec, ^date_field)
    else
      from rec in qry, order_by: [desc: field(rec, ^date_field)]
    end
  end

  defp create_deposit_transactions(multi, name, com, user) do
    pdc_id = Accounting.get_account_by_name("Post Dated Cheques", com, user).id

    multi
    |> Multi.insert_all(:insert_transactions, Transaction, fn %{^name => deposit} ->
      deposit = Repo.preload(deposit, [:cheques])
      now = Timex.now() |> DateTime.truncate(:second)

      (build_deposit_funds_transactions(deposit, com, now) ++
         build_deposit_cheque_transactions(deposit, com, now, pdc_id))
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp build_deposit_funds_transactions(deposit, com, now) do
    if Decimal.gt?(deposit.funds_amount, 0) do
      [
        %{
          doc_type: "Deposit",
          doc_no: deposit.deposit_no,
          doc_id: deposit.id,
          doc_date: deposit.deposit_date,
          account_id: deposit.funds_from_id,
          company_id: com.id,
          amount: Decimal.negate(deposit.funds_amount),
          particulars: "To #{deposit.bank_name}",
          inserted_at: now
        },
        %{
          doc_type: "Deposit",
          doc_no: deposit.deposit_no,
          doc_id: deposit.id,
          doc_date: deposit.deposit_date,
          account_id: deposit.bank_id,
          company_id: com.id,
          amount: deposit.funds_amount,
          particulars: "From #{deposit.funds_from_name}",
          inserted_at: now
        }
      ]
    else
      []
    end
  end

  defp build_deposit_cheque_transactions(deposit, com, now, pdc_id) do
    Enum.flat_map(deposit.cheques, fn x ->
      [
        %{
          doc_type: "Deposit",
          doc_no: deposit.deposit_no,
          doc_id: deposit.id,
          doc_date: deposit.deposit_date,
          account_id: pdc_id,
          company_id: com.id,
          amount: Decimal.negate(x.amount),
          particulars: "#{x.bank} #{x.cheque_no} to #{deposit.bank_name}",
          inserted_at: now
        },
        %{
          doc_type: "Deposit",
          doc_no: deposit.deposit_no,
          doc_id: deposit.id,
          doc_date: deposit.deposit_date,
          account_id: deposit.bank_id,
          company_id: com.id,
          amount: x.amount,
          particulars: "#{x.bank} #{x.cheque_no}",
          inserted_at: now
        }
      ]
    end)
  end

  defp create_return_cheque_transactions(multi, name, com, user) do
    ar_id = Accounting.get_account_by_name("Account Receivables", com, user).id
    pdc_id = Accounting.get_account_by_name("Post Dated Cheques", com, user).id

    multi
    |> Multi.insert_all(:insert_transactions, Transaction, fn %{^name => rtnq} ->
      rtnq = Repo.preload(rtnq, [:cheque])
      now = Timex.now() |> DateTime.truncate(:second)

      build_return_cheque_transactions(rtnq, com, now, ar_id, pdc_id)
    end)
  end

  defp build_return_cheque_transactions(rtnq, com, now, ar_id, pdc_id) do
    credit_txn =
      if is_nil(rtnq.return_from_bank_id) do
        %{
          doc_type: "ReturnCheque",
          doc_no: rtnq.return_no,
          doc_id: rtnq.id,
          doc_date: rtnq.return_date,
          account_id: pdc_id,
          company_id: com.id,
          amount: Decimal.negate(rtnq.cheque_amount),
          particulars:
            "Return #{rtnq.cheque.bank} #{rtnq.cheque.cheque_no} #{rtnq.return_reason} to #{rtnq.cheque_owner_name}",
          inserted_at: now
        }
      else
        %{
          doc_type: "ReturnCheque",
          doc_no: rtnq.return_no,
          doc_id: rtnq.id,
          doc_date: rtnq.return_date,
          account_id: rtnq.return_from_bank_id,
          company_id: com.id,
          amount: Decimal.negate(rtnq.cheque_amount),
          particulars:
            "Return #{rtnq.cheque.bank} #{rtnq.cheque.cheque_no} #{rtnq.return_reason}",
          inserted_at: now
        }
      end

    debit_txn = %{
      doc_type: "ReturnCheque",
      doc_no: rtnq.return_no,
      doc_id: rtnq.id,
      doc_date: rtnq.return_date,
      account_id: ar_id,
      contact_id: rtnq.cheque_owner_id,
      company_id: com.id,
      amount: rtnq.cheque_amount,
      contact_particulars:
        "Return #{rtnq.cheque.bank} #{rtnq.cheque.cheque_no} #{rtnq.return_reason}",
      particulars:
        "Return #{rtnq.cheque.bank} #{rtnq.cheque_no} #{rtnq.return_reason} to #{rtnq.cheque_owner_name}",
      inserted_at: now
    }

    [credit_txn, debit_txn]
  end
end
