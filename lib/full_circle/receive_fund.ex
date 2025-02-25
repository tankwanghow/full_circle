defmodule FullCircle.ReceiveFund do
  import Ecto.Query, warn: false
  alias FullCircle.Repo
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.ReceiveFund.{Receipt, ReceiptDetail, ReceivedCheque}

  alias FullCircle.Accounting.{
    Contact,
    Transaction,
    TaxCode,
    TransactionMatcher
  }

  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.{Sys, Accounting}
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.Accounting.{Account, Contact}
  alias FullCircle.StdInterface
  alias Ecto.Multi

  def get_cheque_by_id!(id) do
    Repo.one(
      from obj in FullCircle.ReceiveFund.ReceivedCheque,
        where: obj.id == ^id
    )
  end

  def get_receipt_by_no!(no, com, user) do
    id =
      Repo.one(
        from obj in Receipt,
          join: com in subquery(Sys.user_company(com, user)),
          on: com.id == obj.company_id,
          where: obj.receipt_no == ^no,
          select: obj.id
      )

    get_receipt!(id, com, user)
  end

  def get_print_receipts!(ids, company, user) do
    Repo.all(
      from rec in Receipt,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        left_join: einv in EInvoice,
        on: einv.uuid == rec.e_inv_uuid,
        where: rec.id in ^ids,
        preload: [:contact, :funds_account],
        preload: [:received_cheques],
        preload: [transaction_matchers: ^receipt_match_trans(company, user)],
        preload: [receipt_details: ^receipt_details()],
        select: rec,
        select_merge: %{e_inv_long_id: einv.longId}
    )
    |> Enum.map(fn x -> Receipt.compute_struct_balance(x) end)
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("receipts", x.id, x.company_id)})
    end)
  end

  def get_receipt!(id, company, user) do
    Repo.one(
      from rec in Receipt,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        join: cont in Contact,
        on: cont.id == rec.contact_id,
        left_join: funds in Account,
        on: funds.id == rec.funds_account_id,
        left_join: einv in EInvoice,
        on: einv.uuid == rec.e_inv_uuid,
        where: rec.id == ^id,
        preload: [:received_cheques],
        preload: [transaction_matchers: ^receipt_match_trans(company, user)],
        preload: [receipt_details: ^receipt_details()],
        select: rec,
        select_merge: %{
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          funds_account_name: funds.name,
          e_inv_long_id: einv.longId
        },
        select_merge: %{cheques_amount: coalesce(subquery(cheques_amount(id)), 0)},
        select_merge: %{matched_amount: coalesce(subquery(matched_amount(id)), 0)},
        select_merge: %{receipt_tax_amount: coalesce(subquery(receipt_tax_amount(id)), 0)},
        select_merge: %{receipt_good_amount: coalesce(subquery(receipt_good_amount(id)), 0)},
        select_merge: %{receipt_detail_amount: coalesce(subquery(receipt_detail_amount(id)), 0)}
    )
  end

  defp matched_amount(id) do
    from mat in TransactionMatcher,
      where: mat.doc_type == "Receipt",
      where: mat.doc_id == ^id,
      select: sum(mat.match_amount)
  end

  defp cheques_amount(id) do
    from chq in ReceivedCheque,
      where: chq.receipt_id == ^id,
      select: sum(chq.amount)
  end

  defp receipt_tax_amount(id) do
    from dtl in ReceiptDetail,
      where: dtl.receipt_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum((dtl.quantity * dtl.unit_price + dtl.discount) * dtl.tax_rate)
        )
  end

  defp receipt_good_amount(id) do
    from dtl in ReceiptDetail,
      where: dtl.receipt_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(dtl.quantity * dtl.unit_price + dtl.discount)
        )
  end

  defp receipt_detail_amount(id) do
    from dtl in ReceiptDetail,
      where: dtl.receipt_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(
            dtl.quantity * dtl.unit_price + dtl.discount +
              (dtl.quantity * dtl.unit_price + dtl.discount) * dtl.tax_rate
          )
        )
  end

  defp receipt_details do
    from recd in ReceiptDetail,
      join: good in Good,
      on: good.id == recd.good_id,
      join: ac in Account,
      on: recd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == recd.tax_code_id,
      left_join: pkg in Packaging,
      on: pkg.id == recd.package_id,
      order_by: recd._persistent_id,
      select: recd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        unit_multiplier: pkg.unit_multiplier,
        tax_rate: recd.tax_rate,
        tax_code_name: tc.code,
        tax_amount:
          fragment(
            "round(?, 2)",
            (recd.quantity * recd.unit_price + recd.discount) * recd.tax_rate
          ),
        good_amount:
          fragment(
            "round(?, 2)",
            recd.quantity * recd.unit_price + recd.discount
          ),
        amount:
          fragment(
            "round(?, 2)",
            recd.quantity * recd.unit_price + recd.discount +
              (recd.quantity * recd.unit_price + recd.discount) * recd.tax_rate
          )
      }
  end

  defp receipt_match_trans(com, user) do
    from recmt in TransactionMatcher,
      join: txn in subquery(Accounting.transaction_with_balance_query(com, user)),
      on: txn.id == recmt.transaction_id,
      where: recmt.doc_type == "Receipt",
      order_by: recmt._persistent_id,
      select: recmt,
      select_merge: %{
        transaction_id: txn.id,
        t_doc_date: txn.doc_date,
        t_doc_type: txn.doc_type,
        t_doc_no: txn.doc_no,
        amount: txn.amount,
        all_matched_amount: txn.all_matched_amount - recmt.match_amount,
        particulars: txn.particulars,
        balance: txn.amount + txn.all_matched_amount,
        match_amount: recmt.match_amount
      }
  end

  def receipt_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(receipt_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:receipt_no, :contact_name, :particulars], terms)
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.receipt_date >= ^date_from, order_by: inv.receipt_date
      else
        from inv in qry, order_by: [desc: inv.receipt_date]
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_receipt_by_id_index_component_field!(id, com, user) do
    from(i in subquery(receipt_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp receipt_raw_query(company, _user) do
    from txn in Transaction,
      left_join: rec in Receipt,
      on: txn.doc_no == rec.receipt_no,
      join: cont in Contact,
      on: cont.id == rec.contact_id or cont.id == txn.contact_id,
      where: txn.company_id == ^company.id,
      where: txn.doc_type == "Receipt",
      where: txn.amount < 0,
      left_join: recd in ReceiptDetail,
      on: recd.receipt_id == rec.id,
      select: %{
        id: coalesce(txn.doc_id, txn.id),
        doc_type: "Receipt",
        doc_id: coalesce(txn.doc_id, txn.id),
        receipt_no: txn.doc_no,
        e_inv_uuid: rec.e_inv_uuid,
        e_inv_internal_id: rec.e_inv_internal_id,
        got_details: fragment("count(?)", recd.id),
        particulars:
          fragment(
            "string_agg(distinct coalesce(?, ?), ', ')",
            txn.contact_particulars,
            txn.particulars
          ),
        receipt_date: txn.doc_date,
        company_id: txn.company_id,
        contact_name: cont.name,
        reg_no: cont.reg_no,
        tax_id: cont.tax_id,
        amount: sum(txn.amount),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(txn.doc_id, txn.id),
        rec.id,
        txn.doc_no,
        cont.id,
        txn.doc_date,
        txn.company_id,
        txn.old_data
      ]
  end

  def create_receipt(attrs, com, user) do
    case can?(user, :create_receipt, com) do
      true ->
        Multi.new()
        |> create_receipt_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_receipt_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    receipt_name = :create_receipt

    multi
    |> get_gapless_doc_id(gapless_name, "Receipt", "RC", com)
    |> Multi.insert(receipt_name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(Receipt, %Receipt{}, Map.merge(attrs, %{"receipt_no" => doc}), com)
    end)
    |> Multi.insert("#{receipt_name}_log", fn %{^receipt_name => entity} ->
      FullCircle.Sys.log_changeset(
        receipt_name,
        entity,
        Map.merge(attrs, %{"receipt_no" => entity.receipt_no}),
        com,
        user
      )
    end)
    |> create_receipt_transactions(receipt_name, com, user)
  end

  defp create_receipt_transactions(multi, name, com, user) do
    pdc_id =
      FullCircle.Accounting.get_account_by_name("Post Dated Cheques", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => receipt} ->
      receipt =
        receipt
        |> FullCircle.Repo.preload([:receipt_details, :received_cheques, :transaction_matchers])

      # Credit Transactions
      if receipt.receipt_details != Ecto.Association.NotLoaded do
        Enum.each(receipt.receipt_details, fn x ->
          x = FullCircle.Repo.preload(x, [:account, :tax_code])

          if !Decimal.eq?(x.good_amount, 0) do
            repo.insert!(%Transaction{
              doc_type: "Receipt",
              doc_no: receipt.receipt_no,
              doc_id: receipt.id,
              doc_date: receipt.receipt_date,
              contact_id:
                if(Accounting.is_balance_sheet_account?(x.account),
                  do: receipt.contact_id,
                  else: nil
                ),
              account_id: x.account_id,
              company_id: com.id,
              amount: Decimal.negate(x.good_amount),
              particulars: "#{receipt.contact_name}, #{x.good_name}"
            })
          end

          if !Decimal.eq?(x.tax_amount, 0) do
            repo.insert!(%Transaction{
              doc_type: "Receipt",
              doc_no: receipt.receipt_no,
              doc_id: receipt.id,
              doc_date: receipt.receipt_date,
              account_id: x.tax_code.account_id,
              company_id: com.id,
              amount: Decimal.negate(x.tax_amount),
              particulars: "#{x.tax_code_name} on #{x.good_name}"
            })
          end
        end)
      end

      # follow matched amount
      if receipt.transaction_matchers != Ecto.Association.NotLoaded do
        Enum.group_by(receipt.transaction_matchers, fn m ->
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
            doc_type: "Receipt",
            doc_no: receipt.receipt_no,
            doc_id: receipt.id,
            doc_date: receipt.receipt_date,
            contact_id: receipt.contact_id,
            account_id: x.account_id,
            particulars: "Received from #{receipt.contact_name}",
            contact_particulars: "Funds Received for " <> x.match_doc_nos,
            company_id: com.id,
            amount: x.amount
          })
        end)
      end

      if Decimal.gt?(receipt.funds_amount, 0) do
        repo.insert!(%Transaction{
          doc_type: "Receipt",
          doc_no: receipt.receipt_no,
          doc_id: receipt.id,
          doc_date: receipt.receipt_date,
          account_id: receipt.funds_account_id,
          company_id: com.id,
          amount: receipt.funds_amount,
          particulars: "Received from #{receipt.contact_name}"
        })
      end

      if receipt.received_cheques != Ecto.Association.NotLoaded do
        Enum.each(receipt.received_cheques, fn x ->
          repo.insert!(%Transaction{
            doc_type: "Receipt",
            doc_no: receipt.receipt_no,
            doc_id: receipt.id,
            doc_date: receipt.receipt_date,
            account_id: pdc_id,
            company_id: com.id,
            amount: x.amount,
            particulars: "#{x.bank} #{x.cheque_no} from #{receipt.contact_name}"
          })
        end)
      end

      {:ok, nil}
    end)
  end

  def update_receipt(%Receipt{} = receipt, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "receipt_no")

    case can?(user, :update_receipt, com) do
      true ->
        Multi.new()
        |> update_receipt_multi(receipt, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_receipt_multi(multi, receipt, attrs, com, user) do
    receipt_name = :update_receipt

    multi
    |> Multi.update(receipt_name, StdInterface.changeset(Receipt, receipt, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "Receipt",
        where: txn.doc_no == ^receipt.receipt_no,
        where: txn.doc_id == ^receipt.id,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(receipt_name, attrs, com, user)
    |> create_receipt_transactions(receipt_name, com, user)
  end
end
