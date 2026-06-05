defmodule FullCircle.Billing do
  import Ecto.Query, warn: false
  import FullCircle.Helpers
  import FullCircle.Authorization

  alias FullCircle.Billing.{Invoice, InvoiceDetail, PurInvoice, PurInvoiceDetail}

  alias FullCircle.Accounting.{
    TransactionMatcher,
    Contact,
    Account,
    Transaction,
    TaxCode,
    SeedTransactionMatcher
  }

  alias FullCircle.EInvMetas.EInvoice
  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.{Repo, Sys, Accounting, StdInterface}
  alias Ecto.Multi

  @invoice_txn_opts [
    doc_type: "Invoice",
    control_account: "Account Receivables",
    detail_key: :invoice_details,
    doc_no_key: :invoice_no,
    doc_date_key: :invoice_date,
    amount_key: :invoice_amount,
    negate_line: true,
    negate_header: false
  ]

  @pur_invoice_txn_opts [
    doc_type: "PurInvoice",
    control_account: "Account Payables",
    detail_key: :pur_invoice_details,
    doc_no_key: :pur_invoice_no,
    doc_date_key: :pur_invoice_date,
    amount_key: :pur_invoice_amount,
    negate_line: false,
    negate_header: true
  ]

  def get_matcher_by(doc_type, doc_id) do
    from(txn in Transaction,
      join: txm in TransactionMatcher,
      on: txm.transaction_id == txn.id,
      where: txn.doc_type == ^doc_type,
      where: txn.doc_id == ^doc_id,
      select: %{
        doc_type: txm.doc_type,
        doc_id: txm.doc_id,
        match_amount: txm.match_amount
      }
    )
    |> Repo.all()
  end

  def get_invoice_by_no!(inv_no, com, user) do
    id =
      Repo.one(
        from inv in Invoice,
          join: com in subquery(Sys.user_company(com, user)),
          on: com.id == inv.company_id,
          where: inv.e_inv_internal_id == ^inv_no,
          select: inv.id
      )

    get_invoice!(id, com, user)
  end

  def get_print_invoices!(ids, company, user) do
    invoices =
      Repo.all(
        from inv in Invoice,
          join: com in subquery(Sys.user_company(company, user)),
          on: com.id == inv.company_id,
          join: invd in InvoiceDetail,
          on: invd.invoice_id == inv.id,
          join: cont in Contact,
          on: cont.id == inv.contact_id,
          left_join: einv in EInvoice,
          on: einv.uuid == inv.e_inv_uuid,
          where: inv.id in ^ids,
          preload: [contact: cont, invoice_details: ^detail_query(InvoiceDetail)],
          order_by: inv.e_inv_internal_id,
          select: inv,
          select_merge: %{e_inv_long_id: einv.longId}
      )

    log_map = last_log_records_for("invoices", ids, company.id)

    Enum.map(invoices, fn x ->
      x
      |> Invoice.compute_struct_fields()
      |> Map.merge(%{issued_by: Map.get(log_map, x.id)})
    end)
  end

  def get_invoice!(id, company, user) do
    Repo.one(
      from inv in Invoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        left_join: einv in EInvoice,
        on: einv.uuid == inv.e_inv_uuid,
        where: inv.id == ^id,
        preload: [invoice_details: ^detail_query(InvoiceDetail)],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          e_inv_long_id: einv.longId
        }
    )
    |> Invoice.compute_struct_fields()
  end

  defp detail_query(detail_module) do
    from invd in detail_module,
      join: good in Good,
      on: good.id == invd.good_id,
      join: ac in Account,
      on: invd.account_id == ac.id,
      join: tc in TaxCode,
      on: tc.id == invd.tax_code_id,
      left_join: pkg in Packaging,
      on: pkg.id == invd.package_id,
      order_by: invd._persistent_id,
      select: invd,
      select_merge: %{
        package_name: pkg.name,
        package_id: pkg.id,
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        unit_multiplier: pkg.unit_multiplier,
        tax_rate: invd.tax_rate,
        tax_code_name: tc.code,
        tax_amount:
          fragment(
            "round(?, 2)",
            (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate
          ),
        good_amount:
          fragment(
            "round(?, 2)",
            invd.quantity * invd.unit_price + invd.discount
          ),
        amount:
          fragment(
            "round(?, 2)",
            invd.quantity * invd.unit_price + invd.discount +
              (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate
          )
      }
  end

  def invoice_index_query(terms, date_from, due_date_from, bal, com, user,
        page: page,
        per_page: per_page
      ) do
    from(inv in subquery(invoice_transactions(com, user, date_from, due_date_from)))
    |> apply_index_filters(terms, date_from, due_date_from, bal,
      search_fields: [:invoice_no, :contact_name, :particulars],
      date_field: :invoice_date,
      unpaid_op: :gt
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  def get_invoice_by_id_index_component_field!(id, com, _user) do
    stxm_sum =
      from m in SeedTransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    atxm_sum =
      from m in TransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    Repo.one!(
      from txn in Transaction,
        as: :txn,
        join: cont in Contact,
        on: cont.id == txn.contact_id,
        left_join: inv in Invoice,
        on: inv.id == txn.doc_id,
        inner_lateral_join: s in subquery(stxm_sum),
        on: true,
        inner_lateral_join: a in subquery(atxm_sum),
        on: true,
        where: txn.company_id == ^com.id,
        where: txn.doc_type == "Invoice",
        where: txn.doc_id == ^id or (is_nil(txn.doc_id) and txn.id == ^id),
        select: %{
          doc_type: "Invoice",
          doc_id: coalesce(txn.doc_id, txn.id),
          id: coalesce(txn.doc_id, txn.id),
          invoice_no: txn.doc_no,
          e_inv_uuid: inv.e_inv_uuid,
          e_inv_internal_id: inv.e_inv_internal_id,
          particulars: coalesce(txn.contact_particulars, txn.particulars),
          invoice_date: txn.doc_date,
          due_date: txn.doc_date,
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          invoice_amount: txn.amount,
          balance: txn.amount + s.sum + a.sum,
          checked: false,
          old_data: txn.old_data
        }
    )
  end

  defp invoice_transactions(company, _user, date_from, due_date_from) do
    stxm_sum =
      from m in SeedTransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    atxm_sum =
      from m in TransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    q =
      from txn in Transaction,
        as: :txn,
        join: cont in Contact,
        on: cont.id == txn.contact_id,
        left_join: inv in Invoice,
        on: inv.id == txn.doc_id,
        inner_lateral_join: s in subquery(stxm_sum),
        on: true,
        inner_lateral_join: a in subquery(atxm_sum),
        on: true,
        where: txn.company_id == ^company.id,
        where: txn.doc_type == "Invoice",
        select: %{
          doc_type: "Invoice",
          doc_id: coalesce(txn.doc_id, txn.id),
          id: coalesce(txn.doc_id, txn.id),
          invoice_no: txn.doc_no,
          e_inv_uuid: inv.e_inv_uuid,
          e_inv_internal_id: inv.e_inv_internal_id,
          particulars: coalesce(txn.contact_particulars, txn.particulars),
          invoice_date: txn.doc_date,
          due_date: txn.doc_date,
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          invoice_amount: txn.amount,
          balance: txn.amount + s.sum + a.sum,
          checked: false,
          old_data: txn.old_data
        }

    q = if date_from != "", do: from([txn: txn] in q, where: txn.doc_date >= ^date_from), else: q

    if due_date_from != "",
      do: from([txn: txn] in q, where: txn.doc_date >= ^due_date_from),
      else: q
  end

  defp update_doc_multi(multi, step_name, schema, doc, doc_no, attrs, com, user, txn_opts) do
    doc_type = Keyword.fetch!(txn_opts, :doc_type)
    cs = make_changeset(schema, doc, attrs, com, user)

    multi =
      multi
      |> Multi.update(step_name, cs)
      |> Sys.insert_log_for(step_name, attrs, com, user)

    if cs.valid? and doc_transactions_unchanged?(cs, doc_no, doc_type, com, user, txn_opts) do
      # No posted field changed → keep the existing transactions intact.
      # This lets users edit non-GL fields (descriptions, tags, etc.) on docs
      # that have been matched by receipts/payments/notes without hitting the
      # transaction_matchers FK :restrict, and on closed-period docs without
      # hitting the BEFORE DELETE trigger.
      multi
    else
      multi
      |> Multi.delete_all(
        :delete_transaction,
        from(txn in Transaction,
          where: txn.doc_type == ^doc_type,
          where: txn.doc_no == ^doc_no,
          where: txn.company_id == ^com.id
        )
      )
      |> create_doc_transactions(step_name, com, user, txn_opts)
    end
  end

  defp doc_transactions_unchanged?(cs, doc_no, doc_type, com, user, txn_opts) do
    detail_key = Keyword.fetch!(txn_opts, :detail_key)

    target_doc =
      cs
      |> Ecto.Changeset.apply_changes()
      |> Map.update!(detail_key, fn details ->
        details
        |> Enum.reject(&(Map.get(&1, :delete) == true))
        |> FullCircle.Repo.preload([:account, :tax_code])
      end)

    target_attrs = build_doc_transaction_attrs(target_doc, com, user, txn_opts)
    existing = fetch_existing_doc_txn_rows(doc_no, doc_type, com.id)

    txn_fingerprint(target_attrs) == txn_fingerprint(existing)
  end

  defp fetch_existing_doc_txn_rows(doc_no, doc_type, com_id) do
    Repo.all(
      from t in Transaction,
        where: t.doc_no == ^doc_no,
        where: t.doc_type == ^doc_type,
        where: t.company_id == ^com_id,
        select: %{
          doc_date: t.doc_date,
          account_id: t.account_id,
          contact_id: t.contact_id,
          amount: t.amount,
          particulars: t.particulars,
          contact_particulars: t.contact_particulars
        }
    )
  end

  # Compare only GL-affecting fields. `particulars` and `contact_particulars`
  # are descriptive labels derived from upstream names (Good, TaxCode, Contact)
  # and can drift after a rename even when the GL impact is unchanged — we
  # don't force a txn rewrite for that. Use a sorted list (not a set) so that
  # duplicate-tuple rows are counted, not collapsed.
  defp txn_fingerprint(rows) do
    rows
    |> Enum.map(fn r ->
      {
        Map.get(r, :doc_date),
        Map.get(r, :account_id),
        Map.get(r, :contact_id),
        decimal_to_string(Map.get(r, :amount))
      }
    end)
    |> Enum.sort()
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(Decimal.normalize(d), :normal)
  defp decimal_to_string(other), do: to_string(other)

  defp classify_postgrex_error(%Postgrex.Error{postgres: pg}) do
    constraint = Map.get(pg, :constraint, "")
    message = Map.get(pg, :message, "")

    cond do
      is_binary(constraint) and constraint =~ "transaction_matchers" ->
        {:error, :has_matchers}

      String.contains?(message, "CLOSED transaction") ->
        {:error, :closed}

      true ->
        {:sql_error, message}
    end
  end

  def make_changeset(module, struct, attrs, com, user) do
    if user_role_in_company(user.id, com.id) == "admin" do
      StdInterface.changeset(module, struct, attrs, com, :admin_changeset)
    else
      StdInterface.changeset(module, struct, attrs, com)
    end
  end

  def build_invoice_details_from_egg_order(egg_quantities, com, user) do
    egg_quantities
    |> Enum.reject(fn {_grade, qty} -> qty in [nil, "", "0", 0] end)
    |> Enum.with_index()
    |> Enum.map(fn {{grade_name, tray_qty}, idx} ->
      good = FullCircle.Product.get_good_by_name(String.trim(grade_name), com, user)

      if good do
        %{
          "good_name" => good.value,
          "good_id" => good.id,
          "account_name" => good.sales_account_name,
          "account_id" => good.sales_account_id,
          "tax_code_name" => good.sales_tax_code_name,
          "tax_code_id" => good.sales_tax_code_id,
          "tax_rate" => good.sales_tax_rate || 0,
          "package_name" => good.package_name,
          "package_id" => good.package_id,
          "unit" => good.unit,
          "unit_multiplier" => good.unit_multiplier || 1,
          "package_qty" => tray_qty,
          "quantity" =>
            Decimal.mult(Decimal.new("#{tray_qty}"), Decimal.new("#{good.unit_multiplier || 1}")),
          "unit_price" => 0,
          "discount" => 0,
          "_persistent_id" => idx
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def create_invoice(attrs, com, user) do
    case can?(user, :create_invoice, com) do
      true ->
        Multi.new()
        |> create_invoice_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_invoice_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    invoice_name = :create_invoice

    multi
    |> get_gapless_doc_id(gapless_name, "Invoice", "INV", com)
    |> Multi.insert(invoice_name, fn %{^gapless_name => doc} ->
      make_changeset(
        Invoice,
        %Invoice{},
        Map.merge(attrs, %{"invoice_no" => doc, "e_inv_internal_id" => doc}),
        com,
        user
      )
    end)
    |> Multi.insert("#{invoice_name}_log", fn %{^invoice_name => entity} ->
      FullCircle.Sys.log_changeset(
        invoice_name,
        entity,
        Map.merge(attrs, %{
          "invoice_no" => entity.invoice_no,
          "e_inv_internal_id" => entity.e_inv_internal_id
        }),
        com,
        user
      )
    end)
    |> create_doc_transactions(invoice_name, com, user, @invoice_txn_opts)
  end

  defp create_doc_transactions(multi, name, com, user, opts) do
    multi
    |> Multi.insert_all(:create_transactions, Transaction, fn %{^name => doc} ->
      build_doc_transaction_attrs(doc, com, user, opts)
    end)
  end

  defp build_doc_transaction_attrs(doc, com, user, opts) do
    doc_type = Keyword.fetch!(opts, :doc_type)
    control_account = Keyword.fetch!(opts, :control_account)
    detail_key = Keyword.fetch!(opts, :detail_key)
    doc_no_key = Keyword.fetch!(opts, :doc_no_key)
    doc_date_key = Keyword.fetch!(opts, :doc_date_key)
    amount_key = Keyword.fetch!(opts, :amount_key)
    negate_line? = Keyword.fetch!(opts, :negate_line)
    negate_header? = Keyword.fetch!(opts, :negate_header)

    ac_id = Accounting.get_account_by_name(control_account, com, user).id
    apply_sign = fn amount, negate? -> if negate?, do: Decimal.negate(amount), else: amount end

    doc_no = Map.fetch!(doc, doc_no_key)
    doc_date = Map.fetch!(doc, doc_date_key)
    doc_amount = Map.fetch!(doc, amount_key)
    details = Map.fetch!(doc, detail_key)
    now = Timex.now() |> DateTime.truncate(:second)

    (Enum.map(details, fn x ->
       x = FullCircle.Repo.preload(x, [:account, :tax_code])

       [
         if !Decimal.eq?(x.good_amount, 0) do
           %{
             doc_type: doc_type,
             doc_no: doc_no,
             doc_id: doc.id,
             doc_date: doc_date,
             account_id: x.account_id,
             company_id: com.id,
             amount: apply_sign.(x.good_amount, negate_line?),
             particulars: "#{doc.contact_name}, #{x.good_name}",
             inserted_at: now
           }
         end,
         if !Decimal.eq?(x.tax_amount, 0) do
           %{
             doc_type: doc_type,
             doc_no: doc_no,
             doc_id: doc.id,
             doc_date: doc_date,
             account_id: x.tax_code.account_id,
             company_id: com.id,
             amount: apply_sign.(x.tax_amount, negate_line?),
             particulars: "#{x.tax_code_name} on #{x.good_name}",
             inserted_at: now
           }
         end
       ]
     end) ++
       [
         if !Decimal.eq?(doc_amount, 0) do
           cont_part =
             Enum.map(details, fn x -> x.good_name end)
             |> Enum.uniq()
             |> Enum.join(", ")
             |> String.slice(0..200)

           %{
             doc_type: doc_type,
             doc_no: doc_no,
             doc_id: doc.id,
             doc_date: doc_date,
             contact_id: doc.contact_id,
             account_id: ac_id,
             company_id: com.id,
             amount: apply_sign.(doc_amount, negate_header?),
             particulars: doc.contact_name,
             contact_particulars: cont_part,
             inserted_at: now
           }
         end
       ])
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp apply_index_filters(qry, terms, date_from, due_date_from, bal, opts) do
    search_fields = Keyword.fetch!(opts, :search_fields)
    date_field = Keyword.fetch!(opts, :date_field)
    unpaid_op = Keyword.fetch!(opts, :unpaid_op)

    qry =
      if terms != "" do
        from inv in qry, order_by: ^similarity_order(search_fields, terms)
      else
        qry
      end

    qry =
      if date_from != "" do
        from inv in qry,
          where: field(inv, ^date_field) >= ^date_from,
          order_by: field(inv, ^date_field)
      else
        from inv in qry, order_by: [{:desc, field(inv, ^date_field)}]
      end

    qry =
      if due_date_from != "" do
        from inv in qry, where: inv.due_date >= ^due_date_from, order_by: inv.due_date
      else
        from inv in qry, order_by: [desc: inv.due_date]
      end

    case {bal, unpaid_op} do
      {"Paid", _} -> from inv in qry, where: inv.balance == 0
      {"Unpaid", :gt} -> from inv in qry, where: inv.balance > 0
      {"Unpaid", :lt} -> from inv in qry, where: inv.balance < 0
      _ -> qry
    end
  end

  def update_invoice(%Invoice{} = invoice, attrs, com, user) do
    attrs =
      remove_field_if_new_flag(attrs, "e_inv_internal_id")
      |> remove_field_if_new_flag("invoice_no")

    if can?(user, :update_invoice, com) do
      Multi.new()
      |> update_invoice_multi(invoice, attrs, com, user)
      |> Repo.transaction()
    else
      :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      classify_postgrex_error(e)
  end

  def update_invoice_multi(multi, invoice, attrs, com, user) do
    update_doc_multi(
      multi,
      :update_invoice,
      Invoice,
      invoice,
      invoice.invoice_no,
      attrs,
      com,
      user,
      @invoice_txn_opts
    )
  end

  ########
  # Purchase Invoice
  ########

  def get_pur_invoice_by_no!(inv_no, com, user) do
    id =
      Repo.one(
        from inv in PurInvoice,
          join: com in subquery(Sys.user_company(com, user)),
          on: com.id == inv.company_id,
          where: inv.pur_invoice_no == ^inv_no,
          select: inv.id
      )

    get_pur_invoice!(id, com, user)
  end

  def get_pur_invoice!(id, company, user) do
    Repo.one(
      from inv in PurInvoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        left_join: einv in EInvoice,
        on: einv.uuid == inv.e_inv_uuid,
        where: inv.id == ^id,
        preload: [pur_invoice_details: ^detail_query(PurInvoiceDetail)],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          e_inv_long_id: einv.longId
        }
    )
    |> PurInvoice.compute_struct_fields()
  end

  def pur_invoice_index_query(terms, date_from, due_date_from, bal, com, user,
        page: page,
        per_page: per_page
      ) do
    from(inv in subquery(pur_invoice_transactions(com, user, date_from, due_date_from)))
    |> apply_index_filters(terms, date_from, due_date_from, bal,
      search_fields: [:pur_invoice_no, :e_inv_internal_id, :contact_name, :particulars],
      date_field: :pur_invoice_date,
      unpaid_op: :lt
    )
    |> offset((^page - 1) * ^per_page)
    |> limit(^per_page)
    |> Repo.all()
  end

  def get_pur_invoice_by_id_index_component_field!(id, com, _user) do
    stxm_sum =
      from m in SeedTransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    atxm_sum =
      from m in TransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    Repo.one!(
      from txn in Transaction,
        as: :txn,
        join: cont in Contact,
        on: cont.id == txn.contact_id,
        left_join: inv in PurInvoice,
        on: txn.doc_id == inv.id,
        inner_lateral_join: s in subquery(stxm_sum),
        on: true,
        inner_lateral_join: a in subquery(atxm_sum),
        on: true,
        where: txn.company_id == ^com.id,
        where: txn.doc_type == "PurInvoice",
        where: txn.doc_id == ^id or (is_nil(txn.doc_id) and txn.id == ^id),
        select: %{
          id: coalesce(txn.doc_id, txn.id),
          doc_type: "PurInvoice",
          doc_id: coalesce(txn.doc_id, txn.id),
          pur_invoice_no: txn.doc_no,
          e_inv_internal_id: inv.e_inv_internal_id,
          e_inv_uuid: inv.e_inv_uuid,
          particulars: coalesce(txn.contact_particulars, txn.particulars),
          pur_invoice_date: txn.doc_date,
          due_date: txn.doc_date,
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          pur_invoice_amount: txn.amount,
          balance: txn.amount + s.sum + a.sum,
          checked: false,
          old_data: txn.old_data
        }
    )
  end

  defp pur_invoice_transactions(company, _user, date_from, due_date_from) do
    stxm_sum =
      from m in SeedTransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    atxm_sum =
      from m in TransactionMatcher,
        where: m.transaction_id == parent_as(:txn).id,
        select: %{sum: coalesce(sum(m.match_amount), 0)}

    q =
      from txn in Transaction,
        as: :txn,
        join: cont in Contact,
        on: cont.id == txn.contact_id,
        left_join: inv in PurInvoice,
        on: txn.doc_id == inv.id,
        inner_lateral_join: s in subquery(stxm_sum),
        on: true,
        inner_lateral_join: a in subquery(atxm_sum),
        on: true,
        where: txn.company_id == ^company.id,
        where: txn.doc_type == "PurInvoice",
        select: %{
          id: coalesce(txn.doc_id, txn.id),
          doc_type: "PurInvoice",
          doc_id: coalesce(txn.doc_id, txn.id),
          pur_invoice_no: txn.doc_no,
          e_inv_internal_id: inv.e_inv_internal_id,
          e_inv_uuid: inv.e_inv_uuid,
          particulars: coalesce(txn.contact_particulars, txn.particulars),
          pur_invoice_date: txn.doc_date,
          due_date: txn.doc_date,
          contact_name: cont.name,
          reg_no: cont.reg_no,
          tax_id: cont.tax_id,
          pur_invoice_amount: txn.amount,
          balance: txn.amount + s.sum + a.sum,
          checked: false,
          old_data: txn.old_data
        }

    q = if date_from != "", do: from([txn: txn] in q, where: txn.doc_date >= ^date_from), else: q

    if due_date_from != "",
      do: from([txn: txn] in q, where: txn.doc_date >= ^due_date_from),
      else: q
  end

  def create_pur_invoice(attrs, com, user) do
    case can?(user, :create_pur_invoice, com) do
      true ->
        Multi.new()
        |> create_pur_invoice_multi(attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  end

  def create_pur_invoice_multi(multi, attrs, com, user) do
    gapless_name = String.to_atom("update_gapless_doc" <> gen_temp_id())
    pur_invoice_name = :create_pur_invoice

    multi
    |> get_gapless_doc_id(gapless_name, "PurInvoice", "PINV", com)
    |> Multi.insert(pur_invoice_name, fn %{^gapless_name => doc} ->
      make_changeset(
        PurInvoice,
        %PurInvoice{},
        Map.merge(attrs, %{"pur_invoice_no" => doc}),
        com,
        user
      )
    end)
    |> Multi.insert("#{pur_invoice_name}_log", fn %{^pur_invoice_name => entity} ->
      FullCircle.Sys.log_changeset(
        pur_invoice_name,
        entity,
        Map.merge(attrs, %{"pur_invoice_no" => entity.pur_invoice_no}),
        com,
        user
      )
    end)
    |> create_doc_transactions(pur_invoice_name, com, user, @pur_invoice_txn_opts)
  end

  def match_pur_invoice(%PurInvoice{} = pur_invoice, attrs, com, user) do
    pur_invoice_name = :update_pur_invoice
    attrs = remove_field_if_new_flag(attrs, "pur_invoice_no")

    case can?(user, :update_pur_invoice, com) do
      true ->
        Multi.new()
        |> Multi.update(
          pur_invoice_name,
          StdInterface.changeset(PurInvoice, pur_invoice, attrs, com)
        )
        |> Sys.insert_log_for(pur_invoice_name, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_pur_invoice(%PurInvoice{} = pur_invoice, attrs, com, user) do
    attrs = remove_field_if_new_flag(attrs, "pur_invoice_no")

    if can?(user, :update_pur_invoice, com) do
      Multi.new()
      |> update_pur_invoice_multi(pur_invoice, attrs, com, user)
      |> Repo.transaction()
    else
      :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      classify_postgrex_error(e)
  end

  def update_pur_invoice_multi(multi, pur_invoice, attrs, com, user) do
    update_doc_multi(
      multi,
      :update_pur_invoice,
      PurInvoice,
      pur_invoice,
      pur_invoice.pur_invoice_no,
      attrs,
      com,
      user,
      @pur_invoice_txn_opts
    )
  end
end
