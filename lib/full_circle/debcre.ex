defmodule FullCircle.DebCre do
  import Ecto.Query, warn: false
  import FullCircle.Authorization
  import FullCircle.Helpers

  alias Ecto.Multi
  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.DebCre.{CreditNote, CreditNoteDetail, DebitNote, DebitNoteDetail}

  alias FullCircle.Accounting.{
    Account,
    Contact,
    Transaction,
    TaxCode,
    TransactionMatcher
  }

  alias FullCircle.{Repo, Sys, StdInterface, Accounting}

  @credit_note_txn_opts [
    detail_assoc: :credit_note_details,
    detail_sign: :positive,
    header_account: "Account Receivables",
    header_sign: :negate,
    doc_type: "CreditNote",
    desc_prefix: "Credit Note"
  ]

  @debit_note_txn_opts [
    detail_assoc: :debit_note_details,
    detail_sign: :negate,
    header_account: "Account Payables",
    header_sign: :positive,
    doc_type: "DebitNote",
    desc_prefix: "Debit Note"
  ]

  # ── Credit Note ─────────────────────────────────────

  def get_print_credit_notes!(ids, company, user) do
    Repo.all(
      from rec in CreditNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        left_join: einv in EInvoice,
        on: einv.uuid == rec.e_inv_uuid,
        where: rec.id in ^ids,
        preload: [:contact],
        preload: [transaction_matchers: ^match_trans_query(company, user, "CreditNote")],
        preload: [credit_note_details: ^detail_query(CreditNoteDetail)],
        select: rec,
        select_merge: %{e_inv_long_id: einv.longId}
    )
    |> Enum.map(fn x -> CreditNote.compute_struct_fields(x) end)
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("credit_notes", x.id, x.company_id)})
    end)
  end

  def get_credit_note!(id, company, user) do
    Repo.one(
      from obj in CreditNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == obj.company_id,
        join: cont in Contact,
        on: cont.id == obj.contact_id,
        left_join: einv in EInvoice,
        on: einv.uuid == obj.e_inv_uuid,
        left_join: da in subquery(credit_note_amounts(id)),
        on: true,
        where: obj.id == ^id,
        preload: [transaction_matchers: ^match_trans_query(company, user, "CreditNote")],
        preload: [credit_note_details: ^detail_query(CreditNoteDetail)],
        select: obj,
        select_merge: %{
          e_inv_long_id: einv.longId,
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id
        },
        select_merge: %{matched_amount: coalesce(subquery(matched_amount(id, "CreditNote")), 0)},
        select_merge: %{
          note_tax_amount: coalesce(da.tax_amount, 0),
          note_desc_amount: coalesce(da.desc_amount, 0),
          note_amount: coalesce(da.note_amount, 0)
        }
    )
  end

  defp credit_note_amounts(id) do
    from dtl in CreditNoteDetail,
      where: dtl.credit_note_id == ^id,
      select: %{
        desc_amount:
          fragment(
            "sum(round(?*?, 2))",
            dtl.quantity,
            dtl.unit_price
          ),
        tax_amount:
          fragment(
            "sum(round(?*?*?, 2))",
            dtl.quantity,
            dtl.unit_price,
            dtl.tax_rate
          ),
        note_amount:
          fragment(
            "sum(round(?*?+?*?*?, 2))",
            dtl.quantity,
            dtl.unit_price,
            dtl.quantity,
            dtl.unit_price,
            dtl.tax_rate
          )
      }
  end

  def credit_note_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    from(inv in subquery(credit_note_raw_query(com, user)))
    |> apply_simple_filters(terms, date_from,
      search_fields: [:note_no, :contact_name, :particulars],
      date_field: :note_date
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  def get_credit_note_by_id_index_component_field!(id, com, user) do
    from(i in subquery(credit_note_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp credit_note_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "CreditNote",
      left_join: cont in Contact,
      on: cont.id == txn.contact_id,
      left_join: ac in Account,
      on: ac.id == txn.account_id,
      left_join: obj in CreditNote,
      on: txn.doc_no == obj.note_no,
      order_by: [desc: txn.doc_date],
      where: txn.amount < 0,
      select: %{
        id: coalesce(txn.doc_id, txn.id),
        doc_type: "CreditNote",
        doc_id: coalesce(txn.doc_id, txn.id),
        note_no: txn.doc_no,
        e_inv_uuid: obj.e_inv_uuid,
        e_inv_internal_id: obj.e_inv_internal_id,
        particulars:
          fragment(
            "string_agg(distinct coalesce(?, ?), ', ')",
            txn.contact_particulars,
            txn.particulars
          ),
        note_date: txn.doc_date,
        company_id: com.id,
        contact_name: coalesce(cont.name, ac.name),
        amount: sum(txn.amount),
        reg_no: cont.reg_no,
        tax_id: cont.tax_id,
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(txn.doc_id, txn.id),
        obj.id,
        txn.doc_no,
        cont.id,
        txn.doc_date,
        txn.company_id,
        txn.old_data,
        com.id,
        coalesce(cont.name, ac.name)
      ]
  end

  def create_credit_note(attrs, com, user) do
    case can?(user, :create_credit_note, com) do
      true ->
        Multi.new()
        |> create_credit_note_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_credit_note_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_credit_note

    multi
    |> get_gapless_doc_id(gapless_name, "CreditNote", "CN", com)
    |> Multi.insert(note_name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(
        CreditNote,
        %CreditNote{},
        Map.merge(attrs, %{"note_no" => doc}),
        com
      )
    end)
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"note_no" => entity.note_no}),
        com,
        user
      )
    end)
    |> create_note_transactions(note_name, com, user, @credit_note_txn_opts)
  end

  def update_credit_note(%CreditNote{} = credit_note, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "note_no")

    case can?(user, :update_credit_note, com) do
      true ->
        Multi.new()
        |> update_credit_note_multi(credit_note, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_credit_note_multi(multi, credit_note, attrs, com, user) do
    note_name = :update_credit_note

    multi
    |> Multi.update(note_name, StdInterface.changeset(CreditNote, credit_note, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "CreditNote",
        where: txn.doc_no == ^credit_note.note_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(note_name, attrs, com, user)
    |> create_note_transactions(note_name, com, user, @credit_note_txn_opts)
  end

  # ── Debit Note ──────────────────────────────────────

  def get_print_debit_notes!(ids, company, user) do
    Repo.all(
      from rec in DebitNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        left_join: einv in EInvoice,
        on: einv.uuid == rec.e_inv_uuid,
        where: rec.id in ^ids,
        preload: [:contact],
        preload: [transaction_matchers: ^match_trans_query(company, user, "DebitNote")],
        preload: [debit_note_details: ^detail_query(DebitNoteDetail)],
        select: rec,
        select_merge: %{e_inv_long_id: einv.longId}
    )
    |> Enum.map(fn x -> DebitNote.compute_struct_fields(x) end)
    |> Enum.map(fn x ->
      Map.merge(x, %{issued_by: last_log_record_for("debit_notes", x.id, x.company_id)})
    end)
  end

  def get_debit_note!(id, company, user) do
    Repo.one(
      from obj in DebitNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == obj.company_id,
        join: cont in Contact,
        on: cont.id == obj.contact_id,
        left_join: einv in EInvoice,
        on: einv.uuid == obj.e_inv_uuid,
        left_join: da in subquery(debit_note_amounts(id)),
        on: true,
        where: obj.id == ^id,
        preload: [transaction_matchers: ^match_trans_query(company, user, "DebitNote")],
        preload: [debit_note_details: ^detail_query(DebitNoteDetail)],
        select: obj,
        select_merge: %{
          e_inv_long_id: einv.longId,
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id
        },
        select_merge: %{matched_amount: coalesce(subquery(matched_amount(id, "DebitNote")), 0)},
        select_merge: %{
          note_tax_amount: coalesce(da.tax_amount, 0),
          note_desc_amount: coalesce(da.desc_amount, 0),
          note_amount: coalesce(da.note_amount, 0)
        }
    )
  end

  defp debit_note_amounts(id) do
    from dtl in DebitNoteDetail,
      where: dtl.debit_note_id == ^id,
      select: %{
        desc_amount:
          fragment(
            "sum(round(?*?, 2))",
            dtl.quantity,
            dtl.unit_price
          ),
        tax_amount:
          fragment(
            "sum(round(?*?*?, 2))",
            dtl.quantity,
            dtl.unit_price,
            dtl.tax_rate
          ),
        note_amount:
          fragment(
            "sum(round(?*?+?*?*?, 2))",
            dtl.quantity,
            dtl.unit_price,
            dtl.quantity,
            dtl.unit_price,
            dtl.tax_rate
          )
      }
  end

  def debit_note_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    from(inv in subquery(debit_note_raw_query(com, user)))
    |> apply_simple_filters(terms, date_from,
      search_fields: [:note_no, :contact_name, :particulars],
      date_field: :note_date
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  def get_debit_note_by_id_index_component_field!(id, com, user) do
    from(i in subquery(debit_note_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp debit_note_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "DebitNote",
      left_join: cont in Contact,
      on: cont.id == txn.contact_id,
      left_join: ac in Account,
      on: ac.id == txn.account_id,
      left_join: obj in DebitNote,
      on: txn.doc_no == obj.note_no,
      order_by: [desc: txn.doc_date],
      where: txn.amount > 0,
      select: %{
        id: coalesce(txn.doc_id, txn.id),
        doc_type: "DebitNote",
        doc_id: coalesce(txn.doc_id, txn.id),
        note_no: txn.doc_no,
        e_inv_uuid: obj.e_inv_uuid,
        e_inv_internal_id: obj.e_inv_internal_id,
        particulars:
          fragment(
            "string_agg(distinct coalesce(?, ?), ', ')",
            txn.contact_particulars,
            txn.particulars
          ),
        note_date: txn.doc_date,
        company_id: com.id,
        contact_name: coalesce(cont.name, ac.name),
        amount: sum(txn.amount),
        reg_no: cont.reg_no,
        tax_id: cont.tax_id,
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(txn.doc_id, txn.id),
        obj.id,
        txn.doc_no,
        cont.id,
        txn.doc_date,
        txn.company_id,
        txn.old_data,
        com.id,
        coalesce(cont.name, ac.name)
      ]
  end

  def create_debit_note(attrs, com, user) do
    case can?(user, :create_debit_note, com) do
      true ->
        Multi.new()
        |> create_debit_note_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_debit_note_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    note_name = :create_debit_note

    multi
    |> get_gapless_doc_id(gapless_name, "DebitNote", "DN", com)
    |> Multi.insert(note_name, fn %{^gapless_name => doc} ->
      StdInterface.changeset(
        DebitNote,
        %DebitNote{},
        Map.merge(attrs, %{"note_no" => doc}),
        com
      )
    end)
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"note_no" => entity.note_no}),
        com,
        user
      )
    end)
    |> create_note_transactions(note_name, com, user, @debit_note_txn_opts)
  end

  def update_debit_note(%DebitNote{} = debit_note, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "note_no")

    case can?(user, :update_debit_note, com) do
      true ->
        Multi.new()
        |> update_debit_note_multi(debit_note, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_debit_note_multi(multi, debit_note, attrs, com, user) do
    note_name = :update_debit_note

    multi
    |> Multi.update(note_name, StdInterface.changeset(DebitNote, debit_note, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "DebitNote",
        where: txn.doc_no == ^debit_note.note_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(note_name, attrs, com, user)
    |> create_note_transactions(note_name, com, user, @debit_note_txn_opts)
  end

  # ── Shared Private Helpers ──────────────────────────

  defp detail_query(detail_mod) do
    from cnd in detail_mod,
      join: ac in Account,
      on: cnd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == cnd.tax_code_id,
      order_by: cnd._persistent_id,
      select: cnd,
      select_merge: %{
        account_name: ac.name,
        tax_rate: cnd.tax_rate,
        tax_code_name: tc.code,
        tax_amount:
          fragment(
            "round(?, 2)",
            cnd.quantity * cnd.unit_price * cnd.tax_rate
          ),
        desc_amount:
          fragment(
            "round(?, 2)",
            cnd.quantity * cnd.unit_price
          ),
        line_amount:
          fragment(
            "round(?, 2)",
            cnd.quantity * cnd.unit_price +
              cnd.quantity * cnd.unit_price * cnd.tax_rate
          )
      }
  end

  defp match_trans_query(com, user, doc_type) do
    from cnmt in TransactionMatcher,
      join: txn in subquery(Accounting.transaction_with_balance_query(com, user)),
      on: txn.id == cnmt.transaction_id,
      where: cnmt.doc_type == ^doc_type,
      order_by: cnmt._persistent_id,
      select: cnmt,
      select_merge: %{
        transaction_id: txn.id,
        t_doc_date: txn.doc_date,
        t_doc_type: txn.doc_type,
        t_doc_no: txn.doc_no,
        amount: txn.amount,
        all_matched_amount: txn.all_matched_amount - cnmt.match_amount,
        particulars: txn.particulars,
        balance: txn.amount + txn.all_matched_amount,
        match_amount: cnmt.match_amount
      }
  end

  defp matched_amount(id, doc_type) do
    from mat in TransactionMatcher,
      where: mat.doc_type == ^doc_type,
      where: mat.doc_id == ^id,
      select: sum(mat.match_amount)
  end

  defp apply_simple_filters(qry, terms, date_from, opts) do
    search_fields = Keyword.fetch!(opts, :search_fields)
    date_field = Keyword.fetch!(opts, :date_field)

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order(search_fields, terms)
      else
        qry
      end

    if date_from != "" do
      from inv in qry,
        where: field(inv, ^date_field) >= ^date_from,
        order_by: field(inv, ^date_field)
    else
      from inv in qry, order_by: [desc: field(inv, ^date_field)]
    end
  end

  defp create_note_transactions(multi, name, com, user, opts) do
    header_account_id = Accounting.get_account_by_name(opts[:header_account], com, user).id
    detail_assoc = opts[:detail_assoc]

    multi
    |> Multi.insert_all(:insert_transactions, Transaction, fn %{^name => note} ->
      note =
        Repo.preload(note, [
          {detail_assoc, [:account, :tax_code]},
          transaction_matchers: :transaction
        ])
      now = Timex.now() |> DateTime.truncate(:second)

      (build_detail_transactions(note, com, now, opts) ++
         build_matcher_transactions(note, com, now, opts) ++
         build_header_transaction(note, com, now, header_account_id, opts))
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp build_detail_transactions(note, com, now, opts) do
    doc_type = opts[:doc_type]
    detail_assoc = opts[:detail_assoc]
    sign = opts[:detail_sign]

    Map.get(note, detail_assoc)
    |> Enum.flat_map(fn x ->
      [
        if !Decimal.eq?(x.desc_amount, 0) do
          %{
            doc_type: doc_type,
            doc_no: note.note_no,
            doc_id: note.id,
            doc_date: note.note_date,
            account_id: x.account_id,
            company_id: com.id,
            amount: apply_sign(sign, x.desc_amount),
            particulars: "#{note.contact_name}, #{x.descriptions}",
            inserted_at: now
          }
        end,
        if !Decimal.eq?(x.tax_amount, 0) do
          %{
            doc_type: doc_type,
            doc_no: note.note_no,
            doc_id: note.id,
            doc_date: note.note_date,
            account_id: x.tax_code.account_id,
            company_id: com.id,
            amount: apply_sign(sign, x.tax_amount),
            particulars: "#{x.tax_code_name} on #{x.descriptions}",
            inserted_at: now
          }
        end
      ]
    end)
  end

  defp build_matcher_transactions(note, com, now, opts) do
    doc_type = opts[:doc_type]
    desc_prefix = opts[:desc_prefix]

    note.transaction_matchers
    |> Enum.group_by(fn m -> m.transaction.account_id end)
    |> Enum.map(fn {account_id, matchers} ->
      match_doc_nos =
        Enum.map_join(matchers, ", ", fn x -> x.t_doc_no end) |> String.slice(0..200)

      amount = Enum.reduce(matchers, 0, fn x, acc -> Decimal.add(acc, x.match_amount) end)

      %{
        doc_type: doc_type,
        doc_no: note.note_no,
        doc_id: note.id,
        doc_date: note.note_date,
        contact_id: note.contact_id,
        account_id: account_id,
        particulars: "#{desc_prefix} to #{note.contact_name}",
        contact_particulars: "#{desc_prefix} for " <> match_doc_nos,
        company_id: com.id,
        amount: amount,
        inserted_at: now
      }
    end)
  end

  defp build_header_transaction(note, com, now, header_account_id, opts) do
    doc_type = opts[:doc_type]
    detail_assoc = opts[:detail_assoc]
    sign = opts[:header_sign]

    if !Decimal.eq?(note.note_balance, 0) do
      cont_part =
        Map.get(note, detail_assoc)
        |> Enum.map_join(", ", fn x -> x.descriptions end)

      [
        %{
          doc_type: doc_type,
          doc_no: note.note_no,
          doc_id: note.id,
          doc_date: note.note_date,
          contact_id: note.contact_id,
          account_id: header_account_id,
          company_id: com.id,
          amount: apply_sign(sign, note.note_balance),
          particulars: note.contact_name,
          contact_particulars: cont_part,
          inserted_at: now
        }
      ]
    else
      []
    end
  end

  defp apply_sign(:positive, amount), do: amount
  defp apply_sign(:negate, amount), do: Decimal.negate(amount)
end
