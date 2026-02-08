defmodule FullCircle.ReceiveFund do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.ReceiveFund.{Receipt, ReceiptDetail, ReceivedCheque}

  alias FullCircle.Accounting.{
    Account,
    Contact,
    Transaction,
    TaxCode,
    TransactionMatcher
  }

  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.{Repo, Sys, Accounting, StdInterface}
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
        preload: [transaction_matchers: ^match_trans_query("Receipt", company, user)],
        preload: [receipt_details: ^detail_query(ReceiptDetail)],
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
        left_join: da in subquery(receipt_detail_amounts(id)),
        on: true,
        where: rec.id == ^id,
        preload: [:received_cheques],
        preload: [transaction_matchers: ^match_trans_query("Receipt", company, user)],
        preload: [receipt_details: ^detail_query(ReceiptDetail)],
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
        select_merge: %{
          receipt_tax_amount: coalesce(da.tax_amount, 0),
          receipt_good_amount: coalesce(da.good_amount, 0),
          receipt_detail_amount: coalesce(da.detail_amount, 0)
        }
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

  defp receipt_detail_amounts(id) do
    from dtl in ReceiptDetail,
      where: dtl.receipt_id == ^id,
      select: %{
        good_amount:
          fragment(
            "sum(round(?*?+?, 2))",
            dtl.quantity,
            dtl.unit_price,
            dtl.discount
          ),
        tax_amount:
          fragment(
            "sum(round((?*?+?)*?, 2))",
            dtl.quantity,
            dtl.unit_price,
            dtl.discount,
            dtl.tax_rate
          ),
        detail_amount:
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
      }
  end

  defp detail_query(detail_module) do
    from recd in detail_module,
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

  defp match_trans_query(doc_type, com, user) do
    from recmt in TransactionMatcher,
      join: txn in subquery(Accounting.transaction_with_balance_query(com, user)),
      on: txn.id == recmt.transaction_id,
      where: recmt.doc_type == ^doc_type,
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
    from(inv in subquery(receipt_raw_query(com, user)))
    |> apply_simple_filters(terms, date_from,
      search_fields: [:receipt_no, :contact_name, :particulars],
      date_field: :receipt_date
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  def get_receipt_by_id_index_component_field!(id, com, user) do
    from(i in subquery(receipt_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp receipt_raw_query(company, _user) do
    # Define the CTE for receipt_details aggregation
    details_agg =
      from rd in ReceiptDetail,
        group_by: rd.receipt_id,
        select: %{
          receipt_id: rd.receipt_id,
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

    # Define the CTE for received_cheques aggregation
    cheques_agg =
      from rc in ReceivedCheque,
        group_by: rc.receipt_id,
        select: %{
          receipt_id: rc.receipt_id,
          cheques_amount: sum(rc.amount)
        }

    # Build the main query
    base_query =
      from st0 in Transaction,
        left_join: sr1 in Receipt,
        on: st0.doc_id == sr1.id,
        join: sc2 in Contact,
        on: sc2.id == coalesce(sr1.contact_id, st0.contact_id),
        left_join: sr4 in ReceiptDetail,
        on: sr4.receipt_id == sr1.id,
        left_join: da in "details_agg",
        on: da.receipt_id == sr1.id,
        left_join: ma in "matchers_agg",
        on: ma.doc_id == sr1.id,
        left_join: ca in "cheques_agg",
        on: ca.receipt_id == sr1.id,
        where:
          st0.company_id == ^company.id and
            st0.doc_type == "Receipt" and
            st0.amount > 0,
        group_by: [
          fragment("COALESCE(?, ?)", st0.doc_id, st0.id),
          st0.doc_no,
          sc2.id,
          sr1.id,
          st0.doc_date,
          st0.company_id,
          st0.old_data,
          sr1.funds_amount,
          ca.cheques_amount,
          da.details_amount,
          da.tax_amount,
          ma.matched_amount
        ],
        order_by: [desc: st0.doc_no],
        select: %{
          id: coalesce(st0.doc_id, st0.id),
          doc_type: "Receipt",
          doc_id: coalesce(st0.doc_id, st0.id),
          receipt_no: st0.doc_no,
          e_inv_uuid: sr1.e_inv_uuid,
          e_inv_internal_id: sr1.e_inv_internal_id,
          got_details: count(sr4.id),
          particulars:
            fragment(
              "STRING_AGG(DISTINCT COALESCE(?, ?), ', ')",
              st0.contact_particulars,
              st0.particulars
            ),
          receipt_date: st0.doc_date,
          company_id: st0.company_id,
          contact_name: sc2.name,
          reg_no: sc2.reg_no,
          tax_id: sc2.tax_id,
          funds_amount: coalesce(sr1.funds_amount, sum(st0.amount)),
          cheques_amount: coalesce(ca.cheques_amount, 0),
          details_amount: coalesce(da.details_amount, 0),
          tax_amount: coalesce(da.tax_amount, 0),
          matched_amount: coalesce(ma.matched_amount, 0),
          checked: false,
          old_data: st0.old_data
        }

    base_query
    |> with_cte("details_agg", as: ^details_agg)
    |> with_cte("matchers_agg", as: ^matchers_agg)
    |> with_cte("cheques_agg", as: ^cheques_agg)
  end

  defp apply_simple_filters(qry, terms, date_from, opts) do
    search_fields = Keyword.fetch!(opts, :search_fields)
    date_field = Keyword.fetch!(opts, :date_field)

    qry =
      if terms != "" do
        from inv in qry, order_by: ^similarity_order(search_fields, terms)
      else
        qry
      end

    if date_from != "" do
      from inv in qry,
        where: field(inv, ^date_field) >= ^date_from,
        order_by: field(inv, ^date_field)
    else
      from inv in qry, order_by: [{:desc, field(inv, ^date_field)}]
    end
  end

  defp make_changeset(module, struct, attrs, com, user) do
    if user_role_in_company(user.id, com.id) == "admin" do
      StdInterface.changeset(module, struct, attrs, com, :admin_changeset)
    else
      StdInterface.changeset(module, struct, attrs, com)
    end
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
      make_changeset(Receipt, %Receipt{}, Map.merge(attrs, %{"receipt_no" => doc}), com, user)
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
    pdc_id = Accounting.get_account_by_name("Post Dated Cheques", com, user).id

    multi
    |> Multi.insert_all(:create_transactions, Transaction, fn %{^name => receipt} ->
      receipt =
        Repo.preload(receipt, [
          :received_cheques,
          receipt_details: [:account, :tax_code],
          transaction_matchers: :transaction
        ])
      now = Timex.now() |> DateTime.truncate(:second)

      (build_detail_transactions(receipt, com, now) ++
         build_matcher_transactions(receipt, com, now) ++
         build_funds_transaction(receipt, com, now) ++
         build_cheque_transactions(receipt, com, pdc_id, now))
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp build_detail_transactions(receipt, com, now) do
    Enum.flat_map(receipt.receipt_details, fn x ->
      [
        if !Decimal.eq?(x.good_amount, 0) do
          %{
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
            particulars: "#{receipt.contact_name}, #{x.good_name}",
            inserted_at: now
          }
        end,
        if !Decimal.eq?(x.tax_amount, 0) do
          %{
            doc_type: "Receipt",
            doc_no: receipt.receipt_no,
            doc_id: receipt.id,
            doc_date: receipt.receipt_date,
            account_id: x.tax_code.account_id,
            company_id: com.id,
            amount: Decimal.negate(x.tax_amount),
            particulars: "#{x.tax_code_name} on #{x.good_name}",
            inserted_at: now
          }
        end
      ]
    end)
  end

  defp build_matcher_transactions(receipt, com, now) do
    receipt.transaction_matchers
    |> Enum.group_by(fn m -> m.transaction.account_id end)
    |> Enum.map(fn {account_id, matchers} ->
      match_doc_nos =
        Enum.map_join(matchers, ", ", fn x -> x.t_doc_no end) |> String.slice(0..200)

      amount = Enum.reduce(matchers, 0, fn x, acc -> Decimal.add(acc, x.match_amount) end)

      %{
        doc_type: "Receipt",
        doc_no: receipt.receipt_no,
        doc_id: receipt.id,
        doc_date: receipt.receipt_date,
        contact_id: receipt.contact_id,
        account_id: account_id,
        particulars: "Received from #{receipt.contact_name}",
        contact_particulars: "Funds Received for " <> match_doc_nos,
        company_id: com.id,
        amount: amount,
        inserted_at: now
      }
    end)
  end

  defp build_funds_transaction(receipt, com, now) do
    if Decimal.gt?(receipt.funds_amount, 0) do
      [
        %{
          doc_type: "Receipt",
          doc_no: receipt.receipt_no,
          doc_id: receipt.id,
          doc_date: receipt.receipt_date,
          account_id: receipt.funds_account_id,
          company_id: com.id,
          amount: receipt.funds_amount,
          particulars: "Received from #{receipt.contact_name}",
          inserted_at: now
        }
      ]
    else
      []
    end
  end

  defp build_cheque_transactions(receipt, com, pdc_id, now) do
    Enum.map(receipt.received_cheques, fn x ->
      %{
        doc_type: "Receipt",
        doc_no: receipt.receipt_no,
        doc_id: receipt.id,
        doc_date: receipt.receipt_date,
        account_id: pdc_id,
        company_id: com.id,
        amount: x.amount,
        particulars: "#{x.bank} #{x.cheque_no} from #{receipt.contact_name}",
        inserted_at: now
      }
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
    update_doc_multi(multi, :update_receipt, Receipt, receipt, receipt.receipt_no,
      attrs, com, user)
  end

  defp update_doc_multi(multi, step_name, schema, doc, doc_no, attrs, com, user) do
    multi
    |> Multi.update(step_name, fn _ ->
      make_changeset(schema, doc, attrs, com, user)
    end)
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "Receipt",
        where: txn.doc_no == ^doc_no,
        where: txn.doc_id == ^doc.id,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(step_name, attrs, com, user)
    |> create_receipt_transactions(step_name, com, user)
  end
end
