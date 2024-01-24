defmodule FullCircle.DebCre do
  import Ecto.Query, warn: false
  import FullCircle.Authorization

  alias Ecto.Multi
  import FullCircle.Helpers

  alias FullCircle.DebCre.{CreditNote, CreditNoteDetail, DebitNote, DebitNoteDetail}

  alias FullCircle.Accounting.{
    Account,
    Contact,
    Transaction,
    TaxCode,
    TransactionMatcher
  }

  alias FullCircle.{Repo, Sys, StdInterface, Accounting}

  def get_print_credit_notes!(ids, company, user) do
    Repo.all(
      from rec in CreditNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        where: rec.id in ^ids,
        preload: [:contact],
        preload: [transaction_matchers: ^credit_note_match_trans(company, user)],
        preload: [credit_note_details: ^credit_note_details()],
        select: rec
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
        where: obj.id == ^id,
        preload: [transaction_matchers: ^credit_note_match_trans(company, user)],
        preload: [credit_note_details: ^credit_note_details()],
        select: obj,
        select_merge: %{contact_name: cont.name},
        select_merge: %{matched_amount: coalesce(subquery(dn_matched_amount(id)), 0)},
        select_merge: %{note_tax_amount: coalesce(subquery(credit_note_tax_amount(id)), 0)},
        select_merge: %{note_desc_amount: coalesce(subquery(credit_note_desc_amount(id)), 0)},
        select_merge: %{note_amount: coalesce(subquery(credit_note_amount(id)), 0)}
    )
  end

  defp dn_matched_amount(id) do
    from mat in TransactionMatcher,
      where: mat.doc_type == "CreditNote",
      where: mat.doc_id == ^id,
      select: sum(mat.match_amount)
  end

  defp credit_note_tax_amount(id) do
    from dtl in CreditNoteDetail,
      where: dtl.credit_note_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(dtl.quantity * dtl.unit_price * dtl.tax_rate)
        )
  end

  defp credit_note_desc_amount(id) do
    from dtl in CreditNoteDetail,
      where: dtl.credit_note_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(dtl.quantity * dtl.unit_price)
        )
  end

  defp credit_note_amount(id) do
    from dtl in CreditNoteDetail,
      where: dtl.credit_note_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(
            dtl.quantity * dtl.unit_price +
              dtl.quantity * dtl.unit_price * dtl.tax_rate
          )
        )
  end

  defp credit_note_details do
    from cnd in CreditNoteDetail,
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

  defp credit_note_match_trans(com, user) do
    from cnmt in TransactionMatcher,
      join: txn in subquery(Accounting.transaction_with_balance_query(com, user)),
      on: txn.id == cnmt.transaction_id,
      where: cnmt.doc_type == "CreditNote",
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

  def credit_note_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(credit_note_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:note_no, :contact_name, :particulars], terms)
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.note_date >= ^date_from, order_by: inv.note_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
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
      order_by: [desc: txn.inserted_at],
      where: txn.amount < 0,
      select: %{
        id: coalesce(obj.id, txn.id),
        note_no: txn.doc_no,
        particulars:
          fragment(
            "string_agg(distinct coalesce(?, ?), ', ')",
            txn.contact_particulars,
            txn.particulars
          ),
        note_date: txn.doc_date,
        updated_at: txn.inserted_at,
        company_id: com.id,
        contact_name: coalesce(cont.name, ac.name),
        amount: sum(txn.amount),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(obj.id, txn.id),
        txn.doc_no,
        coalesce(cont.name, ac.name),
        txn.doc_date,
        com.id,
        txn.old_data,
        txn.inserted_at
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
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          CreditNote,
          %CreditNote{},
          Map.merge(attrs, %{"note_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"note_no" => entity.note_no}),
        com,
        user
      )
    end)
    |> create_credit_note_transactions(note_name, com, user)
  end

  defp create_credit_note_transactions(multi, name, com, user) do
    ac_rec_id = Accounting.get_account_by_name("Account Receivables", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => cn} ->
      cn =
        cn
        |> FullCircle.Repo.preload([:credit_note_details, :transaction_matchers])

      Enum.each(cn.credit_note_details, fn x ->
        x = FullCircle.Repo.preload(x, [:account, :tax_code])

        if !Decimal.eq?(x.desc_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "CreditNote",
            doc_no: cn.note_no,
            doc_id: cn.id,
            doc_date: cn.note_date,
            account_id: x.account_id,
            company_id: com.id,
            amount: x.desc_amount,
            particulars: "#{cn.contact_name}, #{x.descriptions}"
          })
        end

        if !Decimal.eq?(x.tax_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "CreditNote",
            doc_no: cn.note_no,
            doc_id: cn.id,
            doc_date: cn.note_date,
            account_id: x.tax_code.account_id,
            company_id: com.id,
            amount: x.tax_amount,
            particulars: "#{x.tax_code_name} on #{x.descriptions}"
          })
        end
      end)

      # follow matched amount
      if cn.transaction_matchers != Ecto.Association.NotLoaded do
        Enum.group_by(cn.transaction_matchers, fn m ->
          m = FullCircle.Repo.preload(m, :transaction)
          m.transaction.account_id
        end)
        |> Enum.map(fn {k, v} ->
          %{
            account_id: k,
            match_doc_nos: Enum.map(v, fn x -> x.t_doc_no end) |> Enum.join(", "),
            amount: Enum.reduce(v, 0, fn x, acc -> Decimal.add(acc, x.match_amount) end)
          }
        end)
        |> Enum.each(fn x ->
          repo.insert!(%Transaction{
            doc_type: "CreditNote",
            doc_no: cn.note_no,
            doc_id: cn.id,
            doc_date: cn.note_date,
            contact_id: cn.contact_id,
            account_id: x.account_id,
            particulars: "Credit Note to #{cn.contact_name}",
            contact_particulars: "Credit Note for " <> x.match_doc_nos,
            company_id: com.id,
            amount: x.amount
          })
        end)
      end

      if !Decimal.eq?(cn.note_balance, 0) do
        cont_part =
          Enum.map(cn.credit_note_details, fn x -> x.descriptions end)
          |> Enum.join(", ")

        repo.insert!(%Transaction{
          doc_type: "CreditNote",
          doc_no: cn.note_no,
          doc_id: cn.id,
          doc_date: cn.note_date,
          contact_id: cn.contact_id,
          account_id: ac_rec_id,
          company_id: com.id,
          amount: Decimal.negate(cn.note_balance),
          particulars: cn.contact_name,
          contact_particulars: cont_part
        })
      end

      {:ok, nil}
    end)
  end

  def update_credit_note(%CreditNote{} = credit_note, attrs, com, user) do
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
    |> create_credit_note_transactions(note_name, com, user)
  end

  # Debit Note

  def get_print_debit_notes!(ids, company, user) do
    Repo.all(
      from rec in DebitNote,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == rec.company_id,
        where: rec.id in ^ids,
        preload: [:contact],
        preload: [transaction_matchers: ^debit_note_match_trans(company, user)],
        preload: [debit_note_details: ^debit_note_details()],
        select: rec
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
        where: obj.id == ^id,
        preload: [transaction_matchers: ^debit_note_match_trans(company, user)],
        preload: [debit_note_details: ^debit_note_details()],
        select: obj,
        select_merge: %{contact_name: cont.name},
        select_merge: %{matched_amount: coalesce(subquery(matched_amount(id)), 0)},
        select_merge: %{note_tax_amount: coalesce(subquery(debit_note_tax_amount(id)), 0)},
        select_merge: %{note_desc_amount: coalesce(subquery(debit_note_desc_amount(id)), 0)},
        select_merge: %{note_amount: coalesce(subquery(debit_note_amount(id)), 0)}
    )
  end

  defp matched_amount(id) do
    from mat in TransactionMatcher,
      where: mat.doc_type == "DebitNote",
      where: mat.doc_id == ^id,
      select: sum(mat.match_amount)
  end

  defp debit_note_tax_amount(id) do
    from dtl in DebitNoteDetail,
      where: dtl.debit_note_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(dtl.quantity * dtl.unit_price * dtl.tax_rate)
        )
  end

  defp debit_note_desc_amount(id) do
    from dtl in DebitNoteDetail,
      where: dtl.debit_note_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(dtl.quantity * dtl.unit_price)
        )
  end

  defp debit_note_amount(id) do
    from dtl in DebitNoteDetail,
      where: dtl.debit_note_id == ^id,
      select:
        fragment(
          "round(?, 2)",
          sum(
            dtl.quantity * dtl.unit_price +
              dtl.quantity * dtl.unit_price * dtl.tax_rate
          )
        )
  end

  defp debit_note_details do
    from cnd in DebitNoteDetail,
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

  defp debit_note_match_trans(com, user) do
    from cnmt in TransactionMatcher,
      join: txn in subquery(Accounting.transaction_with_balance_query(com, user)),
      on: txn.id == cnmt.transaction_id,
      where: cnmt.doc_type == "DebitNote",
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

  def debit_note_index_query(terms, date_from, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(debit_note_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:note_no, :contact_name, :particulars], terms)
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.note_date >= ^date_from, order_by: inv.note_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
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
      order_by: [desc: txn.inserted_at],
      where: txn.amount > 0,
      select: %{
        id: coalesce(obj.id, txn.id),
        note_no: txn.doc_no,
        particulars:
          fragment(
            "string_agg(distinct coalesce(?, ?), ', ')",
            txn.contact_particulars,
            txn.particulars
          ),
        note_date: txn.doc_date,
        updated_at: txn.inserted_at,
        company_id: com.id,
        contact_name: coalesce(cont.name, ac.name),
        amount: sum(txn.amount),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [
        coalesce(obj.id, txn.id),
        txn.doc_no,
        coalesce(cont.name, ac.name),
        txn.doc_date,
        com.id,
        txn.old_data,
        txn.inserted_at
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
    |> Multi.insert(
      note_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          DebitNote,
          %DebitNote{},
          Map.merge(attrs, %{"note_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{note_name}_log", fn %{^note_name => entity} ->
      FullCircle.Sys.log_changeset(
        note_name,
        entity,
        Map.merge(attrs, %{"note_no" => entity.note_no}),
        com,
        user
      )
    end)
    |> create_debit_note_transactions(note_name, com, user)
  end

  defp create_debit_note_transactions(multi, name, com, user) do
    ac_paya_id = Accounting.get_account_by_name("Account Payables", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => cn} ->
      cn =
        cn
        |> FullCircle.Repo.preload([:debit_note_details, :transaction_matchers])

      Enum.each(cn.debit_note_details, fn x ->
        x = FullCircle.Repo.preload(x, [:account, :tax_code])

        if !Decimal.eq?(x.desc_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "DebitNote",
            doc_no: cn.note_no,
            doc_id: cn.id,
            doc_date: cn.note_date,
            account_id: x.account_id,
            company_id: com.id,
            amount: Decimal.negate(x.desc_amount),
            particulars: "#{cn.contact_name}, #{x.descriptions}"
          })
        end

        if !Decimal.eq?(x.tax_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "DebitNote",
            doc_no: cn.note_no,
            doc_id: cn.id,
            doc_date: cn.note_date,
            account_id: x.tax_code.account_id,
            company_id: com.id,
            amount: Decimal.negate(x.tax_amount),
            particulars: "#{x.tax_code_name} on #{x.descriptions}"
          })
        end
      end)

      # follow matched amount
      if cn.transaction_matchers != Ecto.Association.NotLoaded do
        Enum.group_by(cn.transaction_matchers, fn m ->
          m = FullCircle.Repo.preload(m, :transaction)
          m.transaction.account_id
        end)
        |> Enum.map(fn {k, v} ->
          %{
            account_id: k,
            match_doc_nos: Enum.map(v, fn x -> x.t_doc_no end) |> Enum.join(", "),
            amount: Enum.reduce(v, 0, fn x, acc -> Decimal.add(acc, x.match_amount) end)
          }
        end)
        |> Enum.each(fn x ->
          repo.insert!(%Transaction{
            doc_type: "DebitNote",
            doc_no: cn.note_no,
            doc_id: cn.id,
            doc_date: cn.note_date,
            contact_id: cn.contact_id,
            account_id: x.account_id,
            particulars: "Debit Note to #{cn.contact_name}",
            contact_particulars: "Debit Note for " <> x.match_doc_nos,
            company_id: com.id,
            amount: x.amount
          })
        end)
      end

      if !Decimal.eq?(cn.note_balance, 0) do
        cont_part =
          Enum.map(cn.debit_note_details, fn x -> x.descriptions end)
          |> Enum.join(", ")

        repo.insert!(%Transaction{
          doc_type: "DebitNote",
          doc_no: cn.note_no,
          doc_id: cn.id,
          doc_date: cn.note_date,
          contact_id: cn.contact_id,
          account_id: ac_paya_id,
          company_id: com.id,
          amount: cn.note_balance,
          particulars: cn.contact_name,
          contact_particulars: cont_part
        })
      end

      {:ok, nil}
    end)
  end

  def update_debit_note(%DebitNote{} = debit_note, attrs, com, user) do
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
    |> create_debit_note_transactions(note_name, com, user)
  end
end
