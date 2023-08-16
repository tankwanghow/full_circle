defmodule FullCircle.BillPay do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.BillPay.{Payment, PaymentDetail}

  alias FullCircle.Accounting.{
    Contact,
    Transaction,
    TaxCode,
    TransactionMatcher
  }

  alias FullCircle.{Sys, Accounting}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface
  alias Ecto.Multi

  def get_print_payments!(ids, company, user) do
    Repo.all(
      from pay in Payment,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == pay.company_id,
        where: pay.id in ^ids,
        preload: [:contact, :funds_account],
        preload: [transaction_matchers: ^payment_match_trans(company, user)],
        preload: [payment_details: ^payment_details()],
        select: pay
    )
    |> Enum.map(fn x -> Payment.compute_struct_balance(x) end)
  end

  def get_payment!(id, company, user) do
    Repo.one(
      from pay in Payment,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == pay.company_id,
        join: cont in Contact,
        on: cont.id == pay.contact_id,
        left_join: funds in Account,
        on: funds.id == pay.funds_account_id,
        where: pay.id == ^id,
        preload: [transaction_matchers: ^payment_match_trans(company, user)],
        preload: [payment_details: ^payment_details()],
        group_by: [pay.id, pay.payment_no, pay.descriptions, funds.name, cont.name],
        select: pay,
        select_merge: %{contact_name: cont.name, funds_account_name: funds.name}
    )
  end

  defp payment_details do
    from payd in PaymentDetail,
      join: good in Good,
      on: good.id == payd.good_id,
      join: ac in Account,
      on: payd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == payd.tax_code_id,
      left_join: pkg in Packaging,
      on: pkg.id == payd.package_id,
      order_by: payd._persistent_id,
      select: payd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        unit_multiplier: pkg.unit_multiplier,
        tax_rate: payd.tax_rate,
        tax_code_name: tc.code,
        tax_amount:
          fragment(
            "round(?, 2)",
            (payd.quantity * payd.unit_price + payd.discount) * payd.tax_rate
          ),
        good_amount:
          fragment(
            "round(?, 2)",
            payd.quantity * payd.unit_price + payd.discount
          ),
        amount:
          fragment(
            "round(?, 2)",
            payd.quantity * payd.unit_price + payd.discount +
              (payd.quantity * payd.unit_price + payd.discount) * payd.tax_rate
          )
      }
  end

  defp payment_match_trans(com, user) do
    from paymt in TransactionMatcher,
      join: txn in subquery(Accounting.transaction_with_balance_query(com, user)),
      on: txn.id == paymt.transaction_id,
      where: paymt.entity == "payments",
      order_by: paymt._persistent_id,
      select: paymt,
      select_merge: %{
        transaction_id: txn.id,
        doc_date: txn.doc_date,
        doc_type: txn.doc_type,
        doc_no: txn.doc_no,
        amount: txn.amount,
        all_matched_amount: txn.all_matched_amount - paymt.match_amount,
        particulars: txn.particulars,
        balance: txn.amount + txn.all_matched_amount,
        match_amount: paymt.match_amount
      }
  end

  def payment_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(payment_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:payment_no, :contact_name, :particulars], terms)
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.payment_date >= ^date_from, order_by: inv.payment_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_payment_by_id_index_component_field!(id, com, user) do
    from(i in subquery(payment_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp payment_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "payments",
      left_join: pay in Payment,
      on: txn.doc_no == pay.payment_no,
      join: cont in Contact,
      on: cont.id == pay.contact_id or cont.id == txn.contact_id,
      order_by: [desc: txn.inserted_at],
      where: txn.amount > 0,
      select: %{
        id: coalesce(pay.id, txn.id),
        payment_no: txn.doc_no,
        particulars:
          fragment(
            "string_agg(distinct coalesce(?, ?), ', ')",
            txn.contact_particulars,
            txn.particulars
          ),
        payment_date: txn.doc_date,
        updated_at: txn.inserted_at,
        company_id: com.id,
        contact_name: cont.name,
        amount: sum(txn.amount),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(pay.id, txn.id),
        txn.doc_no,
        cont.name,
        txn.doc_date,
        com.id,
        txn.old_data,
        txn.inserted_at
      ]
  end

  def create_payment(attrs, com, user) do
    case can?(user, :create_payment, com) do
      true ->
        Multi.new()
        |> create_payment_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_payment_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    payment_name = :create_payment

    multi
    |> get_gapless_doc_id(gapless_name, "payments", "PV", com)
    |> Multi.insert(
      payment_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)
        StdInterface.changeset(Payment, %Payment{}, Map.merge(attrs, %{"payment_no" => doc}), com)
      end
    )
    |> Multi.insert("#{payment_name}_log", fn %{^payment_name => entity} ->
      FullCircle.Sys.log_changeset(
        payment_name,
        entity,
        Map.merge(attrs, %{"payment_no" => entity.payment_no}),
        com,
        user
      )
    end)
    |> create_payment_transactions(payment_name, com, user)
  end

  defp create_payment_transactions(multi, name, com, _user) do
    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => payment} ->
      payment =
        payment
        |> FullCircle.Repo.preload([:payment_details, :transaction_matchers])

      # Debit Transactions
      if payment.payment_details != Ecto.Association.NotLoaded do
        Enum.each(payment.payment_details, fn x ->
          x = FullCircle.Repo.preload(x, [:account, :tax_code])

          if !Decimal.eq?(x.good_amount, 0) do
            repo.insert!(%Transaction{
              doc_type: "payments",
              doc_no: payment.payment_no,
              doc_date: payment.payment_date,
              contact_id:
                if(Accounting.is_balance_sheet_account?(x.account),
                  do: payment.contact_id,
                  else: nil
                ),
              account_id: x.account_id,
              company_id: com.id,
              amount: x.good_amount,
              particulars: "#{payment.contact_name}, #{x.good_name}"
            })
          end

          if !Decimal.eq?(x.tax_amount, 0) do
            repo.insert!(%Transaction{
              doc_type: "payments",
              doc_no: payment.payment_no,
              doc_date: payment.payment_date,
              account_id: x.tax_code.account_id,
              company_id: com.id,
              amount: x.tax_amount,
              particulars: "#{x.tax_code_name} on #{x.good_name}"
            })
          end
        end)
      end

      # follow matched amount
      if payment.transaction_matchers != Ecto.Association.NotLoaded do
        Enum.group_by(payment.transaction_matchers, fn m ->
          m = FullCircle.Repo.preload(m, :transaction)
          m.transaction.account_id
        end)
        |> Enum.map(fn {k, v} ->
          %{
            account_id: k,
            match_doc_nos: Enum.map(v, fn x -> x.doc_no end) |> Enum.join(", "),
            amount: Enum.reduce(v, 0, fn x, acc -> Decimal.add(acc, x.match_amount) end)
          }
        end)
        |> Enum.each(fn x ->
          repo.insert!(%Transaction{
            doc_type: "payments",
            doc_no: payment.payment_no,
            doc_date: payment.payment_date,
            contact_id: payment.contact_id,
            account_id: x.account_id,
            particulars: "Payment to #{payment.contact_name}",
            contact_particulars: "Payment for " <> x.match_doc_nos,
            company_id: com.id,
            amount: x.amount
          })
        end)
      end

      if Decimal.gt?(payment.funds_amount, 0) do
        repo.insert!(%Transaction{
          doc_type: "payments",
          doc_no: payment.payment_no,
          doc_date: payment.payment_date,
          account_id: payment.funds_account_id,
          company_id: com.id,
          amount: Decimal.negate(payment.funds_amount),
          particulars: "Payment to #{payment.contact_name}"
        })
      end

      {:ok, nil}
    end)
  end

  def update_payment(%Payment{} = payment, attrs, com, user) do
    case can?(user, :update_payment, com) do
      true ->
        Multi.new()
        |> update_payment_multi(payment, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_payment_multi(multi, payment, attrs, com, user) do
    payment_name = :update_payment

    multi
    |> Multi.update(payment_name, StdInterface.changeset(Payment, payment, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "payments",
        where: txn.doc_no == ^payment.payment_no
      )
    )
    |> Sys.insert_log_for(payment_name, attrs, com, user)
    |> create_payment_transactions(payment_name, com, user)
  end
end
