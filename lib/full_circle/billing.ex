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

  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.{Repo, Sys, Accounting, StdInterface}
  alias Ecto.Multi

  def get_invoice_by_invoice_no!(inv_no, com, user) do
    id =
      Repo.one(
        from inv in Invoice,
          join: com in subquery(Sys.user_company(com, user)),
          on: com.id == inv.company_id,
          where: inv.invoice_no == ^inv_no,
          select: inv.id
      )

    get_invoice!(id, com, user)
  end

  def get_print_invoices!(ids, company, user) do
    Repo.all(
      from inv in Invoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: invd in InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id in ^ids,
        preload: [contact: cont, invoice_details: ^print_invoice_details()],
        group_by: [inv.id, inv.invoice_no, inv.descriptions, cont.id],
        order_by: inv.invoice_no,
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          invoice_tax_amount:
            sum((invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate),
          invoice_good_amount: sum(invd.quantity * invd.unit_price + invd.discount),
          invoice_amount:
            sum(
              invd.quantity * invd.unit_price + invd.discount +
                (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate
            )
        }
    )
  end

  defp print_invoice_details do
    from invd in InvoiceDetail,
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
        unit: good.unit,
        good_name: good.name,
        account_name: ac.name,
        package_name: pkg.name,
        tax_code: tc.code,
        tax_rate: tc.rate * 100,
        tax_amount: (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate,
        good_amount: invd.quantity * invd.unit_price + invd.discount,
        amount:
          invd.quantity * invd.unit_price + invd.discount +
            (invd.quantity * invd.unit_price + invd.discount) * invd.tax_rate
      }
  end

  def get_invoice!(id, company, user) do
    Repo.one(
      from inv in Invoice,
        join: com in subquery(Sys.user_company(company, user)),
        on: com.id == inv.company_id,
        join: invd in InvoiceDetail,
        on: invd.invoice_id == inv.id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id == ^id,
        preload: [invoice_details: ^invoice_details()],
        group_by: [inv.id, inv.invoice_no, inv.descriptions, cont.name, inv.tags, cont.id],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id
        }
    )
  end

  defp invoice_details do
    from invd in InvoiceDetail,
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
    qry =
      from(inv in subquery(invoice_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:invoice_no, :contact_name, :particulars], terms)
      else
        qry
      end

    qry =
      case bal do
        "Paid" -> from inv in qry, where: inv.balance == 0
        "Unpaid" -> from inv in qry, where: inv.balance > 0
        _ -> qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.invoice_date >= ^date_from, order_by: inv.invoice_date
      else
        qry
      end

    qry =
      if due_date_from != "" do
        from inv in qry, where: inv.due_date >= ^due_date_from, order_by: inv.due_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_invoice_by_id_index_component_field!(id, com, user) do
    from(i in subquery(invoice_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp invoice_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "invoices",
      join: acc in Account,
      on: acc.id == txn.account_id and acc.name == "Account Receivables",
      join: cont in Contact,
      on: cont.id == txn.contact_id,
      left_join: inv in Invoice,
      on:
        txn.doc_no == inv.invoice_no and
          txn.contact_id == inv.contact_id,
      left_join: invd in InvoiceDetail,
      on: inv.id == invd.invoice_id,
      left_join: stxm in SeedTransactionMatcher,
      on: stxm.transaction_id == txn.id,
      left_join: atxm in TransactionMatcher,
      on: atxm.transaction_id == txn.id,
      order_by: [desc: txn.inserted_at],
      select: %{
        id: coalesce(inv.id, txn.id),
        invoice_no: txn.doc_no,
        particulars: coalesce(txn.contact_particulars, txn.particulars),
        invoice_date: txn.doc_date,
        due_date: coalesce(inv.due_date, txn.doc_date),
        updated_at: txn.inserted_at,
        company_id: com.id,
        contact_name: cont.name,
        invoice_amount:
          fragment(
            "abs(?)",
            coalesce(
              sum(
                invd.quantity * invd.unit_price + invd.discount +
                  (invd.tax_rate * (invd.quantity * invd.unit_price) + invd.discount)
              ),
              txn.amount
            )
          ),
        balance:
          fragment(
            "abs(?)",
            coalesce(
              sum(
                invd.quantity * invd.unit_price + invd.discount +
                  (invd.tax_rate * (invd.quantity * invd.unit_price) + invd.discount)
              ),
              txn.amount
            ) + coalesce(sum(stxm.match_amount), 0) + coalesce(sum(atxm.match_amount), 0)
          ),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [inv.id, txn.id, cont.name, com.id]
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
    |> get_gapless_doc_id(gapless_name, "invoices", "INV", com)
    |> Multi.insert(
      invoice_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)
        StdInterface.changeset(Invoice, %Invoice{}, Map.merge(attrs, %{"invoice_no" => doc}), com)
      end
    )
    |> Multi.insert("#{invoice_name}_log", fn %{^invoice_name => entity} ->
      FullCircle.Sys.log_changeset(
        invoice_name,
        entity,
        Map.merge(attrs, %{"invoice_no" => entity.invoice_no}),
        com,
        user
      )
    end)
    |> create_invoice_transactions(invoice_name, com, user)
  end

  defp create_invoice_transactions(multi, name, com, user) do
    ac_rec_id = Accounting.get_account_by_name("Account Receivables", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => invoice} ->
      Enum.each(invoice.invoice_details, fn x ->
        x = FullCircle.Repo.preload(x, [:account, :tax_code])

        if !Decimal.eq?(x.good_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "invoices",
            doc_no: invoice.invoice_no,
            doc_date: invoice.invoice_date,
            contact_id:
              if(Accounting.is_balance_sheet_account?(x.account),
                do: invoice.contact_id,
                else: nil
              ),
            account_id: x.account_id,
            company_id: com.id,
            amount: Decimal.negate(x.good_amount),
            particulars: "#{invoice.contact_name}, #{x.good_name}"
          })
        end

        if !Decimal.eq?(x.tax_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "invoices",
            doc_no: invoice.invoice_no,
            doc_date: invoice.invoice_date,
            account_id: x.tax_code.account_id,
            company_id: com.id,
            amount: Decimal.negate(x.tax_amount),
            particulars: "#{x.tax_code_name} on #{x.good_name}"
          })
        end
      end)

      if !Decimal.eq?(invoice.invoice_amount, 0) do
        cont_part =
          Enum.map(invoice.invoice_details, fn x -> x.good_name end)
          |> Enum.join(", ")

        repo.insert!(%Transaction{
          doc_type: "invoices",
          doc_no: invoice.invoice_no,
          doc_date: invoice.invoice_date,
          contact_id: invoice.contact_id,
          account_id: ac_rec_id,
          company_id: com.id,
          amount: invoice.invoice_amount,
          particulars: invoice.contact_name,
          contact_particulars: cont_part
        })
      end

      {:ok, nil}
    end)
  end

  def update_invoice(%Invoice{} = invoice, attrs, com, user) do
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
    invoice_name = :update_invoice

    multi
    |> Multi.update(invoice_name, StdInterface.changeset(Invoice, invoice, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "invoices",
        where: txn.doc_no == ^invoice.invoice_no
      )
    )
    |> Sys.insert_log_for(invoice_name, attrs, com, user)
    |> create_invoice_transactions(invoice_name, com, user)
  end

  ########
  # Purchase Invocie
  ########

  def get_pur_invoice_by_pur_invoice_no!(inv_no, com, user) do
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
        join: invd in PurInvoiceDetail,
        on: invd.pur_invoice_id == inv.id,
        join: cont in Contact,
        on: cont.id == inv.contact_id,
        where: inv.id == ^id,
        preload: [pur_invoice_details: ^pur_invoice_details()],
        group_by: [
          inv.id,
          inv.pur_invoice_no,
          inv.supplier_invoice_no,
          inv.descriptions,
          cont.name,
          inv.tags,
          cont.id
        ],
        select: inv,
        select_merge: %{
          contact_name: cont.name,
          contact_id: cont.id
        }
    )
  end

  defp pur_invoice_details do
    from invd in PurInvoiceDetail,
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

  def pur_invoice_index_query(terms, date_from, due_date_from, bal, com, user,
        page: page,
        per_page: per_page
      ) do
    qry =
      from(inv in subquery(pur_invoice_raw_query(com, user)))

    qry =
      if terms != "" do
        from inv in subquery(qry),
          order_by: ^similarity_order([:pur_invoice_no, :contact_name, :particulars], terms)
      else
        qry
      end

    qry =
      case bal do
        "Paid" -> from inv in qry, where: inv.balance == 0
        "Unpaid" -> from inv in qry, where: inv.balance < 0
        _ -> qry
      end

    qry =
      if date_from != "" do
        from inv in qry, where: inv.pur_invoice_date >= ^date_from, order_by: inv.pur_invoice_date
      else
        qry
      end

    qry =
      if due_date_from != "" do
        from inv in qry, where: inv.due_date >= ^due_date_from, order_by: inv.due_date
      else
        qry
      end

    qry |> offset((^page - 1) * ^per_page) |> limit(^per_page) |> Repo.all()
  end

  def get_pur_invoice_by_id_index_component_field!(id, com, user) do
    from(i in subquery(pur_invoice_raw_query(com, user)),
      where: i.id == ^id
    )
    |> Repo.one!()
  end

  defp pur_invoice_raw_query(company, user) do
    from txn in Transaction,
      join: com in subquery(Sys.user_company(company, user)),
      on: com.id == txn.company_id and txn.doc_type == "pur_invoices",
      join: acc in Account,
      on: acc.id == txn.account_id and acc.name == "Account Payables",
      join: cont in Contact,
      on: cont.id == txn.contact_id,
      left_join: inv in PurInvoice,
      on:
        txn.doc_no == inv.pur_invoice_no and
          txn.contact_id == inv.contact_id,
      left_join: invd in PurInvoiceDetail,
      on: inv.id == invd.pur_invoice_id,
      left_join: stxm in SeedTransactionMatcher,
      on: stxm.transaction_id == txn.id,
      left_join: atxm in TransactionMatcher,
      on: atxm.transaction_id == txn.id,
      order_by: [desc: txn.inserted_at],
      select: %{
        id: coalesce(inv.id, txn.id),
        pur_invoice_no: txn.doc_no,
        particulars: coalesce(txn.contact_particulars, txn.particulars),
        pur_invoice_date: txn.doc_date,
        due_date: coalesce(inv.due_date, txn.doc_date),
        updated_at: txn.inserted_at,
        company_id: com.id,
        contact_name: cont.name,
        pur_invoice_amount:
          fragment(
            "abs(?)",
            coalesce(
              sum(
                invd.quantity * invd.unit_price + invd.discount +
                  (invd.tax_rate * (invd.quantity * invd.unit_price) + invd.discount)
              ),
              txn.amount
            )
          ),
        balance:
          fragment(
            "abs(?)",
            coalesce(
              sum(
                invd.quantity * invd.unit_price + invd.discount +
                  (invd.tax_rate * (invd.quantity * invd.unit_price) + invd.discount)
              ),
              txn.amount
            ) + coalesce(sum(stxm.match_amount), 0) + coalesce(sum(atxm.match_amount), 0)
          ),
        checked: false,
        old_data: txn.old_data
      },
      group_by: [inv.id, txn.id, cont.name, com.id]
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
    |> get_gapless_doc_id(gapless_name, "pur_invoices", "PINV", com)
    |> Multi.insert(
      pur_invoice_name,
      fn mty ->
        doc = Map.get(mty, gapless_name)

        StdInterface.changeset(
          PurInvoice,
          %PurInvoice{},
          Map.merge(attrs, %{"pur_invoice_no" => doc}),
          com
        )
      end
    )
    |> Multi.insert("#{pur_invoice_name}_log", fn %{^pur_invoice_name => entity} ->
      FullCircle.Sys.log_changeset(
        pur_invoice_name,
        entity,
        Map.merge(attrs, %{"pur_invoice_no" => entity.pur_invoice_no}),
        com,
        user
      )
    end)
    |> create_pur_invoice_transactions(pur_invoice_name, com, user)
  end

  defp create_pur_invoice_transactions(multi, name, com, user) do
    ac_rec_id = Accounting.get_account_by_name("Account Payables", com, user).id

    multi
    |> Ecto.Multi.run("create_transactions", fn repo, %{^name => pur_invoice} ->
      Enum.each(pur_invoice.pur_invoice_details, fn x ->
        x = FullCircle.Repo.preload(x, [:account, :tax_code])

        if !Decimal.eq?(x.good_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "pur_invoices",
            doc_no: pur_invoice.pur_invoice_no,
            doc_date: pur_invoice.pur_invoice_date,
            contact_id:
              if(Accounting.is_balance_sheet_account?(x.account),
                do: pur_invoice.contact_id,
                else: nil
              ),
            account_id: x.account_id,
            company_id: com.id,
            amount: x.good_amount,
            particulars: "#{pur_invoice.contact_name}, #{x.good_name}"
          })
        end

        if !Decimal.eq?(x.tax_amount, 0) do
          repo.insert!(%Transaction{
            doc_type: "pur_invoices",
            doc_no: pur_invoice.pur_invoice_no,
            doc_date: pur_invoice.pur_invoice_date,
            account_id: x.tax_code.account_id,
            company_id: com.id,
            amount: x.tax_amount,
            particulars: "#{x.tax_code_name} on #{x.good_name}"
          })
        end
      end)

      if !Decimal.eq?(pur_invoice.pur_invoice_amount, 0) do
        cont_part =
          Enum.map(pur_invoice.pur_invoice_details, fn x -> String.slice(x.good_name, 0..14) end)
          |> Enum.join(", ")

        repo.insert!(%Transaction{
          doc_type: "pur_invoices",
          doc_no: pur_invoice.pur_invoice_no,
          doc_date: pur_invoice.pur_invoice_date,
          contact_id: pur_invoice.contact_id,
          account_id: ac_rec_id,
          company_id: com.id,
          amount: Decimal.negate(pur_invoice.pur_invoice_amount),
          particulars: pur_invoice.contact_name,
          contact_particulars: cont_part
        })
      end

      {:ok, nil}
    end)
  end

  def update_pur_invoice(%PurInvoice{} = pur_invoice, attrs, com, user) do
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
    pur_invoice_name = :update_pur_invoice

    multi
    |> Multi.update(pur_invoice_name, StdInterface.changeset(PurInvoice, pur_invoice, attrs, com))
    |> Multi.delete_all(
      :delete_transaction,
      from(txn in Transaction,
        where: txn.doc_type == "pur_invoices",
        where: txn.doc_no == ^pur_invoice.pur_invoice_no
      )
    )
    |> Sys.insert_log_for(pur_invoice_name, attrs, com, user)
    |> create_pur_invoice_transactions(pur_invoice_name, com, user)
  end
end
