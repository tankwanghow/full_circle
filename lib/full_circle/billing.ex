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
    from(inv in subquery(invoice_transactions(com, user)))
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
    Repo.one!(
      from txn in Transaction,
        join: cont in Contact,
        on: cont.id == txn.contact_id,
        left_join: inv in Invoice,
        on: inv.id == txn.doc_id,
        left_join: stxm in SeedTransactionMatcher,
        on: stxm.transaction_id == txn.id,
        left_join: atxm in TransactionMatcher,
        on: atxm.transaction_id == txn.id,
        where: txn.company_id == ^com.id,
        where: txn.doc_type == "Invoice",
        where: txn.doc_id == ^id or (is_nil(txn.doc_id) and txn.id == ^id),
        group_by: [txn.id, cont.id, inv.id],
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
          balance:
            txn.amount + coalesce(sum(stxm.match_amount), 0) +
              coalesce(sum(atxm.match_amount), 0),
          checked: false,
          old_data: txn.old_data
        }
    )
  end

  defp invoice_transactions(company, _user) do
    from txn in Transaction,
      join: cont in Contact,
      on: cont.id == txn.contact_id,
      left_join: inv in Invoice,
      on: inv.id == txn.doc_id,
      left_join: stxm in SeedTransactionMatcher,
      on: stxm.transaction_id == txn.id,
      left_join: atxm in TransactionMatcher,
      on: atxm.transaction_id == txn.id,
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
        balance:
          txn.amount + coalesce(sum(stxm.match_amount), 0) + coalesce(sum(atxm.match_amount), 0),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [txn.id, cont.id, inv.id]
  end

  defp update_doc_multi(multi, step_name, schema, doc, doc_no, attrs, com, user, txn_opts) do
    doc_type = Keyword.fetch!(txn_opts, :doc_type)

    multi
    |> Multi.update(step_name, fn _ ->
      make_changeset(schema, doc, attrs, com, user)
    end)
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == ^doc_type,
        where: txn.doc_no == ^doc_no,
        where: txn.company_id == ^com.id
      )
    )
    |> Sys.insert_log_for(step_name, attrs, com, user)
    |> create_doc_transactions(step_name, com, user, txn_opts)
  end

  defp make_changeset(module, struct, attrs, com, user) do
    if user_role_in_company(user.id, com.id) == "admin" do
      StdInterface.changeset(module, struct, attrs, com, :admin_changeset)
    else
      StdInterface.changeset(module, struct, attrs, com)
    end
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

    multi
    |> Multi.insert_all(:create_transactions, Transaction, fn %{^name => doc} ->
      doc_no = Map.fetch!(doc, doc_no_key)
      doc_date = Map.fetch!(doc, doc_date_key)
      doc_amount = Map.fetch!(doc, amount_key)
      details = Map.fetch!(doc, detail_key)

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
               inserted_at: Timex.now() |> DateTime.truncate(:second)
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
               inserted_at: Timex.now() |> DateTime.truncate(:second)
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
               inserted_at: Timex.now() |> DateTime.truncate(:second)
             }
           end
         ])
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
    end)
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

    case can?(user, :update_invoice, com) do
      true ->
        Multi.new()
        |> update_invoice_multi(invoice, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_invoice_multi(multi, invoice, attrs, com, user) do
    update_doc_multi(multi, :update_invoice, Invoice, invoice, invoice.invoice_no,
      attrs, com, user, @invoice_txn_opts)
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
    from(inv in subquery(pur_invoice_transactions(com, user)))
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
    Repo.one!(
      from txn in Transaction,
        join: cont in Contact,
        on: cont.id == txn.contact_id,
        left_join: inv in PurInvoice,
        on: txn.doc_id == inv.id,
        left_join: stxm in SeedTransactionMatcher,
        on: stxm.transaction_id == txn.id,
        left_join: atxm in TransactionMatcher,
        on: atxm.transaction_id == txn.id,
        where: txn.company_id == ^com.id,
        where: txn.doc_type == "PurInvoice",
        where: txn.doc_id == ^id or (is_nil(txn.doc_id) and txn.id == ^id),
        group_by: [txn.id, cont.id, inv.id],
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
          balance:
            txn.amount + coalesce(sum(stxm.match_amount), 0) +
              coalesce(sum(atxm.match_amount), 0),
          checked: false,
          old_data: txn.old_data
        }
    )
  end

  defp pur_invoice_transactions(company, _user) do
    from txn in Transaction,
      join: cont in Contact,
      on: cont.id == txn.contact_id,
      left_join: inv in PurInvoice,
      on: txn.doc_id == inv.id,
      left_join: stxm in SeedTransactionMatcher,
      on: stxm.transaction_id == txn.id,
      left_join: atxm in TransactionMatcher,
      on: atxm.transaction_id == txn.id,
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
        balance:
          txn.amount + coalesce(sum(stxm.match_amount), 0) + coalesce(sum(atxm.match_amount), 0),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [txn.id, cont.id, inv.id]
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

    case can?(user, :update_pur_invoice, com) do
      true ->
        Multi.new()
        |> update_pur_invoice_multi(pur_invoice, attrs, com, user)
        |> Repo.transaction()

      false ->
        :not_authorise
    end
  rescue
    e in Postgrex.Error ->
      {:sql_error, e.postgres.message}
  end

  def update_pur_invoice_multi(multi, pur_invoice, attrs, com, user) do
    update_doc_multi(multi, :update_pur_invoice, PurInvoice, pur_invoice,
      pur_invoice.pur_invoice_no, attrs, com, user, @pur_invoice_txn_opts)
  end
end
