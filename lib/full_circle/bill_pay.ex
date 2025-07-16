defmodule FullCircle.BillPay do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.BillPay.{Payment, PaymentDetail}

  alias FullCircle.Accounting.{
    TransactionMatcher,
    Contact,
    Account,
    Transaction,
    TaxCode
  }

  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.{Sys, Accounting}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.Accounting.Account
  alias FullCircle.StdInterface
  alias Ecto.Multi

  def get_payment_by_no!(no, com, user) do
    id =
      Repo.one(
        from obj in Payment,
          join: com in subquery(Sys.user_company(com, user)),
          on: com.id == obj.company_id,
          where: obj.payment_no == ^no,
          select: obj.id
      )

    get_payment!(id, com, user)
  end

  def get_print_payments!(ids, company, user) do
    Repo.all(
      from pay in Payment,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == pay.company_id,
        left_join: einv in EInvoice,
        on: einv.uuid == pay.e_inv_uuid,
        where: pay.id in ^ids,
        preload: [:contact, :funds_account],
        preload: [transaction_matchers: ^payment_match_trans(company, user)],
        preload: [payment_details: ^payment_details()],
        select: pay,
        select_merge: %{e_inv_long_id: einv.longId}
    )
    |> Enum.map(fn x -> Payment.compute_struct_balance(x) end)
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("payments", x.id, x.company_id)})
    end)
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
        left_join: einv in EInvoice,
        on: einv.uuid == pay.e_inv_uuid,
        where: pay.id == ^id,
        preload: [transaction_matchers: ^payment_match_trans(company, user)],
        preload: [payment_details: ^payment_details()],
        select: pay,
        select_merge: %{
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          funds_account_name: funds.name,
          e_inv_long_id: einv.longId
        },
        select_merge: %{matched_amount: coalesce(subquery(matched_amount(id)), 0)},
        select_merge: %{payment_tax_amount: coalesce(subquery(payment_tax_amount(id)), 0)},
        select_merge: %{payment_good_amount: coalesce(subquery(payment_good_amount(id)), 0)},
        select_merge: %{payment_detail_amount: coalesce(subquery(payment_detail_amount(id)), 0)}
    )
  end

  defp matched_amount(id) do
    from mat in TransactionMatcher,
      where: mat.doc_type == "Payment",
      where: mat.doc_id == ^id,
      select: sum(mat.match_amount)
  end

  defp payment_tax_amount(id) do
    from dtl in PaymentDetail,
      where: dtl.payment_id == ^id,
      select:
        fragment(
          "sum(round((?*?+?)*?, 2))",
          dtl.quantity,
          dtl.unit_price,
          dtl.discount,
          dtl.tax_rate
        )
  end

  defp payment_good_amount(id) do
    from dtl in PaymentDetail,
      where: dtl.payment_id == ^id,
      select:
        fragment(
          "sum(round(?*?+?, 2))",
          dtl.quantity,
          dtl.unit_price,
          dtl.discount
        )
  end

  defp payment_detail_amount(id) do
    from dtl in PaymentDetail,
      where: dtl.payment_id == ^id,
      select:
        fragment(
          "sum(round(?*?+?+(?*?+?)*?, 2))",
          dtl.quantity,
          dtl.unit_price,
          dtl.discount,
          dtl.quantity,
          dtl.unit_price,
          dtl.discount,
          dtl.tax_rate
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
      where: paymt.doc_type == "Payment",
      order_by: paymt._persistent_id,
      select: paymt,
      select_merge: %{
        transaction_id: txn.id,
        t_doc_date: txn.doc_date,
        t_doc_type: txn.doc_type,
        t_doc_no: txn.doc_no,
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
        from inv in qry, order_by: [desc: inv.payment_date]
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_payment_by_id_index_component_field!(id, com, user) do
    from(i in subquery(payment_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp payment_raw_query(company, _user) do
    # Define the CTE for receipt_details aggregation
    details_agg =
      from rd in PaymentDetail,
        group_by: rd.payment_id,
        select: %{
          payment_id: rd.payment_id,
          details_amount: sum(rd.quantity * rd.unit_price + rd.discount),
          tax_amount: sum((rd.quantity * rd.unit_price + rd.discount) * rd.tax_rate)
        }

    # Define the CTE for transaction_matchers aggregation
    matchers_agg =
      from tm in TransactionMatcher,
        group_by: tm.doc_id,
        select: %{
          doc_id: tm.doc_id,
          matched_amount: sum(tm.match_amount)
        }

    # Build the main query
    base_query =
      from st0 in Transaction,
        left_join: sr1 in Payment,
        on: st0.doc_id == sr1.id,
        join: sc2 in Contact,
        on: sc2.id == coalesce(sr1.contact_id, st0.contact_id),
        left_join: sr4 in PaymentDetail,
        on: sr4.payment_id == sr1.id,
        left_join: da in "details_agg",
        on: da.payment_id == sr1.id,
        left_join: ma in "matchers_agg",
        on: ma.doc_id == sr1.id,
        where:
          st0.company_id == ^company.id and
            st0.doc_type == "Payment" and
            st0.amount > 0,
        group_by: [
          coalesce(st0.doc_id, st0.id),
          st0.doc_no,
          sc2.id,
          sr1.id,
          st0.doc_date,
          st0.company_id,
          st0.old_data,
          sr1.funds_amount,
          da.details_amount,
          da.tax_amount,
          ma.matched_amount
        ],
        order_by: [desc: st0.doc_no],
        select: %{
          id: coalesce(st0.doc_id, st0.id),
          doc_type: "Payment",
          doc_id: coalesce(st0.doc_id, st0.id),
          payment_no: st0.doc_no,
          e_inv_uuid: sr1.e_inv_uuid,
          e_inv_internal_id: sr1.e_inv_internal_id,
          got_details: count(sr4.id),
          particulars:
            fragment(
              "STRING_AGG(DISTINCT COALESCE(?, ?), ', ')",
              st0.contact_particulars,
              st0.particulars
            ),
          payment_date: st0.doc_date,
          company_id: st0.company_id,
          contact_name: sc2.name,
          reg_no: sc2.reg_no,
          tax_id: sc2.tax_id,
          amount: coalesce(sr1.funds_amount, sum(st0.amount)),
          details_amount: coalesce(da.details_amount, 0),
          tax_amount: coalesce(da.tax_amount, 0),
          matched_amount: coalesce(ma.matched_amount, 0),
          checked: false,
          old_data: st0.old_data
        }

    base_query
    |> with_cte("details_agg", as: ^details_agg)
    |> with_cte("matchers_agg", as: ^matchers_agg)
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
    |> get_gapless_doc_id(gapless_name, "Payment", "PV", com)
    |> Multi.insert(payment_name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(Payment, %Payment{}, Map.merge(attrs, %{"payment_no" => doc}), com)
    end)
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

  defp create_payment_transactions(multi, name, com, user) do
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
              doc_type: "Payment",
              doc_no: payment.payment_no,
              doc_id: payment.id,
              doc_date: payment.payment_date,
              account_id: x.account_id,
              company_id: com.id,
              amount: x.good_amount,
              particulars: "#{payment.contact_name}, #{x.good_name}"
            })
          end

          if !Decimal.eq?(x.tax_amount, 0) do
            repo.insert!(%Transaction{
              doc_type: "Payment",
              doc_no: payment.payment_no,
              doc_id: payment.id,
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
            match_doc_nos: Enum.map_join(v, ", ", fn x -> x.t_doc_no end) |> String.slice(0..200),
            amount: Enum.reduce(v, 0, fn x, acc -> Decimal.add(acc, x.match_amount) end)
          }
        end)
        |> Enum.each(fn x ->
          repo.insert!(%Transaction{
            doc_type: "Payment",
            doc_no: payment.payment_no,
            doc_id: payment.id,
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

      if Decimal.gt?(payment.payment_balance, 0) do
        repo.insert!(%Transaction{
          doc_type: "Payment",
          doc_no: payment.payment_no,
          doc_id: payment.id,
          doc_date: payment.payment_date,
          account_id: Accounting.get_account_by_name("Account Receivables", com, user).id,
          contact_id: payment.contact_id,
          company_id: com.id,
          amount: payment.payment_balance,
          particulars: "Pre-Payment to #{payment.contact_name}",
          contact_particulars: "Pre-Payment to #{payment.contact_name}"
        })
      end

      if Decimal.gt?(payment.funds_amount, 0) do
        repo.insert!(%Transaction{
          doc_type: "Payment",
          doc_no: payment.payment_no,
          doc_id: payment.id,
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
    attrs = remove_field_if_new_flag(attrs, "payment_no")

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
        where: txn.doc_type == "Payment",
        where: txn.doc_no == ^payment.payment_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(payment_name, attrs, com, user)
    |> create_payment_transactions(payment_name, com, user)
  end
end
