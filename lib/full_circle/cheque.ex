defmodule FullCircle.Cheque do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  
  alias FullCircle.Cheque.{Deposit}

  alias FullCircle.Accounting.{
    Account,
    Transaction
  }

  alias FullCircle.{Repo, Sys, StdInterface}
  alias Ecto.Multi

  def deposit_index_query(terms, d_date, com, user, page: page, per_page: per_page) do
    qry = from(q in subquery(deposit_raw_query(com, user)))

    qry =
      if terms != "" do
        from rec in qry,
          order_by: ^similarity_order([:particulars, :deposit_no, :deposit_bank_name], terms)
      else
        qry
      end

    qry =
      if d_date != "" do
        from rec in qry, where: rec.deposit_date >= ^d_date, order_by: [desc: rec.deposit_date]
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
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
      order_by: [desc: txn.inserted_at],
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
    |> Multi.insert(
      deposit_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)
        StdInterface.changeset(Deposit, %Deposit{}, Map.merge(attrs, %{"deposit_no" => doc}), com)
      end
    )
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

  defp create_deposit_transactions(multi, name, com, user) do
    pdc_id =
      FullCircle.Accounting.get_account_by_name("Post Dated Cheques Received", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => deposit} ->
      deposit = deposit |> FullCircle.Repo.preload([:cheques])

      if Decimal.gt?(deposit.funds_amount, 0) do
        repo.insert!(%Transaction{
          doc_type: "Deposit",
          doc_no: deposit.deposit_no,
          doc_id: deposit.id,
          doc_date: deposit.deposit_date,
          account_id: deposit.funds_from_id,
          company_id: com.id,
          amount: Decimal.negate(deposit.funds_amount),
          particulars: "To #{deposit.bank_name}"
        })

        repo.insert!(%Transaction{
          doc_type: "Deposit",
          doc_no: deposit.deposit_no,
          doc_id: deposit.id,
          doc_date: deposit.deposit_date,
          account_id: deposit.bank_id,
          company_id: com.id,
          amount: deposit.funds_amount,
          particulars: "From #{deposit.funds_from_name}"
        })
      end

      if deposit.cheques != Ecto.Association.NotLoaded do
        Enum.each(deposit.cheques, fn x ->
          repo.insert!(%Transaction{
            doc_type: "Deposit",
            doc_no: deposit.deposit_no,
            doc_id: deposit.id,
            doc_date: deposit.deposit_date,
            account_id: pdc_id,
            company_id: com.id,
            amount: Decimal.negate(x.amount),
            particulars: "#{x.bank} #{x.cheque_no} to #{deposit.bank_name}"
          })

          repo.insert!(%Transaction{
            doc_type: "Deposit",
            doc_no: deposit.deposit_no,
            doc_id: deposit.id,
            doc_date: deposit.deposit_date,
            account_id: deposit.bank_id,
            company_id: com.id,
            amount: x.amount,
            particulars: "#{x.bank} #{x.cheque_no}"
          })
        end)
      end

      {:ok, nil}
    end)
  end

  def update_deposit(%Deposit{} = deposit, attrs, com, user) do
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
end
